// Port of TRemoteFile::SetListingStr from WinSCP (core/RemoteFiles.cpp).
// Copyright (C) Martin Prikryl. Licensed under GPL-3; see LICENSE.
import Foundation

public enum ListingParser {
    public struct Failure: Error, CustomStringConvertible {
        public let line: String
        public var description: String { "Unexpected directory listing line: \(line)" }
    }

    public static func parse(_ output: String, now: Date = Date()) throws -> [RemoteFile] {
        try output.split(whereSeparator: \.isNewline).compactMap { raw -> RemoteFile? in
            let line = String(raw)
            if line.isEmpty || line.hasPrefix("total ") { return nil }
            let file = try parseLine(line, now: now)
            return file.name == "." || file.name == ".." ? nil : file
        }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func parseLine(_ value: String, now: Date = Date()) throws -> RemoteFile {
        var line = Substring(value.replacingOccurrences(of: "\t", with: " "))
        let fail = Failure(line: value)

        func getNCol() throws -> Substring {
            guard !line.isEmpty else { throw fail }
            if let sp = line.firstIndex(of: " ") {
                let col = line[..<sp]
                line = line[line.index(after: sp)...]
                return col
            }
            defer { line = "" }
            return line
        }

        func getCol() throws -> Substring {
            let col = try getNCol()
            line = line.drop(while: { $0 == " " })
            return col
        }

        guard let typeChar = line.first else { throw fail }
        line = line.dropFirst()
        let type: FileType = switch typeChar {
        case "d": .directory
        case "l": .symlink
        case "-": .file
        default: .other
        }

        let permissions = Permissions(text: line.prefix(9)) ?? Permissions(0)
        line = line.dropFirst(9)

        if let f = line.first, "+@.".contains(f) {
            line = line.dropFirst()
        } else if line.count >= 2, line.first == " ", "+@.".contains(line[line.index(after: line.startIndex)]) {
            line = line.dropFirst(2)
        }
        line = line.drop(while: { $0 == " " })

        var col = try getCol()

        if Int(col) != nil { col = try getCol() }
        let owner = String(col)

        var group = ""
        col = try getCol()
        var size: Int64 = -1
        repeat {
            group += col
            col = try getCol()
            if group == "?" && col == "?" {
                size = 0
            } else {
                if col.last == "," { col = try getCol() }
                size = Int64(col) ?? -1
                if size < 0 { col = " " + col }
            }
        } while size < 0

        var modified: Date?
        col = try getCol()
        if col == "?" {
            _ = try getCol()
        } else {
            var day = Int(col) ?? 0
            var dayMonthFormat = false
            if day > 0 {
                dayMonthFormat = true
                col = try getCol()
            }
            func month(of c: Substring) -> Int { (months.firstIndex(of: c.lowercased()) ?? -1) + 1 }
            var monthNo = month(of: col)
            var year = 0, hour = 0, minute = 0, second = 0

            if monthNo == 0, col.count == 10, col.dropFirst(4).first == "-", col.dropFirst(7).first == "-" {
                let c = Array(col)
                year = Int(String(c[0..<4])) ?? 0
                monthNo = Int(String(c[5..<7])) ?? 0
                day = Int(String(c[8..<10])) ?? 0
                let t = Array(try getCol())
                guard t.count >= 5 else { throw fail }
                hour = Int(String(t[0..<2])) ?? 0
                minute = Int(String(t[3..<5])) ?? 0
                second = t.count >= 8 ? Int(String(t[6..<8])) ?? 0 : 0

                _ = try getNCol()
            } else {
                var fullTime = false
                if monthNo == 0 {
                    col = try getCol()
                    monthNo = month(of: col)
                    guard monthNo != 0 else { throw fail }
                    fullTime = true
                }
                if day == 0 { day = Int(try getNCol()) ?? 0 }
                guard (1...31).contains(day) else { throw fail }

                if fullTime {
                    let t = Array(try getCol())
                    guard t.count == 8 else { throw fail }
                    hour = Int(String(t[0..<2])) ?? 0
                    minute = Int(String(t[3..<5])) ?? 0
                    second = Int(String(t[6..<8])) ?? 0
                    year = Int(try getNCol()) ?? 0
                } else if !dayMonthFormat, let t = Array(line.prefix(while: { $0 != " " })) as [Character]?,
                          t.count == 8, t[2] == ":", t[5] == ":" {
                    _ = try getCol()
                    hour = Int(String(t[0..<2])) ?? 99
                    minute = Int(String(t[3..<5])) ?? 99
                    second = Int(String(t[6..<8])) ?? 99
                    guard hour <= 23, minute <= 59, second <= 60 else { throw fail }
                    year = Int(try getNCol()) ?? 0
                } else {
                    if dayMonthFormat {
                        col = try getCol()
                    } else {
                        col = Substring(line.prefix(6).trimmingCharacters(in: .whitespaces))
                        line = line.dropFirst(6)
                    }
                    if let colon = col.firstIndex(of: ":") {
                        hour = Int(col[..<colon]) ?? 99
                        minute = Int(col[col.index(after: colon)...]) ?? 99
                        guard hour <= 23, minute <= 59 else { throw fail }

                        var utc = Calendar(identifier: .gregorian)
                        utc.timeZone = TimeZone(identifier: "UTC")!
                        let today = utc.dateComponents([.year, .month, .day], from: now)
                        year = today.year!
                        if monthNo > today.month! || (monthNo == today.month! && day > today.day!) { year -= 1 }
                    } else {
                        guard let y = Int(col), y <= 10000 else { throw fail }
                        year = y
                    }
                }
            }
            var c = DateComponents()
            (c.year, c.month, c.day, c.hour, c.minute, c.second) = (year, monthNo, day, hour, minute, second)
            c.timeZone = TimeZone(identifier: "UTC")
            modified = Calendar(identifier: .gregorian).date(from: c)
            guard modified != nil else { throw fail }
        }

        var name = String(line)
        var linkTarget: String?
        if type == .symlink {
            guard let arrow = name.range(of: " -> ") else { throw fail }
            linkTarget = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }

        if name.count > 1, let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        return RemoteFile(name: name, type: type, size: size, modified: modified, permissions: permissions,
                          owner: owner, group: group, linkTarget: linkTarget)
    }
}
