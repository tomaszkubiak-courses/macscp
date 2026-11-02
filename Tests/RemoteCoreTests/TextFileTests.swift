import Foundation
import XCTest
@testable import RemoteCore

final class TextFileTests: XCTestCase {
    func testRoundTrips() throws {
        let samples: [(Data, String.Encoding, Bool, TextFile.LineEnding)] = [
            (Data("a\nżółw\n".utf8), .utf8, false, .lf),
            (Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8), .utf8, true, .crlf),
            ("caf\u{E9}\r\n".data(using: .windowsCP1252)!, .windowsCP1252, false, .crlf),
            (Data("old\rmac\r".utf8), .utf8, false, .cr),
        ]
        for (data, encoding, bom, ending) in samples {
            let f = try XCTUnwrap(TextFile.decode(data))
            XCTAssertEqual(f.encoding, encoding)
            XCTAssertEqual(f.bom, bom)
            XCTAssertEqual(f.lineEnding, ending)
            XCTAssertFalse(f.text.contains("\r"))
            XCTAssertEqual(f.encode(f.text), data)
        }
    }

    func testBinaryAndUnencodable() throws {
        XCTAssertNil(TextFile.decode(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01])))
        let latin = try XCTUnwrap(TextFile.decode("caf\u{E9}".data(using: .windowsCP1252)!))
        XCTAssertNil(latin.encode("日本"))
    }
}
