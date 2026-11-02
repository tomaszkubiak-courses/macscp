import Foundation
import XCTest
@testable import RemoteCore

final class CustomCommandTests: XCTestCase {
    let ctx = CustomCommand.Context(directory: "/srv/www", host: "example.com", user: "joe", port: 2222, sessionName: "Prod")

    func testExpansionQuotesNames() {
        let touch = CustomCommand(name: "t", command: "touch \"!\"")
        XCTAssertTrue(touch.runsOncePerFile)
        XCTAssertEqual(touch.expand(file: "a b$(rm).txt", files: [], answers: [], context: ctx), "touch 'a b$(rm).txt'")
        let tar = CustomCommand(name: "t", command: "tar -czvf \"!?&Archive name:?a.tgz!\" !& # !! !/ !@ !U !# !N")
        XCTAssertFalse(tar.runsOncePerFile)
        XCTAssertEqual(tar.prompts.map(\.prompt), ["Archive name:"])
        XCTAssertEqual(tar.prompts.map(\.defaultValue), ["a.tgz"])
        XCTAssertEqual(tar.expand(file: nil, files: ["x", "it's"], answers: ["out.tgz"], context: ctx),
                       "tar -czvf 'out.tgz' 'x' 'it'\\''s' # ! /srv/www/ example.com joe 2222 Prod")
        let plain = CustomCommand(name: "u", command: "uptime")
        XCTAssertFalse(plain.usesFiles)
        XCTAssertEqual(plain.expand(file: nil, files: [], answers: [], context: ctx), "uptime")
    }
}

extension IntegrationTests {
    func testShellCommandsTrackDirectory() async throws {
        for s in servers where s.hasShell {
            for proto in s.protocols where proto == .sftp || proto == .scp {
                let fs = try await connect(s, proto) as! any RemoteShell
                let home = try await fs.homeDirectory()
                let r = try await fs.run("echo hello; echo oops >&2; cd /tmp", in: home)
                XCTAssertEqual(r.output, "hello\n", "\(s.name)/\(proto)")
                XCTAssertEqual(r.errorOutput, "oops\n", "\(s.name)/\(proto)")
                XCTAssertEqual(r.exitCode, 0, "\(s.name)/\(proto)")
                let moved = try await fs.canonicalPath(r.directory), tmp = try await fs.canonicalPath("/tmp")
                XCTAssertEqual(moved, tmp, "\(s.name)/\(proto)")
                let failed = try await fs.run("exit 3", in: home)
                XCTAssertEqual(failed.exitCode, 3, "\(s.name)/\(proto)")
                XCTAssertEqual(failed.directory, home, "\(s.name)/\(proto)")
                await fs.disconnect()
            }
        }
        for s in ftpServers {
            let fs = try await connect(s, s.protocols[0]) as! any RemoteShell
            let r = try await fs.run("NOOP", in: "/")
            XCTAssertTrue(r.output.hasPrefix("200"), "\(s.name): \(r.output)")
            await fs.disconnect()
        }
    }
}
