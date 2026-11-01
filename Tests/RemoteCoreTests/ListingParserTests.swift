import XCTest
@testable import RemoteCore

final class ListingParserTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_534_400)

    func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func parse(_ line: String) throws -> RemoteFile { try ListingParser.parseLine(line, now: now) }

    func testGNUFullTime() throws {
        let f = try parse("-rw-r--r-- 1 alice staff 1234 2024-03-05 14:22:33.123456789 +0000 file name.txt")
        XCTAssertEqual(f.name, "file name.txt")
        XCTAssertEqual(f.type, .file)
        XCTAssertEqual(f.size, 1234)
        XCTAssertEqual(f.owner, "alice")
        XCTAssertEqual(f.group, "staff")
        XCTAssertEqual(f.permissions.mode, 0o644)
        XCTAssertEqual(f.modified, utc(2024, 3, 5, 14, 22, 33))
    }

    func testYearlessDateIsThisYearUnlessInFuture() throws {
        XCTAssertEqual(try parse("drwxr-xr-x  2 root root 4096 Mar  5 14:22 dir").modified, utc(2026, 3, 5, 14, 22))
        XCTAssertEqual(try parse("drwxr-xr-x  2 root root 4096 Dec 15 10:00 dir").modified, utc(2025, 12, 15, 10, 0))
    }

    func testYearColumn() throws {
        let f = try parse("-rw-r--r--  1 root root  100 Dec 31  2019 old")
        XCTAssertEqual(f.modified, utc(2019, 12, 31))
        XCTAssertEqual(f.name, "old")
    }

    func testBSDWithXattrMarker() throws {
        let f = try parse("-rw-r--r--@  1 alice  staff  1234 Nov  1 09:07 file")
        XCTAssertEqual(f.name, "file")
        XCTAssertEqual(f.owner, "alice")
        XCTAssertEqual(f.size, 1234)
    }

    func testSymlink() throws {
        let f = try parse("lrwxrwxrwx 1 root root 7 2024-03-05 14:22:33.000000000 +0000 bin -> usr/bin")
        XCTAssertEqual(f.type, .symlink)
        XCTAssertEqual(f.name, "bin")
        XCTAssertEqual(f.linkTarget, "usr/bin")
    }

    func testDeviceColumnSkipped() throws {
        let f = try parse("crw-rw-rw- 1 root root 1, 3 Mar  5 14:22 null")
        XCTAssertEqual(f.type, .other)
        XCTAssertEqual(f.size, 3)
        XCTAssertEqual(f.name, "null")
    }

    func testGroupWithSpace() throws {
        let f = try parse("-rw-r--r-- 1 user Domain Users 1234 Mar  5 14:22 file")
        XCTAssertEqual(f.group, "Domain Users")
        XCTAssertEqual(f.size, 1234)
    }

    func testSSHFSUnknownEntry() throws {
        let f = try parse("d????????? ? ? ? ? ? broken")
        XCTAssertEqual(f.name, "broken")
        XCTAssertNil(f.modified)
    }

    func testDayMonthFormat() throws {
        let f = try parse("-rw-r--r-- 1 user group 1234 5 Mar 14:22 file")
        XCTAssertEqual(f.modified, utc(2026, 3, 5, 14, 22))
        XCTAssertEqual(f.name, "file")
    }

    func testSecondFullTimeFormat() throws {
        let f = try parse("-rw-r--r-- 1 user group 1234 Tue Mar  5 14:22:33 2024 file")
        XCTAssertEqual(f.modified, utc(2024, 3, 5, 14, 22, 33))
        XCTAssertEqual(f.name, "file")
    }

    func testBSDFullTime() throws {
        let f = try parse("-rw-r--r--  1 alice  staff  300000 Nov 14 22:14:05 2023 my file")
        XCTAssertEqual(f.modified, utc(2023, 11, 14, 22, 14, 5))
        XCTAssertEqual(f.name, "my file")
    }

    func testSpecialPermissions() throws {
        XCTAssertEqual(try parse("drwxrwxrwt 2 root root 4096 Mar  5 14:22 tmp").permissions.mode, 0o1777)
        XCTAssertEqual(try parse("-rwsr-xr-x 1 root root 1 Mar  5 14:22 su").permissions.mode, 0o4755)
        XCTAssertEqual(try parse("-rwSr--r-- 1 root root 1 Mar  5 14:22 x").permissions.mode, 0o4644)
    }

    func testListingSkipsTotalAndDots() throws {
        let out = """
        total 8
        drwxr-xr-x  2 root root 4096 Mar  5 14:22 .
        drwxr-xr-x  3 root root 4096 Mar  5 14:22 ..
        -rw-r--r--  1 root root   10 Mar  5 14:22 a
        """
        XCTAssertEqual(try ListingParser.parse(out, now: now).map(\.name), ["a"])
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try parse("hello world"))
    }
}

final class PermissionsTests: XCTestCase {
    func testRoundTrip() {
        for mode: UInt16 in [0o644, 0o755, 0o1777, 0o4755, 0o2750, 0o4644, 0o000, 0o7777] {
            XCTAssertEqual(Permissions(text: Permissions(mode).text)?.mode, mode, Permissions(mode).text)
        }
        XCTAssertEqual(Permissions(0o755).text, "rwxr-xr-x")
        XCTAssertEqual(Permissions(octal: "644")?.mode, 0o644)
        XCTAssertNil(Permissions(octal: "999"))
        XCTAssertEqual(Permissions(0o640).addingExecuteWhereReadable.mode, 0o750)
    }
}

final class RemotePathTests: XCTestCase {
    func testPaths() {
        XCTAssertEqual(RemotePath.join("/a", "b"), "/a/b")
        XCTAssertEqual(RemotePath.join("/", "b"), "/b")
        XCTAssertEqual(RemotePath.join("/a/", "b"), "/a/b")
        XCTAssertEqual(RemotePath.parent("/a/b"), "/a")
        XCTAssertEqual(RemotePath.parent("/a"), "/")
        XCTAssertEqual(RemotePath.parent("/"), "/")
        XCTAssertEqual(RemotePath.name("/a/b/"), "b")
        XCTAssertEqual(RemotePath.shellQuote("it's"), "'it'\\''s'")
    }
}
