import AppKit
import RemoteCore
import SwiftUI

enum Preferences {
    static let showHidden = "showHiddenFiles"
    static let commanderKeys = "commanderKeymap"
    static let confirmOverwrite = "confirmOverwrite"
    static let parallelTransfers = "parallelTransfers"
    static let transferOptions = "transferOptions"
    static let confirmDelete = "confirmDelete"

    static var defaults: [String: Any] {
        [showHidden: false, commanderKeys: false, confirmOverwrite: true, parallelTransfers: 2, confirmDelete: true]
    }

    static var options: TransferOptions {
        get {
            guard let d = UserDefaults.standard.data(forKey: transferOptions),
                  let o = try? JSONDecoder().decode(TransferOptions.self, from: d) else { return TransferOptions() }
            return o
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: transferOptions) }
    }

    @MainActor
    static func makeWindowController() -> NSWindowController {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable]
        return NSWindowController(window: window)
    }
}

struct PreferencesView: View {
    @AppStorage(Preferences.showHidden) private var showHidden = false
    @AppStorage(Preferences.commanderKeys) private var commanderKeys = false
    @AppStorage(Preferences.confirmOverwrite) private var confirmOverwrite = true
    @AppStorage(Preferences.confirmDelete) private var confirmDelete = true
    @AppStorage(Preferences.parallelTransfers) private var parallel = 2
    @State private var options = Preferences.options

    var body: some View {
        TabView {
            Form {
                Toggle("Show hidden files", isOn: $showHidden)
                Toggle("Commander keys (F2 rename, F4 edit, F5 copy, F7 new folder, F8 delete)", isOn: $commanderKeys)
                Toggle("Confirm before deleting", isOn: $confirmDelete)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Toggle("Ask before overwriting files", isOn: $confirmOverwrite)
                Stepper("Parallel transfers: \(parallel)", value: $parallel, in: 1...9)
                Text("Applies to sessions opened after the change.").font(.caption).foregroundStyle(.secondary)
                Divider()
                TransferOptionsForm(options: $options)
            }
            .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: options) { Preferences.options = options }
    }
}

struct TransferOptionsForm: View {
    @Binding var options: TransferOptions

    var body: some View {
        Section("Upload") {
            Toggle("Set permissions", isOn: $options.setPermissions)
            if options.setPermissions {
                PermissionsGrid(mode: $options.permissions.mode)
                Toggle("Add X to directories", isOn: $options.addXToDirectories)
            }
            Toggle("Ignore permission errors", isOn: $options.ignorePermissionErrors)
        }
        Section("Common") {
            Picker("Transfer mode", selection: $options.mode) {
                Text("Binary").tag(TransferOptions.Mode.binary)
                Text("Text (convert line endings)").tag(TransferOptions.Mode.text)
                Text("Automatic").tag(TransferOptions.Mode.automatic)
            }
            if options.mode == .automatic {
                TextField("Transfer as text", text: $options.textMask, axis: .vertical)
            }
            Toggle("Preserve timestamp", isOn: $options.preserveTime)
            Picker("Resume interrupted transfers", selection: $options.resumeSupport) {
                Text("Always").tag(TransferOptions.ResumeSupport.on)
                Text("Files over 100 KB").tag(TransferOptions.ResumeSupport.smart)
                Text("Never").tag(TransferOptions.ResumeSupport.off)
            }
        }
        Section("Other") {
            TextField("File mask", text: $options.includeMask, prompt: Text("*.txt; *.log | *.bak; .git/"))
            Toggle("New and updated files only", isOn: $options.newerOnly)
            Toggle("Exclude hidden files", isOn: $options.excludeHiddenFiles)
        }
    }
}

struct PermissionsGrid: View {
    @Binding var mode: UInt16
    @State private var octal = ""

    private func bit(_ b: UInt16) -> Binding<Bool> {
        Binding(get: { mode & b != 0 }, set: { mode = $0 ? mode | b : mode & ~b })
    }

    var body: some View {
        Grid(alignment: .leading) {
            ForEach(Array(zip(["Owner", "Group", "Others"], [UInt16(6), 3, 0])), id: \.0) { name, shift in
                GridRow {
                    Text(LocalizedStringKey(name))
                    Toggle("R", isOn: bit(4 << shift))
                    Toggle("W", isOn: bit(2 << shift))
                    Toggle("X", isOn: bit(1 << shift))
                    let special: [String: (String, UInt16)] = ["Owner": ("Set UID", 0o4000), "Group": ("Set GID", 0o2000), "Others": ("Sticky bit", 0o1000)]
                    Toggle(LocalizedStringKey(special[name]!.0), isOn: bit(special[name]!.1))
                }
            }
            GridRow {
                Text("Octal")
                TextField("", text: $octal)
                    .frame(width: 60)
                    .onSubmit { if let p = Permissions(octal: octal) { mode = p.mode } }
                    .gridCellColumns(2)
                Text(Permissions(mode).text).font(.system(.body, design: .monospaced)).gridCellColumns(2)
            }
        }
        .onAppear { octal = String(mode, radix: 8) }
        .onChange(of: mode) { octal = String(mode, radix: 8) }
    }
}
