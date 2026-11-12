import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// SQLITE_TRANSIENT is a C macro that Swift does not import.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value bound to, or read from, a SQLite statement.
enum SQLValue: Sendable, Hashable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    static func optional(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    static func optional(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
    static func optional(_ v: Data?) -> SQLValue { v.map { .blob($0) } ?? .null }
    static func bool(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
    static func date(_ d: Date) -> SQLValue { .double(d.timeIntervalSince1970) }
    static func optionalDate(_ d: Date?) -> SQLValue { d.map { .date($0) } ?? .null }
    static func uuid(_ u: UUID) -> SQLValue { .text(u.uuidString) }
}

/// A raw SQLite failure from the internal wrapper.
struct SQLiteFailure: Error, CustomStringConvertible {
    /// Extended result code.
    let code: Int32
    let message: String
    let sql: String?

    /// Primary result code (extended code masked to its low byte).
    var primaryCode: Int32 { code & 0xFF }

    /// True for the result codes that mean the file itself is damaged or is not a database.
    var indicatesCorruption: Bool { primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB }

    var description: String {
        if let sql { return "SQLite error \(code): \(message) [\(sql)]" }
        return "SQLite error \(code): \(message)"
    }
}

/// A minimal, non-Sendable SQLite connection. It must stay confined to one isolation domain;
/// ``PersistenceStore`` keeps its only instance inside the actor.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statementCache: [String: SQLiteStatement] = [:]
    /// Depth of nested ``transaction(_:)`` calls (outermost is BEGIN IMMEDIATE, inner ones are savepoints).
    private(set) var transactionDepth = 0

    /// Opens (creating if needed) a database. `path` may be `":memory:"`.
    init(path: String, readOnly: Bool = false, busyTimeoutMilliseconds: Int32 = 5000) throws(SQLiteFailure) {
        var db: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX)
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteFailure(code: rc, message: msg, sql: nil)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
    }

    deinit { close() }

    /// Finalizes cached statements and closes the handle. Safe to call twice.
    func close() {
        statementCache.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var isOpen: Bool { handle != nil }

    private func failure(_ rc: Int32? = nil, sql: String?) -> SQLiteFailure {
        guard let handle else { return SQLiteFailure(code: SQLITE_MISUSE, message: "connection closed", sql: sql) }
        return SQLiteFailure(code: rc ?? sqlite3_extended_errcode(handle),
                             message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    /// Runs one or more statements with no bindings and no results.
    func execute(_ sql: String) throws(SQLiteFailure) {
        guard let handle else { throw failure(sql: sql) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteFailure(code: sqlite3_extended_errcode(handle), message: msg, sql: sql)
        }
    }

    /// Prepares a statement. With `cached`, the statement is reused across calls (it is reset before reuse).
    func prepare(_ sql: String, cached: Bool = true) throws(SQLiteFailure) -> SQLiteStatement {
        if cached, let s = statementCache[sql] {
            s.reset()
            return s
        }
        guard let handle else { throw failure(sql: sql) }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw failure(rc, sql: sql)
        }
        let s = SQLiteStatement(stmt: stmt, connection: self, sql: sql)
        if cached { statementCache[sql] = s }
        return s
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ bindings: [SQLValue] = []) throws(SQLiteFailure) {
        let s = try prepare(sql)
        defer { s.reset() }
        try s.bind(bindings)
        while try s.step() {}
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        let s = try prepare(sql)
        defer { s.reset() }
        try s.bind(bindings)
        var out: [T] = []
        while try s.step() { out.append(try map(SQLiteRow(statement: s))) }
        return out
    }

    /// Runs a query and maps the first row, if any.
    func queryFirst<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (SQLiteRow) throws -> T) throws -> T? {
        let s = try prepare(sql)
        defer { s.reset() }
        try s.bind(bindings)
        guard try s.step() else { return nil }
        return try map(SQLiteRow(statement: s))
    }

    /// Single integer from the first column of the first row.
    func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64? {
        try queryFirst(sql, bindings) { $0.isNull(0) ? nil : $0.int(0) } ?? nil
    }

    /// Rowid of the most recent successful INSERT.
    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    /// Rows changed by the most recent statement.
    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    /// Runs `body` in a transaction. The outermost level uses `BEGIN IMMEDIATE` so a writer takes the lock
    /// up front (and the busy timeout applies) instead of failing on a read-to-write upgrade; nested levels
    /// use savepoints. Any thrown error rolls back that level.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let depth = transactionDepth
        if depth == 0 {
            try execute("BEGIN IMMEDIATE")
        } else {
            try execute("SAVEPOINT sp\(depth)")
        }
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            if depth == 0 { try execute("COMMIT") } else { try execute("RELEASE sp\(depth)") }
            return result
        } catch {
            transactionDepth -= 1
            if depth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO sp\(depth)")
                try? execute("RELEASE sp\(depth)")
            }
            throw error
        }
    }

    /// True when the linked SQLite can create R*Tree virtual tables (probed, not assumed).
    func supportsRTree() -> Bool {
        do {
            try execute("CREATE VIRTUAL TABLE temp.__rtree_probe USING rtree(id, a, b)")
            try execute("DROP TABLE temp.__rtree_probe")
            return true
        } catch {
            return false
        }
    }

    /// Library version string, for diagnostics.
    static var libraryVersion: String { String(cString: sqlite3_libversion()) }
}

/// A prepared statement owned by a ``SQLiteConnection``.
final class SQLiteStatement {
    fileprivate let stmt: OpaquePointer
    private unowned let connection: SQLiteConnection
    let sql: String

    fileprivate init(stmt: OpaquePointer, connection: SQLiteConnection, sql: String) {
        self.stmt = stmt
        self.connection = connection
        self.sql = sql
    }

    deinit { sqlite3_finalize(stmt) }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    private func check(_ rc: Int32) throws(SQLiteFailure) {
        guard rc == SQLITE_OK else {
            throw SQLiteFailure(code: rc, message: String(cString: sqlite3_errstr(rc)), sql: sql)
        }
    }

    func bind(_ values: [SQLValue]) throws(SQLiteFailure) {
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .int(let v): try check(sqlite3_bind_int64(stmt, idx, v))
            case .double(let v): try check(sqlite3_bind_double(stmt, idx, v))
            case .text(let v): try check(sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient))
            case .blob(let v):
                let rc = v.withUnsafeBytes { buf -> Int32 in
                    // A zero-length blob still needs a non-null pointer to bind as a blob rather than NULL.
                    if buf.count == 0 { return sqlite3_bind_zeroblob(stmt, idx, 0) }
                    return sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), sqliteTransient)
                }
                try check(rc)
            case .null: try check(sqlite3_bind_null(stmt, idx))
            }
        }
    }

    /// Advances; true while a row is available.
    func step() throws(SQLiteFailure) -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc & 0xFF {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let f = SQLiteFailure(code: rc, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))), sql: sql)
            sqlite3_reset(stmt)
            throw f
        }
    }
}

/// Typed accessors for the current row of a statement.
struct SQLiteRow {
    fileprivate let statement: SQLiteStatement
    private var stmt: OpaquePointer { statement.stmt }

    func isNull(_ c: Int32) -> Bool { sqlite3_column_type(stmt, c) == SQLITE_NULL }
    func int(_ c: Int32) -> Int64 { sqlite3_column_int64(stmt, c) }
    func bool(_ c: Int32) -> Bool { sqlite3_column_int64(stmt, c) != 0 }
    func double(_ c: Int32) -> Double { sqlite3_column_double(stmt, c) }
    func optionalDouble(_ c: Int32) -> Double? { isNull(c) ? nil : double(c) }
    func text(_ c: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, c) else { return "" }
        return String(cString: p)
    }
    func optionalText(_ c: Int32) -> String? { isNull(c) ? nil : text(c) }
    func date(_ c: Int32) -> Date { Date(timeIntervalSince1970: double(c)) }
    func optionalDate(_ c: Int32) -> Date? { isNull(c) ? nil : date(c) }
    func blob(_ c: Int32) -> Data? {
        if isNull(c) { return nil }
        let n = Int(sqlite3_column_bytes(stmt, c))
        guard n > 0, let p = sqlite3_column_blob(stmt, c) else { return Data() }
        return Data(bytes: p, count: n)
    }
    func uuid(_ c: Int32) throws(PersistenceError) -> UUID {
        let s = text(c)
        guard let u = UUID(uuidString: s) else { throw .decoding("invalid UUID '\(s)'") }
        return u
    }
}
