// Session import ported from WinSCP (core/SessionData.cpp, core/Security.cpp, core/HierarchicalStorage.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.

import Foundation

public struct ImportedSite: Sendable {
    public var site: Site
    public var password: String?
    public var windowsKeyFile: String?
}

public struct WinSCPImportResult: Sendable {
    public var sites: [ImportedSite] = []
    public var skipped: [String] = []
}

public enum WinSCPImport {
    public static func parse(_ data: Data) -> WinSCPImportResult {
        var result = WinSCPImportResult()
        for (munged, values) in sessions(decode(data)) {
            let path = unmunge(munged)
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last, path != "Default Settings", values["IsWorkspace"] != "1" else { continue }
            var host = values["HostName"].map(unmunge) ?? ""
            var user = values["UserName"].map(unmunge) ?? ""
            let keyUser = user, keyHost = host
            if let at = host.lastIndex(of: "@") {
                user = String(host[..<at])
                host = String(host[host.index(after: at)...])
            }
            let ftps = Int(values["Ftps"] ?? "") ?? 0
            let proto: FileProtocol
            switch Int(values["FSProtocol"] ?? "") ?? 1 {
            case 0: proto = .scp
            case 1, 2: proto = .sftp
            case 5: proto = ftps == 0 ? .ftp : ftps == 1 ? .ftpsImplicit : .ftps
            case 7: proto = ftps == 1 ? .s3 : .s3http
            default:
                result.skipped.append(path)
                continue
            }
            var site = Site(name: name, host: host, fileProtocol: proto, user: user)
            site.folder = parts.dropLast().joined(separator: "/")
            let defaultPort = switch proto {
            case .sftp, .scp: 22
            case .ftp, .ftps: 21
            case .ftpsImplicit: 990
            case .s3: 443
            case .s3http: 80
            }
            if let port = Int(values["PortNumber"] ?? ""), port != defaultPort { site.port = port }
            if let dir = values["RemoteDirectory"].map(unmunge), !dir.isEmpty { site.remoteDirectory = dir }
            if let dir = values["LocalDirectory"].map(unmunge), dir.hasPrefix("/") { site.localDirectory = dir }
            if let region = values["S3DefaultRegion"].map(unmunge), !region.isEmpty { site.region = region }
            var imported = ImportedSite(site: site)
            if let key = values["PublicKeyFile"].map(unmunge), !key.isEmpty {
                if key.hasPrefix("/") || key.hasPrefix("~") { imported.site.privateKeyPath = key } else { imported.windowsKeyFile = key }
            }
            if let plain = values["PasswordPlain"] {
                imported.password = unmunge(plain)
            } else if let encrypted = values["Password"] {
                imported.password = decryptPassword(unmunge(encrypted), key: keyUser + keyHost)
            }
            result.sites.append(imported)
        }
        return result
    }

    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }

    static func sessions(_ text: String) -> [(String, [String: String])] {
        var result: [(String, [String: String])] = []
        var current: String?
        var values: [String: String] = [:]
        func flush() {
            if let current { result.append((current, values)) }
            values = [:]
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                let section = String(line.dropFirst().dropLast())
                current = section.range(of: "Sessions\\", options: .backwards).map { String(section[$0.upperBound...]) }
                if current?.contains("\\") == true { current = nil }
            } else if current != nil, let eq = line.firstIndex(of: "=") {
                var key = String(line[..<eq])
                var value = String(line[line.index(after: eq)...])
                if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 { key = String(key.dropFirst().dropLast()) }
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                } else if value.hasPrefix("dword:"), let n = UInt32(value.dropFirst(6), radix: 16) {
                    value = String(Int32(bitPattern: n))
                }
                values[key] = value
            }
        }
        flush()
        return result
    }

    static func unmunge(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var bytes: [UInt8] = []
        var i = s.utf8.startIndex
        let u = s.utf8
        while i < u.endIndex {
            if u[i] == UInt8(ascii: "%"), let j = u.index(i, offsetBy: 3, limitedBy: u.endIndex),
               let b = UInt8(String(decoding: u[u.index(after: i)..<j], as: UTF8.self), radix: 16) {
                bytes.append(b)
                i = j
            } else {
                bytes.append(u[i])
                i = u.index(after: i)
            }
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        return String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: .windowsCP1252) ?? s
    }

    static func decryptPassword(_ encrypted: String, key: String) -> String? {
        let digits = Array("0123456789ABCDEF".utf8)
        var input = Array(encrypted.uppercased().utf8)[...]
        func next() -> UInt8 {
            guard input.count >= 2, let hi = digits.firstIndex(of: input[input.startIndex]),
                  let lo = digits.firstIndex(of: input[input.startIndex + 1]) else { return 0 }
            input = input.dropFirst(2)
            return ~UInt8((hi << 4) + lo) ^ 0xA3
        }
        let flag = next()
        var length: Int
        if flag == 0xFF {
            switch next() {
            case 0x00: length = Int(next())
            case 0x02: length = Int(next()) << 8 + Int(next())
            default: return nil
            }
        } else {
            length = Int(flag)
        }
        let shift = Int(next())
        input = input.dropFirst(shift * 2)
        var bytes: [UInt8] = []
        for _ in 0..<length { bytes.append(next()) }
        var result = String(decoding: bytes, as: UTF8.self)
        if flag == 0xFF {
            guard result.hasPrefix(key) else { return nil }
            result.removeFirst(key.count)
        }
        return result
    }
}
