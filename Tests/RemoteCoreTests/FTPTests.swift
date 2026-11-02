import Foundation
import XCTest
@testable import RemoteCore

final class MLSDTests: XCTestCase {
    func testFacts() throws {
        let (f, type) = try XCTUnwrap(FTPFileSystem.facts("type=file;Size=1234;modify=20240102030405.123;UNIX.mode=0o640;UNIX.owner=joe; a b;c.txt"))
        XCTAssertEqual(type, "file")
        XCTAssertEqual(f.name, "a b;c.txt")
        XCTAssertEqual(f.type, .file)
        XCTAssertEqual(f.size, 1234)
        XCTAssertEqual(f.modified, Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertEqual(f.permissions.mode, 0o640)
        XCTAssertEqual(f.owner, "joe")

        let link = try XCTUnwrap(FTPFileSystem.facts("type=OS.unix=slink:/etc/Target;size=7; link")).0
        XCTAssertEqual(link.type, .symlink)
        XCTAssertEqual(link.linkTarget, "/etc/Target")
        XCTAssertEqual(try XCTUnwrap(FTPFileSystem.facts("type=cdir;modify=bogus; .")).1, "cdir")
        XCTAssertNil(FTPFileSystem.facts("garbage"))
    }
}

extension IntegrationTests {
    func testTLSCertificateTrust() async throws {
        for s in ftpServers + s3Servers {
            for proto in s.protocols where proto != .ftp && proto != .s3http {
                let p = parameters(s)
                try? FileManager.default.removeItem(atPath: p.trustedCertificatesPath!)

                let reject = Prompter()
                reject.hostKeyDecision = .reject
                do {
                    _ = try await connect(s, proto, p, prompter: reject)
                    XCTFail("\(s.name): untrusted certificate accepted")
                } catch let e as RemoteError {
                    XCTAssertEqual(e.kind, .hostKeyRejected, "\(s.name): \(e)")
                }
                XCTAssertEqual(reject.certificateQuestions.count, 1, s.name)
                XCTAssertEqual(reject.certificateQuestions.first?.fingerprint.count, 95, s.name)

                let save = Prompter()
                save.hostKeyDecision = .acceptAndSave
                await (try await connect(s, proto, p, prompter: save)).disconnect()

                let again = Prompter()
                again.hostKeyDecision = .reject
                let fs = try await connect(s, proto, p, prompter: again)
                _ = try await fs.list(try await fs.homeDirectory())
                await fs.disconnect()
                XCTAssertTrue(again.certificateQuestions.isEmpty, "\(s.name): saved certificate asked again")
            }

            var bad = parameters(s)
            bad.password = "wrong"
            do {
                _ = try await connect(s, s.protocols[0], bad)
                XCTFail("\(s.name): wrong password accepted")
            } catch let e as RemoteError {
                XCTAssertEqual(e.kind, .authentication, "\(s.name): \(e)")
            }
        }
    }
}
