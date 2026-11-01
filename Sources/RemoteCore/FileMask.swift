// Port of TFileMasks from WinSCP (core/FileMasks.cpp, core/Common.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.
import Foundation

public struct FileMask: Sendable, Equatable {
    public struct ParseError: Error, CustomStringConvertible {
        public let fragment: String
        public var description: String { "Invalid file mask: \(fragment)" }
    }

    enum Kind: Sendable, Equatable { case any, noExt, regular(String) }
    enum Boundary: Sendable, Equatable { case none, open, close }

    struct Mask: Sendable, Equatable {
        var fileName: Kind = .any
        var directory: Kind = .any
        var highSize: Boundary = .none, lowSize: Boundary = .none
        var highSizeValue: Int64 = 0, lowSizeValue: Int64 = 0
        var highTime: Boundary = .none, lowTime: Boundary = .none
        var highTimeValue = Date.distantPast, lowTimeValue = Date.distantPast
    }

    public let string: String

    var fileInclude: [Mask] = [], fileExclude: [Mask] = []
    var dirInclude: [Mask] = [], dirExclude: [Mask] = []

    public static let any = try! FileMask("")

    public init(_ string: String, now: Date = Date()) throws {
        self.string = string
        var from = string.startIndex
        var include = true
        while from < string.endIndex {
            let (part, delimiter, next) = Self.copyToChars(string, from: from, chars: ";,|")
            from = next
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { try addMask(trimmed, include: include, now: now) }
            if delimiter == "|" {
                guard include else { throw ParseError(fragment: String(string[string.index(before: from)...])) }
                include = false
            }
        }
    }

    public var isEmpty: Bool { fileInclude.isEmpty && fileExclude.isEmpty && dirInclude.isEmpty && dirExclude.isEmpty }

    public func matches(path: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) -> Bool {
        let trimmed = RemotePath.trimTrailingSlash(path)
        let name = RemotePath.name(trimmed)
        let dir: String
        if let i = trimmed.lastIndex(of: "/") {
            dir = i == trimmed.startIndex ? "/" : String(trimmed[..<i])
        } else {
            dir = ""
        }
        let includes = isDirectory ? dirInclude : fileInclude
        let excludes = isDirectory ? dirExclude : fileExclude
        let params = size.map { ($0, modified ?? .distantPast) }
        let included = includes.isEmpty
            || Self.matches(name, isDirectory, dir, params, includes, recurse: true)
        return included && !Self.matches(name, isDirectory, dir, params, excludes, recurse: false)
    }

    private static func matches(_ name: String, _ isDirectory: Bool, _ path: String, _ params: (Int64, Date)?,
                                _ masks: [Mask], recurse: Bool) -> Bool {
        for m in masks where kindMatches(m.directory, path) && kindMatches(m.fileName, name) {
            if !boundary(m.highSize, params.map { $0.0 }, m.highSizeValue, high: true) { continue }
            if !boundary(m.lowSize, params.map { $0.0 }, m.lowSizeValue, high: false) { continue }
            if !boundary(m.highTime, params.map { $0.1 }, m.highTimeValue, high: true) { continue }
            if !boundary(m.lowTime, params.map { $0.1 }, m.lowTimeValue, high: false) { continue }
            return true
        }

        if isDirectory, recurse, !path.isEmpty, path != "/" {
            return matches(RemotePath.name(path), true, RemotePath.parent(path), params, masks, recurse: true)
        }
        return false
    }

    private static func boundary<T: Comparable>(_ b: Boundary, _ value: T?, _ limit: T, high: Bool) -> Bool {
        switch b {
        case .none: return true
        case .open: guard let value else { return false }; return high ? value < limit : value > limit
        case .close: guard let value else { return false }; return high ? value <= limit : value >= limit
        }
    }

    private static func kindMatches(_ kind: Kind, _ s: String) -> Bool {
        switch kind {
        case .any: return true
        case .noExt: return !s.contains(".") || wildcard(Array("*.".lowercased()), Array(s.lowercased()))
        case .regular(let pattern): return wildcard(Array(pattern.lowercased()), Array(s.lowercased()))
        }
    }

    static func wildcard(_ p: [Character], _ s: [Character]) -> Bool {
        var memo = [Int: Bool]()
        func go(_ pi: Int, _ si: Int) -> Bool {
            let key = pi * (s.count + 1) + si
            if let r = memo[key] { return r }
            let r: Bool
            if pi == p.count {
                r = si == s.count
            } else if p[pi] == "*" {
                r = go(pi + 1, si) || (si < s.count && go(pi, si + 1))
            } else if si == s.count {
                r = false
            } else if p[pi] == "?" {
                r = go(pi + 1, si + 1)
            } else if p[pi] == "[", let close = p[(pi + 1)...].firstIndex(of: "]") {
                var set = Array(p[(pi + 1)..<close])
                let negate = set.first == "!"
                if negate { set.removeFirst() }
                var hit = false, i = 0
                while i < set.count {
                    if i + 2 < set.count, set[i + 1] == "-" {
                        if set[i] <= s[si] && s[si] <= set[i + 2] { hit = true }
                        i += 3
                    } else {
                        if set[i] == s[si] { hit = true }
                        i += 1
                    }
                }
                r = hit != negate && go(close + 1, si + 1)
            } else {
                r = p[pi] == s[si] && go(pi + 1, si + 1)
            }
            memo[key] = r
            return r
        }
        return go(0, 0)
    }

    private mutating func addMask(_ maskStr: String, include: Bool, now: Date) throws {
        var mask = Mask()
        var isDirectory = false
        var from = maskStr.startIndex
        var partDelimiter: Character? = nil
        while from < maskStr.endIndex {
            let (raw, nextDelimiter, next) = Self.copyToChars(maskStr, from: from, chars: "<>")
            from = next
            defer { partDelimiter = nextDelimiter }
            var part = raw.trimmingCharacters(in: .whitespaces)
            if let d = partDelimiter {
                let low = d == ">"
                var b = Boundary.open
                if part.hasPrefix("=") { b = .close; part.removeFirst() }
                if Int64(part) == nil, let t = Self.parseDateTime(part) ?? Self.parseRelative(part, now: now) {
                    guard (low ? mask.lowTime : mask.highTime) == .none, !isDirectory else { throw ParseError(fragment: maskStr) }
                    if low { (mask.lowTime, mask.lowTimeValue) = (b, t) } else { (mask.highTime, mask.highTimeValue) = (b, t) }
                } else {
                    guard (low ? mask.lowSize : mask.highSize) == .none, !isDirectory,
                          let size = Self.parseSize(part) else { throw ParseError(fragment: maskStr) }
                    if low { (mask.lowSize, mask.lowSizeValue) = (b, size) } else { (mask.highSize, mask.highSizeValue) = (b, size) }
                }
            } else if !part.isEmpty {
                isDirectory = part.hasSuffix("/")
                while part.count > 1, part.hasSuffix("/") { part.removeLast() }
                if let slash = part.lastIndex(of: "/") {
                    let dir = slash == part.startIndex ? "/" : String(part[..<slash])
                    mask.directory = .regular(dir)
                    mask.fileName = Self.fileNameKind(String(part[part.index(after: slash)...]))
                } else {
                    mask.fileName = Self.fileNameKind(part)
                }
            }
        }
        switch (isDirectory, include) {
        case (false, true): fileInclude.append(mask)
        case (false, false): fileExclude.append(mask)
        case (true, true): dirInclude.append(mask)
        case (true, false): dirExclude.append(mask)
        }
    }

    private static func fileNameKind(_ s: String) -> Kind {
        if s.isEmpty || s == "*" || s == "*.*" { return .any }
        return s == "*." ? .noExt : .regular(s)
    }

    static func copyToChars(_ s: String, from: String.Index, chars: String)
        -> (String, Character?, String.Index) {
        var result = ""
        var i = from
        while i < s.endIndex {
            let c = s[i]
            if chars.contains(c) {
                let n = s.index(after: i)
                if n < s.endIndex, s[n] == c {
                    result.append(c)
                    i = s.index(after: n)
                    continue
                }
                return (result, c, n)
            }
            result.append(c)
            i = s.index(after: i)
        }
        return (result, nil, s.endIndex)
    }

    static func parseSize(_ s: String) -> Int64? {
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, var n = Int64(digits) else { return nil }
        let unit = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).uppercased()
        switch unit {
        case "": break
        case "K": n *= 1024
        case "M": n *= 1024 * 1024
        case "G": n *= 1024 * 1024 * 1024
        default: return nil
        }
        return n
    }

    static func parseDateTime(_ s: String) -> Date? {
        let parts = s.split(separator: " ")
        guard (1...2).contains(parts.count) else { return nil }
        let d = parts[0].split(separator: "-").compactMap { Int($0) }
        guard d.count == 3 else { return nil }
        var c = DateComponents(year: d[0], month: d[1], day: d[2])
        if parts.count == 2 {
            let t = parts[1].split(separator: ":").compactMap { Int($0) }
            guard (2...3).contains(t.count) else { return nil }
            (c.hour, c.minute, c.second) = (t[0], t[1], t.count == 3 ? t[2] : 0)
        }
        guard c.isValidDate(in: Calendar.current) else { return nil }
        return Calendar.current.date(from: c)
    }

    static func parseRelative(_ str: String, now: Date) -> Date? {
        var s = str.trimmingCharacters(in: .whitespaces)
        if s.caseInsensitiveCompare("today") == .orderedSame { s = "0DS" }
        if s.caseInsensitiveCompare("yesterday") == .orderedSame { s = "1DS" }
        let digits = s.prefix(while: \.isNumber)
        guard let n = Int(digits) else { return nil }
        var unit = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).uppercased()
        let start = unit.count == 2 && unit.hasSuffix("S")
        if start { unit.removeLast() }
        let cal = Calendar.current
        let (component, startComponents): (Calendar.Component, Set<Calendar.Component>) = switch unit {
        case "S": (.second, [.year, .month, .day, .hour, .minute, .second])
        case "N": (.minute, [.year, .month, .day, .hour, .minute])
        case "H": (.hour, [.year, .month, .day, .hour])
        case "D": (.day, [.year, .month, .day])
        case "Y": (.year, [.year])
        default: (.nanosecond, [])
        }
        guard !startComponents.isEmpty, var date = cal.date(byAdding: component, value: -n, to: now) else { return nil }
        if start { date = cal.date(from: cal.dateComponents(startComponents, from: date))! }
        return date
    }
}
