import CSSH
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 7 else { die("usage: sftp-bench host port user identity remote local [inflight]") }
let (host, port, user, identity, remote, local) = (args[1], Int32(args[2])!, args[3], args[4], args[5], args[6])
let inflight = args.count > 7 ? Int(args[7])! : 16
let cipher = args.count > 8 ? args[8] : nil

guard let ssh = ssh_new() else { die("ssh_new") }
var p = port
ssh_options_set(ssh, SSH_OPTIONS_HOST, host)
ssh_options_set(ssh, SSH_OPTIONS_PORT, &p)
ssh_options_set(ssh, SSH_OPTIONS_USER, user)
ssh_options_set(ssh, SSH_OPTIONS_IDENTITY, identity)
if let cipher {
    ssh_options_set(ssh, SSH_OPTIONS_CIPHERS_C_S, cipher)
    ssh_options_set(ssh, SSH_OPTIONS_CIPHERS_S_C, cipher)
}

guard ssh_connect(ssh) == SSH_OK else { die(String(cString: ssh_get_error(UnsafeMutableRawPointer(ssh)))) }
guard ssh_userauth_publickey_auto(ssh, nil, nil) == SSH_AUTH_SUCCESS.rawValue else { die("auth failed") }

guard let sftp = sftp_new(ssh), sftp_init(sftp) == SSH_OK else { die("sftp init") }
guard let limits = sftp_limits(sftp) else { die("sftp_limits") }
let chunk = Int(limits.pointee.max_read_length)
sftp_limits_free(limits)

guard let file = sftp_open(sftp, remote, O_RDONLY, 0) else { die("open \(remote)") }
guard let attrs = sftp_fstat(file) else { die("fstat") }
let size = Int(attrs.pointee.size)
sftp_attributes_free(attrs)
guard let out = fopen(local, "w") else { die("open \(local)") }

let start = Date()
var requested = 0, received = 0
var queue: [sftp_aio?] = []
var buf = [UInt8](repeating: 0, count: chunk)
@MainActor func request() {
    var aio: sftp_aio?
    let n = sftp_aio_begin_read(file, min(chunk, size - requested), &aio)
    guard n > 0 else { die("begin_read") }
    requested += n
    queue.append(aio)
}
while requested < size, queue.count < inflight { request() }
while !queue.isEmpty {
    var aio = queue.removeFirst()
    let n = sftp_aio_wait_read(&aio, &buf, chunk)
    guard n > 0 else { die("wait_read \(n)") }

    received += n
    fwrite(buf, 1, n, out)
    if requested < size { request() }
}
fclose(out)
let secs = Date().timeIntervalSince(start)
guard received == size else { die("short download: \(received)/\(size)") }
print(String(format: "libssh: %d MiB in %.2f s = %.1f MiB/s (cipher %@, chunk %d, inflight %d)",
             size >> 20, secs, Double(size) / secs / 1_048_576, String(cString: ssh_get_cipher_in(ssh)), chunk, inflight))

sftp_close(file)
sftp_free(sftp)
ssh_disconnect(ssh)
ssh_free(ssh)
