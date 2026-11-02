import Foundation
import XCTest
@testable import RemoteCore

extension IntegrationTests {
    var proxies: [Proxy] {
        (Self.env["MACSCP_TEST_PROXIES"] ?? "socks5:1080,http:3128").split(separator: ",").map {
            let p = $0.split(separator: ":")
            return Proxy(kind: Proxy.Kind(rawValue: String(p[0]))!, host: "127.0.0.1", port: Int(p[1])!)
        }
    }

    func roundTrip(_ s: Server, _ proto: FileProtocol, _ p: ConnectionParameters, _ label: String) async throws {
        let fs = try await connect(s, proto, p)
        let home = try await fs.homeDirectory()
        let file = RemotePath.join(s.home ?? home, "proxy-\(UUID().uuidString.prefix(6)).bin")
        let local = try randomFile("proxy.bin", size: 70_000)
        try await fs.upload(local, to: file, offset: 0, progress: { _ in })
        let back = scratch.appendingPathComponent("proxy-back-\(UUID().uuidString.prefix(6))")
        try await fs.download(file, to: back, offset: 0, progress: { _ in })
        assertSameContent(local, back, label)
        try await fs.delete(file, isDirectory: false)
        await fs.disconnect()
    }

    func testProxiesAndActiveFTP() async throws {
        try XCTSkipIf(proxies.isEmpty, "set MACSCP_TEST_PROXIES")
        let targets: [(Server, FileProtocol)] = [servers.first.map { ($0, FileProtocol.sftp) }, ftpServers.first.map { ($0, .ftp) },
                                                 s3Servers.first { $0.protocols == [.s3http] }.map { ($0, .s3http) },
                                                 davServers.first { $0.protocols == [.webdavhttp] }.map { ($0, .webdavhttp) }]
            .compactMap { $0 }
        for proxy in proxies {
            for (s, proto) in targets {
                var p = parameters(s)
                p.proxy = proxy
                try await roundTrip(s, proto, p, "\(proxy.kind) \(s.name)/\(proto)")
                var dead = p
                dead.proxy?.port = 9
                do {
                    _ = try await connect(s, proto, dead)
                    XCTFail("\(proxy.kind) \(s.name)/\(proto): connected around a dead proxy")
                } catch {}
            }
        }
        for s in ftpServers {
            var p = parameters(s)
            p.ftpActiveMode = true
            try await roundTrip(s, s.protocols[0], p, "active \(s.name)")
        }
    }
}
