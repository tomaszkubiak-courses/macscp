import AppKit
import RemoteCore
import SwiftUI

@MainActor
@Observable
final class FindFilesModel {
    var mask = "*"
    var directory: String
    var results: [FoundFile] = []
    var selection: Set<String> = []
    var status = ""
    var running = false

    @ObservationIgnored private let session: Session
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var reveal: (FoundFile) -> Void = { _ in }

    init(session: Session, directory: String) {
        self.session = session
        self.directory = directory
    }

    func start() {
        let fileMask: FileMask
        do { fileMask = try FileMask(mask.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : mask) } catch {
            status = "\(error)"
            return
        }
        results = []
        selection = []
        running = true
        let session = session, directory = directory
        task = Task {
            var fs: (any RemoteFileSystem)?
            do {
                fs = try await session.connectTransfer()
                try await FileFinder.find(in: directory, mask: fileMask, fs: fs!,
                                          searching: { dir in await MainActor.run { self.status = String(localized: "Searching \(dir)…") } },
                                          found: { batch in await MainActor.run { self.results += batch } })
                status = String(localized: "Found \(results.count) items.")
            } catch is CancellationError {
                status = String(localized: "Stopped. Found \(results.count) items.")
            } catch let e as RemoteError where e.kind == .cancelled {
                status = String(localized: "Stopped. Found \(results.count) items.")
            } catch {
                status = "\(error)"
            }
            await fs?.disconnect()
            running = false
        }
    }

    func stop() { task?.cancel() }

    func revealSelection(_ ids: Set<String>? = nil) {
        guard let id = (ids ?? selection).first, let found = results.first(where: { $0.id == id }) else { return }
        reveal(found)
    }
}

struct FindFilesView: View {
    @Bindable var model: FindFilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("File mask", text: $model.mask, prompt: Text("*.log; *.txt | .git/; >1M"))
                TextField("Search in", text: $model.directory)
            }
            Table(model.results, selection: $model.selection) {
                TableColumn("Name") { Text($0.file.name) }
                TableColumn("Directory") { Text(RemotePath.parent($0.path)).foregroundStyle(.secondary).truncationMode(.middle) }
                TableColumn("Size") { Text($0.file.isDirectory ? "" : Format.size($0.file.size)).monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("Modified") { Text(Format.date($0.file.modified)) }
                    .width(min: 100, ideal: 140)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Show in Remote Pane") { model.revealSelection(ids) }
            } primaryAction: { ids in
                model.revealSelection(ids)
            }
            HStack {
                Text(model.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Remote Pane") { model.revealSelection() }.disabled(model.selection.isEmpty)
                Button(model.running ? "Stop" : "Find") { model.running ? model.stop() : model.start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
    }
}

@MainActor
final class FindFilesWindowController: NSWindowController, NSWindowDelegate {
    let model: FindFilesModel

    init(model: FindFilesModel, title: String) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: FindFilesView(model: model)))
        window.title = String(localized: "Find Files — \(title)")
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 720, height: 480))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { model.stop() }
}
