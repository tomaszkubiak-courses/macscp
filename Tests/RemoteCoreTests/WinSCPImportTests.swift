import Foundation
import XCTest
@testable import RemoteCore

final class WinSCPImportTests: XCTestCase {
    func testPasswordDecryption() {
        XCTAssertEqual(WinSCPImport.decryptPassword(
            "A35C4A5F5B947D36333939243D312C3039723F33310C3D7C2F2F7D99DE5B947D07595B947D07595B947D07595B947D07595B",
            key: "joeexample.com"), "Pa ss!ł")
        XCTAssertEqual(WinSCPImport.decryptPassword(
            "A35C485C38392C3033256D6C726C726C72692F6F3F2E6F285D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D",
            key: "deploy10.0.0.5"), "s3cr3t")
        XCTAssertNil(WinSCPImport.decryptPassword(
            "A35C485C38392C3033256D6C726C726C72692F6F3F2E6F285D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D",
            key: "someone else"))
    }

    func testIniExport() {
        let ini = """
        [Configuration\\Interface]
        Theme=dark
        [Sessions\\Default%20Settings]
        HostName=ignored
        [Sessions\\Work/Prod%20web]
        HostName=example.com
        UserName=joe
        PortNumber=2222
        RemoteDirectory=/var/www
        LocalDirectory=C:%5CUsers%5Cjoe
        PublicKeyFile=C:%5CUsers%5Cjoe%5Ckey.ppk
        Password=A35C4A5F5B947D36333939243D312C3039723F33310C3D7C2F2F7D99DE5B947D07595B947D07595B947D07595B947D07595B
        [Sessions\\legacy%20ftp]
        HostName=ftp.example.org
        FSProtocol=5
        Ftps=3
        [Sessions\\bucket]
        FSProtocol=7
        Ftps=1
        HostName=s3.amazonaws.com
        S3DefaultRegion=eu-central-1
        [Sessions\\dav]
        FSProtocol=6
        HostName=dav.example.com
        [Sessions\\My%20workspace]
        IsWorkspace=1
        """
        let r = WinSCPImport.parse(Data(ini.utf8))
        XCTAssertEqual(r.sites.map(\.site.name), ["Prod web", "legacy ftp", "bucket", "dav"])
        XCTAssertEqual(r.sites[3].site.fileProtocol, .webdavhttp)
        XCTAssertEqual(r.skipped, [])
        let prod = r.sites[0]
        XCTAssertEqual(prod.site.folder, "Work")
        XCTAssertEqual(prod.site.fileProtocol, .sftp)
        XCTAssertEqual(prod.site.port, 2222)
        XCTAssertEqual(prod.site.remoteDirectory, "/var/www")
        XCTAssertEqual(prod.site.localDirectory, "")
        XCTAssertEqual(prod.windowsKeyFile, "C:\\Users\\joe\\key.ppk")
        XCTAssertEqual(prod.password, "Pa ss!ł")
        XCTAssertEqual(r.sites[1].site.fileProtocol, .ftps)
        XCTAssertEqual(r.sites[2].site.fileProtocol, .s3)
        XCTAssertEqual(r.sites[2].site.region, "eu-central-1")
    }

    func testRegistryExport() {
        let reg = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\Sessions\\deploy@10.0.0.5]
        "HostName"="10.0.0.5"
        "UserName"="deploy"
        "PortNumber"=dword:00000016
        "FSProtocol"=dword:00000000
        "Password"="A35C485C38392C3033256D6C726C726C72692F6F3F2E6F285D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D"
        "PublicKeyFile"="C:\\\\keys\\\\deploy.ppk"

        [HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\Sessions\\deploy@10.0.0.5\\Sub]
        "HostName"="nested"
        """
        var data = Data([0xFF, 0xFE])
        data.append(reg.data(using: .utf16LittleEndian)!)
        let r = WinSCPImport.parse(data)
        XCTAssertEqual(r.sites.count, 1)
        XCTAssertEqual(r.sites[0].site.name, "deploy@10.0.0.5")
        XCTAssertEqual(r.sites[0].site.fileProtocol, .scp)
        XCTAssertNil(r.sites[0].site.port)
        XCTAssertEqual(r.sites[0].password, "s3cr3t")
        XCTAssertEqual(r.sites[0].windowsKeyFile, "C:\\keys\\deploy.ppk")
    }
}
