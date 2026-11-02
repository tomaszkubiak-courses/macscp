import CSSH
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public actor WebDAVFileSystem: RemoteFileSystem {
    private let executor = QueueExecutor(label: "MacSCP.WebDAV")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated var supportsResume: Bool { false }

    private let parameters: ConnectionParameters
    private let base: String
    private let tls: CertificateCheck?
    private nonisolated(unsafe) var curl: UnsafeMutableRawPointer?
    private var user = ""
    private var password = ""

    private init(_ parameters: ConnectionParameters, _ proto: FileProtocol) {
        self.parameters = parameters
        let host = parameters.host.contains(":") ? "[\(parameters.host)]" : parameters.host
        base = "\(proto == .webdav ? "https" : "http")://\(host)" + (parameters.port.map { ":\($0)" } ?? "")
        tls = proto == .webdav ? CertificateCheck(host: parameters.host, port: parameters.port ?? 443) : nil
    }

    public static func connect(_ parameters: ConnectionParameters, _ proto: FileProtocol,
                               prompter: any ConnectionPrompter) async throws -> WebDAVFileSystem {
        let fs = WebDAVFileSystem(parameters, proto)
        try await fs.start(prompter: prompter)
        return fs
    }

    deinit { if let curl { curl_easy_cleanup(curl) } }

    private func start(prompter: any ConnectionPrompter) async throws {
        guard Curl.initialized, let c = curl_easy_init() else { throw RemoteError(.connection, "Cannot initialize libcurl.") }
        curl = c
        user = parameters.user
        if !user.isEmpty {
            if let p = parameters.password {
                password = p
            } else if let p = await prompter.password(user: user, host: parameters.host) {
                password = p
            } else {
                throw RemoteError(.cancelled, "Authentication cancelled.")
            }
        }
        if let tls {
            try await tls.establish(prompter: prompter, file: parameters.trustedCertificatesPath) { try probe() }
        } else {
            try probe()
        }
    }

    private func probe() throws {
        try send("OPTIONS", "/", what: "connect to")
    }

    private func url(_ path: String, directory: Bool = false) -> String {
        let parts = RemotePath.normalize(path, home: "/").split(separator: "/").map { Curl.encode($0) }
        return base + "/" + parts.joined(separator: "/") + (directory && !parts.isEmpty ? "/" : "")
    }

    @discardableResult
    private func send(_ method: String, _ path: String, directory: Bool = false, headers: [String] = [], body: Data? = nil,
                      accept: Set<Int> = [], what: String,
                      _ configure: (UnsafeMutableRawPointer, Exchange) -> Void = { _, _ in }) throws -> Exchange {
        guard let c = curl else { throw RemoteError(.connection, "Not connected.") }
        let x = Curl.prepare(c, url(path, directory: directory), timeout: parameters.timeoutSeconds, tls: tls)
        Curl.applyProxy(c, parameters, tunnel: false)
        if !user.isEmpty {
            cssh_curl_string(c, CURLOPT_USERNAME, user)
            cssh_curl_string(c, CURLOPT_PASSWORD, password)
            cssh_curl_long(c, CURLOPT_HTTPAUTH, CSSH_AUTH_BASIC_DIGEST)
        }
        var list: UnsafeMutablePointer<curl_slist>?
        defer { curl_slist_free_all(list) }
        for h in headers { list = curl_slist_append(list, h) }
        switch method {
        case "GET": break
        case "PUT":
            cssh_curl_long(c, CURLOPT_UPLOAD, 1)
        default:
            cssh_curl_string(c, CURLOPT_CUSTOMREQUEST, method)
            if let body {
                cssh_curl_long(c, CURLOPT_POSTFIELDSIZE, body.count)
                body.withUnsafeBytes { _ = cssh_curl_pointer(c, CURLOPT_COPYPOSTFIELDS, UnsafeMutableRawPointer(mutating: $0.baseAddress!)) }
            }
        }
        if list != nil { cssh_curl_pointer(c, CURLOPT_HTTPHEADER, list) }
        configure(c, x)
        let rc = curl_easy_perform(c)
        if let e = x.localError { throw e }
        guard rc == CURLE_OK else {
            if x.cancelled { throw RemoteError(.cancelled, "Transfer cancelled.") }
            let buffer = String(cString: x.errorBuffer)
            throw RemoteError(Curl.isConnectionError(rc) ? .connection : .failure,
                              "Cannot \(what) \(path): \(buffer.isEmpty ? String(cString: curl_easy_strerror(rc)) : buffer)")
        }
        let status = x.status
        guard (200..<300).contains(status) || accept.contains(status) else {
            let kind: RemoteError.Kind = switch status {
            case 401: .authentication
            case 403: .permissionDenied
            case 404, 409: .noSuchFile
            case 405 where method == "MKCOL", 412: .alreadyExists
            case 405, 501: .unsupported
            case 500...: .connection
            default: .failure
            }
            let reason = x.replies.first { $0.hasPrefix("HTTP/") }.map { String($0.split(separator: " ", maxSplits: 1).last ?? "") }
            throw RemoteError(kind, "Cannot \(what) \(path): \(reason ?? "HTTP status \(status)")")
        }
        return x
    }

    private static let propfind = Data("""
    <?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop>\
    <D:resourcetype/><D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>
    """.utf8)

    private func properties(_ path: String, depth: Int, directory: Bool) throws -> [(path: String, file: RemoteFile)] {
        let x = try send("PROPFIND", path, directory: directory, headers: ["Depth: \(depth)", "Content-Type: application/xml"],
                         body: Self.propfind, what: depth == 0 ? "read attributes of" : "list") { c, _ in
            cssh_curl_long(c, CURLOPT_FOLLOWLOCATION, 1)
        }
        return DAVMultistatus(x.body).responses.compactMap { r in
            guard let href = r.href, let decoded = Self.path(fromHref: href) else { return nil }
            let isDir = r.collection
            let name = RemotePath.name(decoded)
            return (decoded, RemoteFile(name: name, type: isDir ? .directory : .file, size: Int64(r.length ?? "") ?? 0,
                                        modified: r.modified.flatMap(S3FileSystem.httpDate)))
        }
    }

    static func path(fromHref href: String) -> String? {
        var h = href
        if let scheme = h.range(of: "://") {
            guard let slash = h[scheme.upperBound...].firstIndex(of: "/") else { return "/" }
            h = String(h[slash...])
        }
        return h.removingPercentEncoding.map { RemotePath.normalize($0, home: "/") }
    }

    public func homeDirectory() -> String { "/" }

    public func canonicalPath(_ path: String) -> String { RemotePath.normalize(path, home: "/") }

    public func list(_ path: String) throws -> [RemoteFile] {
        let me = RemotePath.normalize(path, home: "/")
        return try properties(path, depth: 1, directory: true).filter { $0.path != me }.map(\.file)
    }

    public func fileInfo(_ path: String) throws -> RemoteFile? {
        do {
            guard var f = try properties(path, depth: 0, directory: false).first?.file else { return nil }
            f.name = RemotePath.name(RemotePath.normalize(path, home: "/"))
            return f
        } catch let e as RemoteError where e.kind == .noSuchFile {
            return nil
        }
    }

    public func makeDirectory(_ path: String) throws { try send("MKCOL", path, directory: true, what: "create directory") }

    public func delete(_ path: String, isDirectory: Bool) throws {
        try send("DELETE", path, directory: isDirectory, what: "delete")
    }

    public func rename(_ path: String, to newPath: String) throws {
        let isDir = try fileInfo(path)?.isDirectory ?? false
        try send("MOVE", path, directory: isDir, headers: ["Destination: \(url(newPath, directory: isDir))", "Overwrite: F"],
                 what: "rename")
    }

    public func setPermissions(_ path: String, _ permissions: Permissions) throws {
        throw RemoteError(.unsupported, "Cannot change permissions of \(path): WebDAV has no file permissions.")
    }

    public func setModified(_ path: String, _ date: Date) {}

    public func createSymlink(_ path: String, target: String) throws {
        throw RemoteError(.unsupported, "Cannot create link \(path): WebDAV has no links.")
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
            try send("GET", path, headers: offset > 0 ? ["Range: bytes=\(offset)-"] : [], what: "download") { _, x in
                x.sink = { [unowned x] data in
                    do { try out.write(contentsOf: data) } catch { x.localError = localError(local, error) }
                    return x.localError == nil
                }
                x.progress = { progress(offset + $0) }
            }
        }
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: ProgressHandler) throws {
        guard offset == 0 else { throw RemoteError(.unsupported, "Cannot resume \(path): WebDAV cannot append.") }
        let input: FileHandle
        let size: Int64
        do {
            input = try FileHandle(forReadingFrom: local)
            size = Int64(try input.seekToEnd())
            try input.seek(toOffset: 0)
        } catch { throw localError(local, error) }
        defer { try? input.close() }
        _ = try withoutActuallyEscaping(progress) { progress in
            try send("PUT", path, headers: ["Content-Type: \(S3FileSystem.contentType(path))"], what: "upload") { c, x in
                cssh_curl_offset(c, CURLOPT_INFILESIZE_LARGE, curl_off_t(size))
                x.source = { [unowned x] buffer in
                    do {
                        let data = try input.read(upToCount: buffer.count) ?? Data()
                        return data.copyBytes(to: buffer)
                    } catch {
                        x.localError = localError(local, error)
                        return nil
                    }
                }
                x.seek = { offset in (try? input.seek(toOffset: UInt64(offset))) != nil }
                x.progress = { progress($0) }
            }
        }
    }

    public func keepalive() {}

    public func disconnect() {
        if let curl { curl_easy_cleanup(curl) }
        curl = nil
    }
}

final class DAVMultistatus: NSObject, XMLParserDelegate {
    struct Response {
        var href: String?
        var collection = false
        var length: String?
        var modified: String?
    }

    private(set) var responses: [Response] = []
    private var current: Response?
    private var props: [String: String] = [:]
    private var collection = false
    private var status = ""
    private var text = ""

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "response": current = Response()
        case "propstat":
            props = [:]
            collection = false
            status = ""
        case "collection": collection = true
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "href" where current?.href == nil: current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "status": status = text
        case "getcontentlength", "getlastmodified": props[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "propstat" where status.contains(" 200"):
            if collection { current?.collection = true }
            if let l = props["getcontentlength"] { current?.length = l }
            if let m = props["getlastmodified"] { current?.modified = m }
        case "response":
            if let c = current { responses.append(c) }
            current = nil
        default: break
        }
        text = ""
    }
}
