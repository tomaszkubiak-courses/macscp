import Foundation

public actor Session {
    public nonisolated let site: Site

    public private(set) var browser: any RemoteFileSystem
    public nonisolated let queue: TransferQueue
    private var keepaliveTask: Task<Void, Never>?

    public static func open(site: Site, password: String?, prompter: any ConnectionPrompter,
                            transferDelegate: any TransferDelegate, parameters: ConnectionParameters? = nil,
                            maxParallel: Int = 2) async throws -> Session {
        let caching = CachingPrompter(prompter)
        let params = parameters ?? site.connectionParameters(password: password)
        let proto = site.fileProtocol
        let connect: TransferQueue.Connect = {
            try await Self.connect(proto, params, caching)
        }
        let browser = try await connect()
        let queue = TransferQueue(maxParallel: maxParallel, delegate: transferDelegate, connect: connect)
        let s = Session(site: site, browser: browser, queue: queue, connect: connect)
        await s.startKeepalive()
        return s
    }

    public static func connect(_ proto: FileProtocol, _ params: ConnectionParameters,
                               _ prompter: any ConnectionPrompter) async throws -> any RemoteFileSystem {
        switch proto {
        case .sftp: try await SFTPFileSystem.connect(params, prompter: prompter)
        case .scp: try await SCPFileSystem.connect(params, prompter: prompter)
        case .ftp, .ftps, .ftpsImplicit: try await FTPFileSystem.connect(params, proto, prompter: prompter)
        case .s3, .s3http: try await S3FileSystem.connect(params, proto, prompter: prompter)
        }
    }

    private init(site: Site, browser: any RemoteFileSystem, queue: TransferQueue, connect: @escaping TransferQueue.Connect) {
        self.site = site; self.browser = browser; self.queue = queue; connectTransfer = connect
    }

    public func browse<T: Sendable>(_ body: @Sendable (any RemoteFileSystem) async throws -> T) async throws -> T {
        do {
            return try await body(browser)
        } catch let e as RemoteError where e.kind == .connection {
            await browser.disconnect()
            browser = try await connectTransfer()
            return try await body(browser)
        }
    }

    private func startKeepalive(interval: Duration = .seconds(30)) {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.browser.keepalive()
            }
        }
    }

    public nonisolated let connectTransfer: TransferQueue.Connect

    public func close() async {
        keepaliveTask?.cancel()
        await queue.shutdown()
        await browser.disconnect()
    }
}

final class CachingPrompter: ConnectionPrompter, @unchecked Sendable {
    private let inner: any ConnectionPrompter
    private let lock = NSLock()
    private var password: String?
    private var passphrases: [String: String] = [:]
    private var acceptedKeys: Set<String> = []

    init(_ inner: any ConnectionPrompter) { self.inner = inner }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func verifyHostKey(_ info: HostKeyInfo) async -> HostKeyDecision {
        if locked({ acceptedKeys.contains(info.fingerprint) }) { return .acceptOnce }
        let d = await inner.verifyHostKey(info)
        if d != .reject { locked { _ = acceptedKeys.insert(info.fingerprint) } }
        return d
    }

    func verifyCertificate(_ info: CertificateInfo) async -> HostKeyDecision {
        if locked({ acceptedKeys.contains(info.fingerprint) }) { return .acceptOnce }
        let d = await inner.verifyCertificate(info)
        if d != .reject { locked { _ = acceptedKeys.insert(info.fingerprint) } }
        return d
    }

    func password(user: String, host: String) async -> String? {
        if let p = locked({ password }) { return p }
        let p = await inner.password(user: user, host: host)
        locked { password = p }
        return p
    }

    func passphrase(keyPath: String) async -> String? {
        if let p = locked({ passphrases[keyPath] }) { return p }
        let p = await inner.passphrase(keyPath: keyPath)
        locked { passphrases[keyPath] = p }
        return p
    }

    func keyboardInteractive(name: String, instruction: String, prompts: [InteractivePrompt]) async -> [String]? {
        await inner.keyboardInteractive(name: name, instruction: instruction, prompts: prompts)
    }

    func banner(_ text: String) async {}
}
