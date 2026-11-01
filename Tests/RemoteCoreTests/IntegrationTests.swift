import Foundation
import XCTest
@testable import RemoteCore

final class IntegrationTests: XCTestCase {
    struct Server {
        let name: String
        let port: Int
        var protocols: [FileProtocol] = FileProtocol.allCases
    }

    static let env = ProcessInfo.processInfo.environment
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let keys = env["MACSCP_TEST_KEYS"] ?? root.appendingPathComponent("build/sshd").path
    let user = env["MACSCP_TEST_USER"] ?? NSUserName()
    let servers: [Server] = (env["MACSCP_TEST_SERVERS"] ?? "openssh:2222,dropbear:2223").split(separator: ",").map {
        let p = $0.split(separator: ":")
        var s = Server(name: String(p[0]), port: Int(p[1])!)
        if p.count > 2 { s.protocols = p[2].split(separator: "+").compactMap { FileProtocol(rawValue: String($0)) } }
        return s
    }
    var scratch: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.env["MACSCP_INTEGRATION"] == "1", "set MACSCP_INTEGRATION=1")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    final class Prompter: ConnectionPrompter, @unchecked Sendable {
        var hostKeyDecision = HostKeyDecision.acceptOnce
        var passphraseAnswer: String?
        var passwordAnswer: String?
        var kbdAnswer: String?
        var hostKeyQuestions: [HostKeyInfo] = []
        var passphraseAsked = 0
        func verifyHostKey(_ info: HostKeyInfo) async -> HostKeyDecision { hostKeyQuestions.append(info); return hostKeyDecision }
        func password(user: String, host: String) async -> String? { passwordAnswer }
        func passphrase(keyPath: String) async -> String? { passphraseAsked += 1; return passphraseAnswer }
        func keyboardInteractive(name: String, instruction: String, prompts: [InteractivePrompt]) async -> [String]? {
            kbdAnswer.map { a in prompts.map { _ in a } }
        }
        func banner(_ text: String) async {}
    }

    func parameters(_ s: Server, key: String? = "id_ed25519") -> ConnectionParameters {
        var p = ConnectionParameters(host: "127.0.0.1", port: s.port, user: user,
                                     privateKeyPath: key.map { "\(keys)/\($0)" })
        p.useAgent = false
        p.useGSSAPI = false
        p.knownHostsPath = scratch.appendingPathComponent("known_hosts").path
        p.sshConfigPath = "/dev/null"
        return p
    }

    func connect(_ s: Server, _ proto: FileProtocol, _ p: ConnectionParameters? = nil,
                 prompter: Prompter = Prompter()) async throws -> any RemoteFileSystem {
        try await Session.connect(proto, p ?? parameters(s), prompter)
    }

    func eachTarget(protocols: [FileProtocol] = FileProtocol.allCases,
                    _ body: (String, any RemoteFileSystem, String) async throws -> Void) async throws {
        for s in servers {
            for proto in protocols where s.protocols.contains(proto) {
                let label = "\(s.name)/\(proto.rawValue)"
                let fs = try await connect(s, proto)
                let base = RemotePath.join(try await fs.homeDirectory(), "macscp-test-\(UUID().uuidString.prefix(8))")
                try await fs.makeDirectory(base)
                do {
                    try await body(label, fs, base)
                } catch {
                    XCTFail("\(label): \(error)")
                }
                try? await fs.delete(base, isDirectory: true)
                await fs.disconnect()
            }
        }
    }

    func randomFile(_ name: String, size: Int, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? scratch).appendingPathComponent(name)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: url)
        return url
    }

    func assertSameContent(_ a: URL, _ b: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try? Data(contentsOf: a), try? Data(contentsOf: b), "\(label): \(b.lastPathComponent) differs",
                       file: file, line: line)
    }

    func testFileOperations() async throws {
        let local = try randomFile("payload.bin", size: 300_000)
        try await eachTarget { label, fs, base in
            let remote = RemotePath.join(base, "payload.bin")
            try await fs.upload(local, to: remote, offset: 0, progress: { _ in })

            let listed = try await fs.list(base)
            XCTAssertEqual(listed.map(\.name), ["payload.bin"], label)
            XCTAssertEqual(listed.first?.size, 300_000, label)
            XCTAssertEqual(listed.first?.type, .file, label)

            let back = scratch.appendingPathComponent("back-\(label.replacingOccurrences(of: "/", with: "-"))")
            try await fs.download(remote, to: back, offset: 0, progress: { _ in })
            assertSameContent(local, back, label)

            let renamed = RemotePath.join(base, "renamed file.bin")
            try await fs.rename(remote, to: renamed)
            let missing = try await fs.fileInfo(remote)
            XCTAssertNil(missing, label)

            try await fs.setPermissions(renamed, Permissions(0o600))
            let info = try await fs.fileInfo(renamed)
            XCTAssertEqual(info?.permissions.mode, 0o600, label)

            let when = Date(timeIntervalSince1970: 1_700_000_040)
            try await fs.setModified(renamed, when)
            let timed = try await fs.fileInfo(renamed)
            XCTAssertEqual(timed?.modified, when, label)

            let sub = RemotePath.join(base, "sub dir")
            try await fs.makeDirectory(sub)
            try await fs.createSymlink(RemotePath.join(base, "file-link"), target: renamed)
            try await fs.createSymlink(RemotePath.join(base, "dir-link"), target: sub)
            try await fs.createSymlink(RemotePath.join(base, "broken-link"), target: RemotePath.join(base, "nope"))
            let entries = Dictionary(uniqueKeysWithValues: try await fs.list(base).map { ($0.name, $0) })
            XCTAssertEqual(entries["file-link"]?.type, .symlink, label)
            XCTAssertEqual(entries["file-link"]?.linkTarget, renamed, label)
            XCTAssertEqual(entries["file-link"]?.targetType, .file, label)
            XCTAssertEqual(entries["dir-link"]?.targetType, .directory, label)
            XCTAssertEqual(entries["dir-link"]?.isDirectory, true, label)
            XCTAssertNil(entries["broken-link"]?.targetType, label)
            XCTAssertEqual(entries["sub dir"]?.type, .directory, label)

            try await fs.delete(RemotePath.join(base, "dir-link"), isDirectory: false)
            let subStill = try await fs.fileInfo(sub)
            XCTAssertNotNil(subStill, label)

            let nested = RemotePath.join(sub, "deeper")
            try await fs.makeDirectory(nested)
            try await fs.upload(local, to: RemotePath.join(nested, "x"), offset: 0, progress: { _ in })
            try await fs.delete(sub, isDirectory: true)
            let gone = try await fs.fileInfo(sub)
            XCTAssertNil(gone, label)

            let canon = try await fs.canonicalPath(base + "/./")
            XCTAssertEqual(canon, base, label)

            do {
                _ = try await fs.list(RemotePath.join(base, "does-not-exist"))
                XCTFail("\(label): listing a missing directory should fail")
            } catch let e as RemoteError {
                XCTAssertEqual(e.kind, .noSuchFile, "\(label): \(e)")
            }
        }
    }

    func testRecursiveTransferWithMaskAndUnicode() async throws {
        let src = scratch.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        _ = try randomFile("one.txt", size: 10, in: src)
        _ = try randomFile("skip.bak", size: 10, in: src)
        _ = try randomFile("deep.txt", size: 200_000, in: src.appendingPathComponent("a/b"))

        let nfd = "zaz\u{0307}o\u{0301}łc\u{0301} 🚀.txt"
        _ = try randomFile(nfd, size: 5, in: src)

        try await eachTarget { label, fs, base in
            var options = TransferOptions()
            options.includeMask = "| *.bak"
            let engine = TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate())
            try await engine.run(TransferRequest(direction: .upload, sources: [src.path], targetDirectory: base, options: options))

            let names = Set(try await fs.list(RemotePath.join(base, "tree")).map(\.name))
            XCTAssertEqual(names, ["one.txt", "a", nfd.precomposedStringWithCanonicalMapping], label)
            let deep = try await fs.fileInfo(RemotePath.join(base, "tree/a/b/deep.txt"))
            XCTAssertEqual(deep?.size, 200_000, label)

            let down = scratch.appendingPathComponent("down-\(label.replacingOccurrences(of: "/", with: "-"))")
            try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
            try await engine.run(TransferRequest(direction: .download, sources: [RemotePath.join(base, "tree")],
                                                 targetDirectory: down.path))
            assertSameContent(src.appendingPathComponent("a/b/deep.txt"), down.appendingPathComponent("tree/a/b/deep.txt"), label)
            let srcTime = try FileManager.default.attributesOfItem(atPath: src.appendingPathComponent("one.txt").path)[.modificationDate] as! Date
            let downTime = try FileManager.default.attributesOfItem(atPath: down.appendingPathComponent("tree/one.txt").path)[.modificationDate] as! Date

            XCTAssertEqual(srcTime.timeIntervalSince1970, downTime.timeIntervalSince1970, accuracy: 60, label)
        }
    }

    func testResume() async throws {
        let local = try randomFile("big.bin", size: 1_000_000)
        let data = try Data(contentsOf: local)
        try await eachTarget(protocols: [.sftp]) { label, fs, base in
            let engine = TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate())

            let half = scratch.appendingPathComponent("half")
            try data.prefix(400_000).write(to: half)
            try await fs.upload(half, to: RemotePath.join(base, "big.bin.filepart"), offset: 0, progress: { _ in })
            let tracker = ByteTracker()
            let resumeEngine = TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(), onProgress: { tracker.record($0) })
            try await resumeEngine.run(TransferRequest(direction: .upload, sources: [local.path], targetDirectory: base))
            let remote = try await fs.fileInfo(RemotePath.join(base, "big.bin"))
            XCTAssertEqual(remote?.size, 1_000_000, label)
            let partialLeft = try await fs.fileInfo(RemotePath.join(base, "big.bin.filepart"))
            XCTAssertNil(partialLeft, label)
            XCTAssertGreaterThanOrEqual(tracker.firstAboveZero ?? 0, 400_000, "\(label): did not resume")

            let down = scratch.appendingPathComponent("down-\(label.replacingOccurrences(of: "/", with: "-"))")
            try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
            try data.prefix(300_000).write(to: down.appendingPathComponent("big.bin.filepart"))
            try await engine.run(TransferRequest(direction: .download, sources: [RemotePath.join(base, "big.bin")],
                                                 targetDirectory: down.path))
            assertSameContent(local, down.appendingPathComponent("big.bin"), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: down.appendingPathComponent("big.bin.filepart").path), label)

            try data.prefix(100_000).write(to: down.appendingPathComponent("big.bin"))
            let resumer = TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(answer: .resume))
            try await resumer.run(TransferRequest(direction: .download, sources: [RemotePath.join(base, "big.bin")],
                                                  targetDirectory: down.path))
            assertSameContent(local, down.appendingPathComponent("big.bin"), label)
        }
    }

    func testOverwriteDecisions() async throws {
        let local = try randomFile("f.txt", size: 100)
        try await eachTarget { label, fs, base in
            let target = RemotePath.join(base, "f.txt")
            let other = try randomFile("other", size: 50)
            try await fs.upload(other, to: target, offset: 0, progress: { _ in })

            try await TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(answer: .skip))
                .run(TransferRequest(direction: .upload, sources: [local.path], targetDirectory: base))
            let skipped = try await fs.fileInfo(target)
            XCTAssertEqual(skipped?.size, 50, label)

            try await fs.setModified(target, Date().addingTimeInterval(3600))
            try await TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(answer: .overwriteAllIfNewer))
                .run(TransferRequest(direction: .upload, sources: [local.path], targetDirectory: base))
            let kept = try await fs.fileInfo(target)
            XCTAssertEqual(kept?.size, 50, label)

            try await TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(answer: .overwrite))
                .run(TransferRequest(direction: .upload, sources: [local.path], targetDirectory: base))
            let replaced = try await fs.fileInfo(target)
            XCTAssertEqual(replaced?.size, 100, label)
        }
    }

    func testQueueRunsInParallelOnOwnConnections() async throws {
        let files = try (0..<4).map { try randomFile("q\($0).bin", size: 150_000) }
        for s in servers {
            let fs = try await connect(s, .sftp)
            let base = RemotePath.join(try await fs.homeDirectory(), "macscp-queue-\(UUID().uuidString.prefix(8))")
            try await fs.makeDirectory(base)
            let params = parameters(s)
            let counter = ByteTracker()
            let queue = TransferQueue(delegate: NonInteractiveTransferDelegate(), connect: {
                counter.record(1)
                return try await Session.connect(.sftp, params, Prompter())
            })
            var ids: [UUID] = []
            for f in files {
                ids.append(await queue.add(TransferRequest(direction: .upload, sources: [f.path], targetDirectory: base)))
            }
            for id in ids { await queue.wait(for: id) }
            let states = await queue.snapshot.map(\.state)
            XCTAssertEqual(states, Array(repeating: .done, count: 4), s.name)
            XCTAssertEqual(counter.count, 2, "\(s.name): expected 2 transfer connections")
            let names = try await fs.list(base).map(\.name).sorted()
            XCTAssertEqual(names, ["q0.bin", "q1.bin", "q2.bin", "q3.bin"], s.name)
            await queue.shutdown()
            try await fs.delete(base, isDirectory: true)
            await fs.disconnect()
        }
    }

    func testEncryptedKeyAsksForPassphrase() async throws {
        for s in servers {
            let p = Prompter()
            p.passphraseAnswer = "test-pass"
            let fs = try await connect(s, .sftp, parameters(s, key: "id_encrypted"), prompter: p)
            XCTAssertEqual(p.passphraseAsked, 1, s.name)
            await fs.disconnect()

            let wrong = Prompter()
            wrong.passphraseAnswer = "nope"
            do {
                _ = try await connect(s, .sftp, parameters(s, key: "id_encrypted"), prompter: wrong)
                XCTFail("\(s.name): wrong passphrase accepted")
            } catch let e as RemoteError {
                XCTAssertEqual(e.kind, .authentication, s.name)
            }
        }
    }

    func testAgentAuthentication() async throws {
        let sock = scratch.appendingPathComponent("agent.sock").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        agent.arguments = ["ssh-agent", "-D", "-a", sock]
        try agent.run()
        defer { agent.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: sock) { try await Task.sleep(for: .milliseconds(100)) }
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        add.arguments = ["SSH_AUTH_SOCK=\(sock)", "ssh-add", "-q", "\(keys)/id_ed25519"]
        try add.run()
        add.waitUntilExit()
        XCTAssertEqual(add.terminationStatus, 0)

        let previous = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        setenv("SSH_AUTH_SOCK", sock, 1)
        defer { if let previous { setenv("SSH_AUTH_SOCK", previous, 1) } else { unsetenv("SSH_AUTH_SOCK") } }
        for s in servers {
            var p = parameters(s, key: nil)
            p.useAgent = true
            let fs = try await connect(s, .sftp, p)
            _ = try await fs.homeDirectory()
            await fs.disconnect()
        }
    }

    func testWrongKeyFailsAuthentication() async throws {
        let other = scratch.appendingPathComponent("other_key")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gen.arguments = ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other.path]
        try gen.run()
        gen.waitUntilExit()
        for s in servers {
            var p = parameters(s)
            p.privateKeyPath = other.path
            do {
                _ = try await connect(s, .sftp, p)
                XCTFail("\(s.name): unknown key accepted")
            } catch let e as RemoteError {
                XCTAssertTrue(e.kind == .authentication || e.kind == .cancelled, "\(s.name): \(e)")
            }
        }
    }

    func testPasswordAndKeyboardInteractive() async throws {
        try XCTSkipIf(Self.env["MACSCP_TEST_PASSWORD"] == nil, "set MACSCP_TEST_PASSWORD")
        let password = Self.env["MACSCP_TEST_PASSWORD"]!
        for s in servers {
            var p = parameters(s, key: nil)
            p.password = password
            let fs = try await connect(s, .sftp, p)
            await fs.disconnect()

            let prompter = Prompter()
            prompter.passwordAnswer = password
            prompter.kbdAnswer = password
            let fs2 = try await connect(s, s.protocols.last!, parameters(s, key: nil), prompter: prompter)
            await fs2.disconnect()

            var bad = parameters(s, key: nil)
            bad.password = "wrong-\(password)"
            do {
                _ = try await connect(s, .sftp, bad)
                XCTFail("\(s.name): wrong password accepted")
            } catch let e as RemoteError {
                XCTAssertTrue(e.kind == .authentication || e.kind == .cancelled, "\(s.name): \(e)")
            }
        }
    }

    func testHostKeyVerification() async throws {
        for s in servers {
            let p = parameters(s)
            try? FileManager.default.removeItem(atPath: p.knownHostsPath!)

            let first = Prompter()
            first.hostKeyDecision = .acceptAndSave
            await (try await connect(s, .sftp, p, prompter: first)).disconnect()
            XCTAssertEqual(first.hostKeyQuestions.map(\.status), [.unknown], s.name)
            XCTAssertTrue(first.hostKeyQuestions.first?.fingerprint.hasPrefix("SHA256:") == true, s.name)

            let second = Prompter()
            await (try await connect(s, .sftp, p, prompter: second)).disconnect()
            XCTAssertTrue(second.hostKeyQuestions.isEmpty, "\(s.name): known host asked again")

            let fake = try String(contentsOfFile: "\(keys)/id_ed25519.pub", encoding: .utf8).split(separator: " ")
            try "[127.0.0.1]:\(s.port) \(fake[0]) \(fake[1])\n".write(toFile: p.knownHostsPath!, atomically: true, encoding: .utf8)
            let third = Prompter()
            third.hostKeyDecision = .reject
            do {
                _ = try await connect(s, .sftp, p, prompter: third)
                XCTFail("\(s.name): changed key accepted")
            } catch let e as RemoteError {
                XCTAssertEqual(e.kind, .hostKeyRejected, s.name)
            }
            XCTAssertEqual(third.hostKeyQuestions.map(\.status), [.changed], s.name)
        }
    }
}

final class ByteTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func record(_ v: Int64) { lock.lock(); values.append(v); lock.unlock() }
    func record(_ p: TransferProgress) { record(p.doneBytes) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var firstAboveZero: Int64? { lock.lock(); defer { lock.unlock() }; return values.first { $0 > 0 } }
}
