import Foundation
#if canImport(Security)
import Security
#endif

public enum FileProtocol: String, Codable, Sendable, CaseIterable {
    case sftp, scp, ftp, ftps, ftpsImplicit, s3, s3http, webdav, webdavhttp

    public var isFTP: Bool { self == .ftp || self == .ftps || self == .ftpsImplicit }
    public var isS3: Bool { self == .s3 || self == .s3http }
    public var isWebDAV: Bool { self == .webdav || self == .webdavhttp }
    public var isSSH: Bool { self == .sftp || self == .scp }
}

public struct Site: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String

    public var folder = ""
    public var fileProtocol = FileProtocol.sftp
    public var host: String
    public var port: Int?
    public var user = ""
    public var privateKeyPath: String?
    public var useAgent = true
    public var remoteDirectory = ""
    public var localDirectory = ""
    public var region: String?

    public init(name: String, host: String, fileProtocol: FileProtocol = .sftp, user: String = "") {
        self.name = name; self.host = host; self.fileProtocol = fileProtocol; self.user = user
    }

    public func connectionParameters(password: String?) -> ConnectionParameters {
        var p = ConnectionParameters(host: host, port: port, user: user, password: password,
                                     privateKeyPath: privateKeyPath?.isEmpty == false ? privateKeyPath : nil)
        p.useAgent = useAgent
        p.region = region?.isEmpty == false ? region : nil
        return p
    }
}

public struct SiteStore: Sendable {
    public let url: URL

    public static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacSCP/sites.json")

    public init(url: URL = SiteStore.defaultURL) { self.url = url }

    public func load() throws -> [Site] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Site].self, from: Data(contentsOf: url))
    }

    public func save(_ sites: [Site]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(sites).write(to: url, options: .atomic)
    }
}

#if canImport(Security)

public enum Keychain {
    static let service = "MacSCP"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    public static func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String?, for id: UUID) throws {
        SecItemDelete(query(id) as CFDictionary)
        guard let password else { return }
        var q = query(id)
        q[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RemoteError(.failure, "Cannot save password to Keychain (\(status)).")
        }
    }
}
#endif
