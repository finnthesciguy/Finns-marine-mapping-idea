import Foundation

/// Errors thrown by ``PersistenceStore``.
public enum PersistenceError: Error, Sendable, Hashable, CustomStringConvertible {
    /// An underlying SQLite call failed. `code` is SQLite's extended result code.
    case sqlite(code: Int32, message: String)
    /// The database file is damaged. On open this is handled by setting the file aside (see
    /// ``OpenReport/recoveredCorruptFile``); if it happens later the store reports it and will recover on the next open.
    case corrupt(String)
    /// The file was written by a newer version of the app. The store refuses to open it rather than
    /// risk losing data; the file is left untouched.
    case schemaTooNew(found: Int, supported: Int)
    /// A schema migration failed. The database was rolled back to `fromVersion` and left untouched.
    case migrationFailed(fromVersion: Int, toVersion: Int, reason: String)
    /// No entity of that kind has that identifier.
    case notFound(EntityKind, UUID)
    /// An argument was rejected (invalid coordinate, empty name, wrong state for the operation…).
    case invalidArgument(String)
    /// Stored data could not be decoded.
    case decoding(String)
    /// The store was closed.
    case closed

    public var description: String {
        switch self {
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .corrupt(let m): return "Database is corrupt: \(m)"
        case .schemaTooNew(let found, let supported):
            return "Database schema version \(found) is newer than this app supports (\(supported))"
        case .migrationFailed(let from, let to, let reason):
            return "Migration from schema \(from) to \(to) failed: \(reason)"
        case .notFound(let kind, let id): return "No \(kind.rawValue) with id \(id)"
        case .invalidArgument(let m): return "Invalid argument: \(m)"
        case .decoding(let m): return "Could not decode stored data: \(m)"
        case .closed: return "The store is closed"
        }
    }

    /// Maps any error from the internal layer to a public error.
    static func wrap(_ error: any Error) -> PersistenceError {
        if let e = error as? PersistenceError { return e }
        if let f = error as? SQLiteFailure {
            if f.indicatesCorruption { return .corrupt(f.message) }
            return .sqlite(code: f.code, message: f.message)
        }
        return .sqlite(code: -1, message: String(describing: error))
    }
}
