import Foundation
import XCTest
@testable import RemoteCore

extension IntegrationTests {
    static func killServerSessions() {
        let dir = Self.root.appendingPathComponent("build/sshd")
        for pidFile in ["sshd.pid", "dropbear.pid"] {
            guard let pid = try? String(contentsOf: dir.appendingPathComponent(pidFile), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-P", pid]
            try? p.run()
            p.waitUntilExit()
        }
    }

    func testTransferSurvivesDroppedConnection() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("build/sshd/sshd.pid").path),
                          "needs the local test servers")
        let local = try randomFile("drop.bin", size: 20_000_000)
        for s in servers {
            for proto in s.protocols {
                let label = "\(s.name)/\(proto.rawValue)"
                let params = parameters(s)
                let connect: TransferEngine.Connect = { try await Session.connect(proto, params, Prompter()) }
                let setup = try await connect()
                let base = RemotePath.join(try await setup.homeDirectory(), "macscp-drop-\(UUID().uuidString.prefix(8))")
                try await setup.makeDirectory(base)
                await setup.disconnect()

                let killed = Flag()
                let kill: @Sendable () -> Void = { Self.killServerSessions() }
                let engine = TransferEngine(fs: try await connect(), delegate: NonInteractiveTransferDelegate(),
                                            reconnect: connect, onProgress: { p in

                    if p.doneBytes > 3_000_000, killed.setOnce() { kill() }
                })
                do {
                    try await engine.run(TransferRequest(direction: .upload, sources: [local.path], targetDirectory: base))
                    XCTAssertTrue(killed.isSet, "\(label): connection was never dropped")

                    let down = scratch.appendingPathComponent("drop-\(label.replacingOccurrences(of: "/", with: "-"))")
                    try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
                    let killed2 = Flag()
                    let engine2 = TransferEngine(fs: try await connect(), delegate: NonInteractiveTransferDelegate(),
                                                 reconnect: connect, onProgress: { p in
                        if p.doneBytes > 3_000_000, killed2.setOnce() { kill() }
                    })
                    try await engine2.run(TransferRequest(direction: .download, sources: [RemotePath.join(base, "drop.bin")],
                                                          targetDirectory: down.path))
                    XCTAssertTrue(killed2.isSet, "\(label): download connection was never dropped")
                    assertSameContent(local, down.appendingPathComponent("drop.bin"), label)
                } catch {
                    XCTFail("\(label): \(error)")
                }
                let cleanup = try await connect()
                try? await cleanup.delete(base, isDirectory: true)
                await cleanup.disconnect()
            }
        }
    }

    func testDifferentlyNormalizedNameIsOverwrittenNotDuplicated() async throws {
        let nfc = "Zürich.txt".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let dir = scratch.appendingPathComponent("nfc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(nfc)
        try "new".write(to: local, atomically: true, encoding: .utf8)
        let old = try randomFile("old", size: 10)
        try await eachTarget { label, fs, base in
            try await fs.upload(old, to: RemotePath.join(base, nfd), offset: 0, progress: { _ in })
            try await TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(answer: .overwriteAll))
                .run(TransferRequest(direction: .upload, sources: [local.path], targetDirectory: base))
            let entries = try await fs.list(base)
            XCTAssertEqual(entries.count, 1, "\(label): \(entries.map(\.name))")
            XCTAssertEqual(entries.first?.size, 3, label)
        }
    }

    func testSymlinkLoopsEnd() async throws {
        let src = scratch.appendingPathComponent("looped")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        _ = try randomFile("f", size: 10, in: src.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("sub/up").path, withDestinationPath: "..")
        try await eachTarget { label, fs, base in
            let engine = TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate())
            try await engine.run(TransferRequest(direction: .upload, sources: [src.path], targetDirectory: base))
            let sub = try await fs.list(RemotePath.join(base, "looped/sub")).map(\.name).sorted()
            XCTAssertEqual(sub, ["f"], label)

            if !target(label).1.isSSH { return }
            let remoteLoop = RemotePath.join(base, "looped/sub/back")
            try await fs.createSymlink(remoteLoop, target: RemotePath.join(base, "looped"))
            let down = scratch.appendingPathComponent("loopdown-\(label.replacingOccurrences(of: "/", with: "-"))")
            try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
            try await engine.run(TransferRequest(direction: .download, sources: [RemotePath.join(base, "looped")],
                                                 targetDirectory: down.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: down.appendingPathComponent("looped/sub/f").path), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: down.appendingPathComponent("looped/sub/back").path), label)
        }
    }

    func testTransferNeverReplacesAFolderWithAFile() async throws {
        let file = try randomFile("victim", size: 10)
        try await eachTarget { label, fs, base in

            let remoteDir = RemotePath.join(base, "victim")
            try await fs.makeDirectory(remoteDir)
            try await fs.upload(file, to: RemotePath.join(remoteDir, "keep"), offset: 0, progress: { _ in })
            let e1 = Recorder()
            try await TransferEngine(fs: fs, delegate: e1)
                .run(TransferRequest(direction: .upload, sources: [file.path], targetDirectory: base))
            let kept = try await fs.fileInfo(RemotePath.join(remoteDir, "keep"))
            XCTAssertNotNil(kept, "\(label): remote folder content lost")
            XCTAssertEqual(e1.failures, 1, label)

            let down = scratch.appendingPathComponent("fold-\(label.replacingOccurrences(of: "/", with: "-"))")
            try FileManager.default.createDirectory(at: down.appendingPathComponent("payload"), withIntermediateDirectories: true)
            try "x".write(to: down.appendingPathComponent("payload/keep"), atomically: true, encoding: .utf8)
            try await fs.upload(file, to: RemotePath.join(base, "payload"), offset: 0, progress: { _ in })
            let e2 = Recorder()
            try await TransferEngine(fs: fs, delegate: e2)
                .run(TransferRequest(direction: .download, sources: [RemotePath.join(base, "payload")], targetDirectory: down.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: down.appendingPathComponent("payload/keep").path), label)
            XCTAssertEqual(e2.failures, 1, label)
        }
    }

    func testListsHundredThousandEntries() async throws {
        try XCTSkipUnless(Self.env["MACSCP_PERF"] == "1", "set MACSCP_PERF=1")
        try await eachTarget { label, fs, base in
            let big = RemotePath.join(base, "big")
            try await fs.makeDirectory(big)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "cd \(RemotePath.shellQuote(big)) && seq -f 'file-%06g.txt' 1 100000 | xargs touch"]
            try p.run()
            p.waitUntilExit()
            let start = Date()
            let entries = try await fs.list(big)
            let secs = Date().timeIntervalSince(start)
            print("PERF \(label): listed \(entries.count) entries in \(String(format: "%.2f", secs)) s")
            XCTAssertEqual(entries.count, 100_000, label)
            XCTAssertLessThan(secs, 10, label)
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func setOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if set { return false }; set = true; return true }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
}

final class Recorder: TransferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var failures: Int { lock.lock(); defer { lock.unlock() }; return count }
    func overwrite(_ q: OverwriteQuestion) async -> OverwriteAnswer { .overwriteAll }
    func failed(_ error: RemoteError, path: String) async -> FailureAnswer {
        lock.withLock { count += 1 }
        return .skip
    }
}

extension IntegrationTests {
    func testBrowsingReconnectsAfterDrop() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("build/sshd/sshd.pid").path),
                          "needs the local test servers")
        for s in servers {
            for proto in s.protocols {
                var site = Site(name: s.name, host: "127.0.0.1", fileProtocol: proto, user: user)
                site.port = s.port
                let session = try await Session.open(site: site, password: nil, prompter: Prompter(),
                                                     transferDelegate: NonInteractiveTransferDelegate(), parameters: parameters(s))
                let home = try await session.browse { try await $0.homeDirectory() }
                Self.killServerSessions()
                try await Task.sleep(for: .milliseconds(300))
                let listed = try await session.browse { try await $0.list(home) }
                XCTAssertFalse(listed.isEmpty, "\(s.name)/\(proto.rawValue)")
                await session.close()
            }
        }
    }
}
