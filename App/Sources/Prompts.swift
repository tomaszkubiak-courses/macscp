import AppKit
import RemoteCore

@MainActor
enum Alerts {
    private static var tail: Task<Void, Never>?

    static func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return alert.runModal() }
        return await withCheckedContinuation { c in
            alert.beginSheetModal(for: window) { c.resume(returning: $0) }
        }
    }

    static func error(_ error: Error, in window: NSWindow?) async {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "Operation failed")
        a.informativeText = "\(error)"
        _ = await serialized { await run(a, in: window) }
    }

    static func ask(_ message: String, info: String = "", value: String = "", secure: Bool = false,
                    ok: String = String(localized: "OK"), in window: NSWindow?) async -> String? {
        await serialized {
            let a = NSAlert()
            a.messageText = message
            a.informativeText = info
            a.addButton(withTitle: ok)
            a.addButton(withTitle: String(localized: "Cancel"))
            let field = secure ? NSSecureTextField() : NSTextField()
            field.stringValue = value
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            a.accessoryView = field
            a.window.initialFirstResponder = field
            return await run(a, in: window) == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }

    static func confirm(_ message: String, info: String, action: String, in window: NSWindow?) async -> Bool {
        await serialized {
            let a = NSAlert()
            a.messageText = message
            a.informativeText = info
            a.addButton(withTitle: action)
            a.addButton(withTitle: String(localized: "Cancel"))
            return await run(a, in: window) == .alertFirstButtonReturn
        }
    }
}

@MainActor
final class UIPrompter: ConnectionPrompter {
    weak var window: NSWindow?

    init(window: NSWindow?) { self.window = window }

    func verifyHostKey(_ info: HostKeyInfo) async -> HostKeyDecision {
        await Alerts.serialized { [window] in
            let a = NSAlert()
            switch info.status {
            case .unknown:
                a.messageText = String(localized: "Continue connecting to an unknown server?")
                a.informativeText = String(localized: """
                The server \(info.host):\(String(info.port)) is not in your known hosts. Its \(info.keyType) key fingerprint is:

                \(info.fingerprint)

                Only continue if you trust this server.
                """)
            case .changed:
                a.alertStyle = .critical
                a.messageText = String(localized: "WARNING: the server's host key has changed!")
                a.informativeText = String(localized: """
                The \(info.keyType) key of \(info.host):\(String(info.port)) does not match the one in your known hosts. \
                Someone may be intercepting the connection, or the server was reinstalled. New fingerprint:

                \(info.fingerprint)
                """)
            }
            a.addButton(withTitle: info.status == .changed ? String(localized: "Cancel") : String(localized: "Accept"))
            a.addButton(withTitle: info.status == .changed ? String(localized: "Update Key") : String(localized: "Connect Once"))
            a.addButton(withTitle: info.status == .changed ? String(localized: "Connect Once") : String(localized: "Cancel"))
            let r = await Alerts.run(a, in: window)
            switch (info.status, r) {
            case (.unknown, .alertFirstButtonReturn), (.changed, .alertSecondButtonReturn): return .acceptAndSave
            case (.unknown, .alertSecondButtonReturn), (.changed, .alertThirdButtonReturn): return .acceptOnce
            default: return .reject
            }
        }
    }

    func password(user: String, host: String) async -> String? {
        await Alerts.ask(String(localized: "Password for \(user)@\(host)"), secure: true, in: window)
    }

    func passphrase(keyPath: String) async -> String? {
        await Alerts.ask(String(localized: "Passphrase for key \(keyPath)"), secure: true, in: window)
    }

    func keyboardInteractive(name: String, instruction: String, prompts: [InteractivePrompt]) async -> [String]? {
        await Alerts.serialized { [window] in
            let a = NSAlert()
            a.messageText = name.isEmpty ? String(localized: "Server authentication") : name
            a.informativeText = instruction
            a.addButton(withTitle: String(localized: "OK"))
            a.addButton(withTitle: String(localized: "Cancel"))
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            var fields: [NSTextField] = []
            for p in prompts {
                stack.addArrangedSubview(NSTextField(labelWithString: p.text))
                let f = p.echo ? NSTextField() : NSSecureTextField()
                f.widthAnchor.constraint(equalToConstant: 300).isActive = true
                stack.addArrangedSubview(f)
                fields.append(f)
            }
            stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(prompts.count) * 50)
            a.accessoryView = stack
            a.window.initialFirstResponder = fields.first
            return await Alerts.run(a, in: window) == .alertFirstButtonReturn ? fields.map(\.stringValue) : nil
        }
    }

    func banner(_ text: String) async {
        await Alerts.serialized { [window] in
            let a = NSAlert()
            a.messageText = String(localized: "Server message")
            a.informativeText = text
            _ = await Alerts.run(a, in: window)
        }
    }
}

@MainActor
final class UITransferDelegate: TransferDelegate {
    weak var window: NSWindow?

    func overwrite(_ q: OverwriteQuestion) async -> OverwriteAnswer {
        if !UserDefaults.standard.bool(forKey: Preferences.confirmOverwrite) { return .overwriteAll }
        return await Alerts.serialized { [window] in
            let a = NSAlert()
            let name = (q.target.path as NSString).lastPathComponent
            a.messageText = String(localized: "“\(name)” already exists. Overwrite it?")
            func line(_ s: FileSummary) -> String {
                let date = s.modified.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "?"
                return "\(Format.size(s.size)), \(date)"
            }
            a.informativeText = String(localized: "New: \(line(q.source))\nExisting: \(line(q.target))")
            a.addButton(withTitle: String(localized: "Overwrite"))
            a.addButton(withTitle: String(localized: "Skip"))
            a.addButton(withTitle: String(localized: "Cancel"))
            if q.canResume { a.addButton(withTitle: String(localized: "Resume")) }
            a.showsSuppressionButton = true
            a.suppressionButton?.title = String(localized: "Apply to all remaining files")
            let newer = NSButton(checkboxWithTitle: String(localized: "Only overwrite with newer files"), target: nil, action: nil)
            a.accessoryView = newer
            let r = await Alerts.run(a, in: window)
            let all = a.suppressionButton?.state == .on
            switch r {
            case .alertFirstButtonReturn:
                if newer.state == .on { return .overwriteAllIfNewer }
                return all ? .overwriteAll : .overwrite
            case .alertSecondButtonReturn: return all ? .skipAll : .skip
            case .alertThirdButtonReturn: return .cancel
            default: return .resume
            }
        }
    }

    func failed(_ error: RemoteError, path: String) async -> FailureAnswer {
        await Alerts.serialized { [window] in
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = String(localized: "Transfer of “\((path as NSString).lastPathComponent)” failed")
            a.informativeText = error.message
            a.addButton(withTitle: String(localized: "Retry"))
            a.addButton(withTitle: String(localized: "Skip"))
            a.addButton(withTitle: String(localized: "Abort"))
            switch await Alerts.run(a, in: window) {
            case .alertFirstButtonReturn: return .retry
            case .alertSecondButtonReturn: return .skip
            default: return .abort
            }
        }
    }
}

enum Format {
    nonisolated(unsafe) private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }

    static func date(_ d: Date?) -> String {
        d.map { $0.formatted(date: .numeric, time: .shortened) } ?? ""
    }
}

extension NSView {
    func pinVertically(_ views: [NSView], flexible: NSView) {
        var above: NSLayoutYAxisAnchor = topAnchor
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: above),
            ])
            if v !== flexible {
                (v as? NSStackView)?.setHuggingPriority(.required, for: .vertical)
                v.setContentHuggingPriority(.required, for: .vertical)
                v.setContentCompressionResistancePriority(.required, for: .vertical)
            }
            above = v.bottomAnchor
        }
        above.constraint(equalTo: bottomAnchor).isActive = true
    }
}
