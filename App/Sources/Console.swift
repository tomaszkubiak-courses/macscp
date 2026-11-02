import AppKit
import RemoteCore
import SwiftUI

@MainActor
@Observable
final class ConsoleModel {
    var directory: String
    var input = ""
    var log = ""
    var running = false
    var history: [String] = []
    @ObservationIgnored var historyIndex: Int?
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private let session: Session
    @ObservationIgnored private var shell: (any RemoteShell)?
    @ObservationIgnored private var task: Task<CommandResult?, Never>?

    static let customCommandsKey = "customCommands"

    static var customCommands: [CustomCommand] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customCommandsKey),
                  let list = try? JSONDecoder().decode([CustomCommand].self, from: data) else { return CustomCommand.defaults }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customCommandsKey) }
    }

    init(session: Session, directory: String) {
        self.session = session
        self.directory = directory
        if session.site.fileProtocol.isFTP {
            log = String(localized: "Commands are sent to the FTP server as they are, for example SITE or STAT.\n")
        }
    }

    func submit() {
        let command = input.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !running else { return }
        input = ""
        if history.last != command { history.append(command) }
        historyIndex = nil
        run(command)
    }

    @discardableResult
    func run(_ command: String, echo: Bool = true) -> Task<CommandResult?, Never> {
        running = true
        if echo { log += "\(directory)$ \(command)\n" }
        let session = session, directory = directory
        let t = Task { () -> CommandResult? in
            defer { running = false }
            do {
                if shell == nil {
                    guard let s = try await session.connectTransfer() as? any RemoteShell else {
                        log += String(localized: "This session has no command line.\n")
                        return nil
                    }
                    shell = s
                }
                let r = try await shell!.run(command, in: directory)
                log += r.output + (r.output.isEmpty || r.output.hasSuffix("\n") ? "" : "\n")
                log += r.errorOutput + (r.errorOutput.isEmpty || r.errorOutput.hasSuffix("\n") ? "" : "\n")
                if r.exitCode != 0 { log += String(localized: "[exit code \(r.exitCode)]\n") }
                self.directory = r.directory
                onFinish()
                return r
            } catch {
                log += "\(error)\n"
                if (error as? RemoteError)?.kind == .connection { shell = nil }
                return nil
            }
        }
        task = t
        return t
    }

    func stop() {
        task?.cancel()
        let s = shell
        shell = nil
        Task { await s?.disconnect() }
    }

    func recall(_ step: Int) {
        guard !history.isEmpty else { return }
        let i = max(0, min(history.count, (historyIndex ?? history.count) + step))
        historyIndex = i
        input = i < history.count ? history[i] : ""
    }

    func close() {
        task?.cancel()
        let s = shell
        Task { await s?.disconnect() }
    }
}

struct ConsoleView: View {
    @Bindable var model: ConsoleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? " " : model.log)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.log) { proxy.scrollTo("end") }
            }
            HStack {
                Text(model.directory + "$").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                TextField("Command", text: $model.input)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit { model.submit() }
                    .onKeyPress(.upArrow) { model.recall(-1); return .handled }
                    .onKeyPress(.downArrow) { model.recall(1); return .handled }
                    .disabled(model.running)
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.stop() }
                }
            }
            Text("Commands run without a terminal: interactive programs such as vim or top do not work.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { focused = true }
    }
}

@MainActor
final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    let model: ConsoleModel

    init(model: ConsoleModel, title: String) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: ConsoleView(model: model)))
        window.title = String(localized: "Console — \(title)")
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 720, height: 460))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { model.close() }
}

struct CustomCommandsEditor: View {
    @State private var commands = ConsoleModel.customCommands
    @State private var selection: UUID?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Commands").font(.headline)
            HStack(alignment: .top) {
                List(selection: $selection) {
                    ForEach(commands) { Text($0.name.isEmpty ? String(localized: "Untitled") : $0.name).tag($0.id) }
                }
                .frame(width: 180, height: 220)
                if let i = commands.firstIndex(where: { $0.id == selection }) {
                    Form {
                        TextField("Name", text: $commands[i].name)
                        TextField("Command", text: $commands[i].command, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                        Toggle("Apply to folders", isOn: $commands[i].applyToDirectories)
                        Toggle("Show output in the console", isOn: $commands[i].showOutput)
                        Text("""
                        ! file name, !& selected files, !/ current folder, !@ host, !U user, !# port, !N site name, \
                        !?Prompt:?default! asks for a value, !! a literal !. Names and answers are quoted for the shell.
                        """).font(.caption).foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                } else {
                    Text("Select a command.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                Button("Add") {
                    let c = CustomCommand(name: String(localized: "New Command"), command: "")
                    commands.append(c)
                    selection = c.id
                }
                Button("Remove") { commands.removeAll { $0.id == selection } }.disabled(selection == nil)
                Button("Restore Defaults") { commands = CustomCommand.defaults }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    ConsoleModel.customCommands = commands
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640)
    }
}
