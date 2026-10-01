import Foundation

/// Helpers for folder-relative paths: NFC-normalized, "/"-separated, no leading or trailing slash.
enum SyncPath {
    /// Name of the per-folder safety marker / metadata directory at the folder root.
    static let markerName = ".oneswitch"
    static let tempSuffix = ".oneswitch-tmp"

    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
    }

    /// Byte-wise NFC check (Swift `==` compares canonically equivalent strings as equal).
    static func isNFC(_ s: String) -> Bool {
        s.utf8.elementsEqual(normalize(s).utf8)
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    static func parent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    static func name(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: i)...])
    }

    static func depth(_ path: String) -> Int {
        path.utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "/") ? 1 : 0) }
    }

    /// True when `path` is strictly inside `ancestor` ("" is the folder root).
    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        if ancestor.isEmpty { return !path.isEmpty }
        return path.utf8.count > ancestor.utf8.count + 1
            && path.utf8.starts(with: ancestor.utf8)
            && path.utf8[path.utf8.index(path.utf8.startIndex, offsetBy: ancestor.utf8.count)] == UInt8(ascii: "/")
    }

    static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        path.utf8.elementsEqual(ancestor.utf8) || isInside(path, ancestor)
    }

    /// "a/b/c" → ["a", "a/b"].
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var idx = path.startIndex
        while let slash = path[idx...].firstIndex(of: "/") {
            result.append(String(path[..<slash]))
            idx = path.index(after: slash)
        }
        return result
    }

    /// Case-folded key used to detect paths that collide on case-insensitive volumes.
    static func fold(_ path: String) -> String {
        path.lowercased()
    }

    /// Validates a relative path received from the peer. Rejects anything that could escape the folder
    /// or touch our metadata: absolute paths, "..", ".", empty components, NUL, the marker directory.
    static func isValidRelative(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count < 4096, !path.hasPrefix("/"), !path.hasSuffix("/") else { return false }
        if path.utf8.contains(0) { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
            if component.utf8.count > 255 { return false }
        }
        if isMarkerPath(path) { return false }
        return true
    }

    /// The marker directory or anything inside it (case-insensitively: the volume may not distinguish case).
    static func isMarkerPath(_ path: String) -> Bool {
        let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return first.lowercased() == markerName
    }

    /// Splits "report.docx" into ("report", "docx"); dot-files and names without an extension keep "".
    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        if ext.isEmpty || ext.contains(" ") || ext.utf8.count > 16 { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    private static let conflictFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func timestamp(_ date: Date) -> String {
        conflictFormatter.string(from: date)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        conflictFormatter.date(from: s)
    }

    /// "<name>.sync-conflict-<yyyyMMdd-HHmmss>-<deviceName>.<ext>" next to the original.
    /// `attempt` > 0 appends "-<attempt>" to make the name unique.
    static func conflictPath(for path: String, date: Date, deviceName: String, isDirectory: Bool, attempt: Int = 0) -> String {
        let name = self.name(path)
        let (stem, ext) = isDirectory ? (name, "") : splitExtension(name)
        let device = sanitizeComponent(deviceName.isEmpty ? "Mac" : deviceName)
        var tail = ".sync-conflict-\(timestamp(date))-\(device)"
        if attempt > 0 { tail += "-\(attempt)" }
        let extPart = ext.isEmpty ? "" : "." + ext
        let limit = 255 - tail.utf8.count - extPart.utf8.count
        let newName = truncateUTF8(stem, maxBytes: max(8, limit)) + tail + extPart
        return join(parent(path), newName)
    }

    static let conflictMarker = ".sync-conflict-"

    static func isConflictCopy(_ path: String) -> Bool {
        name(path).contains(conflictMarker)
    }

    /// "a/report.sync-conflict-20260929-101500-MacBook.docx" → "a/report.docx" (best effort, for display).
    static func originalPath(ofConflictCopy path: String) -> String {
        let n = name(path)
        guard let range = n.range(of: conflictMarker) else { return path }
        let stem = String(n[..<range.lowerBound])
        let ext = splitExtension(String(n[range.upperBound...])).ext
        return join(parent(path), stem + (ext.isEmpty ? "" : "." + ext))
    }

    /// Hidden temp name in the destination directory, matched by the default ignore "*.oneswitch-tmp".
    static func tempName(for name: String) -> String {
        let random = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        let base = truncateUTF8(name, maxBytes: 200)
        return ".\(base).\(random)\(tempSuffix)"
    }

    /// True for names made by `tempName(for:)`: ".<name>.<8 hex digits>.oneswitch-tmp" (not for any user
    /// file that merely ends in the suffix).
    static func isTempName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let suffix = Array(tempSuffix.utf8)
        guard bytes.count >= 1 + 1 + 8 + suffix.count, bytes.first == UInt8(ascii: "."),
              bytes.suffix(suffix.count).elementsEqual(suffix) else { return false }
        let end = bytes.count - suffix.count
        guard bytes[end - 9] == UInt8(ascii: ".") else { return false }
        return bytes[(end - 8)..<end].allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func sanitizeComponent(_ s: String) -> String {
        let cleaned = s.map { ch -> Character in
            (ch == "/" || ch == ":" || ch == "\0" || ch.isNewline) ? "-" : ch
        }
        return truncateUTF8(String(cleaned), maxBytes: 64)
    }

    static func truncateUTF8(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var result = ""
        var count = 0
        for ch in s {
            let n = String(ch).utf8.count
            if count + n > maxBytes { break }
            result.append(ch)
            count += n
        }
        return result
    }

    /// Finder / AppleDouble litter that may be removed when deleting a directory.
    static func isJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "Icon\r"
    }
}

/// Ignore patterns (fnmatch globs). A pattern without "/" matches any path component's name;
/// a pattern with "/" matches the whole relative path (a leading "/" anchors it at the folder root).
/// Lines starting with "#" are comments. An ignored directory excludes its whole subtree.
struct IgnoreMatcher: Sendable, Equatable {
    static let defaultPatterns: [String] = [
        ".DS_Store", "._*", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", "Icon\r",
        "*" + SyncPath.tempSuffix,
    ]

    private struct Pattern: Sendable, Equatable {
        let glob: [CChar]
        let matchesPath: Bool
    }

    private let patterns: [Pattern]

    init(userPatterns: [String]) {
        var list: [Pattern] = []
        for raw in Self.defaultPatterns {
            list.append(Pattern(glob: Array(raw.utf8CString), matchesPath: false))
        }
        for line in userPatterns {
            var p = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty || p.hasPrefix("#") { continue }
            while p.hasSuffix("/") { p.removeLast() }
            var matchesPath = p.contains("/")
            if p.hasPrefix("/") {
                p.removeFirst()
                matchesPath = true
            }
            if p.isEmpty { continue }
            list.append(Pattern(glob: Array(SyncPath.normalize(p).utf8CString), matchesPath: matchesPath))
        }
        patterns = list
    }

    /// Splits a multi-line text field into pattern lines.
    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Checks only the entry itself (its ancestors are known not to be ignored) — used while walking.
    func isIgnoredEntry(path: String, name: String) -> Bool {
        if !path.contains("/") && name.lowercased() == SyncPath.markerName { return true }
        return path.withCString { cPath in
            name.withCString { cName in
                for p in patterns {
                    let hit = p.glob.withUnsafeBufferPointer { g in
                        fnmatch(g.baseAddress!, p.matchesPath ? cPath : cName, p.matchesPath ? FNM_PATHNAME : 0) == 0
                    }
                    if hit { return true }
                }
                return false
            }
        }
    }

    /// Full check including every ancestor directory.
    func isIgnored(_ path: String) -> Bool {
        if SyncPath.isMarkerPath(path) { return true }
        for ancestor in SyncPath.ancestors(of: path) where isIgnoredEntry(path: ancestor, name: SyncPath.name(ancestor)) {
            return true
        }
        return isIgnoredEntry(path: path, name: SyncPath.name(path))
    }
}
