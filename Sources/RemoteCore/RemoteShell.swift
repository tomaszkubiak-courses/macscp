import Foundation

public struct CommandResult: Sendable, Equatable {
    public var output: String
    public var errorOutput: String
    public var exitCode: Int
    public var directory: String
}

public protocol RemoteShell: RemoteFileSystem {
    func run(_ command: String, in directory: String) async throws -> CommandResult
}

extension SSHConnection {
    func runShell(_ command: String, in directory: String) throws -> CommandResult {
        let marker = "@@MACSCP-\(UUID().uuidString.prefix(8))@@"
        let script = """
        cd \(RemotePath.shellQuote(directory)) || exit 1
        \(command)
        macscp_status=$?
        printf '\\n%s%s\\n' '\(marker)' "$PWD"
        exit $macscp_status
        """
        let r = try exec("sh -c \(RemotePath.shellQuote(script))")
        var output = String(decoding: r.stdout, as: UTF8.self)
        var newDirectory = directory
        if let range = output.range(of: "\n" + marker, options: .backwards) {
            newDirectory = output[range.upperBound...].trimmingCharacters(in: .newlines)
            output = String(output[..<range.lowerBound])
        }
        return CommandResult(output: output, errorOutput: r.stderr, exitCode: Int(r.exitCode), directory: newDirectory)
    }
}

extension SFTPFileSystem: RemoteShell {
    public func run(_ command: String, in directory: String) throws -> CommandResult { try sshConnection.runShell(command, in: directory) }
}

extension SCPFileSystem: RemoteShell {
    public func run(_ command: String, in directory: String) throws -> CommandResult { try sshConnection.runShell(command, in: directory) }
}

public struct CustomCommand: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var command: String
    public var applyToDirectories = false
    public var showOutput = true

    public init(name: String, command: String, applyToDirectories: Bool = false, showOutput: Bool = true) {
        self.name = name; self.command = command; self.applyToDirectories = applyToDirectories; self.showOutput = showOutput
    }

    public static let defaults = [
        CustomCommand(name: "Execute", command: "./\"!\""),
        CustomCommand(name: "Touch", command: "touch \"!\"", applyToDirectories: true, showOutput: false),
        CustomCommand(name: "Tar/GZip", command: "tar -czvf \"!?Archive name:?archive.tgz!\" !&", applyToDirectories: true),
        CustomCommand(name: "Untar/GUnzip", command: "tar -xvzf \"!\""),
        CustomCommand(name: "Grep", command: "grep -n \"!?Pattern:?!\" !&"),
        CustomCommand(name: "Disk Usage", command: "du -sh !&", applyToDirectories: true),
    ]

    public struct Context: Sendable {
        public var directory: String
        public var host: String
        public var user: String
        public var port: Int?
        public var sessionName: String
        public init(directory: String, host: String, user: String, port: Int?, sessionName: String) {
            self.directory = directory; self.host = host; self.user = user; self.port = port; self.sessionName = sessionName
        }
    }

    enum Token: Equatable { case text(String), file, files, prompt(String, String), directory, host, user, port, session }

    static func tokens(_ command: String) -> [Token] {
        var result: [Token] = []
        var text = ""
        let c = Array(command)
        var i = 0
        func flush() {
            if !text.isEmpty { result.append(.text(text)) }
            text = ""
        }
        func token(at j: Int) -> (Token, Int)? {
            guard j < c.count, c[j] == "!" else { return nil }
            let next = j + 1 < c.count ? c[j + 1] : nil
            switch next {
            case "!": return (.text("!"), j + 2)
            case "&": return (.files, j + 2)
            case "/": return (.directory, j + 2)
            case "@": return (.host, j + 2)
            case "U": return (.user, j + 2)
            case "#": return (.port, j + 2)
            case "N": return (.session, j + 2)
            case "?":
                guard let q = c[(j + 2)...].firstIndex(of: "?"), let end = c[(q + 1)...].firstIndex(of: "!") else { return (.file, j + 1) }
                return (.prompt(String(c[(j + 2)..<q]).replacingOccurrences(of: "&", with: ""), String(c[(q + 1)..<end])), end + 1)
            default: return (.file, j + 1)
            }
        }
        while i < c.count {
            if c[i] == "\"", let (t, end) = token(at: i + 1), t != .text("!"), end < c.count, c[end] == "\"" {
                flush()
                result.append(t)
                i = end + 1
            } else if let (t, end) = token(at: i) {
                if case .text(let s) = t { text += s } else {
                    flush()
                    result.append(t)
                }
                i = end
            } else {
                text.append(c[i])
                i += 1
            }
        }
        flush()
        return result
    }

    public var usesFiles: Bool { Self.tokens(command).contains { $0 == .file || $0 == .files } }
    public var runsOncePerFile: Bool { Self.tokens(command).contains(.file) && !Self.tokens(command).contains(.files) }
    public var prompts: [(prompt: String, defaultValue: String)] {
        Self.tokens(command).compactMap { if case .prompt(let p, let d) = $0 { (p, d) } else { nil } }
    }

    public func expand(file: String?, files: [String], answers: [String], context: Context) -> String {
        var answerIndex = 0
        var out = ""
        for t in Self.tokens(command) {
            switch t {
            case .text(let s): out += s
            case .file: out += RemotePath.shellQuote(file ?? files.first ?? "")
            case .files: out += files.map(RemotePath.shellQuote).joined(separator: " ")
            case .prompt:
                out += RemotePath.shellQuote(answerIndex < answers.count ? answers[answerIndex] : "")
                answerIndex += 1
            case .directory: out += context.directory.hasSuffix("/") ? context.directory : context.directory + "/"
            case .host: out += context.host
            case .user: out += context.user
            case .port: out += context.port.map(String.init) ?? ""
            case .session: out += context.sessionName
            }
        }
        return out
    }
}

extension FTPFileSystem: RemoteShell {
    public func run(_ command: String, in directory: String) throws -> CommandResult {
        let replies = try rawCommand(command)
        let failed = replies.last.map { $0.first == "4" || $0.first == "5" } ?? false
        return CommandResult(output: replies.joined(separator: "\n"), errorOutput: "", exitCode: failed ? 1 : 0, directory: directory)
    }
}
