// Comparison rules follow WinSCP's TTerminal::SynchronizeCollect (core/Terminal.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.
import Foundation

public struct SyncOptions: Sendable, Codable, Equatable {
    public enum Direction: String, Sendable, Codable, CaseIterable { case toRemote, toLocal, both }

    public var direction = Direction.toRemote
    public var mirror = false
    public var deleteExtra = false
    public var existingOnly = false
    public var byTime = true
    public var bySize = false
    public var recursive = true
    public var transfer = TransferOptions()

    public init() {}
}

public struct SyncAction: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case uploadNew, uploadUpdate, downloadNew, downloadUpdate, deleteRemote, deleteLocal }

    public let id = UUID()
    public let kind: Kind
    public let localPath: String
    public let remotePath: String
    public let isDirectory: Bool
    public let local: FileSummary?
    public let remote: FileSummary?

    public var isUpload: Bool { kind == .uploadNew || kind == .uploadUpdate }
    public var isDownload: Bool { kind == .downloadNew || kind == .downloadUpdate }
}

public struct SyncProgress: Sendable, Equatable {
    public var doneActions = 0
    public var totalActions = 0
    public var current = ""
    public var transfer = TransferProgress()

    public init(totalActions: Int = 0) { self.totalActions = totalActions }
}

public actor Synchronizer {
    public private(set) var fs: any RemoteFileSystem
    let reconnect: TransferEngine.Connect?

    public init(fs: any RemoteFileSystem, reconnect: TransferEngine.Connect? = nil) {
        self.fs = fs
        self.reconnect = reconnect
    }

    public func compare(local: String, remote: String, options: SyncOptions) async throws -> [SyncAction] {
        let mask = options.transfer.includeMask.isEmpty ? nil : try FileMask(options.transfer.includeMask)
        var actions: [SyncAction] = []
        try await compareDirectory(local, remote, options, mask, &actions)
        return actions
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
    }

    private func localEntries(_ dir: String) throws -> [Entry] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: dir) } catch {
            throw localError(URL(fileURLWithPath: dir), error)
        }
        return names.compactMap { name in
            let path = (dir as NSString).appendingPathComponent(name)
            guard let a = try? FileManager.default.attributesOfItem(atPath: realPath(path)) else { return nil }
            return Entry(name: name, isDirectory: a[.type] as? FileAttributeType == .typeDirectory,
                         size: (a[.size] as? NSNumber)?.int64Value ?? 0, modified: a[.modificationDate] as? Date)
        }
    }

    private func remoteEntries(_ dir: String) async throws -> [Entry] {
        try await fs.list(dir).compactMap { f in
            if f.type == .symlink && f.targetType == nil { return nil }
            return Entry(name: f.name, isDirectory: f.isDirectory, size: f.size, modified: f.modified)
        }
    }

    private func included(_ e: Entry, path: String, _ o: SyncOptions, _ mask: FileMask?) -> Bool {
        if o.transfer.excludeHiddenFiles && e.name.hasPrefix(".") { return false }
        if let mask, !mask.matches(path: path, isDirectory: e.isDirectory, size: e.size, modified: e.modified) { return false }
        return true
    }

    private func compareDirectory(_ localDir: String, _ remoteDir: String, _ o: SyncOptions, _ mask: FileMask?,
                                  _ actions: inout [SyncAction]) async throws {
        let locals = try localEntries(localDir).filter {
            included($0, path: (localDir as NSString).appendingPathComponent($0.name), o, mask)
        }
        let remotes = try await remoteEntries(remoteDir).filter {
            included($0, path: RemotePath.join(remoteDir, $0.name), o, mask)
        }
        var remoteByName: [String: Entry] = [:]
        for r in remotes { remoteByName[r.name.precomposedStringWithCanonicalMapping] = r }
        var matched = Set<String>()

        for l in locals.sorted(by: { $0.name < $1.name }) {
            let key = l.name.precomposedStringWithCanonicalMapping
            let lp = (localDir as NSString).appendingPathComponent(l.name)
            let lsum = FileSummary(path: lp, size: l.size, modified: l.modified)
            if let r = remoteByName[key] {
                matched.insert(key)
                let rp = RemotePath.join(remoteDir, r.name)
                guard l.isDirectory == r.isDirectory else { continue }
                if l.isDirectory {
                    if o.recursive { try await compareDirectory(lp, rp, o, mask, &actions) }
                    continue
                }
                let rsum = FileSummary(path: rp, size: r.size, modified: r.modified)
                if let kind = Self.updateKind(local: l, remote: r, o) {
                    actions.append(SyncAction(kind: kind, localPath: lp, remotePath: rp, isDirectory: false, local: lsum, remote: rsum))
                }
            } else {
                let rp = RemotePath.join(remoteDir, key)
                if o.direction != .toLocal {
                    if !o.existingOnly {
                        actions.append(SyncAction(kind: .uploadNew, localPath: lp, remotePath: rp, isDirectory: l.isDirectory, local: lsum, remote: nil))
                    }
                } else if o.deleteExtra {
                    actions.append(SyncAction(kind: .deleteLocal, localPath: lp, remotePath: rp, isDirectory: l.isDirectory, local: lsum, remote: nil))
                }
            }
        }
        for r in remotes.sorted(by: { $0.name < $1.name }) where !matched.contains(r.name.precomposedStringWithCanonicalMapping) {
            let rp = RemotePath.join(remoteDir, r.name)
            let lp = (localDir as NSString).appendingPathComponent(r.name)
            let rsum = FileSummary(path: rp, size: r.size, modified: r.modified)
            if o.direction != .toRemote {
                if !o.existingOnly {
                    actions.append(SyncAction(kind: .downloadNew, localPath: lp, remotePath: rp, isDirectory: r.isDirectory, local: nil, remote: rsum))
                }
            } else if o.deleteExtra {
                actions.append(SyncAction(kind: .deleteRemote, localPath: lp, remotePath: rp, isDirectory: r.isDirectory, local: nil, remote: rsum))
            }
        }
    }

    private static func updateKind(local l: Entry, remote r: Entry, _ o: SyncOptions) -> SyncAction.Kind? {
        var cmp = 0
        if o.byTime, let lm = l.modified, let rm = r.modified {
            let ls = Int(lm.timeIntervalSince1970), rs = Int(rm.timeIntervalSince1970)
            cmp = ls < rs ? -1 : ls > rs ? 1 : 0
        }
        switch o.direction {
        case .toRemote:
            if cmp > 0 || (cmp < 0 && o.mirror) { return .uploadUpdate }
        case .toLocal:
            if cmp < 0 || (cmp > 0 && o.mirror) { return .downloadUpdate }
        case .both:
            if cmp > 0 { return .uploadUpdate }
            if cmp < 0 { return .downloadUpdate }
        }
        if cmp == 0, o.bySize, l.size != r.size {
            switch o.direction {
            case .toRemote: return .uploadUpdate
            case .toLocal: return .downloadUpdate
            case .both: return nil
            }
        }
        return nil
    }

    public func apply(_ actions: [SyncAction], options: SyncOptions,
                      onProgress: @escaping @Sendable (SyncProgress) -> Void = { _ in }) async throws {
        var transfer = options.transfer
        transfer.includeMask = ""
        transfer.newerOnly = false
        if options.byTime { transfer.preserveTime = true }
        var progress = SyncProgress(totalActions: actions.count)
        for action in actions {
            try Task.checkCancellation()
            progress.current = action.isDownload || action.kind == .deleteLocal ? action.localPath : action.remotePath
            onProgress(progress)
            switch action.kind {
            case .uploadNew, .uploadUpdate:
                try await run(TransferRequest(direction: .upload, sources: [action.localPath],
                                              targetDirectory: RemotePath.parent(action.remotePath), options: transfer), progress, onProgress)
            case .downloadNew, .downloadUpdate:
                try await run(TransferRequest(direction: .download, sources: [action.remotePath],
                                              targetDirectory: (action.localPath as NSString).deletingLastPathComponent, options: transfer),
                              progress, onProgress)
            case .deleteRemote:
                try await fs.delete(action.remotePath, isDirectory: action.isDirectory)
            case .deleteLocal:
                do {
                    #if canImport(Darwin)
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: action.localPath), resultingItemURL: nil)
                    #else
                    try FileManager.default.removeItem(atPath: action.localPath)
                    #endif
                } catch {
                    throw localError(URL(fileURLWithPath: action.localPath), error)
                }
            }
            progress.doneActions += 1
            onProgress(progress)
        }
    }

    private func run(_ request: TransferRequest, _ base: SyncProgress,
                     _ onProgress: @escaping @Sendable (SyncProgress) -> Void) async throws {
        let engine = TransferEngine(fs: fs, delegate: NonInteractiveTransferDelegate(answer: .overwriteAll), reconnect: reconnect,
                                    onProgress: { p in
            var s = base
            s.transfer = p
            onProgress(s)
        })
        do {
            try await engine.run(request)
            fs = await engine.fs
        } catch {
            fs = await engine.fs
            throw error
        }
    }
}
