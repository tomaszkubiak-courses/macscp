import Foundation
import XCTest
@testable import RemoteCore

extension IntegrationTests {
    func testSynchronizeDirectionsAndModes() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_700_003_600)
        try await eachTarget { label, fs, base in
            if target(label).1.isS3 || target(label).0.coarseListingTimes { return }
            let local = scratch.appendingPathComponent("sync-\(UUID().uuidString.prefix(6))")
            let fm = FileManager.default
            try fm.createDirectory(at: local.appendingPathComponent("sub"), withIntermediateDirectories: true)
            func writeLocal(_ name: String, _ text: String, _ date: Date) throws {
                let url = local.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            func writeRemote(_ name: String, _ text: String, _ date: Date) async throws {
                let tmp = scratch.appendingPathComponent(UUID().uuidString)
                try text.write(to: tmp, atomically: true, encoding: .utf8)
                let path = RemotePath.join(base, name)
                try await fs.upload(tmp, to: path, offset: 0, progress: { _ in })
                try await fs.setModified(path, date)
            }
            try writeLocal("a.txt", "local only", old)
            try writeLocal("b.txt", "local newer", new)
            try writeLocal("c.txt", "local older", old)
            try writeLocal("sub/d.txt", "same", old)
            try await fs.makeDirectory(RemotePath.join(base, "sub"))
            try await fs.makeDirectory(RemotePath.join(base, "rdir"))
            try await writeRemote("b.txt", "remote older", old)
            try await writeRemote("c.txt", "remote newer", new)
            try await writeRemote("sub/d.txt", "same", old)
            try await writeRemote("r.txt", "remote only", old)
            try await writeRemote("rdir/x", "x", old)

            let sync = Synchronizer(fs: fs)
            func plan(_ configure: (inout SyncOptions) -> Void) async throws -> [String] {
                var o = SyncOptions()
                configure(&o)
                return try await sync.compare(local: local.path, remote: base, options: o)
                    .map { "\($0.kind.rawValue) \(RemotePath.name($0.remotePath))" }.sorted()
            }
            let toRemote = try await plan { $0.direction = .toRemote }
            XCTAssertEqual(toRemote, ["uploadNew a.txt", "uploadUpdate b.txt"], label)
            let mirror = try await plan { $0.direction = .toRemote; $0.mirror = true; $0.deleteExtra = true }
            XCTAssertEqual(mirror, ["deleteRemote r.txt", "deleteRemote rdir", "uploadNew a.txt", "uploadUpdate b.txt", "uploadUpdate c.txt"], label)
            let toLocal = try await plan { $0.direction = .toLocal }
            XCTAssertEqual(toLocal, ["downloadNew r.txt", "downloadNew rdir", "downloadUpdate c.txt"], label)
            let existing = try await plan { $0.direction = .toLocal; $0.existingOnly = true }
            XCTAssertEqual(existing, ["downloadUpdate c.txt"], label)
            let masked = try await plan { $0.direction = .both; $0.transfer.includeMask = "| r*; r*/" }
            XCTAssertEqual(masked, ["downloadUpdate c.txt", "uploadNew a.txt", "uploadUpdate b.txt"], label)

            var both = SyncOptions()
            both.direction = .both
            let actions = try await sync.compare(local: local.path, remote: base, options: both)
            XCTAssertEqual(actions.count, 5, label)
            try await sync.apply(actions, options: both)
            let after = try await sync.compare(local: local.path, remote: base, options: both)
            XCTAssertEqual(after.map { "\($0.kind.rawValue) \($0.remotePath)" }, [], label)
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("c.txt"), encoding: .utf8), "remote newer", label)
            XCTAssertTrue(fm.fileExists(atPath: local.appendingPathComponent("rdir/x").path), label)
            let uploaded = try await fs.fileInfo(RemotePath.join(base, "a.txt"))
            XCTAssertEqual(uploaded?.size, 10, label)

            var del = SyncOptions()
            del.direction = .toLocal
            del.deleteExtra = true
            try fm.removeItem(at: local.appendingPathComponent("rdir"))
            try await fs.delete(RemotePath.join(base, "a.txt"), isDirectory: false)
            let delPlan = try await sync.compare(local: local.path, remote: base, options: del)
            XCTAssertEqual(delPlan.map { "\($0.kind.rawValue) \(RemotePath.name($0.remotePath))" }.sorted(),
                           ["deleteLocal a.txt", "downloadNew rdir"], label)
            try await sync.apply(delPlan, options: del)
            XCTAssertFalse(fm.fileExists(atPath: local.appendingPathComponent("a.txt").path), label)
        }
    }
}
