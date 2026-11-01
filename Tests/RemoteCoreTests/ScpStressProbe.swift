import Foundation
import XCTest
@testable import RemoteCore

extension IntegrationTests {
    func testProbeConcurrentScp() async throws {
        try XCTSkipUnless(Self.env["MACSCP_PROBE"] == "1")
        for s in servers where s.protocols.contains(.scp) {
            let writer = try await connect(s, .scp)
            let reader = try await connect(s, .scp)
            let base = RemotePath.join(try await writer.homeDirectory(), "probe-\(UUID().uuidString.prefix(6))")
            try await writer.makeDirectory(base)
            let file = RemotePath.join(base, "f.txt")
            let src = try randomFile("probe.bin", size: 2000)
            try await writer.upload(src, to: file, offset: 0, progress: { _ in })
            var failures: [String] = []
            let rounds = 150
            let dir: URL = scratch
            for i in 0..<rounds {
                let target = dir.appendingPathComponent("p\(i)")
                async let w: Void = writer.upload(src, to: file, offset: 0, progress: { _ in })
                async let r: Void = reader.download(file, to: target, offset: 0, progress: { _ in })
                async let l = reader.fileInfo(file)
                do { try await w } catch { failures.append("upload: \(error)") }
                do { try await r } catch { failures.append("download: \(error)") }
                do { _ = try await l } catch { failures.append("info: \(error)") }
            }
            print("PROBE \(s.name) eof=\(Self.env["MACSCP_NO_EXEC_EOF"] == nil): \(failures.count) failures in \(rounds) rounds")
            for f in Set(failures).prefix(5) { print("PROBE   \(f)") }
            try? await writer.delete(base, isDirectory: true)
            await writer.disconnect()
            await reader.disconnect()
        }
    }
}
