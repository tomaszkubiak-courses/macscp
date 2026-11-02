import AppKit
import RemoteCore
import UniformTypeIdentifiers

struct PaneItem: Hashable, Sendable {
    var name: String
    var isDirectory: Bool
    var isLink = false
    var size: Int64 = 0
    var modified: Date?
    var mode: UInt16 = 0
    var owner = ""
    var group = ""
    var hasMode = true
    var isHidden: Bool { name.hasPrefix(".") }
}

@MainActor
protocol PaneSource: AnyObject {
    var isRemote: Bool { get }
    func list(_ path: String) async throws -> [PaneItem]
    func home() async throws -> String

    func resolveDirectory(_ path: String) async throws -> String
    func makeDirectory(_ path: String) async throws
    func delete(_ path: String, isDirectory: Bool) async throws
    func rename(_ path: String, to: String) async throws
    func setPermissions(_ path: String, _ mode: UInt16) async throws
    var canChangeOwner: Bool { get }
    func setOwner(_ path: String, owner: String?, group: String?) async throws
}

@MainActor
final class LocalSource: PaneSource {
    var isRemote: Bool { false }

    func list(_ path: String) async throws -> [PaneItem] {
        try await Task.detached(priority: .userInitiated) { try Self.listSync(path) }.value
    }

    nonisolated static func listSync(_ path: String) throws -> [PaneItem] {
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        var owners: [uid_t: String] = [:], groups: [gid_t: String] = [:]
        return names.compactMap { name in
            let full = RemotePath.join(path, name)
            var st = stat()
            guard lstat(full, &st) == 0 else { return nil }
            let isLink = st.st_mode & S_IFMT == S_IFLNK
            if isLink { var t = stat(); if stat(full, &t) == 0 { st = t } }
            let owner = owners[st.st_uid] ?? {
                let n = getpwuid(st.st_uid).map { String(cString: $0.pointee.pw_name) } ?? String(st.st_uid)
                owners[st.st_uid] = n
                return n
            }()
            let group = groups[st.st_gid] ?? {
                let n = getgrgid(st.st_gid).map { String(cString: $0.pointee.gr_name) } ?? String(st.st_gid)
                groups[st.st_gid] = n
                return n
            }()
            return PaneItem(name: name, isDirectory: st.st_mode & S_IFMT == S_IFDIR, isLink: isLink,
                            size: Int64(st.st_size),
                            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                            mode: UInt16(st.st_mode & 0o7777), owner: owner, group: group)
        }
    }

    func home() async throws -> String { NSHomeDirectory() }

    func resolveDirectory(_ path: String) async throws -> String {
        let p = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
            throw RemoteError(.noSuchFile, String(localized: "\(path) is not a folder."))
        }
        return p
    }

    func makeDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    func rename(_ path: String, to: String) async throws {
        try FileManager.default.moveItem(atPath: path, toPath: to)
    }

    func setPermissions(_ path: String, _ mode: UInt16) async throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
    }

    var canChangeOwner: Bool { true }

    func setOwner(_ path: String, owner: String?, group: String?) async throws {
        var a: [FileAttributeKey: Any] = [:]
        if let owner { a[.ownerAccountName] = owner }
        if let group { a[.groupOwnerAccountName] = group }
        try FileManager.default.setAttributes(a, ofItemAtPath: path)
    }
}

@MainActor
final class RemoteSource: PaneSource {
    let session: Session
    var isRemote: Bool { true }

    init(session: Session) { self.session = session }

    func list(_ path: String) async throws -> [PaneItem] {
        let hasMode = !session.site.fileProtocol.isS3 && !session.site.fileProtocol.isWebDAV
        return try await session.browse { try await $0.list(path) }.map { f in
            PaneItem(name: f.name, isDirectory: f.isDirectory, isLink: f.type == .symlink, size: f.size,
                     modified: f.modified, mode: f.permissions.mode, owner: f.owner, group: f.group, hasMode: hasMode)
        }
    }

    func home() async throws -> String { try await session.browse { try await $0.homeDirectory() } }
    func resolveDirectory(_ path: String) async throws -> String { try await session.browse { try await $0.canonicalPath(path) } }
    func makeDirectory(_ path: String) async throws { try await session.browse { try await $0.makeDirectory(path) } }
    func delete(_ path: String, isDirectory: Bool) async throws {
        try await session.browse { try await $0.delete(path, isDirectory: isDirectory) }
    }
    func rename(_ path: String, to: String) async throws { try await session.browse { try await $0.rename(path, to: to) } }
    func setPermissions(_ path: String, _ mode: UInt16) async throws {
        try await session.browse { try await $0.setPermissions(path, Permissions(mode)) }
    }

    var canChangeOwner: Bool { session.site.fileProtocol.isSSH }

    func setOwner(_ path: String, owner: String?, group: String?) async throws {
        try await session.browse { try await $0.setOwner(path, owner: owner, group: group) }
    }
}

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]
    static let folder = NSWorkspace.shared.icon(for: .folder)

    static func icon(for item: PaneItem) -> NSImage {
        if item.isDirectory { return folder }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if let i = cache[ext] { return i }
        let i = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = i
        return i
    }
}
