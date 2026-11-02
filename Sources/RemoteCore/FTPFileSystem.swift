import CSSH
import Foundation

public actor FTPFileSystem: RemoteFileSystem {
    private let executor = QueueExecutor(label: "MacSCP.FTP")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated var supportsResume: Bool { true }


    private let parameters: ConnectionParameters
    private let proto: FileProtocol
    private nonisolated(unsafe) var curl: UnsafeMutableRawPointer?
    private let certificates: CertificateCheck
    private var user = ""
    private var password = ""
    private var home = "/"
    private var mlsd = true
    private var mlst = true
    private var timeCommand: String? = "MFMT"
    private var mdtm = true
    private var factsSent = false

    private init(_ parameters: ConnectionParameters, _ proto: FileProtocol) {
        self.parameters = parameters
        self.proto = proto
        certificates = CertificateCheck(host: parameters.host, port: parameters.port ?? (proto == .ftpsImplicit ? 990 : 21))
    }

    public static func connect(_ parameters: ConnectionParameters, _ proto: FileProtocol,
                               prompter: any ConnectionPrompter) async throws -> FTPFileSystem {
        let fs = FTPFileSystem(parameters, proto)
        try await fs.start(prompter: prompter)
        return fs
    }

    deinit { if let curl { curl_easy_cleanup(curl) } }

    private func start(prompter: any ConnectionPrompter) async throws {
        guard Curl.initialized, let c = curl_easy_init() else { throw RemoteError(.connection, "Cannot initialize libcurl.") }
        curl = c
        if parameters.user.isEmpty {
            user = "anonymous"
            password = "anonymous@"
        } else {
            user = parameters.user
            if let p = parameters.password {
                password = p
            } else if let p = await prompter.password(user: user, host: parameters.host) {
                password = p
            } else {
                throw RemoteError(.cancelled, "Authentication cancelled.")
            }
        }
        try await certificates.establish(prompter: prompter, file: parameters.trustedCertificatesPath) {
            try command([], "connect to", parameters.host)
        }
        if let entry = cssh_curl_info_string(c, CURLINFO_FTP_ENTRY_PATH) { home = String(cString: entry) }
    }

    private var base: String {
        let host = parameters.host.contains(":") ? "[\(parameters.host)]" : parameters.host
        return "\(proto == .ftpsImplicit ? "ftps" : "ftp")://\(host)" + (parameters.port.map { ":\($0)" } ?? "")
    }

    private func checked(_ s: String) throws -> String {
        guard !s.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw RemoteError(.failure, "FTP does not support line breaks in names: \(s)")
        }
        return s
    }

    private func url(_ path: String, directory: Bool = false) throws -> String {
        let parts = try checked(path).split(separator: "/").map { Curl.encode($0) }
        return base + "/%2F" + parts.joined(separator: "/") + (directory ? "/" : "")
    }

    @discardableResult
    private func perform(_ url: String, quote: [String] = [], facts: Bool = false, _ what: String, _ path: String,
                         _ configure: (UnsafeMutableRawPointer, Exchange) -> Void = { _, _ in }) throws -> Exchange {
        guard let c = curl else { throw RemoteError(.connection, "Not connected.") }
        let x = Curl.prepare(c, url, timeout: parameters.timeoutSeconds, tls: proto == .ftp ? nil : certificates)
        cssh_curl_string(c, CURLOPT_USERNAME, user)
        cssh_curl_string(c, CURLOPT_PASSWORD, password)
        cssh_curl_long(c, CURLOPT_SERVER_RESPONSE_TIMEOUT, 60)
        cssh_curl_long(c, CURLOPT_FTP_FILEMETHOD, CSSH_FTP_SINGLECWD)
        if proto == .ftps { cssh_curl_long(c, CURLOPT_USE_SSL, CSSH_USESSL_ALL) }
        let sendFacts = facts && !factsSent
        var list: UnsafeMutablePointer<curl_slist>?
        defer { curl_slist_free_all(list) }
        for q in (sendFacts ? ["*OPTS MLST type;size;modify;UNIX.mode;UNIX.owner;UNIX.group;UNIX.uid;UNIX.gid;"] : []) + quote {
            list = curl_slist_append(list, try checked(q))
        }
        if list != nil { cssh_curl_pointer(c, CURLOPT_QUOTE, list) }
        configure(c, x)
        let rc = curl_easy_perform(c)
        let reconnected = cssh_curl_info_long(c, CURLINFO_NUM_CONNECTS) > 0
        factsSent = sendFacts || (factsSent && !reconnected)
        if let e = x.localError { throw e }
        guard rc == CURLE_OK else { throw failure(rc, x, what, path) }
        return x
    }

    @discardableResult
    private func command(_ commands: [String], facts: Bool = false, _ what: String, _ path: String) throws -> Exchange {
        try perform(base + "/", quote: commands, facts: facts, what, path) { c, _ in cssh_curl_long(c, CURLOPT_NOBODY, 1) }
    }

    private func failure(_ rc: CURLcode, _ x: Exchange, _ what: String, _ path: String) -> RemoteError {
        if x.cancelled { return RemoteError(.cancelled, "Transfer cancelled.") }
        let reply = x.replies.last { $0.first == "4" || $0.first == "5" }
        let buffer = String(cString: x.errorBuffer)
        let detail = reply ?? (buffer.isEmpty ? String(cString: curl_easy_strerror(rc)) : buffer)
        let code = reply.flatMap { Int($0.prefix(3)) } ?? 0
        let lower = detail.lowercased()
        let kind: RemoteError.Kind
        switch rc {
        case CURLE_LOGIN_DENIED: kind = .authentication
        case CURLE_COULDNT_RESOLVE_HOST, CURLE_COULDNT_CONNECT, CURLE_SEND_ERROR, CURLE_RECV_ERROR,
             CURLE_OPERATION_TIMEDOUT, CURLE_GOT_NOTHING, CURLE_PARTIAL_FILE, CURLE_SSL_CONNECT_ERROR,
             CURLE_WEIRD_SERVER_REPLY, CURLE_FTP_WEIRD_PASV_REPLY, CURLE_FTP_WEIRD_227_FORMAT,
             CURLE_FTP_CANT_GET_HOST, CURLE_FTP_ACCEPT_FAILED, CURLE_FTP_ACCEPT_TIMEOUT, CURLE_FTP_PORT_FAILED:
            kind = .connection
        case CURLE_REMOTE_FILE_NOT_FOUND: kind = .noSuchFile
        default:
            if [500, 502, 504].contains(code) {
                kind = .unsupported
            } else if lower.contains("permission") || lower.contains("denied") {
                kind = .permissionDenied
            } else if lower.contains("exists") {
                kind = .alreadyExists
            } else if code == 550 || lower.contains("no such file") || lower.contains("not found") {
                kind = .noSuchFile
            } else {
                kind = .failure
            }
        }
        return RemoteError(kind, "Cannot \(what) \(path): \(detail)")
    }

    private func probe(_ path: String) -> FileType? {
        if (try? perform(url(path, directory: true), "open", path) { c, _ in cssh_curl_long(c, CURLOPT_NOBODY, 1) }) != nil {
            return .directory
        }
        if (try? perform(url(path), "open", path) { c, _ in cssh_curl_long(c, CURLOPT_NOBODY, 1) }) != nil {
            return .file
        }
        return nil
    }

    func rawCommand(_ text: String) throws -> [String] {
        let x = try command(["*" + text], "run", text)
        guard let start = x.replies.lastIndex(where: { $0.hasPrefix("257 ") || $0.hasPrefix("230 ") }) else { return x.replies }
        return Array(x.replies[(start + 1)...])
    }

    public func homeDirectory() -> String { home }

    public func canonicalPath(_ path: String) -> String { RemotePath.normalize(path, home: home) }

    public func list(_ path: String) throws -> [RemoteFile] {
        var files: [RemoteFile]
        if mlsd {
            do {
                let x = try perform(url(path, directory: true), facts: true, "list", path) { c, _ in
                    cssh_curl_string(c, CURLOPT_CUSTOMREQUEST, "MLSD")
                }
                files = String(decoding: x.body, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
                    guard let (f, type) = Self.facts(String($0)), type != "cdir", type != "pdir" else { return nil }
                    return f.name == "." || f.name == ".." ? nil : f
                }
            } catch let e as RemoteError where e.kind == .unsupported {
                mlsd = false
                return try list(path)
            }
        } else {
            let x = try perform(url(path, directory: true), "list", path) { c, _ in
                cssh_curl_string(c, CURLOPT_CUSTOMREQUEST, "LIST -a")
            }
            files = try ListingParser.parse(String(decoding: x.body, as: UTF8.self))
        }
        for i in files.indices where files[i].type == .symlink && files[i].targetType == nil {
            files[i].targetType = probe(RemotePath.join(path, files[i].name))
        }
        return files
    }

    public func fileInfo(_ path: String) throws -> RemoteFile? {
        let path = RemotePath.trimTrailingSlash(path)
        if path == "/" { return RemoteFile(name: "/", type: .directory) }
        if mlst {
            do {
                let x = try command(["MLST \(path)"], facts: true, "read attributes of", path)
                if let line = x.replies.first(where: { $0.hasPrefix(" ") }), var (f, _) = Self.facts(String(line.dropFirst())) {
                    f.name = RemotePath.name(path)
                    if f.type == .symlink { f.targetType = probe(path) }
                    return f
                }
            } catch let e as RemoteError where e.kind == .noSuchFile {
                return nil
            } catch let e as RemoteError where e.kind == .unsupported {
                mlst = false
            }
        }
        do {
            guard var f = try list(RemotePath.parent(path)).first(where: { $0.name == RemotePath.name(path) }) else { return nil }
            if f.type == .file, mdtm, let t = try modifiedTime(path) { f.modified = t }
            return f
        } catch let e as RemoteError where e.kind == .noSuchFile {
            return nil
        }
    }

    private func modifiedTime(_ path: String) throws -> Date? {
        do {
            let x = try command(["MDTM \(path)"], "read time of", path)
            return x.replies.last { $0.hasPrefix("213 ") }.flatMap { Self.time($0.dropFirst(4)) }
        } catch let e as RemoteError where e.kind == .unsupported {
            mdtm = false
            return nil
        }
    }

    static func time(_ s: Substring) -> Date? {
        let d = Array(s.utf8.prefix(14)).map { Int32($0) - 48 }
        guard d.count == 14, d.allSatisfy({ (0...9).contains($0) }) else { return nil }
        func n(_ r: Range<Int>) -> Int32 { d[r].reduce(0) { $0 * 10 + $1 } }
        var t = tm()
        t.tm_year = n(0..<4) - 1900
        t.tm_mon = n(4..<6) - 1
        t.tm_mday = n(6..<8)
        t.tm_hour = n(8..<10)
        t.tm_min = n(10..<12)
        t.tm_sec = n(12..<14)
        return Date(timeIntervalSince1970: TimeInterval(timegm(&t)))
    }

    static func facts(_ line: String) -> (RemoteFile, String)? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            guard let eq = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<eq].lowercased()] = String(fact[fact.index(after: eq)...])
        }
        let rawType = facts["type"] ?? ""
        let type = rawType.lowercased()
        var f = RemoteFile(name: String(line[line.index(after: space)...]), type: .other)
        switch type {
        case "file": f.type = .file
        case "dir", "cdir", "pdir": f.type = .directory
        default:
            if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") {
                f.type = .symlink
                if let colon = rawType.firstIndex(of: ":") { f.linkTarget = String(rawType[rawType.index(after: colon)...]) }
            }
        }
        f.size = Int64(facts["size"] ?? facts["sizd"] ?? "") ?? 0
        if let m = facts["modify"] { f.modified = time(Substring(m)) }
        if let mode = facts["unix.mode"], let p = Permissions(octal: mode.replacingOccurrences(of: "0o", with: "")) { f.permissions = p }
        f.owner = facts["unix.owner"] ?? facts["unix.uid"] ?? ""
        f.group = facts["unix.group"] ?? facts["unix.gid"] ?? ""
        return (f, type)
    }

    public func makeDirectory(_ path: String) throws { try command(["MKD \(path)"], "create directory", path) }

    public func delete(_ path: String, isDirectory: Bool) throws {
        if isDirectory {
            for f in try list(path) {
                try delete(RemotePath.join(path, f.name), isDirectory: f.type == .directory)
            }
            try command(["RMD \(path)"], "delete", path)
        } else {
            try command(["DELE \(path)"], "delete", path)
        }
    }

    public func rename(_ path: String, to newPath: String) throws {
        try command(["RNFR \(path)", "RNTO \(newPath)"], "rename", path)
    }

    public func setPermissions(_ path: String, _ permissions: Permissions) throws {
        try command(["SITE CHMOD \(permissions.octal) \(path)"], "change permissions of", path)
    }

    public func setModified(_ path: String, _ date: Date) throws {
        guard let verb = timeCommand else { return }
        var t = time_t(date.timeIntervalSince1970)
        var parts = tm()
        gmtime_r(&t, &parts)
        let stamp = String(format: "%04d%02d%02d%02d%02d%02d", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
                           parts.tm_hour, parts.tm_min, parts.tm_sec)
        do {
            try command(["\(verb) \(stamp) \(path)"], "set time of", path)
        } catch let e as RemoteError where e.kind == .unsupported && verb == "MFMT" {
            timeCommand = "MDTM"
            try setModified(path, date)
        } catch let e as RemoteError where verb == "MDTM" && e.kind != .connection && e.kind != .cancelled {
            timeCommand = nil
        }
    }

    public func createSymlink(_ path: String, target: String) throws {
        throw RemoteError(.unsupported, "Cannot create link \(path): FTP has no command for links.")
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: ProgressHandler) throws {
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
        _ = try withoutActuallyEscaping(progress) { progress in
            try perform(url(path), "download", path) { c, x in
                if offset > 0 { cssh_curl_offset(c, CURLOPT_RESUME_FROM_LARGE, curl_off_t(offset)) }
                x.sink = { [unowned x] data in
                    do { try out.write(contentsOf: data) } catch { x.localError = localError(local, error) }
                    return x.localError == nil
                }
                x.progress = { progress(offset + $0) }
            }
        }
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: ProgressHandler) throws {
        let input: FileHandle
        let size: Int64
        do {
            input = try FileHandle(forReadingFrom: local)
            size = Int64(try input.seekToEnd())
            try input.seek(toOffset: UInt64(offset))
        } catch { throw localError(local, error) }
        defer { try? input.close() }
        _ = try withoutActuallyEscaping(progress) { progress in
            try perform(url(path), "upload", path) { c, x in
                cssh_curl_long(c, CURLOPT_UPLOAD, 1)
                if offset > 0 { cssh_curl_long(c, CURLOPT_APPEND, 1) }
                cssh_curl_offset(c, CURLOPT_INFILESIZE_LARGE, curl_off_t(size - offset))
                x.source = { [unowned x] buffer in
                    do {
                        let data = try input.read(upToCount: buffer.count) ?? Data()
                        return data.copyBytes(to: buffer)
                    } catch {
                        x.localError = localError(local, error)
                        return nil
                    }
                }
                x.progress = { progress(offset + $0) }
            }
        }
    }

    public func keepalive() { _ = try? command(["NOOP"], "keep alive", parameters.host) }

    public func disconnect() {
        if let curl { curl_easy_cleanup(curl) }
        curl = nil
    }
}
