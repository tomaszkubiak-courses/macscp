import CSSH
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public actor S3FileSystem: RemoteFileSystem {
    private let executor = QueueExecutor(label: "MacSCP.S3")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated var supportsResume: Bool { false }
    public nonisolated var uploadsInPlace: Bool { true }

    private let parameters: ConnectionParameters
    private let scheme: String
    private let endpoint: String
    private let aws: Bool
    private let defaultRegion: String
    private let tls: CertificateCheck?
    private nonisolated(unsafe) var curl: UnsafeMutableRawPointer?
    private var accessKey = ""
    private var secretKey = ""
    private var sessionToken: String?
    private var regions: [String: String] = [:]
    var multipartThreshold: Int64 = 64 << 20
    var partSize: Int64 = 16 << 20
    var copyThreshold: Int64 = 5 << 30
    var copyPartSize: Int64 = 512 << 20

    private init(_ parameters: ConnectionParameters, _ proto: FileProtocol) {
        self.parameters = parameters
        let host = parameters.host.isEmpty ? "s3.amazonaws.com" : parameters.host
        aws = host.hasSuffix(".amazonaws.com")
        scheme = proto == .s3 ? "https" : "http"
        endpoint = (host.contains(":") ? "[\(host)]" : host) + (parameters.port.map { ":\($0)" } ?? "")
        let env = ProcessInfo.processInfo.environment
        defaultRegion = parameters.region ?? env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] ?? "us-east-1"
        tls = proto == .s3 ? CertificateCheck(host: host, port: parameters.port ?? 443) : nil
    }

    public static func connect(_ parameters: ConnectionParameters, _ proto: FileProtocol,
                               prompter: any ConnectionPrompter) async throws -> S3FileSystem {
        let fs = S3FileSystem(parameters, proto)
        try await fs.start(prompter: prompter)
        return fs
    }

    deinit { if let curl { curl_easy_cleanup(curl) } }

    func setMultipart(threshold: Int64, partSize: Int64, copyThreshold: Int64? = nil, copyPartSize: Int64? = nil) {
        multipartThreshold = threshold
        self.partSize = partSize
        if let copyThreshold { self.copyThreshold = copyThreshold }
        if let copyPartSize { self.copyPartSize = copyPartSize }
    }

    private func start(prompter: any ConnectionPrompter) async throws {
        guard Curl.initialized, let c = curl_easy_init() else { throw RemoteError(.connection, "Cannot initialize libcurl.") }
        curl = c
        if !parameters.user.isEmpty {
            accessKey = parameters.user
            if let p = parameters.password {
                secretKey = p
            } else if let p = await prompter.password(user: accessKey, host: endpoint) {
                secretKey = p
            } else {
                throw RemoteError(.cancelled, "Authentication cancelled.")
            }
        } else if let (key, secret, token) = Self.credentials(ProcessInfo.processInfo.environment) {
            accessKey = key
            secretKey = secret
            sessionToken = token
        } else {
            throw RemoteError(.authentication, "No S3 credentials: enter an access key ID, or set up ~/.aws/credentials.")
        }
        if let tls {
            try await tls.establish(prompter: prompter, file: parameters.trustedCertificatesPath) { try probe() }
        } else {
            try probe()
        }
    }

    private func probe() throws {
        do {
            try send("GET", nil, region: defaultRegion, what: "connect to", path: endpoint)
        } catch let e as RemoteError where e.kind == .permissionDenied {
        }
    }

    static func credentials(_ env: [String: String]) -> (String, String, String?)? {
        if let key = env["AWS_ACCESS_KEY_ID"], let secret = env["AWS_SECRET_ACCESS_KEY"] {
            return (key, secret, env["AWS_SESSION_TOKEN"])
        }
        let file = env["AWS_SHARED_CREDENTIALS_FILE"] ?? NSHomeDirectory() + "/.aws/credentials"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let profile = env["AWS_PROFILE"] ?? "default"
        var section = ""
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            } else if section == profile, let eq = line.firstIndex(of: "=") {
                values[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let key = values["aws_access_key_id"], let secret = values["aws_secret_access_key"] else { return nil }
        return (key, secret, values["aws_session_token"])
    }

    private func split(_ path: String) -> (bucket: String?, key: String) {
        let parts = RemotePath.normalize(path, home: "/").dropFirst().split(separator: "/", maxSplits: 1)
        guard let bucket = parts.first else { return (nil, "") }
        return (String(bucket), parts.count > 1 ? String(parts[1]) : "")
    }

    private func location(_ bucket: String?, _ key: String, _ region: String) -> (host: String, path: String) {
        let encoded = key.split(separator: "/", omittingEmptySubsequences: false).map { Curl.encode($0) }.joined(separator: "/")
        let regional = "s3.\(region).amazonaws.com"
        guard let bucket else { return (aws ? regional : endpoint, "/") }
        if aws && !bucket.contains(".") { return ("\(bucket).\(regional)", "/" + encoded) }
        return (aws ? regional : endpoint, "/\(Curl.encode(bucket))/" + encoded)
    }

    private func region(for bucket: String) throws -> String {
        guard aws else { return defaultRegion }
        if let r = regions[bucket] { return r }
        let x = try send("HEAD", bucket, region: "us-east-1", raw: true, what: "locate", path: "/" + bucket)
        let r = x.header("x-amz-bucket-region") ?? defaultRegion
        regions[bucket] = r
        return r
    }

    @discardableResult
    private func send(_ method: String, _ bucket: String?, _ key: String = "", query: [(String, String)] = [],
                      headers: [String] = [], body: Data? = nil, region: String? = nil, raw: Bool = false,
                      what: String, path: String,
                      _ configure: (UnsafeMutableRawPointer, Exchange) -> Void = { _, _ in }) throws -> Exchange {
        guard let c = curl else { throw RemoteError(.connection, "Not connected.") }
        let region = try region ?? bucket.map { try self.region(for: $0) } ?? defaultRegion
        let (host, urlPath) = location(bucket, key, region)
        let q = query.map { "\(Curl.encode($0.0))=\(Curl.encode($0.1))" }.joined(separator: "&")
        if aws { tls?.host = host }
        let x = Curl.prepare(c, "\(scheme)://\(host)\(urlPath)" + (q.isEmpty ? "" : "?" + q),
                             timeout: parameters.timeoutSeconds, tls: tls)
        cssh_curl_string(c, CURLOPT_USERNAME, accessKey)
        cssh_curl_string(c, CURLOPT_PASSWORD, secretKey)
        cssh_curl_string(c, CURLOPT_AWS_SIGV4, "aws:amz:\(region):s3")
        Curl.applyProxy(c, parameters, tunnel: false)
        var list: UnsafeMutablePointer<curl_slist>?
        defer { curl_slist_free_all(list) }
        for h in headers + (sessionToken.map { ["x-amz-security-token: \($0)"] } ?? []) { list = curl_slist_append(list, h) }
        let data = body ?? Data()
        switch method {
        case "GET": break
        case "HEAD": cssh_curl_long(c, CURLOPT_NOBODY, 1)
        case "PUT":
            cssh_curl_long(c, CURLOPT_UPLOAD, 1)
            cssh_curl_offset(c, CURLOPT_INFILESIZE_LARGE, curl_off_t(data.count))
            var sent = 0
            x.source = { buffer in
                let n = min(buffer.count, data.count - sent)
                data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: sent..<(sent + n))
                sent += n
                return n
            }
        case "POST":
            cssh_curl_long(c, CURLOPT_POST, 1)
            cssh_curl_long(c, CURLOPT_POSTFIELDSIZE, data.count)
            if data.isEmpty {
                cssh_curl_string(c, CURLOPT_COPYPOSTFIELDS, "")
            } else {
                data.withUnsafeBytes { _ = cssh_curl_pointer(c, CURLOPT_COPYPOSTFIELDS, UnsafeMutableRawPointer(mutating: $0.baseAddress!)) }
            }
        default: cssh_curl_string(c, CURLOPT_CUSTOMREQUEST, method)
        }
        if list != nil { cssh_curl_pointer(c, CURLOPT_HTTPHEADER, list) }
        configure(c, x)
        let rc = curl_easy_perform(c)
        if let e = x.localError { throw e }
        guard rc == CURLE_OK else { throw failure(rc, x, what, path) }
        if raw { return x }
        let status = x.status
        if status >= 300 || ((method == "PUT" || method == "POST") && S3XML(x.body).root == "Error") {
            throw s3Error(status, x, what, path)
        }
        return x
    }

    private func failure(_ rc: CURLcode, _ x: Exchange, _ what: String, _ path: String) -> RemoteError {
        if x.cancelled { return RemoteError(.cancelled, "Transfer cancelled.") }
        let buffer = String(cString: x.errorBuffer)
        let detail = buffer.isEmpty ? String(cString: curl_easy_strerror(rc)) : buffer
        return RemoteError(Curl.isConnectionError(rc) ? .connection : .failure, "Cannot \(what) \(path): \(detail)")
    }

    private func s3Error(_ status: Int, _ x: Exchange, _ what: String, _ path: String) -> RemoteError {
        let xml = S3XML(x.body)
        let code = xml.top["Code"] ?? ""
        let kind: RemoteError.Kind
        switch (code, status) {
        case ("NoSuchKey", _), ("NoSuchBucket", _), ("NoSuchUpload", _), (_, 404): kind = .noSuchFile
        case ("InvalidAccessKeyId", _), ("SignatureDoesNotMatch", _), ("ExpiredToken", _), ("InvalidToken", _):
            kind = .authentication
        case (_, 403): kind = .permissionDenied
        case ("BucketAlreadyExists", _), ("BucketAlreadyOwnedByYou", _): kind = .alreadyExists
        case (_, 501): kind = .unsupported
        case (_, 500...): kind = .connection
        default: kind = .failure
        }
        let message = xml.top["Message"].map { ": " + $0 } ?? ""
        let reason = code.isEmpty ? (status == 404 ? "No such file or directory" : "HTTP status \(status)") : code + message
        return RemoteError(kind, "Cannot \(what) \(path): \(reason)")
    }

    public func homeDirectory() -> String { "/" }

    public func canonicalPath(_ path: String) -> String { RemotePath.normalize(path, home: "/") }

    public func list(_ path: String) throws -> [RemoteFile] {
        let (bucket, key) = split(path)
        guard let bucket else {
            let xml = S3XML(try send("GET", nil, region: defaultRegion, what: "list", path: path).body, records: ["Bucket"])
            return xml.records.compactMap { r in
                r.fields["Name"].map { RemoteFile(name: $0, type: .directory, modified: r.fields["CreationDate"].flatMap(Self.isoDate)) }
            }
        }
        let prefix = key.isEmpty ? "" : key + "/"
        var files: [RemoteFile] = []
        try listObjects(bucket, prefix: prefix, delimiter: true, what: "list", path: path) { tag, fields in
            if tag == "CommonPrefixes", let p = fields["Prefix"] {
                let name = String(p.dropFirst(prefix.count).dropLast())
                if !name.isEmpty { files.append(RemoteFile(name: name, type: .directory)) }
            } else if tag == "Contents", let k = fields["Key"], k != prefix {
                files.append(RemoteFile(name: String(k.dropFirst(prefix.count)), type: .file,
                                        size: Int64(fields["Size"] ?? "") ?? 0,
                                        modified: fields["LastModified"].flatMap(Self.isoDate)))
            }
        }
        if files.isEmpty, !key.isEmpty, try fileInfo(path)?.isDirectory != true {
            throw RemoteError(.noSuchFile, "Cannot list \(path): No such file or directory")
        }
        return files
    }

    private func listObjects(_ bucket: String, prefix: String, delimiter: Bool, limit: Int? = nil, what: String, path: String,
                             _ each: (String, [String: String]) -> Void) throws {
        var token: String?
        repeat {
            var q = [("list-type", "2"), ("prefix", prefix)]
            if delimiter { q.append(("delimiter", "/")) }
            if let limit { q.append(("max-keys", String(limit))) }
            if let token { q.append(("continuation-token", token)) }
            let xml = S3XML(try send("GET", bucket, query: q, what: what, path: path).body, records: ["Contents", "CommonPrefixes"])
            for r in xml.records { each(r.tag, r.fields) }
            token = limit == nil && xml.top["IsTruncated"] == "true" ? xml.top["NextContinuationToken"] : nil
        } while token != nil
    }

    private func objects(_ bucket: String, under prefix: String, path: String) throws -> [(key: String, size: Int64)] {
        var objects: [(key: String, size: Int64)] = []
        try listObjects(bucket, prefix: prefix, delimiter: false, what: "list", path: path) { tag, fields in
            if tag == "Contents", let k = fields["Key"] { objects.append((k, Int64(fields["Size"] ?? "") ?? 0)) }
        }
        return objects
    }

    public func fileInfo(_ path: String) throws -> RemoteFile? {
        let (bucket, key) = split(path)
        guard let bucket else { return RemoteFile(name: "/", type: .directory) }
        do {
            let x = try send("HEAD", bucket, key, what: "read attributes of", path: path)
            if key.isEmpty { return RemoteFile(name: bucket, type: .directory) }
            return RemoteFile(name: RemotePath.name(path), type: .file, size: Int64(x.header("content-length") ?? "") ?? 0,
                              modified: x.header("last-modified").flatMap(Self.httpDate))
        } catch let e as RemoteError where e.kind == .noSuchFile {
            if key.isEmpty { return nil }
        }
        var found = false
        try listObjects(bucket, prefix: key + "/", delimiter: false, limit: 1, what: "read attributes of", path: path) { _, _ in found = true }
        return found ? RemoteFile(name: RemotePath.name(path), type: .directory) : nil
    }

    public func makeDirectory(_ path: String) throws {
        let (bucket, key) = split(path)
        guard let bucket else { throw RemoteError(.alreadyExists, "Cannot create directory /: it exists.") }
        if key.isEmpty {
            let body = aws && defaultRegion != "us-east-1"
                ? "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>\(defaultRegion)</LocationConstraint></CreateBucketConfiguration>"
                : ""
            try send("PUT", bucket, body: Data(body.utf8), region: defaultRegion, what: "create bucket", path: path)
            regions[bucket] = defaultRegion
        } else {
            try send("PUT", bucket, key + "/", what: "create directory", path: path)
        }
    }

    public func delete(_ path: String, isDirectory: Bool) throws {
        let (bucket, key) = split(path)
        guard let bucket else { throw RemoteError(.unsupported, "Cannot delete /.") }
        guard isDirectory else {
            try send("DELETE", bucket, key, what: "delete", path: path)
            return
        }
        try deleteObjects(bucket, try objects(bucket, under: key.isEmpty ? "" : key + "/", path: path).map(\.key), path: path)
        if key.isEmpty {
            try send("DELETE", bucket, what: "delete bucket", path: path)
            regions[bucket] = nil
        }
    }

    private func deleteObjects(_ bucket: String, _ keys: [String], path: String) throws {
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let objects = keys[start..<min(start + 1000, keys.count)].map { "<Object><Key>\(Self.escape($0))</Key></Object>" }
            let body = Data(("<Delete><Quiet>true</Quiet>" + objects.joined() + "</Delete>").utf8)
            let x = try send("POST", bucket, query: [("delete", "")],
                             headers: ["Content-MD5: \(Self.md5(body))", "Content-Type: application/xml"],
                             body: body, what: "delete", path: path)
            if let failed = S3XML(x.body, records: ["Error"]).records.first {
                throw RemoteError(failed.fields["Code"] == "AccessDenied" ? .permissionDenied : .failure,
                                  "Cannot delete /\(bucket)/\(failed.fields["Key"] ?? ""): \(failed.fields["Message"] ?? failed.fields["Code"] ?? "")")
            }
        }
    }

    public func rename(_ path: String, to newPath: String) throws {
        let (from, fromKey) = split(path)
        let (to, toKey) = split(newPath)
        guard let from, let to, !fromKey.isEmpty, !toKey.isEmpty else {
            throw RemoteError(.unsupported, "Cannot rename \(path): buckets cannot be renamed.")
        }
        guard let info = try fileInfo(path) else { throw RemoteError(.noSuchFile, "Cannot rename \(path): No such file or directory") }
        if !info.isDirectory {
            try copy(from, fromKey, size: info.size, to, toKey, path)
            try send("DELETE", from, fromKey, what: "rename", path: path)
            return
        }
        let all = try objects(from, under: fromKey + "/", path: path)
        for o in all { try copy(from, o.key, size: o.size, to, toKey + "/" + o.key.dropFirst(fromKey.count + 1), path) }
        try deleteObjects(from, all.map(\.key), path: path)
    }

    private func copy(_ from: String, _ fromKey: String, size: Int64, _ to: String, _ toKey: String, _ path: String) throws {
        let source = "x-amz-copy-source: /" + Curl.encode(from) + "/"
            + fromKey.split(separator: "/", omittingEmptySubsequences: false).map { Curl.encode($0) }.joined(separator: "/")
        guard size > copyThreshold else {
            try send("PUT", to, toKey, headers: [source], what: "rename", path: path)
            return
        }
        let type = try send("HEAD", from, fromKey, what: "rename", path: path).header("content-type") ?? Self.contentType(toKey)
        try multipart(to, toKey, contentType: type, path: path) { id in
            let chunk = max(copyPartSize, (size + 9_999) / 10_000)
            var etags: [String] = []
            for start in stride(from: Int64(0), to: size, by: Int(chunk)) {
                let x = try send("PUT", to, toKey, query: [("partNumber", String(etags.count + 1)), ("uploadId", id)],
                                 headers: [source, "x-amz-copy-source-range: bytes=\(start)-\(min(start + chunk, size) - 1)"],
                                 what: "rename", path: path)
                guard let etag = S3XML(x.body).top["ETag"] else { throw RemoteError(.failure, "Cannot rename \(path): a part has no ETag.") }
                etags.append(etag)
            }
            return etags
        }
    }

    private func multipart(_ bucket: String, _ key: String, contentType: String, path: String,
                           _ parts: (String) throws -> [String]) throws {
        let started = try send("POST", bucket, key, query: [("uploads", "")], headers: ["Content-Type: \(contentType)"],
                               what: "upload", path: path)
        guard let id = S3XML(started.body).top["UploadId"] else {
            throw RemoteError(.failure, "Cannot upload \(path): the server did not start a multipart upload.")
        }
        do {
            let list = try parts(id).enumerated().map { "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\(Self.escape($0.element))</ETag></Part>" }
            let body = Data(("<CompleteMultipartUpload>" + list.joined() + "</CompleteMultipartUpload>").utf8)
            try send("POST", bucket, key, query: [("uploadId", id)], headers: ["Content-Type: application/xml"],
                     body: body, what: "upload", path: path)
        } catch {
            _ = try? send("DELETE", bucket, key, query: [("uploadId", id)], what: "abort upload of", path: path) { _, x in
                x.cancellable = false
            }
            throw error
        }
    }

    public func setPermissions(_ path: String, _ permissions: Permissions) throws {
        throw RemoteError(.unsupported, "Cannot change permissions of \(path): S3 has no file permissions.")
    }

    public func setModified(_ path: String, _ date: Date) {}

    public func createSymlink(_ path: String, target: String) throws {
        throw RemoteError(.unsupported, "Cannot create link \(path): S3 has no links.")
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: ProgressHandler) throws {
        let (bucket, key) = split(path)
        guard let bucket, !key.isEmpty else { throw RemoteError(.failure, "Cannot download \(path): it is not a file.") }
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
            try send("GET", bucket, key, headers: offset > 0 ? ["Range: bytes=\(offset)-"] : [], what: "download", path: path) { _, x in
                x.sink = { [unowned x] data in
                    do { try out.write(contentsOf: data) } catch { x.localError = localError(local, error) }
                    return x.localError == nil
                }
                x.progress = { progress(offset + $0) }
            }
        }
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: ProgressHandler) throws {
        guard offset == 0 else { throw RemoteError(.unsupported, "Cannot resume \(path): S3 objects cannot be appended to.") }
        let (bucket, key) = split(path)
        guard let bucket, !key.isEmpty else { throw RemoteError(.failure, "Cannot upload \(path): files must be inside a bucket.") }
        let input: FileHandle
        let size: Int64
        do {
            input = try FileHandle(forReadingFrom: local)
            size = Int64(try input.seekToEnd())
            try input.seek(toOffset: 0)
        } catch { throw localError(local, error) }
        defer { try? input.close() }
        try withoutActuallyEscaping(progress) { progress in
            func part(_ c: UnsafeMutableRawPointer, _ x: Exchange, length: Int64, base: Int64) {
                cssh_curl_offset(c, CURLOPT_INFILESIZE_LARGE, curl_off_t(length))
                var left = length
                x.source = { [unowned x] buffer in
                    do {
                        let data = try input.read(upToCount: Int(min(Int64(buffer.count), left))) ?? Data()
                        left -= Int64(data.count)
                        return data.copyBytes(to: buffer)
                    } catch {
                        x.localError = localError(local, error)
                        return nil
                    }
                }
                x.progress = { progress(base + $0) }
            }
            let type = Self.contentType(key)
            if size < multipartThreshold {
                try send("PUT", bucket, key, headers: ["Content-Type: \(type)"], what: "upload", path: path) {
                    part($0, $1, length: size, base: 0)
                }
                return
            }
            try multipart(bucket, key, contentType: type, path: path) { id in
                let chunk = max(partSize, (size + 9_999) / 10_000)
                var etags: [String] = []
                var done: Int64 = 0
                while done < size {
                    let length = min(chunk, size - done)
                    let x = try send("PUT", bucket, key, query: [("partNumber", String(etags.count + 1)), ("uploadId", id)],
                                     what: "upload", path: path) { part($0, $1, length: length, base: done) }
                    guard let etag = x.header("etag") else { throw RemoteError(.failure, "Cannot upload \(path): a part has no ETag.") }
                    etags.append(etag)
                    done += length
                }
                return etags
            }
        }
    }

    public func keepalive() {}

    public func disconnect() {
        if let curl { curl_easy_cleanup(curl) }
        curl = nil
    }

    static let contentTypes: [String: String] = [
        "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "xml": "application/xml", "txt": "text/plain", "csv": "text/csv", "md": "text/markdown",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "ico": "image/vnd.microsoft.icon", "pdf": "application/pdf",
        "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar", "wasm": "application/wasm",
        "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg", "wav": "audio/wav", "woff": "font/woff",
        "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "webmanifest": "application/manifest+json",
    ]

    static func contentType(_ key: String) -> String {
        contentTypes[(RemotePath.name(key) as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func md5(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 16)
        var length: UInt32 = 0
        _ = data.withUnsafeBytes { EVP_Digest($0.baseAddress, data.count, &digest, &length, EVP_md5(), nil) }
        return Data(digest).base64EncodedString()
    }

    static func isoDate(_ s: String) -> Date? {
        let d = Array(s.utf8)
        guard d.count >= 19 else { return nil }
        func n(_ r: Range<Int>) -> Int32? {
            var v: Int32 = 0
            for c in d[r] {
                guard (48...57).contains(c) else { return nil }
                v = v * 10 + Int32(c) - 48
            }
            return v
        }
        guard let y = n(0..<4), let mo = n(5..<7), let day = n(8..<10), let h = n(11..<13), let mi = n(14..<16), let sec = n(17..<19)
        else { return nil }
        var t = tm()
        t.tm_year = y - 1900
        t.tm_mon = mo - 1
        t.tm_mday = day
        t.tm_hour = h
        t.tm_min = mi
        t.tm_sec = sec
        return Date(timeIntervalSince1970: TimeInterval(timegm(&t)))
    }

    static func httpDate(_ s: String) -> Date? {
        let p = s.split(separator: " ")
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard p.count >= 5, let day = Int32(p[1]), let mo = months.firstIndex(of: String(p[2])), let y = Int32(p[3]) else { return nil }
        let time = p[4].split(separator: ":").compactMap { Int32($0) }
        guard time.count == 3 else { return nil }
        var t = tm()
        t.tm_year = y - 1900
        t.tm_mon = Int32(mo)
        t.tm_mday = day
        t.tm_hour = time[0]
        t.tm_min = time[1]
        t.tm_sec = time[2]
        return Date(timeIntervalSince1970: TimeInterval(timegm(&t)))
    }
}

final class S3XML: NSObject, XMLParserDelegate {
    private(set) var root = ""
    private(set) var top: [String: String] = [:]
    private(set) var records: [(tag: String, fields: [String: String])] = []
    private let recordTags: Set<String>
    private var current: (tag: String, fields: [String: String])?
    private var text = ""

    init(_ data: Data, records: Set<String> = []) {
        recordTags = records
        super.init()
        guard !data.isEmpty else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if root.isEmpty { root = name }
        if recordTags.contains(name) { current = (name, [:]) }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if recordTags.contains(name), let c = current {
            records.append(c)
            current = nil
        } else if current != nil {
            current?.fields[name] = text
        } else {
            top[name] = text
        }
        text = ""
    }
}
