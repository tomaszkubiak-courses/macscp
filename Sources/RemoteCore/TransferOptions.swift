// Port of the v1 subset of TCopyParamType from WinSCP (core/CopyParam.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.
import Foundation

public struct TransferOptions: Sendable, Equatable, Codable {
    public enum ResumeSupport: String, Sendable, Codable { case on, smart, off }
    public enum Mode: String, Sendable, Codable, CaseIterable { case binary, text, automatic }

    public static let defaultTextMask = "*.*html; *.htm; *.txt; *.php; *.php3; *.cgi; *.c; *.cpp; *.h; *.pas; *.bas; *.tex; *.pl; *.js; .htaccess; *.xtml; *.css; *.cfg; *.ini; *.sh; *.xml"

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

    public var mode = Mode.binary
    public var textMask = TransferOptions.defaultTextMask
    public var remoteCRLF = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TransferOptions()
        preserveTime = try c.decodeIfPresent(Bool.self, forKey: .preserveTime) ?? d.preserveTime
        setPermissions = try c.decodeIfPresent(Bool.self, forKey: .setPermissions) ?? d.setPermissions
        permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions) ?? d.permissions
        addXToDirectories = try c.decodeIfPresent(Bool.self, forKey: .addXToDirectories) ?? d.addXToDirectories
        ignorePermissionErrors = try c.decodeIfPresent(Bool.self, forKey: .ignorePermissionErrors) ?? d.ignorePermissionErrors
        resumeSupport = try c.decodeIfPresent(ResumeSupport.self, forKey: .resumeSupport) ?? d.resumeSupport
        resumeThreshold = try c.decodeIfPresent(Int64.self, forKey: .resumeThreshold) ?? d.resumeThreshold
        includeMask = try c.decodeIfPresent(String.self, forKey: .includeMask) ?? d.includeMask
        excludeHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .excludeHiddenFiles) ?? d.excludeHiddenFiles
        newerOnly = try c.decodeIfPresent(Bool.self, forKey: .newerOnly) ?? d.newerOnly
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        textMask = try c.decodeIfPresent(String.self, forKey: .textMask) ?? d.textMask
        remoteCRLF = try c.decodeIfPresent(Bool.self, forKey: .remoteCRLF) ?? d.remoteCRLF
    }

    public func isText(_ name: String) -> Bool {
        switch mode {
        case .binary: false
        case .text: true
        case .automatic: (try? FileMask(textMask).matches(path: name, isDirectory: false)) ?? false
        }
    }

    public static func convertLineEndings(_ data: Data, crlf: Bool) -> Data {
        var out = Data(capacity: data.count + data.count / 32)
        var previousCR = false
        for b in data {
            if b == 13 {
                out.append(contentsOf: crlf ? [13, 10] : [10])
                previousCR = true
                continue
            }
            if b == 10 {
                if !previousCR { out.append(contentsOf: crlf ? [13, 10] : [10]) }
            } else {
                out.append(b)
            }
            previousCR = false
        }
        return out
    }

    public static let partialSuffix = ".filepart"

    public func allowsResume(size: Int64, fileName: String) -> Bool {
        if isText(fileName) { return false }
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
