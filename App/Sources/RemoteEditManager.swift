import AppKit
import RemoteCore
import SwiftUI

@MainActor
@Observable
final class RemoteEditManager {
    static let editorsKey = "editorsByExtension"

    private(set) var files: [EditedFile] = []
    @ObservationIgnored private var editor: RemoteEditor!
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var reportedFailures: Set<UUID> = []
    @ObservationIgnored private var editors: [URL: TextEditorWindowController] = [:]
    @ObservationIgnored private var closedEditors: Set<URL> = []
    @ObservationIgnored private let host: String

    init(session: Session, id: String) {
        host = session.site.host
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSCP/edit/\(id)")
        editor = RemoteEditor(
            cacheRoot: cache, connect: session.connectTransfer,
            onConflict: { [weak self] path in await self?.askOverwrite(path) ?? false },
            onChange: { [weak self] files in Task { @MainActor in self?.changed(files) } })
    }

    var hasPendingUploads: Bool { files.contains { $0.state == .pending || $0.state == .uploading } }

    var hasUnsavedEditors: Bool { editors.values.contains { $0.window?.isDocumentEdited == true } }

    func edit(_ paths: [String], with app: URL?, builtIn: Bool = false) {
        var editors = UserDefaults.standard.dictionary(forKey: Self.editorsKey) as? [String: String] ?? [:]
        for path in paths {
            let ext = (path as NSString).pathExtension.lowercased()
            if let app { editors[ext] = app.path }
            if builtIn { editors[ext] = nil }
            guard let chosen = app ?? editors[ext].map({ URL(fileURLWithPath: $0) }) else {
                Task { await openInternal(path) }
                continue
            }
            Task {
                do {
                    let local = try await editor.open(path)
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    try await NSWorkspace.shared.open([local], withApplicationAt: chosen, configuration: config)
                } catch {
                    await Alerts.error(error, in: window)
                }
            }
        }
        UserDefaults.standard.set(editors, forKey: Self.editorsKey)
    }

    private func openInternal(_ path: String) async {
        do {
            let local = try await editor.open(path)
            if let open = editors[local] { return open.showWindow(nil) }
            let data = try Data(contentsOf: local)
            guard let file = TextFile.decode(data) else {
                await stopTracking(local)
                let a = NSAlert()
                a.messageText = String(localized: "“\((path as NSString).lastPathComponent)” is not a text file.")
                a.informativeText = String(localized: "Use Files › Edit With… to open it in another app.")
                _ = await Alerts.serialized { [window] in await Alerts.run(a, in: window) }
                return
            }
            if data.count > 20 << 20, !(await Alerts.confirm(
                String(localized: "“\((path as NSString).lastPathComponent)” is \(Format.size(Int64(data.count))).") ,
                info: String(localized: "Large files can make the editor slow."), action: String(localized: "Open"), in: window)) {
                await stopTracking(local)
                return
            }
            let controller = TextEditorWindowController(localURL: local, remotePath: path, file: file, host: host)
            controller.onClose = { [weak self] in self?.editorClosed(local) }
            editors[local] = controller
            closedEditors.remove(local)
            if let f = files.first(where: { $0.localURL == local }) { controller.setUploadStatus(f.statusText) }
            controller.showWindow(nil)
        } catch {
            await Alerts.error(error, in: window)
        }
    }

    private func stopTracking(_ local: URL) async {
        if let id = await editor.files.first(where: { $0.localURL == local })?.id { await editor.stop(id) }
    }

    private func editorClosed(_ local: URL) {
        editors[local] = nil
        if let f = files.first(where: { $0.localURL == local }), f.state == .synced {
            stop(f.id)
        } else {
            closedEditors.insert(local)
        }
    }

    func closeEditors() {
        for e in editors.values {
            e.window?.isDocumentEdited = false
            e.close()
        }
    }

    func stop(_ id: UUID) { Task { await editor.stop(id) } }

    #if DEBUG
    func debugInsertAndSave(_ text: String) { editors.values.first?.debugInsertAndSave(text) }
    #endif

    func confirmStop(_ f: EditedFile) {
        guard f.state != .synced else { return stop(f.id) }
        Task {
            if await Alerts.confirm(String(localized: "“\((f.remotePath as NSString).lastPathComponent)” has changes not on the server."),
                                    info: String(localized: "Stopping deletes the local copy and its changes."),
                                    action: String(localized: "Stop and Discard"), in: NSApp.keyWindow) {
                stop(f.id)
            }
        }
    }
    func retry(_ id: UUID) { Task { await editor.retry(id) } }
    func stopAll() async { await editor.stopAll() }

    private func changed(_ new: [EditedFile]) {
        files = new
        for f in new {
            editors[f.localURL]?.setUploadStatus(f.statusText)
            if f.state == .synced, closedEditors.contains(f.localURL) {
                closedEditors.remove(f.localURL)
                stop(f.id)
            }
            if case .failed(let m) = f.state, !reportedFailures.contains(f.id) {
                reportedFailures.insert(f.id)
                Task { await Alerts.error(RemoteError(.failure, "Upload of \(f.remotePath) failed: \(m)"), in: window) }
            } else if f.state == .synced {
                reportedFailures.remove(f.id)
            }
        }
    }

    private func askOverwrite(_ path: String) async -> Bool {
        await Alerts.serialized { [window] in
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = String(localized: "“\((path as NSString).lastPathComponent)” changed on the server since you opened it.")
            a.informativeText = String(localized: "Overwrite the server's version with yours?")
            a.addButton(withTitle: String(localized: "Overwrite"))
            a.addButton(withTitle: String(localized: "Keep Server Version"))
            return await Alerts.run(a, in: window) == .alertFirstButtonReturn
        }
    }
}

struct EditedFilesView: View {
    let manager: RemoteEditManager
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text("Edited Files").font(.headline)
            if manager.files.isEmpty {
                Text("No files are being edited. Choose Files > Edit on a remote file.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(manager.files) { f in
                    HStack {
                        VStack(alignment: .leading) {
                            Text((f.remotePath as NSString).lastPathComponent)
                            Text(f.remotePath).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(f.statusText).font(.caption).foregroundStyle(color(f))
                        if case .failed = f.state { Button("Retry") { manager.retry(f.id) } }
                        if f.state == .conflict { Button("Upload Anyway") { manager.retry(f.id) } }
                        Button("Stop") { manager.confirmStop(f) }.help("Stop tracking and delete the local copy")
                    }
                }
                .frame(minHeight: 160)
            }
            HStack { Spacer(); Button("Done") { close() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func color(_ f: EditedFile) -> Color {
        switch f.state {
        case .failed, .conflict: .red
        case .pending, .uploading: .orange
        default: .secondary
        }
    }
}

extension EditedFile {
    var statusText: String {
        switch state {
        case .synced: lastUpload.map { String(localized: "Uploaded \($0.formatted(date: .omitted, time: .shortened))") }
            ?? String(localized: "Opened")
        case .pending: String(localized: "Changed")
        case .uploading: String(localized: "Uploading…")
        case .conflict: String(localized: "Server version kept")
        case .failed: String(localized: "Upload failed")
        }
    }
}
