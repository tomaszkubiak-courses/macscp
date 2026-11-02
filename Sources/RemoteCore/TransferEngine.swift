// Overwrite, resume and retry decisions follow WinSCP's TTerminal (core/Terminal.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.
import Foundation

public enum TransferDirection: Sendable, Equatable { case upload, download }

public struct FileSummary: Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var modified: Date?
}

public struct OverwriteQuestion: Sendable, Equatable {
    public var direction: TransferDirection
    public var source: FileSummary
    public var target: FileSummary

    public var canResume: Bool
}

public enum OverwriteAnswer: Sendable, Equatable {
    case overwrite, skip, resume, cancel

    case overwriteAll, skipAll, overwriteAllIfNewer
}

public enum FailureAnswer: Sendable { case retry, skip, abort }

public protocol TransferDelegate: Sendable {
    func overwrite(_ question: OverwriteQuestion) async -> OverwriteAnswer
    func failed(_ error: RemoteError, path: String) async -> FailureAnswer
}

public struct NonInteractiveTransferDelegate: TransferDelegate {
    public var answer: OverwriteAnswer
    public init(answer: OverwriteAnswer = .overwriteAll) { self.answer = answer }
    public func overwrite(_ question: OverwriteQuestion) async -> OverwriteAnswer { answer }
    public func failed(_ error: RemoteError, path: String) async -> FailureAnswer { .abort }
}

public struct TransferProgress: Sendable, Equatable {
    public var totalBytes: Int64 = 0
    public var doneBytes: Int64 = 0
    public var totalFiles = 0
    public var doneFiles = 0
    public var currentFile = ""
}

public struct TransferRequest: Sendable {
    public var direction: TransferDirection

    public var sources: [String]

    public var targetDirectory: String
    public var options: TransferOptions

    public init(direction: TransferDirection, sources: [String], targetDirectory: String, options: TransferOptions = .init()) {
        self.direction = direction; self.sources = sources; self.targetDirectory = targetDirectory; self.options = options
    }
}

public actor TransferEngine {
    public typealias Connect = @Sendable () async throws -> any RemoteFileSystem

    public private(set) var fs: any RemoteFileSystem
    let reconnect: Connect?
    let delegate: any TransferDelegate
    let onProgress: @Sendable (TransferProgress) -> Void
    private var progress = TransferProgress()
    private var batch: OverwriteAnswer?

    private var remoteNames: [String: [String: String]] = [:]

    var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    public init(fs: any RemoteFileSystem, delegate: any TransferDelegate, reconnect: Connect? = nil,
                onProgress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) {
        self.fs = fs; self.delegate = delegate; self.reconnect = reconnect; self.onProgress = onProgress
    }

    enum Step { case directory(source: String, target: String), file(source: String, target: String, size: Int64, modified: Date?) }

    public func run(_ request: TransferRequest) async throws {
        let mask = try request.options.includeMask.isEmpty ? nil : FileMask(request.options.includeMask)
        var steps: [Step] = []
        try await withReconnect {
            steps = []
            for source in request.sources {
                try await self.plan(source, into: request.targetDirectory, request, mask, &steps)
            }
        }
        for case let .file(_, _, size, _) in steps {
            progress.totalBytes += size
            progress.totalFiles += 1
        }
        onProgress(progress)

        for step in steps {
            try Task.checkCancellation()
            switch step {
            case let .directory(source, target):
                try await withRetry(target) { try await self.makeDirectory(source, target, request) }
            case let .file(source, target, size, modified):
                progress.currentFile = source
                let before = progress.doneBytes
                try await withRetry(source) {
                    self.progress.doneBytes = before
                    try await self.transferFile(source, target, size, modified, request)
                }
                progress.doneBytes = before + size
                progress.doneFiles += 1
                onProgress(progress)
            }
        }
    }

    private func withReconnect(_ body: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let e as RemoteError where e.kind == .connection && reconnect != nil && attempt < reconnectDelays.count {
                try await Task.sleep(for: reconnectDelays[attempt])
                attempt += 1
                await fs.disconnect()
                if let f = try? await reconnect!() { fs = f }
            }
        }
    }

    private func withRetry(_ path: String, _ body: () async throws -> Void) async throws {
        while true {
            do {
                return try await withReconnect(body)
            } catch let e as RemoteError where e.kind != .cancelled {
                switch await delegate.failed(e, path: path) {
                case .retry: continue
                case .skip: return
                case .abort: throw e
                }
            }
        }
    }

    private func plan(_ source: String, into targetDir: String, _ r: TransferRequest, _ mask: FileMask?,
                      _ steps: inout [Step]) async throws {
        switch r.direction {
        case .download:
            guard let f = try await fs.fileInfo(source) else {
                throw RemoteError(.noSuchFile, "\(source): No such file or directory")
            }
            let target = (targetDir as NSString).appendingPathComponent(f.name)
            let key = (try? await fs.canonicalPath(source)) ?? source
            try await planRemote(f, source, key, target, [], r, mask, &steps)
        case .upload:
            let name = try await remoteName(in: targetDir, for: (source as NSString).lastPathComponent)
            try await planLocal(source, RemotePath.join(targetDir, name), [], r, mask, &steps)
        }
    }

    private func planRemote(_ f: RemoteFile, _ path: String, _ realPath: String, _ target: String, _ ancestors: Set<String>,
                            _ r: TransferRequest, _ mask: FileMask?, _ steps: inout [Step]) async throws {
        if r.options.excludeHiddenFiles && f.isHidden { return }
        if let mask, !mask.matches(path: path, isDirectory: f.isDirectory, size: f.size, modified: f.modified) { return }
        if f.isDirectory {
            let real = f.type == .symlink ? ((try? await fs.canonicalPath(path)) ?? realPath) : realPath
            if ancestors.contains(real) { return }
            steps.append(.directory(source: path, target: target))
            for child in try await fs.list(path) {
                try await planRemote(child, RemotePath.join(path, child.name), RemotePath.join(real, child.name),
                                     (target as NSString).appendingPathComponent(child.name), ancestors.union([real]),
                                     r, mask, &steps)
            }
        } else if f.type == .symlink && f.targetType == nil {
            return
        } else {
            var size = f.size
            if f.type == .symlink, let t = try? await fs.canonicalPath(path), let real = try await fs.fileInfo(t) {
                size = real.size
            }
            steps.append(.file(source: path, target: target, size: size, modified: f.modified))
        }
    }

    private func planLocal(_ path: String, _ target: String, _ ancestors: Set<String>, _ r: TransferRequest,
                           _ mask: FileMask?, _ steps: inout [Step]) async throws {
        let name = (path as NSString).lastPathComponent
        if r.options.excludeHiddenFiles && name.hasPrefix(".") { return }
        let real = realPath(path)
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: real) } catch {
            throw localError(URL(fileURLWithPath: path), error)
        }
        let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs[.modificationDate] as? Date
        if let mask, !mask.matches(path: path, isDirectory: isDir, size: size, modified: modified) { return }
        if isDir {
            if ancestors.contains(real) { return }
            steps.append(.directory(source: path, target: target))
            let children: [String]
            do { children = try FileManager.default.contentsOfDirectory(atPath: path).sorted() } catch {
                throw localError(URL(fileURLWithPath: path), error)
            }
            for child in children {
                let remoteChild = try await remoteName(in: target, for: child)
                try await planLocal((path as NSString).appendingPathComponent(child), RemotePath.join(target, remoteChild),
                                    ancestors.union([real]), r, mask, &steps)
            }
        } else {
            steps.append(.file(source: path, target: target, size: size, modified: modified))
        }
    }

    private func remoteName(in dir: String, for localName: String) async throws -> String {
        let nfc = localName.precomposedStringWithCanonicalMapping
        if remoteNames[dir] == nil {
            var names: [String: String] = [:]
            if let d = try await fs.fileInfo(dir), d.isDirectory {
                for f in try await fs.list(dir) { names[f.name.precomposedStringWithCanonicalMapping] = f.name }
            }
            remoteNames[dir] = names
        }
        return remoteNames[dir]?[nfc] ?? nfc
    }

    private func makeDirectory(_ source: String, _ target: String, _ r: TransferRequest) async throws {
        switch r.direction {
        case .download:
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), !isDir.boolValue {
                throw RemoteError(.alreadyExists, "\(target) exists and is not a folder.")
            }
            do { try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true) } catch {
                throw localError(URL(fileURLWithPath: target), error)
            }
        case .upload:
            if let existing = try await fs.fileInfo(target) {
                guard existing.isDirectory else {
                    throw RemoteError(.alreadyExists, "\(target) exists and is not a directory.")
                }
            } else {
                try await fs.makeDirectory(target)
            }
            if let p = r.options.uploadPermissions(isDirectory: true) {
                try await ignoringPermissionErrors(r.options) { try await self.fs.setPermissions(target, p) }
            }
        }
    }

    private func ignoringPermissionErrors(_ o: TransferOptions, _ body: () async throws -> Void) async throws {
        do { try await body() } catch let e as RemoteError where o.ignorePermissionErrors && e.kind != .cancelled {}
    }

    private func decide(_ q: OverwriteQuestion, _ o: TransferOptions) async throws -> Int64? {
        if o.newerOnly, let s = q.source.modified, let t = q.target.modified, Int(s.timeIntervalSince1970) <= Int(t.timeIntervalSince1970) {
            return nil
        }
        let answer: OverwriteAnswer
        if let batch { answer = batch } else { answer = await delegate.overwrite(q) }
        switch answer {
        case .overwriteAll, .skipAll, .overwriteAllIfNewer: batch = answer
        default: break
        }
        switch answer {
        case .overwrite, .overwriteAll: return 0
        case .skip, .skipAll: return nil
        case .resume: return q.canResume ? q.target.size : 0
        case .cancel: throw RemoteError(.cancelled, "Transfer cancelled.")
        case .overwriteAllIfNewer:

            guard let s = q.source.modified, let t = q.target.modified else { return nil }
            return Int(s.timeIntervalSince1970) > Int(t.timeIntervalSince1970) ? 0 : nil
        }
    }

    private func transferFile(_ source: String, _ target: String, _ size: Int64, _ modified: Date?,
                              _ r: TransferRequest) async throws {
        let base = progress.doneBytes
        let report: ProgressHandler = { [onProgress, progress] done in
            var p = progress
            p.doneBytes = base + done
            onProgress(p)
        }
        let o = r.options
        let src = FileSummary(path: source, size: size, modified: modified)
        let resumable = fs.supportsResume && o.allowsResume(size: size, fileName: RemotePath.name(target))
        let partial = target + TransferOptions.partialSuffix

        switch r.direction {
        case .download:
            let fm = FileManager.default
            let targetURL = URL(fileURLWithPath: target)
            var appendAt: Int64 = 0
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: target, isDirectory: &isDir) {
                guard !isDir.boolValue else { throw RemoteError(.alreadyExists, "\(target) is a folder.") }
                let a = try? fm.attributesOfItem(atPath: target)
                let t = FileSummary(path: target, size: (a?[.size] as? NSNumber)?.int64Value ?? 0, modified: a?[.modificationDate] as? Date)
                guard let offset = try await decide(OverwriteQuestion(direction: .download, source: src, target: t,
                                                                      canResume: fs.supportsResume && t.size < size), o) else { return }
                appendAt = offset
            }
            if appendAt > 0 {
                try await fs.download(source, to: targetURL, offset: appendAt, progress: report)
            } else {
                let partialURL = URL(fileURLWithPath: partial)
                let have = resumable ? ((try? fm.attributesOfItem(atPath: partial)[.size] as? NSNumber)?.int64Value ?? 0) : 0
                try await fs.download(source, to: partialURL, offset: have < size ? have : 0, progress: report)

                guard rename(partial, target) == 0 else {
                    throw RemoteError(.failure, "Cannot replace \(target): \(String(cString: strerror(errno)))")
                }
            }
            if o.preserveTime, let modified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target)
            }

        case .upload:
            let sourceURL = URL(fileURLWithPath: source)
            var appendAt: Int64 = 0
            let existing = try await fs.fileInfo(target)
            if let e = existing {
                guard !e.isDirectory else { throw RemoteError(.alreadyExists, "\(target) is a directory.") }
                let t = FileSummary(path: target, size: e.size, modified: e.modified)
                guard let offset = try await decide(OverwriteQuestion(direction: .upload, source: src, target: t,
                                                                      canResume: fs.supportsResume && t.size < size), o) else { return }
                appendAt = offset
            }
            if appendAt > 0 || fs.uploadsInPlace {
                try await fs.upload(sourceURL, to: target, offset: appendAt, progress: report)
            } else {
                let have = resumable ? (try await fs.fileInfo(partial)?.size ?? 0) : 0
                try await fs.upload(sourceURL, to: partial, offset: have < size ? have : 0, progress: report)
                do {
                    try await fs.rename(partial, to: target)
                } catch let e as RemoteError where existing != nil && e.kind != .connection {
                    try await fs.delete(target, isDirectory: false)
                    try await fs.rename(partial, to: target)
                }

                if let e = existing, o.uploadPermissions(isDirectory: false) == nil {
                    try? await fs.setPermissions(target, e.permissions)
                }
            }
            if let p = o.uploadPermissions(isDirectory: false) {
                try await ignoringPermissionErrors(o) { try await self.fs.setPermissions(target, p) }
            }
            if o.preserveTime, let modified {
                try await ignoringPermissionErrors(o) { try await self.fs.setModified(target, modified) }
            }
        }
    }
}

func realPath(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}
