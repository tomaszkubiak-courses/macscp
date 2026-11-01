import AppKit
import CoreServices
import RemoteCore
import SwiftUI

final class LocalWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "MacSCP.LocalWatcher")

    init(path: String, latency: TimeInterval = 0.5, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LocalWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handler(list)
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

@MainActor
@Observable
final class KeepUpToDateModel {
    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        let isError: Bool
    }

    var localDir: String
    var remoteDir: String
    var deleteExtra = false
    var syncFirst = true
    var mask = ""
    var running = false
    var busy = false
    var log: [LogLine] = []

    @ObservationIgnored private let session: Session
    @ObservationIgnored private var synchronizer: Synchronizer?
    @ObservationIgnored private var watcher: LocalWatcher?
    @ObservationIgnored private var pending = Set<String>()
    @ObservationIgnored private var realBase = ""
    @ObservationIgnored var onChange: () -> Void = {}

    init(session: Session, localDir: String, remoteDir: String) {
        self.session = session
        self.localDir = localDir
        self.remoteDir = remoteDir
    }

    private var options: SyncOptions {
        var o = SyncOptions()
        o.direction = .toRemote
        o.deleteExtra = deleteExtra
        o.transfer = Preferences.options
        o.transfer.includeMask = mask
        return o
    }

    private func add(_ text: String, error: Bool = false) {
        log.insert(LogLine(text: text, isError: error), at: 0)
        if log.count > 500 { log.removeLast() }
    }

    var canStart: Bool { !running && !localDir.isEmpty && remoteDir.hasPrefix("/") }

    func start() {
        guard canStart else { return }
        realBase = URL(fileURLWithPath: localDir).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: realBase) else {
            add(String(localized: "Local folder does not exist."), error: true)
            return
        }
        running = true
        add(String(localized: "Watching \(localDir)"))
        let w = LocalWatcher(path: realBase) { [weak self] paths in
            Task { @MainActor in self?.changed(paths) }
        }
        watcher = w
        if syncFirst { changed([realBase], recursive: true) }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        pending.removeAll()
        if running { add(String(localized: "Stopped")) }
        running = false
        let s = synchronizer
        synchronizer = nil
        Task { await s?.fs.disconnect() }
    }

    @ObservationIgnored private var fullPass = false

    private func changed(_ paths: [String], recursive: Bool = false) {
        guard running else { return }
        if recursive { fullPass = true }
        for p in paths {
            let dir = p.hasSuffix("/") ? String(p.dropLast()) : p
            guard dir == realBase || dir.hasPrefix(realBase + "/") else { continue }
            pending.insert(dir)
        }
        if !busy { Task { await process() } }
    }

    private func remotePath(for local: String) -> String {
        guard local != realBase else { return remoteDir }
        return RemotePath.join(remoteDir, String(local.dropFirst(realBase.count + 1)))
    }

    private func process() async {
        busy = true
        defer { busy = false }
        while running, let dir = pending.min(by: { $0.count < $1.count }) {
            pending.remove(dir)
            var o = options
            o.recursive = fullPass
            fullPass = false
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            do {
                if synchronizer == nil {
                    synchronizer = Synchronizer(fs: try await session.connectTransfer(), reconnect: session.connectTransfer)
                }
                let actions = try await synchronizer!.compare(local: dir, remote: remotePath(for: dir), options: o)
                guard !actions.isEmpty else { continue }
                try await synchronizer!.apply(actions, options: o)
                for a in actions {
                    let name = String(a.localPath.dropFirst(min(realBase.count + 1, a.localPath.count)))
                    switch a.kind {
                    case .uploadNew, .uploadUpdate: add(String(localized: "Uploaded \(name)"))
                    case .deleteRemote: add(String(localized: "Deleted \(name) on the server"))
                    default: break
                    }
                }
                onChange()
            } catch {
                add("\(error)", error: true)
            }
        }
    }
}

struct KeepUpToDateView: View {
    @Bindable var model: KeepUpToDateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Watch local folder", text: $model.localDir).disabled(model.running)
                TextField("Upload to remote folder", text: $model.remoteDir).disabled(model.running)
                TextField("File mask", text: $model.mask, prompt: Text("| .git/; *.tmp")).disabled(model.running)
                Toggle("Delete remote files that are deleted locally", isOn: $model.deleteExtra).disabled(model.running)
                Toggle("Synchronize the whole folder before watching", isOn: $model.syncFirst).disabled(model.running)
            }
            .formStyle(.grouped)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.running ? "Watching for changes…" : "Stopped").foregroundStyle(.secondary)
                Spacer()
                if model.running {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Start") { model.start() }.keyboardShortcut(.defaultAction).disabled(!model.canStart)
                }
            }
            List(model.log) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(line.text).foregroundStyle(line.isError ? .red : .primary).lineLimit(2).textSelection(.enabled)
                }
            }
            .frame(minHeight: 180)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 600)
    }
}

@MainActor
final class KeepUpToDateWindowController: NSWindowController, NSWindowDelegate {
    let model: KeepUpToDateModel

    init(model: KeepUpToDateModel, title: String) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: KeepUpToDateView(model: model)))
        window.title = String(localized: "Keep Remote Folder Up to Date — \(title)")
        window.styleMask.insert(.resizable)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { model.stop() }
}
