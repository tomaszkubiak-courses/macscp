import Foundation

public enum FileType: Sendable, Equatable {
    case file, directory, symlink, other
}

public struct RemoteFile: Sendable, Equatable {
    public var name: String
    public var type: FileType
    public var size: Int64

    public var modified: Date?
    public var permissions: Permissions
    public var owner: String
    public var group: String

    public var linkTarget: String?

    public var targetType: FileType?

    public init(name: String, type: FileType, size: Int64 = 0, modified: Date? = nil,
                permissions: Permissions = Permissions(0), owner: String = "", group: String = "",
                linkTarget: String? = nil, targetType: FileType? = nil) {
        self.name = name; self.type = type; self.size = size; self.modified = modified
        self.permissions = permissions; self.owner = owner; self.group = group
        self.linkTarget = linkTarget; self.targetType = targetType
    }

    public var isDirectory: Bool { type == .directory || (type == .symlink && targetType == .directory) }
    public var isHidden: Bool { name.hasPrefix(".") }
}

public struct Permissions: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var mode: UInt16

    public init(_ mode: UInt16) { self.mode = mode & 0o7777 }

    public static let fileDefault = Permissions(0o644)
    public static let directoryDefault = Permissions(0o755)

    public init?(text: some StringProtocol) {
        let c = Array(text)
        guard c.count == 9 else { return nil }
        var m: UInt16 = 0
        for (i, bit) in [UInt16](arrayLiteral: 0o400, 0o200, 0o100, 0o40, 0o20, 0o10, 0o4, 0o2, 0o1).enumerated() {
            let ch = c[i]
            switch i % 3 {
            case 0: if ch == "r" { m |= bit }
            case 1: if ch == "w" { m |= bit }
            default:
                let special: UInt16 = i == 2 ? 0o4000 : i == 5 ? 0o2000 : 0o1000
                switch ch {
                case "x": m |= bit
                case "s", "t": m |= bit | special
                case "S", "T": m |= special
                default: break
                }
            }
        }
        mode = m
    }

    public init?(octal: String) {
        guard let v = UInt16(octal, radix: 8), v <= 0o7777 else { return nil }
        mode = v
    }

    public var octal: String { String(mode, radix: 8) }

    public var text: String {
        var s = ""
        for (i, bit) in [UInt16](arrayLiteral: 0o400, 0o200, 0o100, 0o40, 0o20, 0o10, 0o4, 0o2, 0o1).enumerated() {
            let set = mode & bit != 0
            switch i % 3 {
            case 0: s += set ? "r" : "-"
            case 1: s += set ? "w" : "-"
            default:
                let special: UInt16 = i == 2 ? 0o4000 : i == 5 ? 0o2000 : 0o1000
                let (on, off): (Character, Character) = i == 8 ? ("t", "T") : ("s", "S")
                s.append(mode & special != 0 ? (set ? on : off) : (set ? "x" : "-"))
            }
        }
        return s
    }

    public var description: String { text }

    public var addingExecuteWhereReadable: Permissions {
        var m = mode
        if m & 0o400 != 0 { m |= 0o100 }
        if m & 0o40 != 0 { m |= 0o10 }
        if m & 0o4 != 0 { m |= 0o1 }
        return Permissions(m)
    }
}
