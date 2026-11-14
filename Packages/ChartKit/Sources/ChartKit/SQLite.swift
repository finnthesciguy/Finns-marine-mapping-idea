import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Errors raised by the thin internal SQLite wrapper.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

// SQLITE_TRANSIENT is a C macro that Swift does not import.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal, non-Sendable SQLite connection. It must be confined to one isolation domain
/// (ChartKit keeps each one inside an actor).
final class SQLiteConnection {
    private(set) var handle: OpaquePointer?

    enum Mode { case readOnly, readWriteCreate }

    init(path: String, mode: Mode) throws {
        var db: OpaquePointer?
        let flags: Int32
        switch mode {
        case .readOnly: flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        case .readWriteCreate: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        }
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        // Corrupt or busy files must fail fast rather than block.
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private var lastError: SQLiteError {
        guard let handle else { return SQLiteError(code: SQLITE_MISUSE, message: "connection closed") }
        return SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw lastError }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw lastError }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw lastError
        }
        return SQLiteStatement(stmt: stmt, connection: self)
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], map: (SQLiteStatement) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        try stmt.bind(bindings)
        var out: [T] = []
        while try stmt.step() {
            out.append(try map(stmt))
        }
        return out
    }

    fileprivate func error() -> SQLiteError { lastError }
}

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let connection: SQLiteConnection

    fileprivate init(stmt: OpaquePointer, connection: SQLiteConnection) {
        self.stmt = stmt
        self.connection = connection
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLiteValue]) throws {
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), sqliteTransient)
                }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK { throw connection.error() }
        }
    }

    /// Returns true while rows are available.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.error()
        }
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(stmt, column) == SQLITE_NULL }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }

    func text(_ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: ptr)
    }

    func blob(_ column: Int32) -> Data? {
        if isNull(column) { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: ptr, count: count)
    }
}

/// The SQLite library version, for diagnostics.
public func chartKitSQLiteVersion() -> String { String(cString: sqlite3_libversion()) }
