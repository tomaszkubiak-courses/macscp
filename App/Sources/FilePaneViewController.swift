import AppKit
import Quartz
import RemoteCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let macscpRemote = NSPasteboard.PasteboardType("io.github.tomaszkubiak-courses.MacSCP.remote-path")
}

@MainActor
final class FilePaneViewController: NSViewController, NSMenuItemValidation {
    let source: PaneSource
    weak var commander: CommanderWindowController?
    private(set) var path = ""
    private var items: [PaneItem] = []
    private(set) var visible: [PaneItem] = []
    private var back: [String] = [], forward: [String] = []
    private var loadTask: Task<Void, Never>?

    let table = PaneTableView()
    private let pathControl = NSPathControl()
    private let status = NSTextField(labelWithString: "")
    private let header = NSView()
    private let spinner = NSProgressIndicator()

    init(source: PaneSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isRemote: Bool { source.isRemote }

    override func loadView() {
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = tip
            return b
        }
        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.toolTip = String(localized: "Double-click to type a path")
        pathControl.doubleAction = #selector(goToFolder(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let bar = NSStackView(views: [
            button("chevron.left", String(localized: "Back"), #selector(goBack(_:))),
            button("chevron.right", String(localized: "Forward"), #selector(goForward(_:))),
            button("arrow.up", String(localized: "Enclosing Folder"), #selector(goUp(_:))),
            button("house", String(localized: "Home"), #selector(goHome(_:))),
            button("arrow.clockwise", String(localized: "Refresh"), #selector(refresh(_:))),
            pathControl, spinner,
        ])
        bar.spacing = 4
        bar.setHuggingPriority(.required, for: .vertical)
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        header.wantsLayer = true
        header.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: header.leadingAnchor), bar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bar.topAnchor.constraint(equalTo: header.topAnchor), bar.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        setUpTable()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let statusRow = NSStackView(views: [status])
        statusRow.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 4, right: 8)

        let root = NSView()
        root.pinVertically([header, scroll, statusRow], flexible: scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        view = root
        setActive(false)
    }

    private func setUpTable() {
        let columns: [(String, String, CGFloat)] = [
            ("name", String(localized: "Name"), 220), ("size", String(localized: "Size"), 80),
            ("modified", String(localized: "Modified"), 140), ("permissions", String(localized: "Permissions"), 90),
            ("owner", String(localized: "Owner"), 80),
        ]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autosaveName = isRemote ? "RemotePane" : "LocalPane"
        table.autosaveTableColumns = true
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection(_:))
        table.pane = self
        table.menu = contextMenu()
        table.setAccessibilityLabel(isRemote ? String(localized: "Remote files") : String(localized: "Local files"))
        pathControl.setAccessibilityLabel(isRemote ? String(localized: "Remote folder") : String(localized: "Local folder"))
        table.registerForDraggedTypes([.fileURL, .macscpRemote])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
    }

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        let entries: [(String, Selector)] = [
            (String(localized: "Open"), #selector(openSelection(_:))),
            (String(localized: "Edit"), #selector(editSelection(_:))),
            (String(localized: "Edit With…"), #selector(editSelectionWith(_:))),
            (isRemote ? String(localized: "Download…") : String(localized: "Upload…"), #selector(transferSelection(_:))),
            (String(localized: "Rename…"), #selector(renameSelection(_:))),
            (isRemote ? String(localized: "Delete") : String(localized: "Move to Trash"), #selector(deleteSelection(_:))),
            (String(localized: "New Folder…"), #selector(newFolder(_:))),
            (String(localized: "Get Info"), #selector(getInfo(_:))),
        ]
        for (title, sel) in entries { m.addItem(withTitle: title, action: sel, keyEquivalent: "") }
        return m
    }

    func setActive(_ active: Bool) {
        header.layer?.backgroundColor = (active ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
                                         : NSColor.clear).cgColor
    }

    func start(at initial: String) {
        Task {
            var start = initial
            if start.isEmpty { start = (try? await source.home()) ?? "/" }
            navigate(to: start, record: false)
        }
    }

    func navigate(to target: String, record: Bool = true, select: String? = nil) {
        loadTask?.cancel()
        spinner.startAnimation(nil)
        loadTask = Task {
            defer { spinner.stopAnimation(nil) }
            do {
                let resolved = try await source.resolveDirectory(target)
                #if DEBUG
                let t0 = Date()
                #endif
                let listed = try await source.list(resolved)
                guard !Task.isCancelled else { return }
                #if DEBUG
                defer { NSLog("listed %d entries in %@ in %.2f s (with sort)", listed.count, resolved, Date().timeIntervalSince(t0)) }
                #endif
                if record, resolved != path, !path.isEmpty { back.append(path); forward.removeAll() }
                let selectedNames = resolved == path ? Set(selectedItems.map(\.name)) : Set(select.map { [$0] } ?? [])
                path = resolved
                items = listed
                applyFilterAndSort(selecting: selectedNames)
                pathControl.url = isRemote ? remoteURL(resolved) : URL(fileURLWithPath: resolved)
                commander?.paneDidNavigate(self)
            } catch {
                guard !Task.isCancelled else { return }
                await Alerts.error(error, in: view.window)
            }
        }
    }

    private func remoteURL(_ p: String) -> URL? {
        var c = URLComponents()
        c.scheme = "sftp"
        c.host = commander?.session.site.host
        c.path = p
        return c.url
    }

    func applyFilterAndSort(selecting names: Set<String> = []) {
        let showHidden = UserDefaults.standard.bool(forKey: Preferences.showHidden)
        var list = showHidden ? items : items.filter { !$0.isHidden }
        let sd = table.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        let asc = sd.ascending
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Bool { asc ? a < b : a > b }
        list.sort { a, b in

            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sd.key {
            case "size" where a.size != b.size: return cmp(a.size, b.size)
            case "modified" where a.modified != b.modified: return cmp(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case "permissions" where a.mode != b.mode: return cmp(a.mode, b.mode)
            case "owner" where a.owner != b.owner: return cmp(a.owner, b.owner)
            default:
                let r = a.name.localizedStandardCompare(b.name)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        }
        visible = list
        table.reloadData()
        let rows = IndexSet(visible.indices.filter { names.contains(visible[$0].name) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
        updateStatus()
    }

    private func updateStatus() {
        let sel = selectedItems
        let total = visible.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        let selSize = sel.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        status.stringValue = String(localized: "\(Format.size(selSize)) of \(Format.size(total)) in \(sel.count) of \(visible.count)")
    }

    var selectedItems: [PaneItem] { table.selectedRowIndexes.compactMap { $0 < visible.count ? visible[$0] : nil } }

    var targetItems: [PaneItem] {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked), clicked < visible.count { return [visible[clicked]] }
        return selectedItems
    }

    func fullPath(_ item: PaneItem) -> String { RemotePath.join(path, item.name) }

    @objc func pathClicked(_ sender: Any?) {
        guard let url = pathControl.clickedPathItem?.url else { return }
        navigate(to: url.path.isEmpty ? "/" : url.path)
    }

    @objc func goBack(_ sender: Any?) {
        guard let p = back.popLast() else { return }
        forward.append(path)
        navigate(to: p, record: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let p = forward.popLast() else { return }
        back.append(path)
        navigate(to: p, record: false)
    }

    @objc func goUp(_ sender: Any?) {
        guard path != "/" else { return }
        navigate(to: RemotePath.parent(path), select: RemotePath.name(path))
    }

    @objc func goHome(_ sender: Any?) {
        Task { if let h = try? await source.home() { navigate(to: h) } }
    }

    @objc func refresh(_ sender: Any?) { navigate(to: path, record: false) }

    @objc func goToFolder(_ sender: Any?) {
        Task {
            if let p = await Alerts.ask(String(localized: "Go to folder"), value: path, ok: String(localized: "Go"), in: view.window) {
                navigate(to: p.hasPrefix("/") || p.hasPrefix("~") ? p : RemotePath.join(path, p))
            }
        }
    }

    @objc func openSelection(_ sender: Any?) {
        let sel = targetItems
        if sel.count == 1, sel[0].isDirectory {
            navigate(to: fullPath(sel[0]))
        } else if !sel.isEmpty {
            if isRemote {
                commander?.edit(sel.filter { !$0.isDirectory }.map(fullPath), with: nil)
            } else {
                for i in sel { NSWorkspace.shared.open(URL(fileURLWithPath: fullPath(i))) }
            }
        }
    }

    @objc func editSelection(_ sender: Any?) {
        let files = targetItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        if isRemote {
            commander?.edit(files.map(fullPath), with: nil)
        } else {
            for f in files { NSWorkspace.shared.open(URL(fileURLWithPath: fullPath(f))) }
        }
    }

    @objc func editSelectionWith(_ sender: Any?) {
        let files = targetItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = String(localized: "Choose an editor")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        if isRemote {
            commander?.edit(files.map(fullPath), with: app)
        } else {
            NSWorkspace.shared.open(files.map { URL(fileURLWithPath: fullPath($0)) }, withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func transferSelection(_ sender: Any?) {
        let sel = targetItems
        guard !sel.isEmpty else { return }
        commander?.transfer(sel.map(fullPath), from: self)
    }

    @objc func renameSelection(_ sender: Any?) {
        guard let item = targetItems.first else { return }
        Task {
            guard let name = await Alerts.ask(String(localized: "Rename “\(item.name)”"), value: item.name,
                                              ok: String(localized: "Rename"), in: view.window),
                  !name.isEmpty, name != item.name else { return }

            if visible.contains(where: { $0.name == name }) || items.contains(where: { $0.name == name }) {
                guard await Alerts.confirm(String(localized: "“\(name)” already exists. Replace it?"),
                                           info: String(localized: "The existing item is overwritten."),
                                           action: String(localized: "Replace"), in: view.window) else { return }
            }
            do {
                let target = name.hasPrefix("/") ? name : RemotePath.join(path, name)
                try await source.rename(fullPath(item), to: target)
                navigate(to: path, record: false, select: name)
            } catch { await Alerts.error(error, in: view.window) }
        }
    }

    @objc func deleteSelection(_ sender: Any?) {
        let sel = targetItems
        guard !sel.isEmpty else { return }
        Task {
            let what = sel.count == 1 ? "“\(sel[0].name)”" : String(localized: "\(sel.count) items")
            if UserDefaults.standard.bool(forKey: Preferences.confirmDelete) {
                let ok = isRemote
                    ? await Alerts.confirm(String(localized: "Delete \(what)?"),
                                           info: String(localized: "Remote files are deleted permanently."),
                                           action: String(localized: "Delete"), in: view.window)
                    : await Alerts.confirm(String(localized: "Move \(what) to the Trash?"), info: "",
                                           action: String(localized: "Move to Trash"), in: view.window)
                guard ok else { return }
            }
            for item in sel {
                do {
                    try await source.delete(fullPath(item), isDirectory: item.isDirectory && !item.isLink)
                } catch {
                    await Alerts.error(error, in: view.window)
                    break
                }
            }
            refresh(nil)
        }
    }

    @objc func newFolder(_ sender: Any?) {
        Task {
            guard let name = await Alerts.ask(String(localized: "New folder"), value: String(localized: "untitled folder"),
                                              ok: String(localized: "Create"), in: view.window), !name.isEmpty else { return }
            do {
                try await source.makeDirectory(RemotePath.join(path, name))
                navigate(to: path, record: false, select: name)
            } catch { await Alerts.error(error, in: view.window) }
        }
    }

    @objc func getInfo(_ sender: Any?) {
        let sel = targetItems
        guard !sel.isEmpty else { return }
        commander?.showProperties(sel, in: self)
    }

    @objc func quickLook(_ sender: Any?) {
        guard !isRemote, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return !back.isEmpty
        case #selector(goForward(_:)): return !forward.isEmpty
        case #selector(quickLook(_:)): return !isRemote && !selectedItems.isEmpty
        case #selector(openSelection(_:)), #selector(transferSelection(_:)), #selector(renameSelection(_:)),
             #selector(deleteSelection(_:)), #selector(getInfo(_:)):
            return !targetItems.isEmpty
        case #selector(editSelection(_:)), #selector(editSelectionWith(_:)):
            return targetItems.contains { !$0.isDirectory }
        default: return true
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !isRemote }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

extension FilePaneViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { selectedItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { URL(fileURLWithPath: fullPath(selectedItems[index])) as NSURL }
    }
}

extension FilePaneViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier, row < visible.count else { return nil }
        let item = visible[row]
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingMiddle
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            var leading = t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2)
            if id.rawValue == "name" {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(iv)
                c.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                ])
                leading = t.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4)
            }
            NSLayoutConstraint.activate([
                leading, t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let t = cell.textField!
        t.alignment = .left
        t.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
        switch id.rawValue {
        case "name":
            t.stringValue = item.name
            cell.imageView?.image = Icons.icon(for: item)
            cell.imageView?.alphaValue = item.isHidden ? 0.5 : 1
        case "size":
            t.stringValue = item.isDirectory ? "" : Format.size(item.size)
            t.alignment = .right
        case "modified": t.stringValue = Format.date(item.modified)
        case "permissions":
            t.stringValue = item.hasMode ? (item.isLink ? "l" : item.isDirectory ? "d" : "-") + Permissions(item.mode).text : ""
            t.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        case "owner": t.stringValue = item.owner
        default: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilterAndSort(selecting: Set(selectedItems.map(\.name)))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        if let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self { panel.reloadData() }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == "name" ? visible[row].name : nil
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = visible[row]
        let full = fullPath(item)
        if !isRemote { return URL(fileURLWithPath: full) as NSURL }
        guard let commander else { return nil }
        let type: UTType = item.isDirectory ? .folder : UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        let provider = RemoteFilePromise(fileType: type.identifier, delegate: commander.promiseDelegate)
        provider.userInfo = RemoteFilePromise.Info(sessionID: commander.sessionID, path: full, name: item.name)
        return provider
    }

    private func dropDirectory(_ row: Int, _ op: NSTableView.DropOperation) -> String {
        if op == .on, row >= 0, row < visible.count, visible[row].isDirectory { return fullPath(visible[row]) }
        return path
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on, row < visible.count, !visible[row].isDirectory { tableView.setDropRow(-1, dropOperation: .on) }
        let pb = info.draggingPasteboard
        if isRemote {
            return info.draggingSource as? NSTableView === table ? [] : pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
        }

        guard let s = pb.string(forType: .macscpRemote), s.hasPrefix(commander?.sessionID ?? "-") else { return [] }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        let target = dropDirectory(row, op)
        let pb = info.draggingPasteboard
        if isRemote {
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            commander?.enqueue(TransferRequest(direction: .upload, sources: urls.map(\.path), targetDirectory: target,
                                               options: Preferences.options))
            return !urls.isEmpty
        }
        let paths = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .macscpRemote) }
            .map { String($0.split(separator: "\n", maxSplits: 1).last ?? "") }
        commander?.enqueue(TransferRequest(direction: .download, sources: paths, targetDirectory: target,
                                           options: Preferences.options))
        return !paths.isEmpty
    }
}

@MainActor
final class PaneTableView: NSTableView {
    weak var pane: FilePaneViewController?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let pane { pane.commander?.activate(pane) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        guard let pane else { return super.keyDown(with: event) }
        let commanderKeys = UserDefaults.standard.bool(forKey: Preferences.commanderKeys)
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch (event.keyCode, plain) {
        case (36, true), (76, true): pane.openSelection(nil)
        case (48, _): pane.commander?.switchPane(nil)
        case (49, true): pane.quickLook(nil)
        case (51, true): pane.goUp(nil)
        case (120, true) where commanderKeys: pane.renameSelection(nil)
        case (118, true) where commanderKeys: pane.editSelection(nil)
        case (96, true) where commanderKeys: pane.transferSelection(nil)
        case (98, true) where commanderKeys: pane.newFolder(nil)
        case (100, true) where commanderKeys: pane.deleteSelection(nil)
        default: super.keyDown(with: event)
        }
    }
}

final class RemoteFilePromise: NSFilePromiseProvider {
    struct Info { let sessionID: String; let path: String; let name: String }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.macscpRemote]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .macscpRemote, let info = userInfo as? Info { return info.sessionID + "\n" + info.path }
        return super.pasteboardPropertyList(forType: type)
    }
}
