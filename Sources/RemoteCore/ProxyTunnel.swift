import Foundation
#if canImport(Glibc)
import Glibc
#endif

enum ProxyTunnel {
    static func open(_ proxy: Proxy, password: String?, host: String, port: Int, timeout: Int) throws -> Int32 {
        let fd = try connect(proxy.host, proxy.port, timeout)
        do {
            var tv = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            switch proxy.kind {
            case .socks5: try socks5(fd, proxy, password, host, port)
            case .http: try httpConnect(fd, proxy, password, host, port)
            }
            var none = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func failure(_ proxy: Proxy, _ why: String) -> RemoteError {
        RemoteError(.connection, "Proxy \(proxy.host):\(proxy.port): \(why)")
    }

    private static func connect(_ host: String, _ port: Int, _ timeout: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw RemoteError(.connection, "Cannot resolve proxy \(host).")
        }
        defer { freeaddrinfo(list) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        var lastError = "connection refused"
        while let a = ai {
            ai = a.pointee.ai_next
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var rc = Foundation.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
            if rc != 0 && errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, Int32(timeout * 1000)) == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    rc = err == 0 ? 0 : -1
                    errno = err
                } else {
                    errno = ETIMEDOUT
                }
            }
            if rc == 0 {
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            lastError = String(cString: strerror(errno))
            close(fd)
        }
        throw RemoteError(.connection, "Cannot connect to proxy \(host):\(port): \(lastError)")
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8], _ proxy: Proxy) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Foundation.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            guard n > 0 else { throw failure(proxy, "connection closed") }
            sent += n
        }
    }

    private static func read(_ fd: Int32, _ count: Int, _ proxy: Proxy) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            guard n > 0 else { throw failure(proxy, n == 0 ? "connection closed" : "no answer") }
            got += n
        }
        return buf
    }

    private static func socks5(_ fd: Int32, _ proxy: Proxy, _ password: String?, _ host: String, _ port: Int) throws {
        let withLogin = !proxy.user.isEmpty
        try send(fd, withLogin ? [5, 2, 0, 2] : [5, 1, 0], proxy)
        let method = try read(fd, 2, proxy)
        guard method[0] == 5, method[1] != 0xFF else { throw failure(proxy, "no acceptable login method") }
        if method[1] == 2 {
            let u = Array(proxy.user.utf8.prefix(255)), pw = Array((password ?? "").utf8.prefix(255))
            try send(fd, [1, UInt8(u.count)] + u + [UInt8(pw.count)] + pw, proxy)
            guard try read(fd, 2, proxy)[1] == 0 else {
                throw RemoteError(.authentication, "Proxy \(proxy.host):\(proxy.port) rejected the user name or password.")
            }
        }
        let name = Array(host.utf8.prefix(255))
        try send(fd, [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)], proxy)
        let reply = try read(fd, 4, proxy)
        guard reply[1] == 0 else { throw failure(proxy, "SOCKS error \(reply[1]) connecting to \(host):\(port)") }
        let rest: Int
        switch reply[3] {
        case 1: rest = 4
        case 4: rest = 16
        default: rest = Int(try read(fd, 1, proxy)[0])
        }
        _ = try read(fd, rest + 2, proxy)
    }

    private static func httpConnect(_ fd: Int32, _ proxy: Proxy, _ password: String?, _ host: String, _ port: Int) throws {
        let target = (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if !proxy.user.isEmpty {
            request += "Proxy-Authorization: Basic \(Data("\(proxy.user):\(password ?? "")".utf8).base64EncodedString())\r\n"
        }
        try send(fd, Array((request + "\r\n").utf8), proxy)
        var head: [UInt8] = []
        while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
            head += try read(fd, 1, proxy)
            guard head.count < 16384 else { throw failure(proxy, "answer too long") }
        }
        let status = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
        let code = status.split(separator: " ").dropFirst().first
        if code == "407" { throw RemoteError(.authentication, "Proxy \(proxy.host):\(proxy.port) needs a user name and password.") }
        guard code == "200" else { throw failure(proxy, status) }
    }
}
