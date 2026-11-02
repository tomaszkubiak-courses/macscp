import AppKit
import RemoteCore
import SwiftUI

@MainActor
@Observable
final class SyncModel {
    enum Phase { case setup, comparing, preview, applying, done }

    struct Row: Identifiable {
        let action: SyncAction
        var checked = true
        var id: UUID { action.id }
    }

    static let optionsKey = "syncOptions"

    var localDir: String
    var remoteDir: String
    var options: SyncOptions
    var phase = Phase.setup
    var rows: [Row] = []
    var progress = SyncProgress()
    var message = ""
    var failed = false

    @ObservationIgnored private let session: Session
    @ObservationIgnored private var synchronizer: Synchronizer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onFinish: () -> Void = {}

    init(session: Session, localDir: String, remoteDir: String) {
        self.session = session
        self.localDir = localDir
        self.remoteDir = remoteDir
        if let d = UserDefaults.standard.data(forKey: Self.optionsKey), let o = try? JSONDecoder().decode(SyncOptions.self, from: d) {
            options = o
        } else {
            options = SyncOptions()
            options.transfer = Preferences.options
        }
    }

    var isBusy: Bool { phase == .comparing || phase == .applying }
    var checkedCount: Int { rows.filter(\.checked).count }
    var deletions: Int { rows.filter { $0.checked && ($0.action.kind == .deleteLocal || $0.action.kind == .deleteRemote) }.count }

    private func engine() async throws -> Synchronizer {
        if let synchronizer { return synchronizer }
        let s = Synchronizer(fs: try await session.connectTransfer(), reconnect: session.connectTransfer)
        synchronizer = s
        return s
    }

    func compare() {
        UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: Self.optionsKey)
        phase = .comparing
        failed = false
        let (local, remote, options) = (localDir, remoteDir, options)
        task = Task {
            do {
                let actions = try await engine().compare(local: local, remote: remote, options: options)
                rows = actions.map { Row(action: $0) }
                if rows.isEmpty {
                    message = String(localized: "The folders are already in sync.")
                    phase = .done
                } else {
                    phase = .preview
                }
            } catch {
                fail(error)
            }
        }
    }

    func apply() {
        let actions = rows.filter(\.checked).map(\.action)
        progress = SyncProgress(totalActions: actions.count)
        phase = .applying
        let options = options
        task = Task {
            do {
                try await engine().apply(actions, options: options) { p in
                    Task { @MainActor in self.progress = p }
                }
                message = String(localized: "Synchronized \(actions.count) items.")
                phase = .done
            } catch {
                fail(error)
            }
            onFinish()
        }
    }

    private func fail(_ error: Error) {
        failed = true
        message = (error as? RemoteError)?.kind == .cancelled || error is CancellationError
            ? String(localized: "Synchronization cancelled.") : "\(error)"
        phase = .done
    }

    func cancel() { task?.cancel() }

    func close() {
        task?.cancel()
        let s = synchronizer
        synchronizer = nil
        Task { await s?.fs.disconnect() }
    }

    func chooseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: localDir)
        if panel.runModal() == .OK, let url = panel.url { localDir = url.path }
    }
}

struct SynchronizeSheet: View {
    @Bindable var model: SyncModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .setup, .comparing: setup
            case .preview: preview
            case .applying: applying
            case .done: done
            }
        }
        .padding(20)
        .frame(width: 640)
        .frame(minHeight: 420)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synchronize").font(.headline)
            Form {
                Section("Folders") {
                    HStack {
                        TextField("Local folder", text: $model.localDir)
                        Button("Choose…") { model.chooseLocal() }
                    }
                    TextField("Remote folder", text: $model.remoteDir)
                }
                Section("Direction") {
                    Picker("Direction", selection: $model.options.direction) {
                        Text("Local → Remote").tag(SyncOptions.Direction.toRemote)
                        Text("Remote → Local").tag(SyncOptions.Direction.toLocal)
                        Text("Both").tag(SyncOptions.Direction.both)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("Options") {
                    Toggle("Mirror files (overwrite when times differ either way)", isOn: $model.options.mirror)
                        .disabled(model.options.direction == .both)
                    Toggle("Delete files that are not in the source", isOn: $model.options.deleteExtra)
                        .disabled(model.options.direction == .both)
                    Toggle("Existing files only", isOn: $model.options.existingOnly)
                    Toggle("Compare by time", isOn: $model.options.byTime)
                    Toggle("Compare by size", isOn: $model.options.bySize)
                        .disabled(model.options.direction == .both)
                    Toggle("Compare contents by checksum (SFTP and SCP)", isOn: $model.options.byChecksum)
                    Toggle("Synchronize timestamps only (no file transfers)", isOn: $model.options.timestampsOnly)
                    TextField("File mask", text: $model.options.transfer.includeMask, prompt: Text("| .git/; *.tmp"))
                    Toggle("Exclude hidden files", isOn: $model.options.transfer.excludeHiddenFiles)
                }
            }
            .formStyle(.grouped)
            HStack {
                if model.phase == .comparing {
                    ProgressView().controlSize(.small)
                    Text("Comparing…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    model.close()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Compare") { model.compare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase == .comparing || model.localDir.isEmpty || model.remoteDir.isEmpty)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.rows.count) changes found").font(.headline)
            if model.deletions > 0 {
                Label("\(model.deletions) items will be deleted.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            List($model.rows) { $row in
                HStack {
                    Toggle("", isOn: $row.checked).labelsHidden()
                    Image(systemName: icon(row.action.kind)).foregroundStyle(color(row.action.kind)).frame(width: 18)
                    VStack(alignment: .leading) {
                        Text(relative(row.action)).lineLimit(1).truncationMode(.middle)
                        Text(detail(row.action)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Button("All") { for i in model.rows.indices { model.rows[i].checked = true } }
                Button("None") { for i in model.rows.indices { model.rows[i].checked = false } }
                Spacer()
                Button("Back") { model.phase = .setup }
                Button("Synchronize \(model.checkedCount)") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checkedCount == 0)
            }
        }
    }

    private var applying: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synchronizing…").font(.headline)
            ProgressView(value: Double(model.progress.doneActions), total: Double(max(model.progress.totalActions, 1)))
            Text("\(model.progress.doneActions) of \(model.progress.totalActions)").foregroundStyle(.secondary)
            Text(model.progress.current).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            HStack { Spacer(); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.message, systemImage: model.failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(model.failed ? .red : .green)
                .textSelection(.enabled)
            Spacer()
            HStack {
                Spacer()
                if model.failed { Button("Back") { model.phase = .setup } }
                Button("Close") {
                    model.close()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func relative(_ a: SyncAction) -> String {
        let (path, base) = a.isDownload || a.kind == .deleteLocal || a.kind == .setLocalTime
            ? (a.localPath, model.localDir) : (a.remotePath, model.remoteDir)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func icon(_ k: SyncAction.Kind) -> String {
        switch k {
        case .uploadNew, .uploadUpdate: "arrow.up.circle"
        case .downloadNew, .downloadUpdate: "arrow.down.circle"
        case .deleteRemote, .deleteLocal: "trash"
        case .setRemoteTime, .setLocalTime: "clock.arrow.circlepath"
        }
    }

    private func color(_ k: SyncAction.Kind) -> Color {
        k == .deleteLocal || k == .deleteRemote ? .red : .accentColor
    }

    private func detail(_ a: SyncAction) -> String {
        let what: String = switch a.kind {
        case .uploadNew: String(localized: "Upload new")
        case .uploadUpdate: String(localized: "Upload newer")
        case .downloadNew: String(localized: "Download new")
        case .downloadUpdate: String(localized: "Download newer")
        case .deleteRemote: String(localized: "Delete on server")
        case .deleteLocal: String(localized: "Move to Trash")
        case .setRemoteTime: String(localized: "Set the server file's time")
        case .setLocalTime: String(localized: "Set the local file's time")
        }
        if a.isDirectory { return what + " · " + String(localized: "folder") }
        let summary: FileSummary? = (a.isDownload || a.kind == .deleteRemote || a.kind == .setLocalTime) ? a.remote : a.local
        guard let summary else { return what }
        return "\(what) · \(Format.size(summary.size)) · \(Format.date(summary.modified))"
    }
}
