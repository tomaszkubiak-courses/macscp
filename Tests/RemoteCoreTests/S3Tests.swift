import Foundation
import XCTest
@testable import RemoteCore

final class S3ParsingTests: XCTestCase {
    func testDatesAndXML() throws {
        XCTAssertEqual(S3FileSystem.isoDate("2023-11-14T22:13:20.000Z"), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(S3FileSystem.httpDate("Tue, 14 Nov 2023 22:13:20 GMT"), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(S3FileSystem.isoDate("yesterday"))
        let xml = S3XML(Data("""
        <ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>t1</NextContinuationToken>
        <Contents><Key>a &amp; b.txt</Key><Size>3</Size></Contents><CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """.utf8), records: ["Contents", "CommonPrefixes"])
        XCTAssertEqual(xml.root, "ListBucketResult")
        XCTAssertEqual(xml.top["NextContinuationToken"], "t1")
        XCTAssertEqual(xml.records.map(\.tag), ["Contents", "CommonPrefixes"])
        XCTAssertEqual(xml.records[0].fields["Key"], "a & b.txt")
        XCTAssertEqual(S3FileSystem.md5(Data("hello".utf8)), "XUFAKrxLKna5cZ2REBfFkg==")
        XCTAssertEqual(S3FileSystem.contentType("site/Index.HTML"), "text/html")
        XCTAssertEqual(S3FileSystem.contentType("dir/noext"), "application/octet-stream")
    }

    func testCredentialsFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aws-\(UUID().uuidString)")
        try "[default]\naws_access_key_id = AK1\naws_secret_access_key=S1\n\n[work]\naws_access_key_id=AK2\naws_secret_access_key = S2\naws_session_token = T2\n"
            .write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let base = ["AWS_SHARED_CREDENTIALS_FILE": file.path]
        XCTAssertEqual(S3FileSystem.credentials(base)?.0, "AK1")
        let work = S3FileSystem.credentials(base.merging(["AWS_PROFILE": "work"]) { $1 })
        XCTAssertEqual(work?.1, "S2")
        XCTAssertEqual(work?.2, "T2")
        XCTAssertEqual(S3FileSystem.credentials(["AWS_ACCESS_KEY_ID": "E", "AWS_SECRET_ACCESS_KEY": "F"])?.0, "E")
    }
}

extension IntegrationTests {
    func testS3MultipartRenameAndBuckets() async throws {
        let big = try randomFile("multi.bin", size: 12 << 20)
        for s in s3Servers {
            let fs = try await connect(s, s.protocols[0]) as! S3FileSystem
            await fs.setMultipart(threshold: 6 << 20, partSize: 5 << 20, copyThreshold: 6 << 20, copyPartSize: 5 << 20)
            let bucket = "/macscp-b-\(UUID().uuidString.prefix(8).lowercased())"
            try await fs.makeDirectory(bucket)
            let buckets = try await fs.list("/").map(\.name)
            XCTAssertTrue(buckets.contains(String(bucket.dropFirst())), s.name)

            try await fs.makeDirectory(bucket + "/dir")
            try await fs.upload(big, to: bucket + "/dir/multi.bin", offset: 0, progress: { _ in })
            let info = try await fs.fileInfo(bucket + "/dir/multi.bin")
            XCTAssertEqual(info?.size, 12 << 20, s.name)

            try await fs.rename(bucket + "/dir", to: bucket + "/moved")
            let gone = try await fs.fileInfo(bucket + "/dir")
            XCTAssertNil(gone, s.name)
            let back = scratch.appendingPathComponent("multi-\(s.name)")
            try await fs.download(bucket + "/moved/multi.bin", to: back, offset: 0, progress: { _ in })
            assertSameContent(big, back, s.name)

            try await fs.delete(bucket, isDirectory: true)
            let after = try await fs.list("/").map(\.name)
            XCTAssertFalse(after.contains(String(bucket.dropFirst())), s.name)
            await fs.disconnect()
        }
    }
}
