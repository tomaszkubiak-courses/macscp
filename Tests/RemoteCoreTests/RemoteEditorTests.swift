import Foundation
import XCTest
@testable import RemoteCore

final class Answers: @unchecked Sendable {
    var overwrite = true
    var asked = 0
}

extension IntegrationTests {
    func waitFor(_ what: String, timeout: Double = 10, _ check: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await check()) == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func remoteContent(_ fs: any RemoteFileSystem, _ path: String) async throws -> String {
        let tmp = scratch.appendingPathComponent(UUID().uuidString)
        try await fs.download(path, to: tmp, offset: 0, progress: { _ in })
        return try String(contentsOf: tmp, encoding: .utf8)
    }

    func testSavesUploadForEveryEditorStyle() async throws {
        let seed = scratch.appendingPathComponent("seed.txt")
        try "original\n".write(to: seed, atomically: true, encoding: .utf8)
        try await eachTarget { label, fs, base in
            let remote = RemotePath.join(base, "notes.txt")
            try await fs.upload(seed, to: remote, offset: 0, progress: { _ in })
            let (s, proto) = target(label)
            if hasAttributes(label) { try await fs.setPermissions(remote, Permissions(0o640)) }
            let params = parameters(s)
            let answers = Answers()
            let editor = RemoteEditor(cacheRoot: scratch.appendingPathComponent("edit-\(UUID().uuidString)"),
                                      settleDelay: .milliseconds(100),
                                      connect: { try await Session.connect(proto, params, Prompter()) },
                                      onConflict: { _ in answers.asked += 1; return answers.overwrite })
            let local: URL
            do { local = try await editor.open(remote) } catch { await editor.stopAll(); throw error }
            do {
            XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "original\n", label)

            try "in place\n".write(to: local, atomically: false, encoding: .utf8)
            try await waitFor("\(label) in-place upload") { try await remoteContent(fs, remote) == "in place\n" }

            let tmp = local.deletingLastPathComponent().appendingPathComponent(".notes.txt.tmp")
            try "atomic\n".write(to: tmp, atomically: false, encoding: .utf8)
            XCTAssertEqual(rename(tmp.path, local.path), 0)
            try await waitFor("\(label) atomic upload") { try await remoteContent(fs, remote) == "atomic\n" }

            let backup = local.appendingPathExtension("~")
            try FileManager.default.moveItem(at: local, to: backup)
            try "vim\n".write(to: local, atomically: false, encoding: .utf8)
            try FileManager.default.removeItem(at: backup)
            try await waitFor("\(label) vim upload") { try await remoteContent(fs, remote) == "vim\n" }

            let info = try await fs.fileInfo(remote)
            if hasAttributes(label) { XCTAssertEqual(info?.permissions.mode, 0o640, label) }
            try await waitFor("\(label) settled") { await !editor.hasPendingUploads }

            let other = scratch.appendingPathComponent("other.txt")
            try "theirs\n".write(to: other, atomically: true, encoding: .utf8)
            if !hasAttributes(label) { try await Task.sleep(for: .milliseconds(1100)) }
            try await fs.upload(other, to: remote, offset: 0, progress: { _ in })
            try await fs.setModified(remote, Date().addingTimeInterval(-7200))
            answers.overwrite = false
            try "mine\n".write(to: local, atomically: false, encoding: .utf8)
            try await waitFor("\(label) conflict") { await editor.files.first?.state == .conflict }
            XCTAssertEqual(answers.asked, 1, label)
            let kept = try await remoteContent(fs, remote)
            XCTAssertEqual(kept, "theirs\n", label)
            } catch {
                await editor.stopAll()
                throw error
            }
            await editor.stopAll()
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.path), label)
        }
    }
}
