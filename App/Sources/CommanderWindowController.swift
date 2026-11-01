import AppKit
import RemoteCore
import SwiftUI

@MainActor
final class CommanderWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: Session
    let transferDelegate: UITransferDelegate
    let local: FilePaneViewController
    let remote: FilePaneViewController
    let queueView = QueueViewController()
    private(set) var edits: RemoteEditManager!
    private(set) lazy var promiseDelegate = PromiseDelegate(commander: self)
    private var queueItems: [QueueItem] = []
    private var finished: Set<UUID> = []
    private(set) weak var activePane: FilePaneViewController?
    private let outerSplit = NSSplitViewController()
    private let statusLabel = NSTextField(labelWithString: "")
    private var closing = false

    let sessionID = UUID().uuidString

    init(session: Session, transferDelegate: UITransferDelegate) {
        self.session = session
        self.transferDelegate = transferDelegate
        local = FilePaneViewController(source: LocalSource())
        remote = FilePaneViewController(source: RemoteSource(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "MacSCPCommander"
        super.init(window: window)
        window.delegate = self
        transferDelegate.window = window
        edits = RemoteEditManager(session: session, id: sessionID)
        edits.window = window
        local.commander = self
        remote.commander = self
        queueView.commander = self
        buildLayout()
        let site = session.site
        window.title = site.name.isEmpty ? site.host : site.name
        window.subtitle = "\(site.fileProtocol.rawValue.uppercased()) · \(site.user.isEmpty ? "" : site.user + "@")\(site.host)"
        window.setFrameAutosaveName("Commander")
        if window.frame.width < 600 { window.center() }
        local.start(at: site.localDirectory)
        remote.start(at: site.remoteDirectory)
        Task { [weak self] in
            await session.queue.observe { items in
                Task { @MainActor in self?.queueChanged(items) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        let panes = NSSplitViewController()
        panes.splitView.isVertical = true
        panes.splitView.dividerStyle = .thin
        panes.splitView.autosaveName = "CommanderPanes"
        panes.addSplitViewItem(NSSplitViewItem(viewController: local))
        panes.addSplitViewItem(NSSplitViewItem(viewController: remote))

        outerSplit.splitView.isVertical = false
        outerSplit.splitView.dividerStyle = .thin
        outerSplit.splitView.autosaveName = "CommanderQueue"
        outerSplit.addSplitViewItem(NSSplitViewItem(viewController: panes))
        let q = NSSplitViewItem(viewController: queueView)
        q.canCollapse = true
        q.minimumThickness = 90
        q.maximumThickness = 400
        q.holdingPriority = .init(260)

        q.isCollapsed = true
        outerSplit.addSplitViewItem(q)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        let root = NSViewController()
        let status = NSStackView(views: [statusLabel])
        status.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        root.view = NSView()
        root.view.pinVertically([outerSplit.view, status], flexible: outerSplit.view)
        root.addChild(outerSplit)
        root.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        window?.contentViewController = root
        window?.toolbar = makeToolbar()
        window?.toolbarStyle = .unified
        updateStatus()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)

        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames CommanderPanes") == nil,
           let split = (outerSplit.splitViewItems[0].viewController as? NSSplitViewController)?.splitView {
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        }
        window?.makeFirstResponder(remote.table)
    }

    var hasActiveWork: Bool {
        queueItems.contains { $0.state == .queued || $0.state == .running } || edits.hasPendingUploads
    }

    func activate(_ pane: FilePaneViewController) {
        activePane = pane
        local.setActive(pane === local)
        remote.setActive(pane === remote)
    }

    func other(_ pane: FilePaneViewController) -> FilePaneViewController { pane === local ? remote : local }

    func paneDidNavigate(_ pane: FilePaneViewController) {}

    @objc func switchPane(_ sender: Any?) {
        window?.makeFirstResponder(other(activePane ?? local).table)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Preferences.showHidden), forKey: Preferences.showHidden)
        for p in [local, remote] { p.applyFilterAndSort(selecting: Set(p.selectedItems.map(\.name))) }
    }

    @objc func toggleQueue(_ sender: Any?) {
        let item = outerSplit.splitViewItems[1]
        item.animator().isCollapsed.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleHiddenFiles(_:)): item.state = UserDefaults.standard.bool(forKey: Preferences.showHidden) ? .on : .off
        case #selector(toggleQueue(_:)): item.state = outerSplit.splitViewItems[1].isCollapsed ? .off : .on
        default: break
        }
        return true
    }

    @objc func openInTerminal(_ sender: Any?) {
        let s = session.site
        var args = ["ssh"]
        if let port = s.port { args += ["-p", String(port)] }
        if let key = s.privateKeyPath, !key.isEmpty { args += ["-i", key] }
        args.append(s.user.isEmpty ? s.host : "\(s.user)@\(s.host)")
        args += ["-t", "cd \(RemotePath.shellQuote(remote.path)) && exec \"$SHELL\" -l"]
        let script = "#!/bin/sh\nexec " + args.map(RemotePath.shellQuote).joined(separator: " ") + "\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacSCP-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Task { await Alerts.error(error, in: window) }
        }
    }

    func transfer(_ paths: [String], from pane: FilePaneViewController) {
        let direction: TransferDirection = pane.isRemote ? .download : .upload
        let target = other(pane).path
        let sheet = NSHostingController(rootView: TransferSheet(
            direction: direction, count: paths.count, first: (paths.first as NSString?)?.lastPathComponent ?? "",
            target: target, options: Preferences.options,
            done: { [weak self] result in
                guard let self, let sheetWindow = self.window?.attachedSheet else { return }
                self.window?.endSheet(sheetWindow)
                if let (target, options) = result {
                    self.enqueue(TransferRequest(direction: direction, sources: paths, targetDirectory: target, options: options))
                }
            }))
        window?.contentViewController?.presentAsSheet(sheet)
    }

    func enqueue(_ request: TransferRequest) {
        guard !request.sources.isEmpty else { return }
        Task { await session.queue.add(request) }
        if outerSplit.splitViewItems[1].isCollapsed { toggleQueue(nil) }
    }

    func cancel(_ id: UUID) { Task { await session.queue.cancel(id) } }
    func clearFinished() { Task { await session.queue.clearFinished() } }

    private func queueChanged(_ items: [QueueItem]) {
        queueItems = items
        queueView.update(items)

        for item in items where item.state != .queued && item.state != .running && !finished.contains(item.id) {
            finished.insert(item.id)
            let pane = item.request.direction == .upload ? remote : local
            if pane.path == item.request.targetDirectory { pane.refresh(nil) }
            if case .failed(let message) = item.state {
                Task { await Alerts.error(RemoteError(.failure, message), in: window) }
            }
        }
        updateStatus()
    }

    private func updateStatus() {
        let running = queueItems.filter { $0.state == .running || $0.state == .queued }.count
        statusLabel.stringValue = running == 0 ? String(localized: "Connected")
            : String(localized: "\(running) transfers in progress")
    }

    func edit(_ paths: [String], with app: URL?) { edits.edit(paths, with: app) }

    @objc func showEditedFiles(_ sender: Any?) {
        let host = NSHostingController(rootView: EditedFilesView(manager: edits, close: { [weak self] in
            guard let self, let sheetWindow = self.window?.attachedSheet else { return }
            self.window?.endSheet(sheetWindow)
        }))
        window?.contentViewController?.presentAsSheet(host)
    }

    func showProperties(_ items: [PaneItem], in pane: FilePaneViewController) {
        let model = PropertiesModel(items: items, directory: pane.path, isRemote: pane.isRemote)
        let host = NSHostingController(rootView: PropertiesView(model: model, done: { [weak self, weak pane] apply in
            guard let self, let sheetWindow = self.window?.attachedSheet else { return }
            self.window?.endSheet(sheetWindow)
            guard apply, let pane else { return }
            Task {
                do {
                    try await model.apply(using: pane.source)
                } catch {
                    await Alerts.error(error, in: self.window)
                }
                pane.refresh(nil)
            }
        }))
        window?.contentViewController?.presentAsSheet(host)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasActiveWork, !closing else { return true }
        Task {
            if await Alerts.confirm(String(localized: "Transfers or uploads of edited files are still running."),
                                    info: String(localized: "Closing the session cancels them."),
                                    action: String(localized: "Close"), in: window) {
                closing = true
                window?.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        closeSessionNow()
        AppDelegate.shared.closed(self)
    }

    func closeSessionNow() {
        let s = session
        let e = edits!
        Task {
            await e.stopAll()
            await s.close()
        }
    }
}

final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private weak var commander: CommanderWindowController?
    @MainActor init(commander: CommanderWindowController) { self.commander = commander }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? RemoteFilePromise.Info)?.name ?? "download"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable (Error?) -> Void) {
        guard let info = provider.userInfo as? RemoteFilePromise.Info else { return completionHandler(nil) }
        let path = info.path
        Task { @MainActor [weak commander] in
            guard let session = commander?.session else { return completionHandler(RemoteError(.connection, "Session closed.")) }
            let id = await session.queue.add(TransferRequest(direction: .download, sources: [path],
                                                            targetDirectory: url.deletingLastPathComponent().path,
                                                            options: Preferences.options))
            await session.queue.wait(for: id)
            let state = await session.queue.item(id)?.state
            if case .failed(let m) = state { completionHandler(RemoteError(.failure, m)) } else { completionHandler(nil) }
        }
    }
}

extension CommanderWindowController: NSToolbarDelegate {
    nonisolated(unsafe) private static let items: [(String, String, String, Selector)] = [
        ("transfer", "Copy", "doc.on.doc", #selector(FilePaneViewController.transferSelection(_:))),
        ("edit", "Edit", "pencil", #selector(FilePaneViewController.editSelection(_:))),
        ("newFolder", "New Folder", "folder.badge.plus", #selector(FilePaneViewController.newFolder(_:))),
        ("delete", "Delete", "trash", #selector(FilePaneViewController.deleteSelection(_:))),
        ("info", "Get Info", "info.circle", #selector(FilePaneViewController.getInfo(_:))),
        ("refresh", "Refresh", "arrow.clockwise", #selector(FilePaneViewController.refresh(_:))),
        ("hidden", "Hidden Files", "eye", #selector(CommanderWindowController.toggleHiddenFiles(_:))),
        ("queue", "Queue", "list.bullet.rectangle", #selector(CommanderWindowController.toggleQueue(_:))),
        ("terminal", "Terminal", "terminal", #selector(CommanderWindowController.openInTerminal(_:))),
        ("edited", "Edited Files", "square.and.pencil", #selector(CommanderWindowController.showEditedFiles(_:))),
    ]

    fileprivate func makeToolbar() -> NSToolbar {
        let t = NSToolbar(identifier: "Commander")
        t.delegate = self
        t.displayMode = .iconOnly
        t.allowsUserCustomization = true
        t.autosavesConfiguration = true
        return t
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["transfer", "edit", "newFolder", "delete", "info", NSToolbarItem.Identifier.flexibleSpace.rawValue,
         "hidden", "refresh", "queue", "edited", "terminal"].map { NSToolbarItem.Identifier($0) }
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items.map { NSToolbarItem.Identifier($0.0) } + [.flexibleSpace, .space]
    }

    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            guard let spec = Self.items.first(where: { $0.0 == id.rawValue }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = String(localized: String.LocalizationValue(spec.1))
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: spec.2, accessibilityDescription: item.label)
            item.action = spec.3
            item.isBordered = true
            return item
        }
    }
}
