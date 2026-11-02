import AppKit
import RemoteCore
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private var siteManager: SiteManagerWindowController?
    private var preferences: NSWindowController?

    let updater = SPUStandardUpdaterController(
        startingUpdater: !(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "").isEmpty,
        updaterDelegate: nil, userDriverDelegate: nil)

    private(set) var commanders: [CommanderWindowController] = []

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        UserDefaults.standard.register(defaults: Preferences.defaults)
        #if DEBUG
        if debugConnect() { return }
        #endif
        showSiteManager(nil)
        NSApp.activate()
    }

    #if DEBUG

    private func debugConnect() -> Bool {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: "MacSCPDebugConnect"), let url = URL(string: s), let host = url.host else { return false }
        var site = Site(name: host, host: host, fileProtocol: FileProtocol(rawValue: url.scheme ?? "") ?? .sftp, user: url.user ?? "")
        site.port = url.port
        site.privateKeyPath = d.string(forKey: "MacSCPDebugKey")
        site.remoteDirectory = url.path
        site.localDirectory = d.string(forKey: "MacSCPDebugLocal") ?? ""
        struct Accept: ConnectionPrompter {
            func verifyHostKey(_ info: HostKeyInfo) async -> HostKeyDecision { .acceptOnce }
            func verifyCertificate(_ info: CertificateInfo) async -> HostKeyDecision { .acceptOnce }
            func password(user: String, host: String) async -> String? { nil }
            func passphrase(keyPath: String) async -> String? { nil }
            func keyboardInteractive(name: String, instruction: String, prompts: [InteractivePrompt]) async -> [String]? { nil }
            func banner(_ text: String) async {}
        }
        Task {
            let delegate = UITransferDelegate()
            do {
                let session = try await Session.open(site: site, password: d.string(forKey: "MacSCPDebugPassword"), prompter: Accept(), transferDelegate: delegate)
                open(session, transferDelegate: delegate)
                NSApp.activate()
                if let edit = d.string(forKey: "MacSCPDebugEdit") { commanders.last?.edit([edit], with: nil) }
                if let text = d.string(forKey: "MacSCPDebugEditInsert") {
                    try? await Task.sleep(for: .seconds(2))
                    commanders.last?.debugEditorInsert(text)
                }
                if d.bool(forKey: "MacSCPDebugKeep") {
                    try? await Task.sleep(for: .seconds(2))
                    commanders.last?.keepRemoteUpToDate(nil)
                    commanders.last?.debugStartKeep(downloading: d.bool(forKey: "MacSCPDebugKeepDownload"))
                }
                if let command = d.string(forKey: "MacSCPDebugConsole") {
                    try? await Task.sleep(for: .seconds(2))
                    commanders.last?.debugConsole(command)
                }
                if d.bool(forKey: "MacSCPDebugCompare") {
                    try? await Task.sleep(for: .seconds(2))
                    commanders.last?.compareDirectories(nil)
                }
                if let mask = d.string(forKey: "MacSCPDebugFind") {
                    try? await Task.sleep(for: .seconds(2))
                    commanders.last?.findFiles(nil)
                    commanders.last?.debugFind(mask)
                }
                if d.bool(forKey: "MacSCPDebugSync") {
                    try? await Task.sleep(for: .seconds(1))
                    commanders.last?.synchronize(nil)
                    if d.bool(forKey: "MacSCPDebugSyncCompare") { commanders.last?.debugCompare() }
                }
            } catch {
                await Alerts.error(error, in: nil)
            }
        }
        return true
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSiteManager(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = commanders.filter(\.hasActiveWork)
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Transfers or uploads of edited files are still running.")
        alert.informativeText = String(localized: "Quitting now cancels them.")
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for c in commanders { c.closeSessionNow() }
    }

    @objc func showSiteManager(_ sender: Any?) {
        if siteManager == nil { siteManager = SiteManagerWindowController() }
        siteManager?.showWindow(nil)
        siteManager?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferences == nil { preferences = Preferences.makeWindowController() }
        preferences?.showWindow(nil)
    }

    func open(_ session: Session, transferDelegate: UITransferDelegate) {
        let commander = CommanderWindowController(session: session, transferDelegate: transferDelegate)
        commanders.append(commander)
        if let host = NSApp.keyWindow?.windowController as? CommanderWindowController, let w = host.window,
           let new = commander.window {
            w.addTabbedWindow(new, ordered: .above)
        }
        commander.showWindow(nil)
        siteManager?.close()
    }

    func closed(_ commander: CommanderWindowController) {
        commanders.removeAll { $0 === commander }
        if commanders.isEmpty { showSiteManager(nil) }
    }
}
