import CSSH
import Foundation

public actor SFTPFileSystem: RemoteFileSystem {
    private let executor = QueueExecutor(label: "MacSCP.SFTP")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated var supportsResume: Bool { true }

    private let ssh: SSHConnection
    var sshConnection: SSHConnection { ssh }

    private nonisolated(unsafe) var sftp: sftp_session?

    static let pipelineDepth = 16

    private init(_ parameters: ConnectionParameters) { ssh = SSHConnection(parameters) }

    public static func connect(_ parameters: ConnectionParameters, prompter: any ConnectionPrompter) async throws -> SFTPFileSystem {
        let fs = SFTPFileSystem(parameters)
        try await fs.start(prompter: prompter)
        return fs
    }

    private func start(prompter: any ConnectionPrompter) async throws {
        try await ssh.connect(prompter: prompter)
        guard let s = sftp_new(ssh.session) else { throw RemoteError(.connection, ssh.lastError) }
        guard sftp_init(s) == SSH_OK else {
            sftp_free(s)
            throw RemoteError(.connection, "Cannot start SFTP: \(ssh.lastError)")
        }
        sftp = s
    }

    deinit { if let sftp { sftp_free(sftp) } }

    private var session: sftp_session {
        get throws {
            guard let sftp else { throw RemoteError(.connection, "Not connected.") }
            return sftp
        }
    }

    private func error(_ what: String, _ path: String) -> RemoteError {
        if ssh_is_connected(ssh.session) == 0 {
            return RemoteError(.connection, "Cannot \(what) \(path): connection lost (\(ssh.lastError))")
        }
        let code = sftp.map { sftp_get_error($0) } ?? SSH_FX_NO_CONNECTION
        let kind: RemoteError.Kind = switch code {
        case SSH_FX_NO_SUCH_FILE, SSH_FX_NO_SUCH_PATH: .noSuchFile
        case SSH_FX_PERMISSION_DENIED, SSH_FX_WRITE_PROTECT: .permissionDenied
        case SSH_FX_FILE_ALREADY_EXISTS: .alreadyExists
        case SSH_FX_OP_UNSUPPORTED: .unsupported
        case SSH_FX_NO_CONNECTION, SSH_FX_CONNECTION_LOST: .connection
        default: .failure
        }
        let reason = switch kind {
        case .noSuchFile: "No such file or directory"
        case .permissionDenied: "Permission denied"
        case .alreadyExists: "File already exists"
        default: ssh.lastError
        }
        return RemoteError(kind, "Cannot \(what) \(path): \(reason)")
    }

    private func file(from a: sftp_attributes, name: String) -> RemoteFile {
        let attrs = a.pointee
        let type: FileType = switch Int32(attrs.type) {
        case SSH_FILEXFER_TYPE_REGULAR: .file
        case SSH_FILEXFER_TYPE_DIRECTORY: .directory
        case SSH_FILEXFER_TYPE_SYMLINK: .symlink
        default: .other
        }

        var owner = String(attrs.uid), group = String(attrs.gid)
        if let ln = attrs.longname, let parsed = try? ListingParser.parseLine(String(cString: ln)) {
            owner = parsed.owner
            group = parsed.group
        }
        let hasTime = attrs.flags & UInt32(SSH_FILEXFER_ATTR_ACMODTIME) != 0
        return RemoteFile(name: name, type: type, size: Int64(attrs.size),
                          modified: hasTime ? Date(timeIntervalSince1970: TimeInterval(attrs.mtime)) : nil,
                          permissions: Permissions(UInt16(truncatingIfNeeded: attrs.permissions)),
                          owner: owner, group: group)
    }

    private func resolve(_ f: inout RemoteFile, at path: String) throws {
        guard f.type == .symlink else { return }
        let s = try session
        if let t = sftp_readlink(s, path) {
            f.linkTarget = String(cString: t)
            ssh_string_free_char(t)
        }
        if let a = sftp_stat(s, path) {
            f.targetType = file(from: a, name: f.name).type
            sftp_attributes_free(a)
        }
    }

    public func homeDirectory() throws -> String { try canonicalPath(".") }

    public func canonicalPath(_ path: String) throws -> String {
        guard let p = sftp_canonicalize_path(try session, path) else { throw error("resolve", path) }
        defer { ssh_string_free_char(p) }
        return String(cString: p)
    }

    public func list(_ path: String) throws -> [RemoteFile] {
        let s = try session
        guard let dir = sftp_opendir(s, path) else { throw error("list", path) }
        defer { sftp_closedir(dir) }
        var result: [RemoteFile] = []
        while let a = sftp_readdir(s, dir) {
            let name = String(cString: a.pointee.name)
            var f = file(from: a, name: name)
            sftp_attributes_free(a)
            if name == "." || name == ".." { continue }
            try resolve(&f, at: RemotePath.join(path, name))
            result.append(f)
        }
        guard sftp_dir_eof(dir) != 0 else { throw error("list", path) }
        return result
    }

    public func fileInfo(_ path: String) throws -> RemoteFile? {
        let s = try session
        guard let a = sftp_lstat(s, path) else {
            let code = sftp_get_error(s)
            if code == SSH_FX_NO_SUCH_FILE || code == SSH_FX_NO_SUCH_PATH { return nil }
            throw error("read attributes of", path)
        }
        var f = file(from: a, name: RemotePath.name(path))
        sftp_attributes_free(a)
        try resolve(&f, at: path)
        return f
    }

    public func makeDirectory(_ path: String) throws {
        guard sftp_mkdir(try session, path, 0o755) == SSH_OK else { throw error("create directory", path) }
    }

    public func delete(_ path: String, isDirectory: Bool) throws {
        let s = try session
        if isDirectory {
            for f in try list(path) {
                try delete(RemotePath.join(path, f.name), isDirectory: f.type == .directory)
            }
            guard sftp_rmdir(s, path) == SSH_OK else { throw error("delete", path) }
        } else {
            guard sftp_unlink(s, path) == SSH_OK else { throw error("delete", path) }
        }
    }

    public func rename(_ path: String, to newPath: String) throws {
        guard sftp_rename(try session, path, newPath) == SSH_OK else { throw error("rename", path) }
    }

    public func setPermissions(_ path: String, _ permissions: Permissions) throws {
        guard sftp_chmod(try session, path, mode_t(permissions.mode)) == SSH_OK else {
            throw error("change permissions of", path)
        }
    }

    public func setModified(_ path: String, _ date: Date) throws {
        let t = timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)
        let times = [t, t]
        guard sftp_utimes(try session, path, times) == SSH_OK else { throw error("set time of", path) }
    }

    public nonisolated var supportsOwnership: Bool { true }

    public func checksums(_ paths: [String]) throws -> [String: String]? {
        let r = try ssh.runShell(checksumCommand(paths), in: "/")
        let sums = parseChecksums(r.output, paths)
        return sums.isEmpty ? nil : sums
    }

    public func setOwner(_ path: String, owner: String?, group: String?) throws {
        guard owner != nil || group != nil else { return }
        let uid = owner.flatMap { UInt32($0) }, gid = group.flatMap { UInt32($0) }
        if (owner == nil || uid != nil) && (group == nil || gid != nil) {
            let s = try session
            guard let a = sftp_stat(s, path) else { throw error("change the owner of", path) }
            let current = a.pointee
            sftp_attributes_free(a)
            guard sftp_chown(s, path, uid ?? current.uid, gid ?? current.gid) == SSH_OK else { throw error("change the owner of", path) }
            return
        }
        let r = try ssh.runShell(chownCommand(path, owner: owner, group: group)!, in: "/")
        guard r.exitCode == 0 else {
            let msg = r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError(msg.contains("ermission") || msg.contains("not permitted") ? .permissionDenied : .failure,
                              "Cannot change the owner of \(path): \(msg.isEmpty ? "exit code \(r.exitCode)" : msg)")
        }
    }

    public func createSymlink(_ path: String, target: String) throws {
        let s = try session
        var reversed = false
        if ssh_get_openssh_version(ssh.session) == 0 {
            if sftp_extension_supported(s, "hardlink@openssh.com", "1") != 0 { reversed = true }
            if ssh.serverBanner.contains("mod_sftp") { reversed = true }
        }
        let rc = reversed ? sftp_symlink(s, path, target) : sftp_symlink(s, target, path)
        guard rc == SSH_OK else { throw error("create link", path) }
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: ProgressHandler) throws {
        let s = try session
        guard let file = sftp_open(s, path, O_RDONLY, 0) else { throw error("open", path) }
        defer { sftp_close(file) }
        guard let a = sftp_fstat(file) else { throw error("read attributes of", path) }
        let size = Int64(a.pointee.size)
        sftp_attributes_free(a)

        if offset == 0 || !FileManager.default.fileExists(atPath: local.path) {
            guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
                throw RemoteError(.failure, "Cannot create \(local.path)")
            }
        }
        let out: FileHandle
        do {
            out = try FileHandle(forWritingTo: local)
            try out.truncate(atOffset: UInt64(offset))
        } catch { throw localError(local, error) }
        defer { try? out.close() }

        guard let limits = sftp_limits(s) else { throw error("read limits for", path) }
        let chunk = Int(limits.pointee.max_read_length)
        sftp_limits_free(limits)

        var pending: [(aio: sftp_aio?, offset: Int64, length: Int)] = []
        var next = offset
        var done = offset
        var eof = false
        var buf = [UInt8](repeating: 0, count: chunk)
        func request(_ at: Int64, _ length: Int) throws {
            var aio: sftp_aio?
            if sftp_tell64(file) != UInt64(at) { sftp_seek64(file, UInt64(at)) }
            let n = sftp_aio_begin_read(file, length, &aio)
            guard n > 0 else { throw error("read", path) }
            pending.append((aio, at, n))
        }
        while (next < size || !pending.isEmpty) && !eof {
            while !eof, next < size, pending.count < Self.pipelineDepth {
                let len = Int(min(Int64(chunk), size - next))
                try request(next, len)
                next += Int64(len)
            }
            guard !pending.isEmpty else { break }
            var r = pending.removeFirst()
            let n = sftp_aio_wait_read(&r.aio, &buf, chunk)
            if n < 0 {
                for p in pending { sftp_aio_free(p.aio) }
                throw error("read", path)
            }
            if n == 0 {
                eof = true
                continue
            }
            do {
                try out.seek(toOffset: UInt64(r.offset))
                try out.write(contentsOf: buf[0..<n])
            } catch { throw localError(local, error) }
            done += Int64(n)
            if n < r.length { try request(r.offset + Int64(n), r.length - n) }
            progress(done)
            if Task.isCancelled {
                for p in pending { var a = p.aio; _ = sftp_aio_wait_read(&a, &buf, chunk) }
                throw RemoteError(.cancelled, "Transfer cancelled.")
            }
        }

        for p in pending { var a = p.aio; _ = sftp_aio_wait_read(&a, &buf, chunk) }
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: ProgressHandler) throws {
        let s = try session
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: local)
            try input.seek(toOffset: UInt64(offset))
        } catch { throw localError(local, error) }
        defer { try? input.close() }

        let flags = O_WRONLY | O_CREAT | (offset == 0 ? O_TRUNC : 0)
        guard let file = sftp_open(s, path, flags, 0o644) else { throw error("create", path) }
        defer { sftp_close(file) }
        if offset > 0 { sftp_seek64(file, UInt64(offset)) }

        guard let limits = sftp_limits(s) else { throw error("read limits for", path) }
        let chunk = Int(limits.pointee.max_write_length)
        sftp_limits_free(limits)

        var pending: [sftp_aio?] = []
        var done = offset
        func waitOldest() throws {
            var aio = pending.removeFirst()
            guard sftp_aio_wait_write(&aio) >= 0 else { throw error("write", path) }
        }
        while true {
            let data: Data
            do { data = try input.read(upToCount: chunk) ?? Data() } catch { throw localError(local, error) }
            if data.isEmpty { break }
            if pending.count >= Self.pipelineDepth { try waitOldest() }
            var aio: sftp_aio?
            let n = data.withUnsafeBytes { sftp_aio_begin_write(file, $0.baseAddress, data.count, &aio) }

            guard n == data.count else { throw error("write", path) }
            pending.append(aio)
            done += Int64(n)
            progress(done)
            if Task.isCancelled {
                while !pending.isEmpty { try? waitOldest() }
                throw RemoteError(.cancelled, "Transfer cancelled.")
            }
        }
        while !pending.isEmpty { try waitOldest() }
    }

    public func keepalive() { ssh.sendKeepalive() }

    public func disconnect() {
        if let sftp { sftp_free(sftp) }
        sftp = nil
        ssh_disconnect(ssh.session)
    }
}
