import CSSH
import Foundation

enum PuTTYKey {
    enum Failure: Error, Equatable { case malformed(String), needsPassphrase, wrongPassphrase, unsupported(String) }

    static func isPPK(_ text: String) -> Bool { text.hasPrefix("PuTTY-User-Key-File-") }

    static func isEncrypted(_ text: String) -> Bool { !text.contains("\nEncryption: none") }

    static func openSSH(_ text: String, passphrase: String?) throws -> String {
        var fields: [String: String] = [:]
        var blobs: [String: Data] = [:]
        var version = 0
        var algorithm = ""
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("PuTTY-User-Key-File-") {
                version = Int(key.dropFirst("PuTTY-User-Key-File-".count)) ?? 0
                algorithm = value
            } else if key == "Public-Lines" || key == "Private-Lines", let n = Int(value), i + n <= lines.count {
                guard let data = Data(base64Encoded: lines[i..<(i + n)].joined()) else { throw Failure.malformed("bad base64") }
                blobs[key] = data
                i += n
            } else {
                fields[key] = value
            }
        }
        guard version == 2 || version == 3 else { throw Failure.unsupported("PuTTY key file version \(version)") }
        guard let publicBlob = blobs["Public-Lines"], var privateBlob = blobs["Private-Lines"],
              let encryption = fields["Encryption"], let mac = fields["Private-MAC"] else { throw Failure.malformed("missing fields") }
        let comment = fields["Comment"] ?? ""

        var macKey = Data()
        if encryption == "aes256-cbc" {
            guard let passphrase, !passphrase.isEmpty else { throw Failure.needsPassphrase }
            let pass = Data(passphrase.utf8)
            let cipherKey: Data
            let iv: Data
            if version == 2 {
                cipherKey = (digest(Data([0, 0, 0, 0]) + pass, EVP_sha1()) + digest(Data([0, 0, 0, 1]) + pass, EVP_sha1())).prefix(32)
                iv = Data(count: 16)
                macKey = digest(Data("putty-private-key-file-mac-key".utf8) + pass, EVP_sha1())
            } else {
                guard let kdf = fields["Key-Derivation"], let memory = UInt32(fields["Argon2-Memory"] ?? ""),
                      let passes = UInt32(fields["Argon2-Passes"] ?? ""), let lanes = UInt32(fields["Argon2-Parallelism"] ?? ""),
                      let salt = hex(fields["Argon2-Salt"] ?? "") else { throw Failure.malformed("missing Argon2 parameters") }
                var out = [UInt8](repeating: 0, count: 80)
                let rc = pass.withUnsafeBytes { p in
                    salt.withUnsafeBytes { s in
                        cssh_argon2(kdf.uppercased(), p.baseAddress, p.count, s.baseAddress, s.count, memory, passes, lanes, &out, 80)
                    }
                }
                guard rc == 0 else { throw Failure.unsupported("\(kdf) needs OpenSSL 3.2 or later") }
                cipherKey = Data(out[0..<32])
                iv = Data(out[32..<48])
                macKey = Data(out[48..<80])
            }
            privateBlob = try decrypt(privateBlob, key: cipherKey, iv: iv)
        } else if encryption != "none" {
            throw Failure.unsupported("encryption \(encryption)")
        } else if version == 2 {
            macKey = digest(Data("putty-private-key-file-mac-key".utf8), EVP_sha1())
        }

        var macData = Data()
        for part in [Data(algorithm.utf8), Data(encryption.utf8), Data(comment.utf8), publicBlob, privateBlob] {
            macData.append(sshString(part))
        }
        let computed = hmac(macData, key: macKey, version == 2 ? EVP_sha1() : EVP_sha256())
        guard computed.map({ String(format: "%02x", $0) }).joined() == mac.lowercased() else {
            throw encryption == "none" ? Failure.malformed("MAC mismatch") : Failure.wrongPassphrase
        }

        var pub = Reader(publicBlob)
        var priv = Reader(privateBlob)
        guard try pub.string() == Data(algorithm.utf8) else { throw Failure.malformed("algorithm mismatch") }
        var keyFields = sshString(Data(algorithm.utf8))
        switch algorithm {
        case "ssh-ed25519":
            let pk = try pub.string()
            let seed = try priv.string()
            keyFields += sshString(pk) + sshString(seed + pk)
        case "ssh-rsa":
            let e = try pub.string(), n = try pub.string()
            let d = try priv.string(), p = try priv.string(), q = try priv.string(), iqmp = try priv.string()
            for f in [n, e, d, iqmp, p, q] { keyFields += sshString(f) }
        case let a where a.hasPrefix("ecdsa-sha2-"):
            let curve = try pub.string(), point = try pub.string()
            let d = try priv.string()
            keyFields += sshString(curve) + sshString(point) + sshString(d)
        default:
            throw Failure.unsupported("key type \(algorithm)")
        }

        let check = UInt32.random(in: 0...UInt32.max)
        var section = uint32(check) + uint32(check) + keyFields + sshString(Data(comment.utf8))
        var pad: UInt8 = 1
        while section.count % 8 != 0 {
            section.append(pad)
            pad += 1
        }
        var container = Data("openssh-key-v1".utf8) + Data([0])
        container += sshString(Data("none".utf8)) + sshString(Data("none".utf8)) + sshString(Data()) + uint32(1)
        container += sshString(publicBlob) + sshString(section)
        let b64 = container.base64EncodedString()
        let wrapped = stride(from: 0, to: b64.count, by: 70).map { start -> String in
            let s = b64.index(b64.startIndex, offsetBy: start)
            return String(b64[s..<(b64.index(s, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + wrapped.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    static func publicKey(ofOpenSSH pem: String) -> String? {
        var key: ssh_key?
        guard ssh_pki_import_privkey_base64(pem, nil, nil, nil, &key) == SSH_OK, let key else { return nil }
        defer { ssh_key_free(key) }
        var b64: UnsafeMutablePointer<CChar>?
        guard ssh_pki_export_pubkey_base64(key, &b64) == SSH_OK, let b64 else { return nil }
        defer { ssh_string_free_char(b64) }
        return String(cString: b64)
    }

    struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = Data(data) }

        mutating func string() throws -> Data {
            guard offset + 4 <= data.count else { throw Failure.malformed("truncated key") }
            let n = data[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard n >= 0, offset + n <= data.count else { throw Failure.malformed("truncated key") }
            defer { offset += n }
            return data[offset..<(offset + n)]
        }
    }

    static func uint32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }

    static func sshString(_ d: Data) -> Data { uint32(UInt32(d.count)) + d }

    static func hex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    static func digest(_ data: Data, _ md: OpaquePointer?) -> Data {
        var out = [UInt8](repeating: 0, count: 64)
        var length: UInt32 = 0
        _ = data.withUnsafeBytes { EVP_Digest($0.baseAddress, data.count, &out, &length, md, nil) }
        return Data(out.prefix(Int(length)))
    }

    static func hmac(_ data: Data, key: Data, _ md: OpaquePointer?) -> Data {
        var out = [UInt8](repeating: 0, count: 64)
        var length: UInt32 = 0
        _ = key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                HMAC(md, k.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(key.count), d.bindMemory(to: UInt8.self).baseAddress,
                     data.count, &out, &length)
            }
        }
        return Data(out.prefix(Int(length)))
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard data.count % 16 == 0, let ctx = EVP_CIPHER_CTX_new() else { throw Failure.malformed("bad private blob") }
        defer { EVP_CIPHER_CTX_free(ctx) }
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var n: Int32 = 0
        var total: Int32 = 0
        let ok = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                data.withUnsafeBytes { d in
                    EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), nil, k.bindMemory(to: UInt8.self).baseAddress,
                                       v.bindMemory(to: UInt8.self).baseAddress) == 1
                        && EVP_CIPHER_CTX_set_padding(ctx, 0) == 1
                        && EVP_DecryptUpdate(ctx, &out, &n, d.bindMemory(to: UInt8.self).baseAddress, Int32(data.count)) == 1
                }
            }
        }
        guard ok else { throw Failure.malformed("cannot decrypt") }
        total = n
        out.withUnsafeMutableBufferPointer { _ = EVP_DecryptFinal_ex(ctx, $0.baseAddress! + Int(total), &n) }
        return Data(out.prefix(Int(total + n)))
    }
}
