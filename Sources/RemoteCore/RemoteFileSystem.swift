import Foundation

public typealias ProgressHandler = @Sendable (Int64) -> Void

public protocol RemoteFileSystem: Actor {
    nonisolated var supportsResume: Bool { get }

    func homeDirectory() async throws -> String
    func canonicalPath(_ path: String) async throws -> String

    func list(_ path: String) async throws -> [RemoteFile]

    func fileInfo(_ path: String) async throws -> RemoteFile?
    func makeDirectory(_ path: String) async throws

    func delete(_ path: String, isDirectory: Bool) async throws
    func rename(_ path: String, to newPath: String) async throws
    func setPermissions(_ path: String, _ permissions: Permissions) async throws
    func setModified(_ path: String, _ date: Date) async throws
    func createSymlink(_ path: String, target: String) async throws

    func download(_ path: String, to local: URL, offset: Int64, progress: ProgressHandler) async throws

    func upload(_ local: URL, to path: String, offset: Int64, progress: ProgressHandler) async throws

    func keepalive() async
    func disconnect() async
}

func localError(_ url: URL, _ error: Error) -> RemoteError {
    RemoteError(.failure, "\(url.path): \(error.localizedDescription)")
}
