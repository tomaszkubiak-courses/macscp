import CSSH
import Foundation

public struct CertificateInfo: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let subject: String
    public let issuer: String
    public let fingerprint: String
    public let problem: String
}

enum Curl {
    static let initialized: Bool = cssh_curl_global_init() == CURLE_OK
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let defaultCertificatesPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacSCP/trusted_certificates").path

    static func isConnectionError(_ rc: CURLcode) -> Bool {
        [CURLE_COULDNT_RESOLVE_HOST, CURLE_COULDNT_CONNECT, CURLE_SEND_ERROR, CURLE_RECV_ERROR, CURLE_OPERATION_TIMEDOUT,
         CURLE_GOT_NOTHING, CURLE_PARTIAL_FILE, CURLE_SSL_CONNECT_ERROR, CURLE_WEIRD_SERVER_REPLY].contains(rc)
    }

    static func encode(_ s: some StringProtocol) -> String { String(s).addingPercentEncoding(withAllowedCharacters: unreserved)! }

    static func prepare(_ c: UnsafeMutableRawPointer, _ url: String, timeout: Int, tls: CertificateCheck?) -> Exchange {
        let x = Exchange(c)
        let me = Unmanaged.passUnretained(x).toOpaque()
        curl_easy_reset(c)
        cssh_curl_string(c, CURLOPT_URL, url)
        cssh_curl_long(c, CURLOPT_NOSIGNAL, 1)
        cssh_curl_long(c, CURLOPT_TCP_KEEPALIVE, 1)
        cssh_curl_long(c, CURLOPT_CONNECTTIMEOUT, timeout)
        cssh_curl_long(c, CURLOPT_LOW_SPEED_LIMIT, 1)
        cssh_curl_long(c, CURLOPT_LOW_SPEED_TIME, 60)
        cssh_curl_pointer(c, CURLOPT_ERRORBUFFER, x.errorBuffer)
        cssh_curl_write(c, CURLOPT_HEADERFUNCTION, onReply)
        cssh_curl_pointer(c, CURLOPT_HEADERDATA, me)
        cssh_curl_write(c, CURLOPT_WRITEFUNCTION, onData)
        cssh_curl_pointer(c, CURLOPT_WRITEDATA, me)
        cssh_curl_read(c, onRead)
        cssh_curl_pointer(c, CURLOPT_READDATA, me)
        cssh_curl_xferinfo(c, onProgress)
        cssh_curl_pointer(c, CURLOPT_XFERINFODATA, me)
        cssh_curl_long(c, CURLOPT_NOPROGRESS, 0)
        if let tls {
            cssh_curl_long(c, CURLOPT_SSL_VERIFYPEER, 1)
            cssh_curl_long(c, CURLOPT_SSL_VERIFYHOST, 0)
            cssh_curl_ssl_ctx(c, configureTLS)
            cssh_curl_pointer(c, CURLOPT_SSL_CTX_DATA, Unmanaged.passUnretained(tls).toOpaque())
        }
        return x
    }
}

final class CertificateCheck: @unchecked Sendable {
    var host: String
    let port: Int
    var trusted: Set<String> = []
    var rejected: CertificateInfo?

    init(host: String, port: Int) { self.host = host; self.port = port }

    private var key: String { "\(host):\(port)" }

    func establish(prompter: any ConnectionPrompter, file: String?,
                   isolation: isolated (any Actor)? = #isolation, _ attempt: () throws -> Void) async throws {
        let path = file ?? Curl.defaultCertificatesPath
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count == 2, parts[0] == key { trusted.insert(String(parts[1])) }
            }
        }
        while true {
            do {
                return try attempt()
            } catch {
                guard let info = rejected else { throw error }
                rejected = nil
                switch await prompter.verifyCertificate(info) {
                case .reject:
                    throw RemoteError(.hostKeyRejected, "Certificate of \(info.host) was rejected.")
                case .acceptOnce:
                    trusted.insert(info.fingerprint)
                case .acceptAndSave:
                    trusted.insert(info.fingerprint)
                    try save(info.fingerprint, to: path)
                }
            }
        }
    }

    private func save(_ fingerprint: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try (old + "\(key) \(fingerprint)\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw RemoteError(.failure, "Cannot save the certificate: \(error.localizedDescription)")
        }
    }
}

final class Exchange {
    let handle: UnsafeMutableRawPointer
    var replies: [String] = []
    var body = Data()
    var sink: ((UnsafeRawBufferPointer) -> Bool)?
    var source: ((UnsafeMutableRawBufferPointer) -> Int?)?
    var progress: ((Int64) -> Void)?
    var localError: RemoteError?
    var cancelled = false
    let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(CURL_ERROR_SIZE))

    init(_ handle: UnsafeMutableRawPointer) {
        self.handle = handle
        errorBuffer.initialize(to: 0)
    }

    var status: Int { cssh_curl_info_long(handle, CURLINFO_RESPONSE_CODE) }
    var cancellable = true

    func header(_ name: String) -> String? {
        let prefix = name.lowercased() + ":"
        guard let line = replies.last(where: { $0.lowercased().hasPrefix(prefix) }) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
    deinit { errorBuffer.deallocate() }

    static func from(_ p: UnsafeMutableRawPointer?) -> Exchange { Unmanaged<Exchange>.fromOpaque(p!).takeUnretainedValue() }
}

private let onReply: curl_write_callback = { ptr, size, count, arg in
    let n = size * count
    Exchange.from(arg).replies.append(
        String(decoding: UnsafeRawBufferPointer(start: ptr, count: n), as: UTF8.self).trimmingCharacters(in: .newlines))
    return n
}

private let onData: curl_write_callback = { ptr, size, count, arg in
    let x = Exchange.from(arg)
    let buffer = UnsafeRawBufferPointer(start: ptr, count: size * count)
    if let sink = x.sink, x.status < 300 { return sink(buffer) ? size * count : 0 }
    x.body.append(contentsOf: buffer)
    return size * count
}

private let onRead: curl_read_callback = { ptr, size, count, arg in
    let x = Exchange.from(arg)
    guard let ptr, let n = x.source?(UnsafeMutableRawBufferPointer(start: ptr, count: size * count)) else {
        return Int(CURL_READFUNC_ABORT)
    }
    return n
}

private let onProgress: curl_xferinfo_callback = { arg, _, downloaded, _, uploaded in
    let x = Exchange.from(arg)
    x.progress?(Int64(max(downloaded, uploaded)))
    if x.cancellable, Task.isCancelled {
        x.cancelled = true
        return 1
    }
    return 0
}

private let configureTLS: curl_ssl_ctx_callback = { _, ctx, arg in
    SSL_CTX_set_cert_verify_callback(OpaquePointer(ctx), verifyCertificate, arg)
    return CURLE_OK
}

private let verifyCertificate: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32 = { store, arg in
    let check = Unmanaged<CertificateCheck>.fromOpaque(arg!).takeUnretainedValue()
    let chainValid = X509_verify_cert(store) == 1
    guard let cert = X509_STORE_CTX_get0_cert(store) else { return 0 }
    let hostValid = X509_check_host(cert, check.host, check.host.utf8.count, 0, nil) == 1
        || X509_check_ip_asc(cert, check.host, 0) == 1
    var digest = [UInt8](repeating: 0, count: 64)
    var length: UInt32 = 0
    X509_digest(cert, EVP_sha256(), &digest, &length)
    let fingerprint = digest.prefix(Int(length)).map { String(format: "%02X", $0) }.joined(separator: ":")
    if (chainValid && hostValid) || check.trusted.contains(fingerprint) {
        X509_STORE_CTX_set_error(store, X509_V_OK)
        return 1
    }
    func name(_ n: OpaquePointer?) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        X509_NAME_oneline(n, &buffer, Int32(buffer.count))
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
    let problem = chainValid ? "The certificate was issued for a different host name."
        : String(cString: X509_verify_cert_error_string(Int(X509_STORE_CTX_get_error(store))))
    check.rejected = CertificateInfo(host: check.host, port: check.port, subject: name(X509_get_subject_name(cert)),
                                     issuer: name(X509_get_issuer_name(cert)), fingerprint: fingerprint, problem: problem)
    return 0
}
