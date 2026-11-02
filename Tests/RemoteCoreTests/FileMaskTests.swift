import XCTest
@testable import RemoteCore

final class FileMaskTests: XCTestCase {
    func m(_ mask: String, _ path: String, dir: Bool = false, size: Int64? = nil, modified: Date? = nil) throws -> Bool {
        try FileMask(mask).matches(path: path, isDirectory: dir, size: size, modified: modified)
    }

    func testNameMasks() throws {
        XCTAssertTrue(try m("*.txt", "/a/readme.TXT"))
        XCTAssertFalse(try m("*.txt", "/a/readme.md"))
        XCTAssertTrue(try m("*.txt; *.md", "/a/readme.md"))
        XCTAssertTrue(try m("*.txt, *.md", "/a/readme.md"))
        XCTAssertTrue(try m("file?.[a-c]", "/x/file1.b"))
        XCTAssertFalse(try m("file?.[!a-c]", "/x/file1.b"))
        XCTAssertTrue(try m("", "/x/anything"))
        XCTAssertTrue(try m("*.*", "/x/noext"))
    }

    func testNoExtension() throws {
        XCTAssertTrue(try m("*.", "/x/Makefile"))
        XCTAssertFalse(try m("*.", "/x/main.c"))
    }

    func testIncludeExclude() throws {
        XCTAssertTrue(try m("* | *.bak", "/x/a.txt"))
        XCTAssertFalse(try m("* | *.bak", "/x/a.bak"))
        XCTAssertTrue(try m("| *.bak", "/x/a.txt"))
        XCTAssertThrowsError(try FileMask("a | b | c"))
    }

    func testDirectoryMasks() throws {
        XCTAssertFalse(try m("| .git/", "/repo/.git", dir: true))
        XCTAssertTrue(try m("| .git/", "/repo/src", dir: true))
        XCTAssertTrue(try m("| .git/", "/repo/.gitignore"))

        XCTAssertTrue(try m("src/", "/repo/src/deep", dir: true))
        XCTAssertFalse(try m("src/", "/repo/docs", dir: true))
    }

    func testPathMasks() throws {
        XCTAssertTrue(try m("/home/*/*.log", "/home/bob/x.log"))
        XCTAssertFalse(try m("/home/*/*.log", "/var/bob/x.log"))
    }

    func testSizeConditions() throws {
        XCTAssertTrue(try m("*>1K", "/f", size: 2048))
        XCTAssertFalse(try m("*>1K", "/f", size: 1024))
        XCTAssertTrue(try m("*>=1K", "/f", size: 1024))
        XCTAssertTrue(try m("*<1M", "/f", size: 10))
        XCTAssertFalse(try m("*<1M", "/f", size: 2 * 1024 * 1024))
        XCTAssertFalse(try m("*>1K", "/f"))
        XCTAssertThrowsError(try FileMask("*>1X"))
    }

    func testTimeConditions() throws {
        let now = Date()
        let old = now.addingTimeInterval(-3 * 86400)
        XCTAssertTrue(try m("*<1D", "/f", size: 1, modified: old))
        XCTAssertFalse(try m("*>1D", "/f", size: 1, modified: old))
        XCTAssertTrue(try m("*>2020-01-01", "/f", size: 1, modified: now))
        XCTAssertFalse(try m("*<2020-01-01 10:00", "/f", size: 1, modified: now))
        XCTAssertTrue(try m("*>=today", "/f", size: 1, modified: now))
    }

    func testEscapedDelimiter() throws {
        XCTAssertTrue(try m("a;;b", "/x/a;b"))
    }

    func testTransferOptions() throws {
        var o = TransferOptions()
        XCTAssertTrue(o.allowsResume(size: 200 * 1024, fileName: "x"))
        XCTAssertFalse(o.allowsResume(size: 1024, fileName: "x"))
        o.resumeSupport = .off
        XCTAssertFalse(o.allowsResume(size: 1 << 30, fileName: "x"))
        o.includeMask = "*.txt"
        XCTAssertFalse(try o.allowsTransfer(path: "/a.bin", isDirectory: false, isHidden: false, size: 1, modified: nil))
        o.setPermissions = true
        o.permissions = Permissions(0o640)
        XCTAssertEqual(o.uploadPermissions(isDirectory: true)?.mode, 0o750)
        let decoded = try JSONDecoder().decode(TransferOptions.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(decoded, o)
    }
}

final class TextModeTests: XCTestCase {
    func testConversionAndMask() {
        XCTAssertEqual(TransferOptions.convertLineEndings(Data("a\r\nb\rc\nd".utf8), crlf: false), Data("a\nb\nc\nd".utf8))
        XCTAssertEqual(TransferOptions.convertLineEndings(Data("a\r\nb\rc\n".utf8), crlf: true), Data("a\r\nb\r\nc\r\n".utf8))
        var o = TransferOptions()
        XCTAssertFalse(o.isText("index.html"))
        o.mode = .automatic
        XCTAssertTrue(o.isText("index.html"))
        XCTAssertTrue(o.isText(".htaccess"))
        XCTAssertFalse(o.isText("photo.jpg"))
        XCTAssertFalse(o.allowsResume(size: 10 << 20, fileName: "big.txt"))
        let old = try! JSONDecoder().decode(TransferOptions.self, from: Data(#"{"preserveTime":false}"#.utf8))
        XCTAssertFalse(old.preserveTime)
        XCTAssertEqual(old.mode, .binary)
    }
}

extension IntegrationTests {
    func testTextModeTransfers() async throws {
        let dir = scratch.appendingPathComponent("text-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("one\r\ntwo\r\n".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try await eachTarget(protocols: [.sftp, .ftp]) { label, fs, base in
            var o = TransferOptions()
            o.mode = .automatic
            let engine = TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate())
            try await engine.run(TransferRequest(direction: .upload, sources: [dir.appendingPathComponent("notes.txt").path],
                                                 targetDirectory: base, options: o))
            let plain = scratch.appendingPathComponent(UUID().uuidString)
            try await fs.download(RemotePath.join(base, "notes.txt"), to: plain, offset: 0, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: plain), Data("one\ntwo\n".utf8), label)

            o.remoteCRLF = true
            try await TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(answer: .overwriteAll))
                .run(TransferRequest(direction: .upload, sources: [dir.appendingPathComponent("notes.txt").path], targetDirectory: base, options: o))
            try await fs.download(RemotePath.join(base, "notes.txt"), to: plain, offset: 0, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: plain), Data("one\r\ntwo\r\n".utf8), label)

            let down = scratch.appendingPathComponent("text-down-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
            try await engine.run(TransferRequest(direction: .download, sources: [RemotePath.join(base, "notes.txt")],
                                                 targetDirectory: down.path, options: o))
            XCTAssertEqual(try Data(contentsOf: down.appendingPathComponent("notes.txt")), Data("one\ntwo\n".utf8), label)
        }
    }
}
