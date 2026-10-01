import Foundation
import SQLite3

/// Minimal SQLite wrapper (one connection, used from a single serial queue).
final class SQLiteDatabase {
    struct SQLError: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite error \(code): \(message)" }
    }

    enum Value {
        case int(Int64)
        case text(String)
        case blob(Data)
        case null
    }

    struct Row {
        fileprivate let stmt: OpaquePointer

        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }

        func blob(_ i: Int32) -> Data? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: n)
        }
    }

    private var db: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    private var transactionDepth = 0
    /// Set once any call reported SQLITE_CORRUPT / SQLITE_NOTADB (the file needs to be rebuilt).
    private(set) var corruptionDetected = false

    static func isCorruption(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    /// Self-checks only.
    func simulateCorruption() { corruptionDetected = true }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLError(code: rc, message: msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { close() }

    var isOpen: Bool { db != nil }

    func close() {
        for (_, stmt) in cache { sqlite3_finalize(stmt) }
        cache.removeAll()
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func error(_ rc: Int32) -> SQLError {
        if Self.isCorruption(rc) { corruptionDetected = true }
        return SQLError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    func execute(_ sql: String) throws {
        guard let db else { throw SQLError(code: SQLITE_MISUSE, message: "database closed") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            if Self.isCorruption(rc) { corruptionDetected = true }
            throw SQLError(code: rc, message: msg)
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw SQLError(code: SQLITE_MISUSE, message: "database closed") }
        if let cached = cache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        cache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [Value]) throws {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch arg {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .blob(let d):
                rc = d.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(raw.count), Self.transient)
                }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK { throw error(rc) }
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ args: [Value] = []) throws {
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { throw error(rc) }
    }

    /// Iterates result rows. Do not run other statements on the same SQL text inside `body`.
    func query(_ sql: String, _ args: [Value] = [], _ body: (Row) throws -> Void) throws {
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, args)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            try body(Row(stmt: stmt))
        }
    }

    func scalarInt(_ sql: String, _ args: [Value] = []) throws -> Int64? {
        var result: Int64?
        try query(sql, args) { row in
            if sqlite3_column_type(row.stmt, 0) != SQLITE_NULL { result = row.int(0) }
        }
        return result
    }

    /// Nested calls join the outermost transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }
}
