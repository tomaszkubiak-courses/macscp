import AppKit
import RemoteCore
import SwiftUI

@MainActor
@Observable
final class RemoteEditManager {
    static let editorsKey = "editorsByExtension"
    static let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    private(set) var files: [EditedFile] = []
    @ObservationIgnored private var editor: RemoteEditor!
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var reportedFailures: Set<UUID> = []

    init(session: Session, id: String) {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSCP/edit/\(id)")
        editor = RemoteEditor(
            cacheRoot: cache, connect: session.connectTransfer,
            onConflict: { [weak self] path in await self?.askOverwrite(path) ?? false },
            onChange: { [weak self] files in Task { @MainActor in self?.changed(files) } })
    }

    var hasPendingUploads: Bool { files.contains { $0.state == .pending || $0.state == .uploading } }

    func edit(_ paths: [String], with app: URL?) {
        var editors = UserDefaults.standard.dictionary(forKey: Self.editorsKey) as? [String: String] ?? [:]
        for path in paths {
            let ext = (path as NSString).pathExtension.lowercased()
            if let app { editors[ext] = app.path }
            let chosen = app ?? editors[ext].map { URL(fileURLWithPath: $0) } ?? Self.textEdit
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

    func stop(_ id: UUID) { Task { await editor.stop(id) } }

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
                        Text(status(f)).font(.caption).foregroundStyle(color(f))
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

    private func status(_ f: EditedFile) -> String {
        switch f.state {
        case .synced: f.lastUpload.map { String(localized: "Uploaded \($0.formatted(date: .omitted, time: .shortened))") }
            ?? String(localized: "Opened")
        case .pending: String(localized: "Changed")
        case .uploading: String(localized: "Uploading…")
        case .conflict: String(localized: "Server version kept")
        case .failed: String(localized: "Upload failed")
        }
    }

    private func color(_ f: EditedFile) -> Color {
        switch f.state {
        case .failed, .conflict: .red
        case .pending, .uploading: .orange
        default: .secondary
        }
    }
}
