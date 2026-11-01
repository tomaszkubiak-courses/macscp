// Port of the v1 subset of TCopyParamType from WinSCP (core/CopyParam.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.
import Foundation

public struct TransferOptions: Sendable, Equatable, Codable {
    public enum ResumeSupport: String, Sendable, Codable { case on, smart, off }

    public var preserveTime = true

    public var setPermissions = false
    public var permissions = Permissions.fileDefault

    public var addXToDirectories = true
    public var ignorePermissionErrors = false

    public var resumeSupport = ResumeSupport.smart
    public var resumeThreshold: Int64 = 100 * 1024

    public var includeMask = ""
    public var excludeHiddenFiles = false

    public var newerOnly = false

    public init() {}

    public static let partialSuffix = ".filepart"

    public func allowsResume(size: Int64, fileName: String) -> Bool {
        if fileName.utf8.count + Self.partialSuffix.utf8.count > 255 { return false }
        switch resumeSupport {
        case .on: return true
        case .off: return false
        case .smart: return size >= resumeThreshold
        }
    }

    public func allowsTransfer(path: String, isDirectory: Bool, isHidden: Bool, size: Int64, modified: Date?) throws -> Bool {
        if isHidden && excludeHiddenFiles { return false }
        if includeMask.isEmpty { return true }
        return try FileMask(includeMask).matches(path: path, isDirectory: isDirectory, size: size, modified: modified)
    }

    public func uploadPermissions(isDirectory: Bool) -> Permissions? {
        guard setPermissions else { return nil }
        return isDirectory && addXToDirectories ? permissions.addingExecuteWhereReadable : permissions
    }
}

extension Permissions: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let p = Permissions(octal: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad mode \(s)"))
        }
        self = p
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(octal)
    }
}
