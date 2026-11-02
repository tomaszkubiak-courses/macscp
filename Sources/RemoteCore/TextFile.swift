import Foundation

public struct TextFile: Sendable, Equatable {
    public enum LineEnding: String, Sendable {
        case lf = "LF", crlf = "CRLF", cr = "CR"

        var string: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    public var text: String
    public var encoding: String.Encoding
    public var bom: Bool
    public var lineEnding: LineEnding

    public var encodingName: String {
        switch encoding {
        case .utf8: bom ? "UTF-8 with BOM" : "UTF-8"
        case .windowsCP1252: "Windows Latin 1"
        default: "ISO Latin 1"
        }
    }

    public static func decode(_ data: Data) -> TextFile? {
        guard !data.prefix(8192).contains(0) else { return nil }
        var bom = false
        var body = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = true
            body = data.dropFirst(3)
        }
        let encoding: String.Encoding
        let raw: String
        if let s = String(data: body, encoding: .utf8) {
            (encoding, raw) = (.utf8, s)
        } else if let s = String(data: body, encoding: .windowsCP1252) {
            (encoding, raw) = (.windowsCP1252, s)
        } else {
            (encoding, raw) = (.isoLatin1, String(data: body, encoding: .isoLatin1) ?? "")
        }
        let ending: LineEnding = raw.contains("\r\n") ? .crlf : raw.contains("\r") ? .cr : .lf
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return TextFile(text: text, encoding: encoding, bom: bom, lineEnding: ending)
    }

    public func encode(_ text: String) -> Data? {
        let converted = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.string)
        guard let data = converted.data(using: encoding) else { return nil }
        return bom ? Data([0xEF, 0xBB, 0xBF]) + data : data
    }
}
