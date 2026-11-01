// Edited-file tracking follows WinSCP's TEditorManager (windows/EditorManager.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.
import Foundation

public struct EditedFile: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case synced, pending, uploading
        case failed(String)

        case conflict
    }
    public let id: UUID
    public let remotePath: String
    public let localURL: URL
    public var state: State
    public var lastUpload: Date?
}

public actor RemoteEditor {
    public typealias Connect = @Sendable () async throws -> any RemoteFileSystem

    public typealias ConflictHandler = @Sendable (_ remotePath: String) async -> Bool

    typealias Stamp = (date: Date, size: Int64)

    private struct Tracked {
        var file: EditedFile

        var synced: Stamp

        var seen: Stamp
        var seenAt: Date

        var remoteModified: Date?
    }

    private let connect: Connect
    private let cacheRoot: URL
    private let onConflict: ConflictHandler
    private let onChange: @Sendable ([EditedFile]) -> Void
    private var fs: (any RemoteFileSystem)?
    private var tracked: [UUID: Tracked] = [:]
    private var order: [UUID] = []
    private var poller: Task<Void, Never>?

    let settleDelay: Duration

    public init(cacheRoot: URL, settleDelay: Duration = .milliseconds(500), connect: @escaping Connect,
                onConflict: @escaping ConflictHandler, onChange: @escaping @Sendable ([EditedFile]) -> Void = { _ in }) {
        self.cacheRoot = cacheRoot; self.settleDelay = settleDelay; self.connect = connect
        self.onConflict = onConflict; self.onChange = onChange
    }

    public var files: [EditedFile] { order.compactMap { tracked[$0]?.file } }

    public var hasPendingUploads: Bool {
        tracked.values.contains { $0.file.state == .pending || $0.file.state == .uploading }
    }

    private func connection() async throws -> any RemoteFileSystem {
        if let fs { return fs }
        let f = try await connect()
        fs = f
        return f
    }

    public func open(_ remotePath: String) async throws -> URL {
        if let t = tracked.values.first(where: { $0.file.remotePath == remotePath }) { return t.file.localURL }
        let id = UUID()

        let dir = cacheRoot.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(RemotePath.name(remotePath))
        let fs = try await connection()
        let info = try await fs.fileInfo(remotePath)
        try await fs.download(remotePath, to: local, offset: 0, progress: { _ in })

        let stamp = Self.stamp(local) ?? (.distantPast, -1)
        tracked[id] = Tracked(file: EditedFile(id: id, remotePath: remotePath, localURL: local, state: .synced),
                              synced: stamp, seen: stamp, seenAt: Date(), remoteModified: info?.modified)
        order.append(id)
        if poller == nil {
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    await self?.poll()
                }
            }
        }
        report()
        return local
    }

    public func stop(_ id: UUID) {
        guard let t = tracked.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        try? FileManager.default.removeItem(at: t.file.localURL.deletingLastPathComponent())
        report()
    }

    public func stopAll() async {
        for id in order { stop(id) }
        poller?.cancel()
        poller = nil
        await fs?.disconnect()
        fs = nil
    }

    public func retry(_ id: UUID) {
        tracked[id]?.synced = (.distantPast, -1)
    }

    private static func stamp(_ url: URL) -> Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let s = (a[.size] as? NSNumber)?.int64Value else { return nil }
        return (m, s)
    }

    private func poll() async {
        let settle = Double(settleDelay.components.seconds) + Double(settleDelay.components.attoseconds) / 1e18
        for id in order {
            guard var t = tracked[id], t.file.state != .uploading else { continue }

            guard let now = Self.stamp(t.file.localURL) else { continue }
            if now != t.seen {
                t.seen = now
                t.seenAt = Date()
                if now != t.synced, t.file.state != .pending { t.file.state = .pending; tracked[id] = t; report() }
                tracked[id] = t
            } else if now != t.synced, Date().timeIntervalSince(t.seenAt) >= settle,
                      t.file.state == .pending || t.file.state == .synced {
                await upload(id, stamp: now)
            }
        }
    }

    private func upload(_ id: UUID, stamp: Stamp) async {
        guard let t = tracked[id] else { return }
        update(id) { $0.file.state = .uploading }
        do {
            let fs = try await connection()
            let remote = try await fs.fileInfo(t.file.remotePath)
            if let r = remote?.modified, let known = t.remoteModified, r != known {
                if !(await onConflict(t.file.remotePath)) {
                    update(id) { $0.file.state = .conflict; $0.synced = stamp }
                    return
                }
            }

            try await fs.upload(t.file.localURL, to: t.file.remotePath, offset: 0, progress: { _ in })
            let after = try await fs.fileInfo(t.file.remotePath)
            update(id) {
                $0.synced = stamp
                $0.remoteModified = after?.modified
                $0.file.state = .synced
                $0.file.lastUpload = Date()
            }
        } catch {
            if (error as? RemoteError)?.kind == .connection { fs = nil }
            update(id) { $0.file.state = .failed("\(error)"); $0.synced = stamp }
        }
    }

    private func update(_ id: UUID, _ body: (inout Tracked) -> Void) {
        guard tracked[id] != nil else { return }
        body(&tracked[id]!)
        report()
    }

    private func report() { onChange(files) }
}
