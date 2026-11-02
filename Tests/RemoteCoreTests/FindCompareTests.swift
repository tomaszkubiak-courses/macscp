import Foundation
import XCTest
@testable import RemoteCore

final class DirectoryComparisonTests: XCTestCase {
    func testDifferences() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let local = [
            ComparedEntry(name: "same.txt", isDirectory: false, size: 5, modified: t),
            ComparedEntry(name: "newer-here.txt", isDirectory: false, size: 5, modified: t.addingTimeInterval(60)),
            ComparedEntry(name: "older-here.txt", isDirectory: false, size: 5, modified: t),
            ComparedEntry(name: "resized.txt", isDirectory: false, size: 9, modified: t),
            ComparedEntry(name: "only-local", isDirectory: true, size: 0, modified: t),
            ComparedEntry(name: "both-dirs", isDirectory: true, size: 0, modified: t),
            ComparedEntry(name: "Zu\u{0308}rich", isDirectory: false, size: 1, modified: t),
        ]
        let remote = [
            ComparedEntry(name: "same.txt", isDirectory: false, size: 5, modified: t.addingTimeInterval(0.4)),
            ComparedEntry(name: "newer-here.txt", isDirectory: false, size: 5, modified: t),
            ComparedEntry(name: "older-here.txt", isDirectory: false, size: 5, modified: t.addingTimeInterval(60)),
            ComparedEntry(name: "resized.txt", isDirectory: false, size: 7, modified: t),
            ComparedEntry(name: "only-remote.txt", isDirectory: false, size: 1, modified: t),
            ComparedEntry(name: "both-dirs", isDirectory: true, size: 0, modified: t.addingTimeInterval(99)),
            ComparedEntry(name: "Z\u{00FC}rich", isDirectory: false, size: 1, modified: t),
        ]
        let d = DirectoryComparison.differences(local: local, remote: remote)
        XCTAssertEqual(d.local, ["newer-here.txt", "resized.txt", "only-local"])
        XCTAssertEqual(d.remote, ["older-here.txt", "resized.txt", "only-remote.txt"])
    }
}

extension IntegrationTests {
    func testFindFiles() async throws {
        try await eachTarget { label, fs, base in
            let src = scratch.appendingPathComponent("find-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: src.appendingPathComponent("logs/old"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: src.appendingPathComponent("skip"), withIntermediateDirectories: true)
            _ = try randomFile("a.log", size: 10, in: src)
            _ = try randomFile("b.txt", size: 10, in: src)
            _ = try randomFile("c.log", size: 2000, in: src.appendingPathComponent("logs/old"))
            _ = try randomFile("d.log", size: 10, in: src.appendingPathComponent("skip"))
            try await TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate())
                .run(TransferRequest(direction: .upload, sources: [src.path], targetDirectory: base))
            let root = RemotePath.join(base, src.lastPathComponent)
            func find(_ mask: String) async throws -> [String] {
                let hits = Hits()
                try await FileFinder.find(in: root, mask: try FileMask(mask), fs: fs) { hits.add($0) }
                return hits.paths.map { String($0.dropFirst(root.count + 1)) }.sorted()
            }
            let logs = try await find("*.log")
            XCTAssertEqual(logs, ["a.log", "logs/old/c.log", "skip/d.log"], label)
            let filtered = try await find("*.log | skip/")
            XCTAssertEqual(filtered, ["a.log", "logs/old/c.log"], label)
            let big = try await find(">1K")
            XCTAssertEqual(big, ["logs/old/c.log"], label)
            let dirs = try await find("old/")
            XCTAssertEqual(dirs, ["logs/old"], label)
        }
    }
}

final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [FoundFile] = []
    func add(_ f: [FoundFile]) { lock.lock(); found += f; lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return found.map(\.path) }
}
