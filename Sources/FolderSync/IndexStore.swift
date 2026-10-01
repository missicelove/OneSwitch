import Foundation
import SQLite3
import OneSwitchCore

/// Persistent index: our own records per folder (`local_files`), the peer's records as last announced
/// (`remote_files`) and small key/value state (`meta`).
///
/// SQLite (WAL) was chosen over JSON because folders can hold 100k+ entries: updates touch single rows
/// instead of rewriting a large file, and the queries the engine needs — "records with sequence > N",
/// "records under a/b/", "remote paths that differ only by case", "a local file with this hash" — are
/// indexed lookups. Must only be used from the engine queue.
final class IndexStore {
    enum Table: String {
        case local = "local_files"
        case remote = "remote_files"
    }

    private let db: SQLiteDatabase
    let directory: URL

    static let fileName = "index.sqlite"
    /// Written when corruption is detected at runtime: the next `open` rebuilds the index.
    static let rebuildMarkerName = "index.rebuild"

    /// Opens the index, rebuilding it from scratch when the file is corrupt (or was flagged for a rebuild).
    /// The damaged file is kept next to it as "index.sqlite.corrupt-<date>". `recovered` tells the engine
    /// that everything it knew (folder locations, sequences, the peer's index) is gone.
    static func open(directory: URL) throws -> (store: IndexStore, recovered: Bool) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(rebuildMarkerName).path
        var recovered = false
        if FS.exists(marker) {
            AppLogSync.warning("index database was flagged as corrupted; rebuilding it")
            moveAside(directory)
            unlink(marker)
            recovered = true
        }
        do {
            let store = try IndexStore(directory: directory)
            if let problem = store.quickCheck() {
                store.db.close()
                throw SQLiteDatabase.SQLError(code: SQLITE_CORRUPT, message: problem)
            }
            return (store, recovered)
        } catch let error as SQLiteDatabase.SQLError where SQLiteDatabase.isCorruption(error.code) {
            AppLogSync.error("index database is corrupted (\(error)); rebuilding it")
            moveAside(directory)
            return (try IndexStore(directory: directory), true)
        }
    }

    /// Renames a damaged database (and its WAL / shared-memory files) out of the way, keeping only the
    /// most recent damaged copy for diagnosis.
    private static func moveAside(_ directory: URL) {
        let dir = directory.path
        if case .success(let names) = FS.listDirectory(dir) {
            for name in names where name.hasPrefix(fileName + ".corrupt-") { unlink(dir + "/" + name) }
        }
        let base = dir + "/" + fileName
        let aside = base + ".corrupt-" + SyncPath.timestamp(Date())
        for suffix in ["", "-wal", "-shm"] where FS.exists(base + suffix) {
            if rename(base + suffix, aside + suffix) != 0 { unlink(base + suffix) }
        }
    }

    /// Flags the database for a rebuild on the next `open` (runtime corruption).
    func flagForRebuild() {
        let marker = directory.appendingPathComponent(Self.rebuildMarkerName).path
        FileManager.default.createFile(atPath: marker, contents: Data())
    }

    /// True once SQLite reported corruption for any statement.
    var corruptionDetected: Bool { db.corruptionDetected }

    /// Self-checks only.
    func simulateCorruption() { db.simulateCorruption() }

    /// nil when `PRAGMA quick_check` reports "ok", otherwise its first message.
    func quickCheck() -> String? {
        var result: String?
        do {
            try db.query("PRAGMA quick_check") { row in
                if result == nil { result = row.text(0) ?? "?" }
            }
        } catch {
            return "\(error)"
        }
        return result == "ok" ? nil : (result ?? "quick_check returned nothing")
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let path = directory.appendingPathComponent(Self.fileName).path
        db = try SQLiteDatabase(path: path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")
        try db.execute("PRAGMA temp_store=MEMORY")
        for table in [Table.local, Table.remote] {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS \(table.rawValue) (
                    folder TEXT NOT NULL, path TEXT NOT NULL, fold TEXT NOT NULL,
                    kind INTEGER NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL, mode INTEGER NOT NULL,
                    hash BLOB, target TEXT, deleted INTEGER NOT NULL, version TEXT NOT NULL, seq INTEGER NOT NULL,
                    PRIMARY KEY (folder, path)) WITHOUT ROWID
                """)
            try db.execute("CREATE INDEX IF NOT EXISTS \(table.rawValue)_seq ON \(table.rawValue)(folder, seq)")
            try db.execute("CREATE INDEX IF NOT EXISTS \(table.rawValue)_fold ON \(table.rawValue)(folder, fold)")
        }
        try db.execute("CREATE INDEX IF NOT EXISTS local_files_hash ON local_files(folder, hash) WHERE hash IS NOT NULL")
        try db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
    }

    func close() {
        try? db.execute("PRAGMA wal_checkpoint(PASSIVE)")
        db.close()
    }

    var isOpen: Bool { db.isOpen }

    /// Runs `body` inside a transaction, logging (not propagating) SQLite errors.
    func batch(_ body: () -> Void) {
        do {
            try db.transaction { body() }
        } catch {
            AppLogSync.error("index batch failed: \(error)")
        }
    }

    // MARK: Records

    private static let columns = "path, kind, size, mtime, mode, hash, target, deleted, version, seq"

    private static func decode(_ row: SQLiteDatabase.Row, offset: Int32 = 0) -> FileRecord {
        FileRecord(path: row.text(offset + 0) ?? "",
                   kind: EntryKind(rawValue: Int(row.int(offset + 1))) ?? .file,
                   size: row.int(offset + 2),
                   mtimeNS: row.int(offset + 3),
                   mode: UInt32(truncatingIfNeeded: row.int(offset + 4)),
                   hash: row.blob(offset + 5),
                   target: row.text(offset + 6),
                   deleted: row.int(offset + 7) != 0,
                   version: VersionVector(storageString: row.text(offset + 8) ?? ""),
                   sequence: row.int(offset + 9))
    }

    func record(_ table: Table, folder: String, path: String) -> FileRecord? {
        var result: FileRecord?
        try? db.query("SELECT \(Self.columns) FROM \(table.rawValue) WHERE folder = ? AND path = ?",
                      [.text(folder), .text(path)]) { result = Self.decode($0) }
        return result
    }

    func upsert(_ table: Table, folder: String, _ r: FileRecord) {
        do {
            try db.run("""
                INSERT OR REPLACE INTO \(table.rawValue)
                (folder, path, fold, kind, size, mtime, mode, hash, target, deleted, version, seq)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(folder), .text(r.path), .text(SyncPath.fold(r.path)), .int(Int64(r.kind.rawValue)),
                      .int(r.size), .int(r.mtimeNS), .int(Int64(r.mode)),
                      r.hash.map { .blob($0) } ?? .null, r.target.map { .text($0) } ?? .null,
                      .int(r.deleted ? 1 : 0), .text(r.version.storageString), .int(r.sequence)])
        } catch {
            AppLogSync.error("upsert \(table.rawValue) \(r.path) failed: \(error)")
        }
    }

    /// Records with `seq > after`, ascending, at most `limit`.
    func records(_ table: Table, folder: String, afterSequence after: Int64, limit: Int) -> [FileRecord] {
        var out: [FileRecord] = []
        try? db.query("SELECT \(Self.columns) FROM \(table.rawValue) WHERE folder = ? AND seq > ? ORDER BY seq LIMIT ?",
                      [.text(folder), .int(after), .int(Int64(limit))]) { out.append(Self.decode($0)) }
        return out
    }

    /// Records at `path` and below it ("" = the whole folder).
    func records(_ table: Table, folder: String, under path: String) -> [FileRecord] {
        var out: [FileRecord] = []
        if path.isEmpty {
            try? db.query("SELECT \(Self.columns) FROM \(table.rawValue) WHERE folder = ?", [.text(folder)]) {
                out.append(Self.decode($0))
            }
            return out
        }
        // "/" is 0x2F and "0" is 0x30, so [p + "/", p + "0") is exactly the subtree in binary collation.
        try? db.query("""
            SELECT \(Self.columns) FROM \(table.rawValue)
            WHERE folder = ? AND (path = ? OR (path > ? AND path < ?))
            """, [.text(folder), .text(path), .text(path + "/"), .text(path + "0")]) { out.append(Self.decode($0)) }
        return out
    }

    func forEach(_ table: Table, folder: String, _ body: (FileRecord) -> Void) {
        try? db.query("SELECT \(Self.columns) FROM \(table.rawValue) WHERE folder = ?", [.text(folder)]) {
            body(Self.decode($0))
        }
    }

    /// Joined view for evaluating needs: every remote record with the matching local record (if any).
    func forEachRemoteWithLocal(folder: String, _ body: (FileRecord, FileRecord?) -> Void) {
        let r = Self.columns.split(separator: ",").map { "r." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        let l = Self.columns.split(separator: ",").map { "l." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        try? db.query("""
            SELECT \(r), \(l) FROM remote_files r
            LEFT JOIN local_files l ON l.folder = r.folder AND l.path = r.path
            WHERE r.folder = ?
            """, [.text(folder)]) { row in
            let remote = Self.decode(row)
            let local: FileRecord? = row.text(10) == nil ? nil : Self.decode(row, offset: 10)
            body(remote, local)
        }
    }

    /// Paths (≠ `path`) whose case-folded form equals `path`'s, not deleted.
    func caseVariants(_ table: Table, folder: String, path: String) -> [String] {
        var out: [String] = []
        try? db.query("SELECT path FROM \(table.rawValue) WHERE folder = ? AND fold = ? AND deleted = 0",
                      [.text(folder), .text(SyncPath.fold(path))]) { row in
            if let p = row.text(0), !p.utf8.elementsEqual(path.utf8) { out.append(p) }
        }
        return out
    }

    /// Live local files with the given content hash (candidates for a local clone instead of a transfer).
    func localFiles(folder: String, hash: Data, limit: Int = 4) -> [FileRecord] {
        var out: [FileRecord] = []
        try? db.query("""
            SELECT \(Self.columns) FROM local_files
            WHERE folder = ? AND hash = ? AND deleted = 0 AND kind = 0 LIMIT ?
            """, [.text(folder), .blob(hash), .int(Int64(limit))]) { out.append(Self.decode($0)) }
        return out
    }

    func maxSequence(_ table: Table, folder: String) -> Int64 {
        (try? db.scalarInt("SELECT MAX(seq) FROM \(table.rawValue) WHERE folder = ?", [.text(folder)])) ?? 0
    }

    struct Totals {
        var files = 0
        var directories = 0
        var symlinks = 0
        var bytes: Int64 = 0
    }

    func totals(folder: String) -> Totals {
        var t = Totals()
        try? db.query("""
            SELECT kind, COUNT(*), COALESCE(SUM(size), 0) FROM local_files
            WHERE folder = ? AND deleted = 0 GROUP BY kind
            """, [.text(folder)]) { row in
            let count = Int(row.int(1))
            switch EntryKind(rawValue: Int(row.int(0))) {
            case .file: t.files = count; t.bytes = row.int(2)
            case .directory: t.directories = count
            case .symlink: t.symlinks = count
            case nil: break
            }
        }
        return t
    }

    func count(_ table: Table, folder: String) -> Int {
        Int((try? db.scalarInt("SELECT COUNT(*) FROM \(table.rawValue) WHERE folder = ?", [.text(folder)])) ?? 0)
    }

    func clear(_ table: Table, folder: String) {
        try? db.run("DELETE FROM \(table.rawValue) WHERE folder = ?", [.text(folder)])
    }

    func clearAll(_ table: Table) {
        try? db.run("DELETE FROM \(table.rawValue)")
    }

    func folderIDs() -> Set<String> {
        var ids = Set<String>()
        for table in [Table.local, Table.remote] {
            try? db.query("SELECT DISTINCT folder FROM \(table.rawValue)") { row in
                if let f = row.text(0) { ids.insert(f) }
            }
        }
        try? db.query("SELECT key FROM meta WHERE key LIKE 'folder.%'") { row in
            // "folder.<id>.<field>": field names contain no dots, so the id is everything in between.
            if let key = row.text(0), let lastDot = key.lastIndex(of: "."), key.hasPrefix("folder.") {
                let start = key.index(key.startIndex, offsetBy: "folder.".count)
                if start < lastDot { ids.insert(String(key[start..<lastDot])) }
            }
        }
        return ids
    }

    // MARK: Meta

    func meta(_ key: String) -> String? {
        var v: String?
        try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { v = $0.text(0) }
        return v
    }

    func setMeta(_ key: String, _ value: String?) {
        if let value {
            try? db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try? db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    func deleteMeta(prefix: String) {
        try? db.run("DELETE FROM meta WHERE key >= ? AND key < ?", [.text(prefix), .text(prefix + "\u{10FFFF}")])
    }

    /// Removes everything known about a folder (local + remote records and its meta keys).
    func dropFolder(_ folder: String) {
        batch {
            clear(.local, folder: folder)
            clear(.remote, folder: folder)
            deleteMeta(prefix: "folder.\(folder).")
            deleteMeta(prefix: "remote.\(folder).")
        }
    }
}

/// Logging shorthand for the module ("sync" category).
enum AppLogSync {
    static func info(_ message: @autoclosure () -> String) { AppLog.info("sync", message()) }
    static func warning(_ message: @autoclosure () -> String) { AppLog.warning("sync", message()) }
    static func error(_ message: @autoclosure () -> String) { AppLog.error("sync", message()) }
    static func debug(_ message: @autoclosure () -> String) { AppLog.debug("sync", message()) }
}
