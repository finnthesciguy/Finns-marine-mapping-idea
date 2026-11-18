import Foundation
import NavCore

/// What happened while opening the store.
public struct OpenReport: Sendable, Hashable {
    /// The database file, nil for an in-memory store.
    public var databaseURL: URL?
    /// If the existing file was damaged, where it was moved before a fresh database was created.
    /// The app should tell the user that saved data could not be read (the damaged file is kept for support).
    public var recoveredCorruptFile: URL?
    /// Why the file was judged damaged.
    public var corruptionReason: String?
    /// Schema version found on disk (0 for a new file).
    public var schemaVersionBefore: Int
    /// Schema version after migrations.
    public var schemaVersionAfter: Int
    /// Structure used for bounding-box queries.
    public var spatialIndex: SpatialIndexKind
    /// Linked SQLite library version.
    public var sqliteVersion: String
    /// Tracks that were still recording when the app last stopped (interrupted by termination or a crash).
    /// Offer to resume (``PersistenceStore/resumeRecording(_:)``) or close them
    /// (``PersistenceStore/finishRecording(_:)``).
    public var interruptedRecordings: [UUID]
}

/// The app's local store for user data: waypoints, routes, tracks, boat profiles, settings and
/// anchor-watch state, in one SQLite database (WAL mode, foreign keys on).
///
/// All database access is confined to this actor. Several stores may open the same file (each has its
/// own connection; SQLite's locking and the busy timeout arbitrate), but one per process is the norm.
public actor PersistenceStore {
    /// Opening options.
    public struct Options: Sendable {
        /// Bounding-box index selection.
        public enum SpatialIndexPreference: Sendable, Hashable {
            /// R*Tree if the linked SQLite supports it, otherwise range indexes.
            case automatic
            /// Always range indexes (also used by tests to exercise the fallback).
            case rangeIndexOnly
        }

        public var spatialIndex: SpatialIndexPreference
        /// Run `PRAGMA quick_check` on open (linear in file size; a few ms for typical stores).
        public var integrityCheckOnOpen: Bool
        /// How long a statement waits for another connection's lock before failing.
        public var busyTimeout: Duration
        /// Source of "now" for created/modified stamps.
        public var clock: @Sendable () -> Date

        public init(spatialIndex: SpatialIndexPreference = .automatic, integrityCheckOnOpen: Bool = true,
                    busyTimeout: Duration = .seconds(5), clock: @escaping @Sendable () -> Date = { Date() }) {
            self.spatialIndex = spatialIndex
            self.integrityCheckOnOpen = integrityCheckOnOpen
            self.busyTimeout = busyTimeout
            self.clock = clock
        }
    }

    let db: SQLiteConnection
    let clock: @Sendable () -> Date
    nonisolated let feed = ChangeFeed()
    var pendingChanges: [StoreChange] = []
    /// Tracks whose next append must start a new segment (set by ``resumeRecording(_:)``).
    var segmentBreakPending: Set<UUID> = []

    /// What happened while opening.
    public nonisolated let openReport: OpenReport
    /// The structure answering bounding-box queries.
    public nonisolated var spatialIndex: SpatialIndexKind { openReport.spatialIndex }

    /// Opens (creating if needed) the store at `url`.
    ///
    /// A damaged file is never fatal: it is moved aside (see ``OpenReport/recoveredCorruptFile``) and a
    /// fresh database is created. A file from a newer app version throws
    /// ``PersistenceError/schemaTooNew(found:supported:)`` and is left untouched.
    public init(url: URL, options: Options = Options()) throws(PersistenceError) {
        (db, openReport) = try Self.open(path: url.path, url: url, options: options, migrations: Schema.migrations)
        clock = options.clock
    }

    /// An in-memory store (for previews and tests).
    public init(inMemoryWith options: Options = Options()) throws(PersistenceError) {
        (db, openReport) = try Self.open(path: ":memory:", url: nil, options: options, migrations: Schema.migrations)
        clock = options.clock
    }

    /// Test hook: open with a custom migration list.
    init(url: URL, options: Options, migrations: [Migration]) throws(PersistenceError) {
        (db, openReport) = try Self.open(path: url.path, url: url, options: options, migrations: migrations)
        clock = options.clock
    }

    deinit {
        feed.finishAll()
    }

    /// Closes the connection and ends all change streams. Later calls throw ``PersistenceError/closed``.
    public func close() {
        db.close()
        feed.finishAll()
    }

    // MARK: Change feed

    /// A stream of committed changes to the given kinds of entity. Each subscriber gets its own stream;
    /// cancel the consuming task (or drop the stream) to unsubscribe. Buffers the newest 512 changes.
    public nonisolated func changes(_ kinds: Set<EntityKind>) -> AsyncStream<StoreChange> {
        feed.stream(for: kinds)
    }

    /// A stream of committed changes to one kind of entity.
    public nonisolated func changes(of kind: EntityKind) -> AsyncStream<StoreChange> {
        feed.stream(for: [kind])
    }

    // MARK: Opening

    private static func open(path: String, url: URL?, options: Options,
                             migrations: [Migration]) throws(PersistenceError) -> (SQLiteConnection, OpenReport) {
        let timeout = Int32(clamping: options.busyTimeout.components.seconds * 1000
                            + options.busyTimeout.components.attoseconds / 1_000_000_000_000_000)
        var recovered: URL?
        var reason: String?
        var conn: SQLiteConnection
        do {
            conn = try connect(path: path, timeout: timeout, check: options.integrityCheckOnOpen,
                               supportedVersion: migrations.count)
        } catch let failure as CorruptionDetected {
            guard let url else { throw .corrupt(failure.reason) }
            reason = failure.reason
            recovered = try setAside(url)
            do {
                conn = try connect(path: path, timeout: timeout, check: false, supportedVersion: migrations.count)
            } catch {
                throw PersistenceError.wrap(error)
            }
        } catch {
            throw PersistenceError.wrap(error)
        }

        let outcome: Migrator.Outcome
        do {
            outcome = try Migrator.migrate(conn, migrations: migrations)
        } catch {
            conn.close()
            throw PersistenceError.wrap(error)
        }
        do {
            let wantRTree = options.spatialIndex == .automatic && conn.supportsRTree()
            let kind: SpatialIndexKind = wantRTree ? .rtree : .rangeIndex
            // The spatial side tables reference migrated tables, so only configure them once those exist.
            if outcome.to >= 1 {
                try SpatialIndex.configure(conn, kind: kind, forceRebuild: outcome.didMigrate)
            }
            let interrupted = outcome.to >= 1
                ? try conn.query("SELECT id FROM track WHERE state <> 0 ORDER BY created_at") { try $0.uuid(0) }
                : []
            let report = OpenReport(databaseURL: url, recoveredCorruptFile: recovered, corruptionReason: reason,
                                    schemaVersionBefore: outcome.from, schemaVersionAfter: outcome.to,
                                    spatialIndex: kind, sqliteVersion: SQLiteConnection.libraryVersion,
                                    interruptedRecordings: interrupted)
            return (conn, report)
        } catch {
            conn.close()
            throw PersistenceError.wrap(error)
        }
    }

    private struct CorruptionDetected: Error { let reason: String }

    /// Opens and configures a connection, throwing `CorruptionDetected` if the file is damaged.
    private static func connect(path: String, timeout: Int32, check: Bool, supportedVersion: Int) throws -> SQLiteConnection {
        let conn = try SQLiteConnection(path: path, busyTimeoutMilliseconds: timeout)
        do {
            // The first statements read the header and schema: a non-database or damaged file fails here.
            _ = try conn.scalarInt("SELECT count(*) FROM sqlite_master")
            // Refuse a newer schema before changing anything in the file (switching to WAL rewrites the header).
            let found = try Migrator.userVersion(conn)
            if found > supportedVersion {
                conn.close()
                throw PersistenceError.schemaTooNew(found: found, supported: supportedVersion)
            }
            _ = try conn.queryFirst("PRAGMA journal_mode = WAL") { $0.text(0) }
            try conn.execute("PRAGMA synchronous = NORMAL")
            try conn.execute("PRAGMA foreign_keys = ON")
            if check {
                let rows = try conn.query("PRAGMA quick_check") { $0.text(0) }
                if rows != ["ok"] {
                    conn.close()
                    throw CorruptionDetected(reason: rows.prefix(5).joined(separator: "; "))
                }
            }
            return conn
        } catch let f as SQLiteFailure where f.indicatesCorruption {
            conn.close()
            throw CorruptionDetected(reason: f.message)
        }
    }

    /// Moves a damaged database and its WAL/SHM side files aside; returns the new main-file URL.
    private static func setAside(_ url: URL) throws(PersistenceError) -> URL {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let suffix = ".corrupt-\(f.string(from: Date()))-\(UUID().uuidString.prefix(8))"
        let dest = URL(fileURLWithPath: url.path + suffix)
        do {
            try fm.moveItem(at: url, to: dest)
            for side in ["-wal", "-shm", "-journal"] {
                let src = URL(fileURLWithPath: url.path + side)
                if fm.fileExists(atPath: src.path) {
                    try fm.moveItem(at: src, to: URL(fileURLWithPath: dest.path + side))
                }
            }
        } catch {
            throw .corrupt("damaged database could not be moved aside: \(error)")
        }
        return dest
    }

    // MARK: Transaction helpers

    /// Runs `body` in a write transaction and publishes the changes it recorded after commit.
    func write<T>(_ body: () throws -> T) throws(PersistenceError) -> T {
        guard db.isOpen else { throw .closed }
        do {
            let r = try db.transaction(body)
            if db.transactionDepth == 0 {
                let changes = pendingChanges
                pendingChanges = []
                feed.publish(changes)
            }
            return r
        } catch {
            if db.transactionDepth == 0 { pendingChanges = [] }
            throw PersistenceError.wrap(error)
        }
    }

    /// Runs a read. (WAL readers see a consistent snapshot per statement; multi-statement reads that need
    /// one snapshot use ``readTransaction(_:)``.)
    func read<T>(_ body: () throws -> T) throws(PersistenceError) -> T {
        guard db.isOpen else { throw .closed }
        do { return try body() } catch { throw PersistenceError.wrap(error) }
    }

    /// Runs several reads against one snapshot.
    func readTransaction<T>(_ body: () throws -> T) throws(PersistenceError) -> T {
        guard db.isOpen else { throw .closed }
        if db.transactionDepth > 0 { return try read(body) }
        do {
            try db.execute("BEGIN DEFERRED")
            defer { try? db.execute("COMMIT") }
            return try body()
        } catch {
            throw PersistenceError.wrap(error)
        }
    }

    func record(_ kind: EntityKind, _ op: StoreChange.Operation, ids: [UUID] = [], keys: [String] = []) {
        pendingChanges.append(StoreChange(kind: kind, operation: op, ids: ids, keys: keys))
    }

    func now() -> Date { clock() }

    /// Runs `PRAGMA quick_check` now. Returns "ok" or the problems found.
    public func checkIntegrity() throws(PersistenceError) -> [String] {
        try read { try db.query("PRAGMA quick_check") { $0.text(0) } }
    }

    /// Current schema version.
    public func schemaVersion() throws(PersistenceError) -> Int {
        try read { try Migrator.userVersion(db) }
    }

    /// Diagnostics/test hook: an integer from a read-only query.
    func scalar(_ sql: String, _ bindings: [SQLValue] = []) throws(PersistenceError) -> Int64? {
        try read { try db.scalarInt(sql, bindings) }
    }

    /// Writes the WAL back into the main file (e.g. when the app moves to the background).
    public func checkpoint() throws(PersistenceError) {
        try read { try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    }
}

// MARK: - Shared validation

extension PersistenceStore {
    static func validate(_ c: Coordinate, _ what: @autoclosure () -> String) throws(PersistenceError) {
        guard c.isValid else { throw .invalidArgument("\(what()) has an invalid coordinate \(c)") }
    }
}
