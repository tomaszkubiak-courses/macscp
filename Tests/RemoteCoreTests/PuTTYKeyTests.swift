import Foundation
import XCTest
@testable import RemoteCore

final class PuTTYKeyTests: XCTestCase {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    func check(_ name: String, passphrase: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try String(contentsOf: fixtures.appendingPathComponent(name + ".ppk"), encoding: .utf8)
        let expected = try String(contentsOf: fixtures.appendingPathComponent(name + ".pub"), encoding: .utf8).split(separator: " ")[1]
        let pem = try PuTTYKey.openSSH(text, passphrase: passphrase)
        XCTAssertEqual(PuTTYKey.publicKey(ofOpenSSH: pem), String(expected), name, file: file, line: line)
    }

    func testUnencryptedKeys() throws {
        for name in ["ed25519-v3", "ecdsa256-v3", "ecdsa384-v2"] { try check(name, passphrase: nil) }
    }

    func testVersion2EncryptedKey() throws {
        try check("rsa-v2-enc", passphrase: "test-pass")
        let text = try String(contentsOf: fixtures.appendingPathComponent("rsa-v2-enc.ppk"), encoding: .utf8)
        XCTAssertThrowsError(try PuTTYKey.openSSH(text, passphrase: "nope")) { XCTAssertEqual($0 as? PuTTYKey.Failure, .wrongPassphrase) }
        XCTAssertThrowsError(try PuTTYKey.openSSH(text, passphrase: nil)) { XCTAssertEqual($0 as? PuTTYKey.Failure, .needsPassphrase) }
    }

    func testVersion3Argon2Keys() throws {
        do {
            try check("ed25519-v3-enc", passphrase: "test-pass")
        } catch PuTTYKey.Failure.unsupported(let why) {
            throw XCTSkip(why)
        }
        try check("rsa-v3-enc", passphrase: "test-pass")
        let text = try String(contentsOf: fixtures.appendingPathComponent("ed25519-v3-enc.ppk"), encoding: .utf8)
        XCTAssertThrowsError(try PuTTYKey.openSSH(text, passphrase: "nope")) { XCTAssertEqual($0 as? PuTTYKey.Failure, .wrongPassphrase) }
    }
}

extension IntegrationTests {
    func testPuTTYKeyLogsIn() async throws {
        let ppk = Self.root.appendingPathComponent("Tests/RemoteCoreTests/Fixtures/rsa-v2-enc.ppk").path
        for s in servers {
            var p = parameters(s)
            p.privateKeyPath = ppk
            let prompter = Prompter()
            prompter.passphraseAnswer = "test-pass"
            let fs = try await connect(s, .sftp, p, prompter: prompter)
            XCTAssertEqual(prompter.passphraseAsked, 1, s.name)
            _ = try await fs.homeDirectory()
            await fs.disconnect()
        }
    }
}
