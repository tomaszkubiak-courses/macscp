import AppKit
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SiteManagerModel {
    let store = SiteStore()
    var sites: [Site] = []
    var selection: String? = Node.newSiteID
    var draft = Site(name: "", host: "")
    var password = ""
    var savePassword = true
    var connecting = false
    var error: String?
    weak var window: NSWindow?

    init() {
        do { sites = try store.load() } catch { self.error = "\(error)" }
    }

    struct Node: Identifiable, Hashable {
        static let newSiteID = "new"
        let id: String
        let name: String
        var site: Site?
        var children: [Node]?
    }

    var tree: [Node] {
        var root: [Node] = [Node(id: Node.newSiteID, name: String(localized: "New Site"))]
        func insert(_ site: Site, path: [String], into nodes: inout [Node], prefix: String) {
            if let folder = path.first {
                let id = "folder:" + prefix + folder
                if let i = nodes.firstIndex(where: { $0.id == id }) {
                    var children = nodes[i].children ?? []
                    insert(site, path: Array(path.dropFirst()), into: &children, prefix: prefix + folder + "/")
                    nodes[i].children = children
                } else {
                    var children: [Node] = []
                    insert(site, path: Array(path.dropFirst()), into: &children, prefix: prefix + folder + "/")
                    nodes.append(Node(id: id, name: folder, children: children))
                }
            } else {
                nodes.append(Node(id: site.id.uuidString, name: site.name, site: site))
            }
        }
        var rest: [Node] = []
        for site in sites {
            insert(site, path: site.folder.split(separator: "/").map(String.init), into: &rest, prefix: "")
        }
        func sorted(_ nodes: [Node]) -> [Node] {
            nodes.map { var n = $0; n.children = n.children.map(sorted); return n }
                .sorted { ($0.children == nil ? 1 : 0, $0.name.lowercased()) < ($1.children == nil ? 1 : 0, $1.name.lowercased()) }
        }
        root += sorted(rest)
        return root
    }

    func select(_ id: String?) {
        selection = id
        if id == Node.newSiteID || id == nil {
            draft = Site(name: "", host: "")
            password = ""
        } else if let site = sites.first(where: { $0.id.uuidString == id }) {
            draft = site
            password = Keychain.password(for: site.id) ?? ""
            savePassword = !password.isEmpty
        }
        error = nil
    }

    var isSaved: Bool { sites.contains { $0.id == draft.id } }

    func save() {
        fillDefaultHost()
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = draft.user.isEmpty ? draft.host : "\(draft.user)@\(draft.host)"
        }
        if let i = sites.firstIndex(where: { $0.id == draft.id }) { sites[i] = draft } else { sites.append(draft) }
        do {
            try store.save(sites)
            try Keychain.setPassword(savePassword && !password.isEmpty ? password : nil, for: draft.id)
            selection = draft.id.uuidString
        } catch {
            self.error = "\(error)"
        }
    }

    func delete() {
        sites.removeAll { $0.id == draft.id }
        try? Keychain.setPassword(nil, for: draft.id)
        do { try store.save(sites) } catch { self.error = "\(error)" }
        select(Node.newSiteID)
    }

    private func fillDefaultHost() {
        if draft.host.isEmpty && draft.fileProtocol.isS3 { draft.host = "s3.amazonaws.com" }
    }

    func login() {
        fillDefaultHost()
        guard !draft.host.isEmpty else { error = String(localized: "Enter a host name."); return }
        connecting = true
        error = nil
        let site = draft
        let password = password.isEmpty ? nil : password
        Task {
            let delegate = UITransferDelegate()
            do {
                let session = try await Session.open(
                    site: site, password: password, prompter: UIPrompter(window: window),
                    transferDelegate: delegate,
                    maxParallel: UserDefaults.standard.integer(forKey: Preferences.parallelTransfers))
                connecting = false
                AppDelegate.shared.open(session, transferDelegate: delegate)
            } catch {
                connecting = false
                self.error = "\(error)"
            }
        }
    }

    func importWinSCP() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ini", "reg"].compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "Choose WinSCP.ini, or a .reg export of WinSCP's registry key.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result: WinSCPImportResult
        do { result = WinSCPImport.parse(try Data(contentsOf: url)) } catch { self.error = "\(error)"; return }
        for imported in result.sites {
            sites.append(imported.site)
            if let p = imported.password, !p.isEmpty { try? Keychain.setPassword(p, for: imported.site.id) }
        }
        do { try store.save(sites) } catch { self.error = "\(error)"; return }
        var info: [String] = []
        let keys = result.sites.filter { $0.windowsKeyFile != nil }
        if !keys.isEmpty {
            info.append(String(localized: """
            These sites used private keys at Windows paths: \(keys.map(\.site.name).joined(separator: ", ")). \
            Copy the key files to this Mac, then choose them under Advanced. PuTTY .ppk keys work as they are.
            """))
        }
        if !result.skipped.isEmpty {
            info.append(String(localized: "Skipped, because MacSCP does not support their protocol yet: \(result.skipped.joined(separator: ", "))."))
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Imported \(result.sites.count) sites from WinSCP.")
        alert.informativeText = info.joined(separator: "\n\n")
        alert.runModal()
    }

    func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { draft.privateKeyPath = url.path }
    }
}

struct SiteManagerView: View {
    @Bindable var model: SiteManagerModel
    @State private var advanced = false

    private var ftp: Bool { model.draft.fileProtocol.isFTP }
    private var s3: Bool { model.draft.fileProtocol.isS3 }

    private var defaultPort: String {
        switch model.draft.fileProtocol {
        case .sftp, .scp: "22"
        case .ftp, .ftps: "21"
        case .ftpsImplicit: "990"
        case .s3: "443"
        case .s3http: "80"
        }
    }

    var body: some View {
        HSplitView {
            List(model.tree, children: \.children, selection: Binding(get: { model.selection }, set: { model.select($0) })) { node in
                Label(node.name, systemImage: node.id == SiteManagerModel.Node.newSiteID ? "plus.rectangle.on.rectangle"
                      : node.children != nil ? "folder" : "server.rack")
                    .tag(node.id)
            }
            .frame(minWidth: 200, idealWidth: 220)

            VStack(alignment: .leading, spacing: 12) {
                Form {
                    Section("Session") {
                        Picker("File protocol", selection: Binding(get: { ftp ? .ftp : s3 ? .s3 : model.draft.fileProtocol },
                                                                   set: { model.draft.fileProtocol = $0 })) {
                            Text("SFTP").tag(FileProtocol.sftp)
                            Text("SCP").tag(FileProtocol.scp)
                            Text("FTP").tag(FileProtocol.ftp)
                            Text("Amazon S3").tag(FileProtocol.s3)
                        }
                        if ftp {
                            Picker("Encryption", selection: $model.draft.fileProtocol) {
                                Text("No encryption").tag(FileProtocol.ftp)
                                Text("TLS/SSL Explicit encryption").tag(FileProtocol.ftps)
                                Text("TLS/SSL Implicit encryption").tag(FileProtocol.ftpsImplicit)
                            }
                        }
                        if s3 {
                            Picker("Encryption", selection: $model.draft.fileProtocol) {
                                Text("TLS/SSL Implicit encryption").tag(FileProtocol.s3)
                                Text("No encryption").tag(FileProtocol.s3http)
                            }
                        }
                        HStack {
                            TextField("Host name", text: $model.draft.host, prompt: Text(s3 ? "s3.amazonaws.com" : "example.com"))
                            TextField("Port", value: $model.draft.port, format: .number.grouping(.never), prompt: Text(defaultPort))
                                .frame(width: 110)
                        }
                        TextField(s3 ? "Access key ID" : "User name", text: $model.draft.user,
                                  prompt: Text(s3 ? "From ~/.aws/credentials" : ftp ? "Anonymous" : "From ~/.ssh/config or local user"))
                        SecureField(s3 ? "Secret access key" : "Password", text: $model.password, prompt: Text("Optional"))
                        Toggle("Save password in Keychain", isOn: $model.savePassword)
                    }
                    DisclosureGroup("Advanced", isExpanded: $advanced) {
                        if s3 {
                            TextField("Region", text: Binding(get: { model.draft.region ?? "" },
                                                              set: { model.draft.region = $0.isEmpty ? nil : $0 }),
                                      prompt: Text("us-east-1"))
                        }
                        if !ftp && !s3 {
                            HStack {
                                TextField("Private key", text: Binding(get: { model.draft.privateKeyPath ?? "" },
                                                                       set: { model.draft.privateKeyPath = $0.isEmpty ? nil : $0 }),
                                          prompt: Text("Agent and default keys"))
                                Button("Choose…") { model.chooseKey() }
                            }
                            Toggle("Use ssh-agent", isOn: $model.draft.useAgent)
                        }
                        TextField("Remote directory", text: $model.draft.remoteDirectory, prompt: Text("Home"))
                        TextField("Local directory", text: $model.draft.localDirectory, prompt: Text("Home"))
                        TextField("Site name", text: $model.draft.name, prompt: Text("user@host"))
                        TextField("Folder", text: $model.draft.folder, prompt: Text("e.g. Work/Production"))
                        if !ftp && !s3 {
                            Text("Jump hosts, proxies and other options come from ~/.ssh/config.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)

                if let error = model.error {
                    Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                HStack {
                    Button(model.isSaved ? "Save" : "Save Site") { model.save() }
                    if model.isSaved { Button("Delete", role: .destructive) { model.delete() } }
                    Button("Import from WinSCP…") { model.importWinSCP() }
                    Spacer()
                    if model.connecting { ProgressView().controlSize(.small) }
                    Button("Login") { model.login() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.connecting || (model.draft.host.isEmpty && !model.draft.fileProtocol.isS3))
                }
                .padding([.horizontal, .bottom])
            }
            .frame(minWidth: 420)
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

@MainActor
final class SiteManagerWindowController: NSWindowController {
    let model = SiteManagerModel()

    init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SiteManagerView(model: model)))
        window.title = String(localized: "Login")
        window.setContentSize(NSSize(width: 720, height: 460))
        window.styleMask.insert(.resizable)
        window.setFrameAutosaveName("SiteManager")
        super.init(window: window)
        model.window = window
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        model.window = window
        window?.center()
        super.showWindow(sender)
    }
}
