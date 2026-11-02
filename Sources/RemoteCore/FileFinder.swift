import Foundation

public struct FoundFile: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var file: RemoteFile
}

public enum FileFinder {
    public static func find(in root: String, mask: FileMask, fs: any RemoteFileSystem,
                            searching: @Sendable (String) async -> Void = { _ in },
                            found: @Sendable ([FoundFile]) async -> Void) async throws {
        var pending = [root]
        while let dir = pending.popLast() {
            try Task.checkCancellation()
            await searching(dir)
            let entries: [RemoteFile]
            do {
                entries = try await fs.list(dir)
            } catch let e as RemoteError where dir != root && (e.kind == .permissionDenied || e.kind == .noSuchFile) {
                continue
            }
            var batch: [FoundFile] = []
            for f in entries.sorted(by: { $0.name < $1.name }) {
                let path = RemotePath.join(dir, f.name)
                if f.isDirectory {
                    if mask.selectsDirectories, mask.matches(path: path, isDirectory: true, modified: f.modified) {
                        batch.append(FoundFile(path: path, file: f))
                    }
                    if f.type == .directory, !mask.excludesDirectory(path) { pending.insert(path, at: 0) }
                } else if mask.selectsFiles, mask.matches(path: path, isDirectory: false, size: f.size, modified: f.modified) {
                    batch.append(FoundFile(path: path, file: f))
                }
            }
            if !batch.isEmpty { await found(batch) }
        }
    }
}

public struct ComparedEntry: Sendable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?

    public init(name: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name; self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }
}

public enum DirectoryComparison {
    public static func differences(local: [ComparedEntry], remote: [ComparedEntry]) -> (local: Set<String>, remote: Set<String>) {
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
        let remoteByName = Dictionary(remote.map { (key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        let localNames = Set(local.map { key($0.name) })
        var l: Set<String> = []
        var r: Set<String> = []
        for a in local {
            guard let b = remoteByName[key(a.name)] else {
                l.insert(a.name)
                continue
            }
            guard !a.isDirectory, !b.isDirectory else {
                if a.isDirectory != b.isDirectory {
                    l.insert(a.name)
                    r.insert(b.name)
                }
                continue
            }
            let ta = a.modified.map { Int($0.timeIntervalSince1970) }
            let tb = b.modified.map { Int($0.timeIntervalSince1970) }
            if let ta, let tb, ta != tb {
                if ta > tb { l.insert(a.name) } else { r.insert(b.name) }
            } else if a.size != b.size {
                l.insert(a.name)
                r.insert(b.name)
            }
        }
        for b in remote where !localNames.contains(key(b.name)) { r.insert(b.name) }
        return (l, r)
    }
}
