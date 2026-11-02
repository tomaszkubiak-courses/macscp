import CSSH
import Foundation

public struct RemoteError: Error, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case connection, hostKeyRejected, authentication, noSuchFile, permissionDenied,
             alreadyExists, failure, unsupported, cancelled
    }
    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var description: String { message }
}

public struct ConnectionParameters: Sendable, Equatable {
    public var host: String

    public var port: Int?

    public var user: String

    public var password: String?

    public var privateKeyPath: String?
    public var useAgent = true
    public var useGSSAPI = true

    public var knownHostsPath: String?

    public var trustedCertificatesPath: String?

    public var region: String?

    public var sshConfigPath: String?
    public var timeoutSeconds = 15

    public init(host: String, port: Int? = nil, user: String = "", password: String? = nil,
                privateKeyPath: String? = nil) {
        self.host = host; self.port = port; self.user = user; self.password = password
        self.privateKeyPath = privateKeyPath
    }
}

public struct HostKeyInfo: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case unknown

        case changed
    }
    public let host: String
    public let port: Int
    public let keyType: String

    public let fingerprint: String
    public let status: Status
}

public enum HostKeyDecision: Sendable { case acceptAndSave, acceptOnce, reject }

public struct InteractivePrompt: Sendable, Equatable {
    public let text: String
    public let echo: Bool
}

public protocol ConnectionPrompter: Sendable {
    func verifyHostKey(_ info: HostKeyInfo) async -> HostKeyDecision
    func verifyCertificate(_ info: CertificateInfo) async -> HostKeyDecision
    func password(user: String, host: String) async -> String?
    func passphrase(keyPath: String) async -> String?
    func keyboardInteractive(name: String, instruction: String, prompts: [InteractivePrompt]) async -> [String]?
    func banner(_ text: String) async
}

final class QueueExecutor: SerialExecutor, @unchecked Sendable {
    let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label) }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

final class SSHConnection {
    let session: ssh_session
    let parameters: ConnectionParameters
    private(set) var resolvedUser = ""

    init(_ parameters: ConnectionParameters) {
        session = ssh_new()
        self.parameters = parameters
    }

    deinit {
        ssh_disconnect(session)
        ssh_free(session)
    }

    var lastError: String {
        let e = String(cString: ssh_get_error(UnsafeMutableRawPointer(session)))
        return e.isEmpty ? (ssh_is_connected(session) == 0 ? "connection closed" : "timed out") : e
    }

    var serverBanner: String {
        guard let s = ssh_get_serverbanner(session) else { return "" }
        return String(cString: s)
    }

    static let publicKeyAlgorithms = [
        "ssh-ed25519-cert-v01@openssh.com", "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        "ecdsa-sha2-nistp384-cert-v01@openssh.com", "ecdsa-sha2-nistp256-cert-v01@openssh.com",
        "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com", "rsa-sha2-512-cert-v01@openssh.com", "rsa-sha2-256-cert-v01@openssh.com",
        "ssh-ed25519", "ecdsa-sha2-nistp521", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa",
    ].joined(separator: ",")

    func connect(prompter: any ConnectionPrompter,
                 isolation: isolated (any Actor)? = #isolation) async throws {
        let p = parameters
        ssh_options_set(session, SSH_OPTIONS_HOST, p.host)
        ssh_options_set(session, SSH_OPTIONS_PUBLICKEY_ACCEPTED_TYPES, Self.publicKeyAlgorithms)

        if ssh_options_parse_config(session, p.sshConfigPath) != SSH_OK {
            throw RemoteError(.connection, "Cannot read SSH config: \(lastError)")
        }
        if var port = p.port.map(UInt32.init) { ssh_options_set(session, SSH_OPTIONS_PORT, &port) }
        if !p.user.isEmpty { ssh_options_set(session, SSH_OPTIONS_USER, p.user) }
        if let kh = p.knownHostsPath { ssh_options_set(session, SSH_OPTIONS_KNOWNHOSTS, kh) }
        var timeout = Int(p.timeoutSeconds)
        ssh_options_set(session, SSH_OPTIONS_TIMEOUT, &timeout)
        if var level = ProcessInfo.processInfo.environment["MACSCP_SSH_DEBUG"].flatMap({ Int32($0) }) {
            ssh_options_set(session, SSH_OPTIONS_LOG_VERBOSITY, &level)
        }

        var user: UnsafeMutablePointer<CChar>?
        ssh_options_get(session, SSH_OPTIONS_USER, &user)
        resolvedUser = user.map { String(cString: $0) } ?? NSUserName()
        ssh_string_free_char(user)

        guard ssh_connect(session) == SSH_OK else { throw RemoteError(.connection, lastError) }
        try await verifyHostKey(prompter: prompter)
        try await authenticate(prompter: prompter)
    }

    private func verifyHostKey(prompter: any ConnectionPrompter,
                               isolation: isolated (any Actor)? = #isolation) async throws {
        let state = ssh_session_is_known_server(session)
        let status: HostKeyInfo.Status
        switch state {
        case SSH_KNOWN_HOSTS_OK: return
        case SSH_KNOWN_HOSTS_CHANGED, SSH_KNOWN_HOSTS_OTHER: status = .changed
        case SSH_KNOWN_HOSTS_UNKNOWN, SSH_KNOWN_HOSTS_NOT_FOUND: status = .unknown
        default: throw RemoteError(.connection, "Cannot check host key: \(lastError)")
        }

        var key: ssh_key?
        guard ssh_get_server_publickey(session, &key) == SSH_OK, let key else {
            throw RemoteError(.connection, "Cannot get host key: \(lastError)")
        }
        defer { ssh_key_free(key) }
        var hash: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ssh_get_publickey_hash(key, SSH_PUBLICKEY_HASH_SHA256, &hash, &len) == SSH_OK else {
            throw RemoteError(.connection, "Cannot hash host key")
        }
        defer { ssh_clean_pubkey_hash(&hash) }
        let fp = ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256, hash, len)
        defer { ssh_string_free_char(fp) }

        var port: UInt32 = 22
        ssh_options_get_port(session, &port)
        let info = HostKeyInfo(host: parameters.host, port: Int(port),
                               keyType: String(cString: ssh_key_type_to_char(ssh_key_type(key))),
                               fingerprint: fp.map { String(cString: $0) } ?? "?", status: status)
        switch await prompter.verifyHostKey(info) {
        case .reject:
            throw RemoteError(.hostKeyRejected, "Host key for \(info.host) was rejected.")
        case .acceptOnce:
            break
        case .acceptAndSave:
            if ssh_session_update_known_hosts(session) != SSH_OK {
                throw RemoteError(.connection, "Cannot update known hosts: \(lastError)")
            }
        }
    }

    private func authenticate(prompter: any ConnectionPrompter,
                              isolation: isolated (any Actor)? = #isolation) async throws {
        var rc = ssh_userauth_none(session, nil)
        if let b = ssh_get_issue_banner(session) {
            let text = String(cString: b)
            ssh_string_free_char(b)
            if !text.isEmpty { await prompter.banner(text) }
        }
        if rc == SSH_AUTH_SUCCESS.rawValue { return }
        if rc == SSH_AUTH_ERROR.rawValue { throw RemoteError(.connection, lastError) }

        func methods() -> UInt32 { UInt32(bitPattern: ssh_userauth_list(session, nil)) }
        func ok(_ rc: Int32) throws -> Bool {
            if rc == SSH_AUTH_ERROR.rawValue { throw RemoteError(.connection, lastError) }
            return rc == SSH_AUTH_SUCCESS.rawValue
        }

        if methods() & SSH_AUTH_METHOD_PUBLICKEY != 0 {
            if let path = parameters.privateKeyPath {
                let key = try await loadPrivateKey(path, prompter: prompter)
                defer { ssh_key_free(key) }
                if try ok(ssh_userauth_publickey(session, nil, key)) { return }
            }
            if parameters.useAgent, ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil {
                if try ok(ssh_userauth_agent(session, nil)) { return }
            }
            if parameters.privateKeyPath == nil {
                rc = ssh_userauth_publickey_auto(session, nil, nil)
                if try ok(rc) { return }
            }
        }

        if parameters.useGSSAPI, methods() & SSH_AUTH_METHOD_GSSAPI_MIC != 0 {
            if try ok(ssh_userauth_gssapi(session)) { return }
        }

        if methods() & SSH_AUTH_METHOD_INTERACTIVE != 0 {
            if try await keyboardInteractive(prompter: prompter) { return }
        }

        if methods() & SSH_AUTH_METHOD_PASSWORD != 0 {
            var password = parameters.password
            if password == nil { password = await prompter.password(user: resolvedUser, host: parameters.host) }
            guard let password else { throw RemoteError(.cancelled, "Authentication cancelled.") }
            if try ok(ssh_userauth_password(session, nil, password)) { return }
        }
        throw RemoteError(.authentication, "Authentication failed for \(resolvedUser)@\(parameters.host).")
    }

    private func loadPrivateKey(_ path: String, prompter: any ConnectionPrompter,
                                isolation: isolated (any Actor)? = #isolation) async throws -> ssh_key {
        var key: ssh_key?
        let expanded = (path as NSString).expandingTildeInPath
        if let text = try? String(contentsOfFile: expanded, encoding: .utf8), PuTTYKey.isPPK(text) {
            return try await loadPuTTYKey(text, path: path, prompter: prompter)
        }
        switch ssh_pki_import_privkey_file(expanded, nil, nil, nil, &key) {
        case SSH_OK: return key!
        case SSH_EOF: throw RemoteError(.authentication, "Private key not found: \(path)")
        default: break
        }

        guard let passphrase = await prompter.passphrase(keyPath: path) else {
            throw RemoteError(.cancelled, "Authentication cancelled.")
        }
        guard ssh_pki_import_privkey_file(expanded, passphrase, nil, nil, &key) == SSH_OK, let key else {
            throw RemoteError(.authentication, "Cannot load private key \(path). Wrong passphrase or unsupported format.")
        }
        return key
    }

    private func loadPuTTYKey(_ text: String, path: String, prompter: any ConnectionPrompter,
                              isolation: isolated (any Actor)? = #isolation) async throws -> ssh_key {
        var passphrase: String?
        if PuTTYKey.isEncrypted(text) {
            passphrase = await prompter.passphrase(keyPath: path)
            guard passphrase != nil else { throw RemoteError(.cancelled, "Authentication cancelled.") }
        }
        let pem: String
        do {
            pem = try PuTTYKey.openSSH(text, passphrase: passphrase)
        } catch PuTTYKey.Failure.wrongPassphrase, PuTTYKey.Failure.needsPassphrase {
            throw RemoteError(.authentication, "Cannot load private key \(path). Wrong passphrase.")
        } catch {
            throw RemoteError(.authentication, "Cannot load PuTTY key \(path): \(error)")
        }
        var key: ssh_key?
        guard ssh_pki_import_privkey_base64(pem, nil, nil, nil, &key) == SSH_OK, let key else {
            throw RemoteError(.authentication, "Cannot load PuTTY key \(path).")
        }
        return key
    }

    private func keyboardInteractive(prompter: any ConnectionPrompter,
                                     isolation: isolated (any Actor)? = #isolation) async throws -> Bool {
        var rc = ssh_userauth_kbdint(session, nil, nil)
        var round = 0
        while rc == SSH_AUTH_INFO.rawValue {
            let n = ssh_userauth_kbdint_getnprompts(session)
            var prompts: [InteractivePrompt] = []
            for i in 0..<max(n, 0) {
                var echo: CChar = 0
                let text = ssh_userauth_kbdint_getprompt(session, UInt32(i), &echo).map { String(cString: $0) } ?? ""
                prompts.append(InteractivePrompt(text: text, echo: echo != 0))
            }
            var answers: [String]

            if round == 0, n == 1, !prompts[0].echo, let pw = parameters.password {
                answers = [pw]
            } else if n == 0 {
                answers = []
            } else {
                let name = String(cString: ssh_userauth_kbdint_getname(session))
                let instruction = String(cString: ssh_userauth_kbdint_getinstruction(session))
                guard let a = await prompter.keyboardInteractive(name: name, instruction: instruction, prompts: prompts),
                      a.count == prompts.count else { throw RemoteError(.cancelled, "Authentication cancelled.") }
                answers = a
            }
            for (i, a) in answers.enumerated() { ssh_userauth_kbdint_setanswer(session, UInt32(i), a) }
            rc = ssh_userauth_kbdint(session, nil, nil)
            round += 1
        }
        if rc == SSH_AUTH_ERROR.rawValue { throw RemoteError(.connection, lastError) }
        return rc == SSH_AUTH_SUCCESS.rawValue
    }

    func sendKeepalive() { ssh_send_ignore(session, "") }

    struct ExecResult {
        var stdout: Data
        var stderr: String
        var exitCode: UInt32
    }

    func finish(_ ch: ssh_channel) {
        if ssh_channel_is_closed(ch) == 0, let event = ssh_event_new() {
            ssh_channel_send_eof(ch)
            ssh_event_add_session(event, session)
            let deadline = Date().addingTimeInterval(2)
            while ssh_channel_is_closed(ch) == 0, ssh_is_connected(session) != 0, Date() < deadline {
                if ssh_event_dopoll(event, 50) == SSH_ERROR { break }
            }
            ssh_event_remove_session(event, session)
            ssh_event_free(event)
        }
        ssh_channel_close(ch)
        ssh_channel_free(ch)
    }

    func openExec(_ command: String) throws -> ssh_channel {
        var attempt = 0
        var ch: ssh_channel
        while true {
            guard let c = ssh_channel_new(session) else { throw RemoteError(.connection, lastError) }
            if ssh_channel_open_session(c) == SSH_OK { ch = c; break }
            let msg = lastError
            ssh_channel_free(c)

            attempt += 1
            guard attempt < 3, ssh_is_connected(session) != 0 else {
                throw RemoteError(.connection, "Cannot open a channel: \(msg)")
            }
            usleep(UInt32(100_000 * attempt))
        }
        guard ssh_channel_request_exec(ch, command) == SSH_OK else {
            let msg = lastError
            ssh_channel_free(ch)
            throw RemoteError(.connection, "Cannot run \(command): \(msg)")
        }
        return ch
    }

    func exec(_ command: String) throws -> ExecResult {
        let ch = try openExec(command)

        defer { finish(ch) }
        var out = Data(), err = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = ssh_channel_read_timeout(ch, &buf, UInt32(buf.count), 0, 100)
            if n == SSH_ERROR { throw RemoteError(.connection, "Reading output of \(command): \(lastError)") }
            if n > 0 { out.append(buf, count: Int(n)) }
            let e = ssh_channel_read_nonblocking(ch, &buf, UInt32(buf.count), 1)
            if e > 0 { err.append(buf, count: Int(e)) }
            if n <= 0, e <= 0, ssh_channel_is_eof(ch) != 0 || ssh_channel_is_closed(ch) != 0 { break }
            if Task.isCancelled { throw RemoteError(.cancelled, "Command cancelled.") }
        }
        ssh_channel_send_eof(ch)
        var code: UInt32 = 0
        var signal: UnsafeMutablePointer<CChar>?
        var core: Int32 = 0

        if ssh_channel_get_exit_state(ch, &code, &signal, &core) != SSH_OK { code = 255 }
        ssh_string_free_char(signal)
        return ExecResult(stdout: out, stderr: String(decoding: err, as: UTF8.self), exitCode: code)
    }
}
