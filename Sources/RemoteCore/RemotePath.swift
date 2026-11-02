public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        if name.hasPrefix("/") { return name }
        if dir.isEmpty { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let trimmed = trimTrailingSlash(path)
        guard let i = trimmed.lastIndex(of: "/") else { return "." }
        return i == trimmed.startIndex ? "/" : String(trimmed[..<i])
    }

    public static func name(_ path: String) -> String {
        let trimmed = trimTrailingSlash(path)
        guard let i = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: i)...])
    }

    public static func trimTrailingSlash(_ path: String) -> String {
        var p = Substring(path)
        while p.count > 1, p.hasSuffix("/") { p = p.dropLast() }
        return String(p)
    }

    public static func normalize(_ path: String, home: String) -> String {
        var parts: [Substring] = []
        for p in (path.hasPrefix("/") ? path : join(home, path)).split(separator: "/") {
            if p == "." { continue }
            if p == ".." { _ = parts.popLast() } else { parts.append(p) }
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
