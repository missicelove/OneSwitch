import Foundation

/// A scan request prepared on the engine queue and executed on the scan queue.
struct ScanJob: Sendable {
    let folderID: String
    /// Real (symlink-resolved) absolute root path.
    let root: String
    let matcher: IgnoreMatcher
    /// Relative subtrees to scan; [""] = full scan.
    let roots: [String]
    /// Index records (quick view) at / under `roots`, captured when the job was created.
    let snapshot: [String: QuickRecord]
    let settleTime: TimeInterval
    let settleMinSize: Int64
    let isFull: Bool
    /// On case-insensitive volumes a targeted path must match the on-disk name exactly, otherwise a
    /// case variant ("Readme.txt" vs "README.txt") would be indexed under the wrong name.
    let caseSensitive: Bool
    /// Self-checks only: report deletions parents-first (the worst case for a peer receiving the index in
    /// batches, as with the unordered deletions of v1.0.2) instead of children-first.
    var parentTombstonesFirst = false
}

struct ScanChange: Sendable {
    enum Observed: Sendable {
        case present(DiskState, hash: Data?)
        case missing
    }

    let path: String
    /// The index record the comparison was made against (nil = unknown path).
    let base: QuickRecord?
    let observed: Observed
}

struct ScanOutcome: Sendable {
    var changes: [ScanChange] = []
    /// Files still being written (size / mtime not stable yet): rescan later.
    var deferred: [String] = []
    var markerMissing = false
    var cancelled = false
    var visited = 0
    var hashedFiles = 0
    var hashedBytes: Int64 = 0
    var problems: [String] = []
    /// Our own temp files ("*.oneswitch-tmp") seen during a full scan.
    var tempFiles: [String] = []
    /// New / changed files that are dataless placeholders (content only in iCloud): not hashed, not
    /// indexed, never treated as deleted.
    var dataless: [String] = []
}

/// Walks a folder (or subtrees), compares with the index snapshot and hashes new / changed files.
/// Runs on the scan queue; touches no engine state.
enum Scanner {
    static func markerExists(root: String) -> Bool {
        FS.isDirectory(root) && FS.isDirectory(root + "/" + SyncPath.markerName)
    }

    static func run(_ job: ScanJob, isCancelled: () -> Bool) -> ScanOutcome {
        var out = ScanOutcome()
        guard markerExists(root: job.root) else {
            out.markerMissing = true
            return out
        }
        var seen = Set<String>()
        /// Subtrees we could not read (permissions / I/O): never infer deletions inside them.
        var unreadable: [String] = []

        func absolute(_ rel: String) -> String { rel.isEmpty ? job.root : job.root + "/" + rel }

        func handle(_ rel: String, _ disk: DiskState) {
            let base = job.snapshot[rel]
            if let b = base, !b.deleted, b.kind == disk.kind {
                let unchanged: Bool
                switch disk.kind {
                case .directory: unchanged = b.mode == disk.mode
                case .symlink: unchanged = b.target == disk.target
                case .file: unchanged = b.size == disk.size && b.mtimeNS == disk.mtimeNS && b.mode == disk.mode
                }
                if unchanged { return }
            }
            guard disk.kind == .file else {
                out.changes.append(ScanChange(path: rel, base: base, observed: .present(disk, hash: nil)))
                return
            }
            if disk.dataless {
                // Hashing would download the whole file from iCloud (a download storm for a folder in
                // "optimized storage"). Leave the index as it is until the file is downloaded.
                out.dataless.append(rel)
                return
            }
            // Recently modified large files may still be written: wait until they settle. An mtime in the
            // future (clock skew, archives, cameras) is not "recent" — deferring it would retry forever.
            let ageNS = Int64(Date().timeIntervalSince1970 * 1e9) - disk.mtimeNS
            if disk.size >= job.settleMinSize && ageNS >= 0 && ageNS < Int64(job.settleTime * 1e9) {
                out.deferred.append(rel)
                return
            }
            let path = absolute(rel)
            do {
                guard let (digest, bytes) = try FS.sha256(path: path, cancelled: isCancelled) else {
                    out.cancelled = true
                    return
                }
                out.hashedFiles += 1
                out.hashedBytes += bytes
                // The file must not have changed while we hashed it.
                guard let after = FS.entry(path), after.kind == .file,
                      after.size == disk.size, after.mtimeNS == disk.mtimeNS, bytes == disk.size else {
                    out.deferred.append(rel)
                    return
                }
                out.changes.append(ScanChange(path: rel, base: base, observed: .present(after, hash: digest)))
            } catch let e as FS.HashError where e.code == ENOENT {
                out.deferred.append(rel) // vanished between lstat and open: the next event settles it
            } catch is FS.DatalessError {
                out.dataless.append(rel) // evicted between lstat and open
            } catch {
                out.problems.append("无法读取「\(rel)」：\((error as? FS.HashError).map { FS.localizedError($0.code) } ?? "\(error)")")
            }
        }

        func walk(_ start: String) {
            var stack = [start]
            while let dir = stack.popLast() {
                if isCancelled() { out.cancelled = true; return }
                switch FS.listDirectory(absolute(dir)) {
                case .failure(let code):
                    if dir.isEmpty && (code == ENOENT || code == ENOTDIR) {
                        // The root itself vanished (unmounted / moved) — even if it is back by the time the
                        // walk ends, the results are meaningless: never report its contents as deleted.
                        // (Other errors mark the root unreadable below, which also suppresses deletions.)
                        out.markerMissing = true
                        out.cancelled = true
                        return
                    }
                    if code == ENOENT || code == ENOTDIR {
                        continue // vanished: children are reported missing below
                    }
                    unreadable.append(dir)
                    out.problems.append("无法读取目录「\(dir.isEmpty ? "/" : dir)」：\(FS.localizedError(code))")
                case .success(let names):
                    for rawName in names {
                        let name = SyncPath.normalize(rawName)
                        let rel = SyncPath.join(dir, name)
                        if dir.isEmpty && name == SyncPath.markerName { continue }
                        if job.isFull && name.hasSuffix(SyncPath.tempSuffix) { out.tempFiles.append(rel) }
                        if job.matcher.isIgnoredEntry(path: rel, name: name) { continue }
                        out.visited += 1
                        switch FS.lstatEntry(absolute(rel)) {
                        case .entry(let disk):
                            seen.insert(rel)
                            handle(rel, disk)
                            if out.cancelled { return }
                            if disk.kind == .directory { stack.append(rel) }
                        case .missing:
                            break
                        case .unsupported:
                            seen.insert(rel) // not synced, but never treat as a deletion either
                        case .error(let code):
                            seen.insert(rel)
                            unreadable.append(rel)
                            out.problems.append("无法读取「\(rel)」：\(FS.localizedError(code))")
                        }
                    }
                }
            }
        }

        for root in job.roots {
            if isCancelled() || out.cancelled { out.cancelled = true; break }
            if root.isEmpty {
                walk("")
                continue
            }
            if job.matcher.isIgnored(root) { continue }
            if !job.caseSensitive && !namesMatchOnDisk(root: job.root, rel: root) { continue } // → reported missing
            switch FS.lstatEntry(absolute(root)) {
            case .entry(let disk):
                seen.insert(root)
                handle(root, disk)
                if disk.kind == .directory && !out.cancelled { walk(root) }
            case .missing:
                break
            case .unsupported:
                seen.insert(root)
            case .error(let code):
                seen.insert(root)
                unreadable.append(root)
                out.problems.append("无法读取「\(root)」：\(FS.localizedError(code))")
            }
        }
        if out.cancelled {
            out.changes.removeAll()
            return out
        }

        // Missing entries: indexed, live, inside a scanned root, not seen, not ignored, not unreadable.
        var missing: [(depth: Int, change: ScanChange)] = []
        for (path, record) in job.snapshot where !record.deleted && !seen.contains(path) {
            guard job.roots.contains(where: { SyncPath.isSameOrInside(path, $0) || $0.isEmpty }) else { continue }
            if unreadable.contains(where: { SyncPath.isInside(path, $0) }) { continue }
            if job.matcher.isIgnored(path) { continue }
            missing.append((SyncPath.depth(path), ScanChange(path: path, base: record, observed: .missing)))
        }
        // Children before their directory: changes are committed (and sequenced) in this order, so a
        // directory's tombstone always follows its children's in the index the peer receives in batches.
        // (New entries above are already parents-first, from the walk.)
        let deepestFirst = !job.parentTombstonesFirst
        missing.sort { a, b in
            if a.depth != b.depth { return deepestFirst ? a.depth > b.depth : a.depth < b.depth }
            return a.change.path.utf8.lexicographicallyPrecedes(b.change.path.utf8)
        }
        out.changes.append(contentsOf: missing.map(\.change))

        // Safety: if the marker (or the whole root) vanished while we walked — e.g. the external disk was
        // unmounted — the results are meaningless. Never report a missing root as mass deletion.
        if !markerExists(root: job.root) {
            out.changes.removeAll()
            out.markerMissing = true
        }
        return out
    }

    /// True when every component of `rel` exists on disk with exactly this name (NFC-compared), or when
    /// the entry does not exist at all.
    static func namesMatchOnDisk(root: String, rel: String) -> Bool {
        var prefix = ""
        for component in rel.split(separator: "/") {
            prefix = SyncPath.join(prefix, String(component))
            guard let actual = FS.onDiskName(root + "/" + prefix) else { return true }
            if !SyncPath.normalize(actual).utf8.elementsEqual(component.utf8) { return false }
        }
        return true
    }

    /// Deletes files in `<root>/.oneswitch/versions` older than `retention` (by the timestamp in their
    /// name) and prunes empty directories.
    static func cleanVersions(root: String, retention: TimeInterval, now: Date, isCancelled: () -> Bool = { false }) -> Int {
        let base = root + "/" + SyncPath.markerName + "/versions"
        guard FS.isDirectory(base) else { return 0 }
        var removed = 0
        func visit(_ dir: String) -> Bool { // returns true when dir is empty afterwards
            if isCancelled() { return false }
            guard case .success(let names) = FS.listDirectory(dir) else { return false }
            var remaining = names.count
            for name in names {
                let path = dir + "/" + name
                if FS.isDirectory(path) {
                    if visit(path), rmdir(path) == 0 { remaining -= 1 }
                    continue
                }
                if let date = versionDate(fromName: name), now.timeIntervalSince(date) > retention {
                    if unlink(path) == 0 {
                        removed += 1
                        remaining -= 1
                    }
                }
            }
            return remaining == 0
        }
        _ = visit(base)
        return removed
    }

    /// Versioned files are named "<stem>~<yyyyMMdd-HHmmss>[.<ext>]".
    static func versionName(for name: String, date: Date) -> String {
        let (stem, ext) = SyncPath.splitExtension(name)
        return stem + "~" + SyncPath.timestamp(date) + (ext.isEmpty ? "" : "." + ext)
    }

    static func versionDate(fromName name: String) -> Date? {
        guard let tilde = name.lastIndex(of: "~") else { return nil }
        let rest = name[name.index(after: tilde)...]
        guard rest.count >= 15 else { return nil }
        return SyncPath.parseTimestamp(String(rest.prefix(15)))
    }
}
