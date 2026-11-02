// SCP protocol exchange ported from WinSCP (core/ScpFileSystem.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.

import CSSH
import Foundation

public actor SCPFileSystem: RemoteFileSystem {
    private let executor = QueueExecutor(label: "MacSCP.SCP")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated var supportsResume: Bool { false }

    private let ssh: SSHConnection
    var sshConnection: SSHConnection { ssh }

    private var listCommand: String?

    private init(_ parameters: ConnectionParameters) { ssh = SSHConnection(parameters) }

    public static func connect(_ parameters: ConnectionParameters, prompter: any ConnectionPrompter) async throws -> SCPFileSystem {
        let fs = SCPFileSystem(parameters)
        try await fs.start(prompter: prompter)
        return fs
    }

    private func start(prompter: any ConnectionPrompter) async throws {
        try await ssh.connect(prompter: prompter)
    }

    private func q(_ s: String) -> String { RemotePath.shellQuote(s) }

    private func shell(_ command: String) throws -> SSHConnection.ExecResult {
        try ssh.exec("env LC_ALL=C.UTF-8 TZ=UTC sh -c \(q(command))")
    }

    @discardableResult
    private func run(_ command: String, _ what: String, _ path: String) throws -> String {
        let r = try shell(command)
        guard r.exitCode == 0 else {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: RemoteError.Kind = msg.contains("No such file") ? .noSuchFile
                : msg.contains("Permission denied") ? .permissionDenied
                : msg.contains("File exists") ? .alreadyExists : .failure
            throw RemoteError(kind, "Cannot \(what) \(path): \(msg.isEmpty ? "exit code \(r.exitCode)" : msg)")
        }
        return String(decoding: r.stdout, as: UTF8.self)
    }

    private func lsCommand() throws -> String {
        if let listCommand { return listCommand }
        let c = try shell("ls -ld --full-time /").exitCode == 0 ? "ls -la --full-time"
            : try shell("ls -ldT /").exitCode == 0 ? "ls -laT" : "ls -la"
        listCommand = c
        return c
    }

    public func homeDirectory() throws -> String {
        try run("pwd", "read", "home directory").trimmingCharacters(in: .newlines)
    }

    public func canonicalPath(_ path: String) throws -> String {
        try run("cd \(q(path)) && pwd -P", "resolve", path).trimmingCharacters(in: .newlines)
    }

    public func list(_ path: String) throws -> [RemoteFile] {
        let output = try run("\(try lsCommand()) \(q(path))", "list", path)
        var files = try ListingParser.parse(output)
        try resolveLinks(&files, in: path)
        return files
    }

    public func fileInfo(_ path: String) throws -> RemoteFile? {
        let r = try shell("\(try lsCommand()) -d \(q(path))")
        if r.exitCode != 0 {
            if r.stderr.contains("No such file") { return nil }
            throw RemoteError(.failure, "Cannot read attributes of \(path): \(r.stderr)")
        }
        var file = try ListingParser.parseLine(
            String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .newlines))
        file.name = RemotePath.name(path)
        var one = [file]
        try resolveLinks(&one, in: RemotePath.parent(path))
        return one[0]
    }

    private func resolveLinks(_ files: inout [RemoteFile], in dir: String) throws {
        let links = files.indices.filter { files[$0].type == .symlink }
        guard !links.isEmpty else { return }
        let paths = links.map { q(RemotePath.join(dir, files[$0].name)) }.joined(separator: " ")
        let script = "for f in \(paths); do if [ -d \"$f\" ]; then echo d; elif [ -e \"$f\" ]; then echo f; else echo x; fi; done"
        let kinds = try run(script, "resolve links in", dir).split(separator: "\n")
        for (i, kind) in zip(links, kinds) {
            files[i].targetType = kind == "d" ? .directory : kind == "f" ? .file : nil
        }
    }

    public func makeDirectory(_ path: String) throws { try run("mkdir \(q(path))", "create directory", path) }

    public func delete(_ path: String, isDirectory: Bool) throws { try run("rm -f -r \(q(path))", "delete", path) }

    public func rename(_ path: String, to newPath: String) throws {
        try run("mv -f \(q(path)) \(q(newPath))", "rename", path)
    }

    public func setPermissions(_ path: String, _ permissions: Permissions) throws {
        try run("chmod \(permissions.octal) \(q(path))", "change permissions of", path)
    }

    public func setModified(_ path: String, _ date: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm.ss"
        try run("touch -t \(f.string(from: date)) \(q(path))", "set time of", path)
    }

    public nonisolated var supportsOwnership: Bool { true }

    public func checksums(_ paths: [String]) throws -> [String: String]? {
        let r: CommandResult
        do { r = try ssh.runShell(checksumCommand(paths), in: "/") } catch let e as RemoteError where e.kind == .unsupported { return nil }
        let sums = parseChecksums(r.output, paths)
        return sums.isEmpty ? nil : sums
    }

    public func setOwner(_ path: String, owner: String?, group: String?) throws {
        guard let command = chownCommand(path, owner: owner, group: group) else { return }
        try run(command, "change the owner of", path)
    }

    public func createSymlink(_ path: String, target: String) throws {
        try run("ln -s \(q(target)) \(q(path))", "create link", path)
    }

    private final class Channel {
        let ch: ssh_channel
        let ssh: SSHConnection
        init(_ ch: ssh_channel, _ ssh: SSHConnection) { self.ch = ch; self.ssh = ssh }
        deinit { ssh.finish(ch) }

        func read(_ count: Int) throws -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buf.withUnsafeMutableBytes { ssh_channel_read(ch, $0.baseAddress! + got, UInt32(count - got), 0) }
                if n == SSH_ERROR { throw RemoteError(.connection, "SCP read: \(ssh.lastError)") }
                if n == 0 { throw RemoteError(.failure, "SCP: connection closed unexpectedly.") }
                got += Int(n)
            }
            return buf
        }

        func readLine() throws -> String {
            var line = [UInt8]()
            while true {
                let b = try read(1)[0]
                if b == UInt8(ascii: "\n") { return String(decoding: line, as: UTF8.self) }
                line.append(b)
            }
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws {
            var sent = 0
            while sent < bytes.count {
                let n = ssh_channel_write(ch, bytes.baseAddress! + sent, UInt32(bytes.count - sent))
                guard n > 0 else { throw RemoteError(.connection, "SCP write: \(ssh.lastError)") }
                sent += Int(n)
            }
        }

        func write(_ s: String) throws { try Array(s.utf8).withUnsafeBytes { try write($0) } }

        func response(_ path: String) throws {
            let r = try read(1)[0]
            if r == 0 { return }
            let msg = try readLine()
            throw RemoteError(msg.contains("No such file") ? .noSuchFile : msg.contains("Permission denied")
                              ? .permissionDenied : .failure, "SCP: \(msg.isEmpty ? "error" : msg) (\(path))")
        }
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: ProgressHandler) throws {
        guard offset == 0 else { throw RemoteError(.unsupported, "SCP cannot resume transfers.") }
        let c = Channel(try ssh.openExec("scp -f \(q(path))"), ssh)
        try c.write("\0")

        let first = try c.read(1)[0]
        let header = try c.readLine()
        guard first == UInt8(ascii: "C") else {
            throw RemoteError(header.contains("No such file") ? .noSuchFile : .failure, "SCP: \(header)")
        }
        let parts = header.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, let size = Int64(parts[1]) else {
            throw RemoteError(.failure, "SCP: protocol error: \(header)")
        }
        try c.write("\0")

        guard FileManager.default.createFile(atPath: local.path, contents: nil),
              let out = try? FileHandle(forWritingTo: local) else {
            throw RemoteError(.failure, "Cannot create \(local.path)")
        }
        defer { try? out.close() }
        var done: Int64 = 0
        while done < size {
            let n = Int(min(256 * 1024, size - done))
            let chunk = try c.read(n)
            do { try out.write(contentsOf: chunk) } catch { throw localError(local, error) }
            done += Int64(n)
            progress(done)
            if Task.isCancelled { throw RemoteError(.cancelled, "Transfer cancelled.") }
        }
        try c.response(path)
        try c.write("\0")
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: ProgressHandler) throws {
        guard offset == 0 else { throw RemoteError(.unsupported, "SCP cannot resume transfers.") }
        let input: FileHandle
        let size: Int64
        do {
            input = try FileHandle(forReadingFrom: local)
            size = Int64(try input.seekToEnd())
            try input.seek(toOffset: 0)
        } catch { throw localError(local, error) }
        defer { try? input.close() }

        let c = Channel(try ssh.openExec("scp -t \(q(path))"), ssh)
        try c.response(path)

        try c.write("C0644 \(size) \(RemotePath.name(path))\n")
        try c.response(path)
        var done: Int64 = 0
        while done < size {
            let data: Data
            do { data = try input.read(upToCount: Int(min(256 * 1024, size - done))) ?? Data() } catch { throw localError(local, error) }
            if data.isEmpty { throw RemoteError(.failure, "\(local.path) shrank during upload.") }
            try data.withUnsafeBytes { try c.write($0) }
            done += Int64(data.count)
            progress(done)
            if Task.isCancelled { throw RemoteError(.cancelled, "Transfer cancelled.") }
        }
        try c.write("\0")
        try c.response(path)
        ssh_channel_send_eof(c.ch)
    }

    public func keepalive() { ssh.sendKeepalive() }

    public func disconnect() { ssh_disconnect(ssh.session) }
}
