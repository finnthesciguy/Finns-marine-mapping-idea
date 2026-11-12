import Foundation

/// A numbered, forward-only schema migration. Migration `n` takes a database at `user_version == n - 1`
/// to `n`. Migrations are frozen once released: never edit one, add a new one.
struct Migration: Sendable {
    let version: Int
    let name: String
    let migrate: @Sendable (SQLiteConnection) throws -> Void
}

/// Applies migrations, each in its own transaction, following SQLite's recommended procedure for schema
/// changes (foreign-key enforcement off while migrating, `foreign_key_check` before commit).
enum Migrator {
    struct Outcome: Sendable, Hashable {
        let from: Int
        let to: Int
        var didMigrate: Bool { from != to }
    }

    static func userVersion(_ db: SQLiteConnection) throws -> Int {
        Int(try db.scalarInt("PRAGMA user_version") ?? 0)
    }

    /// Brings `db` up to the last migration in `migrations`.
    /// - Throws: ``PersistenceError/schemaTooNew(found:supported:)`` if the file is ahead of this code,
    ///   ``PersistenceError/migrationFailed(fromVersion:toVersion:reason:)`` if a step fails (that step is rolled back).
    @discardableResult
    static func migrate(_ db: SQLiteConnection, migrations: [Migration]) throws -> Outcome {
        for (i, m) in migrations.enumerated() where m.version != i + 1 {
            preconditionFailure("migrations must be numbered 1...n in order; found \(m.version) at index \(i)")
        }
        let target = migrations.count
        let start = try userVersion(db)
        if start > target { throw PersistenceError.schemaTooNew(found: start, supported: target) }
        if start == target { return Outcome(from: start, to: start) }

        try db.execute("PRAGMA foreign_keys = OFF")
        defer { try? db.execute("PRAGMA foreign_keys = ON") }
        for m in migrations[start...] {
            do {
                try db.transaction {
                    try m.migrate(db)
                    let violations = try db.query("PRAGMA foreign_key_check") { _ in 1 }.count
                    if violations > 0 { throw PersistenceError.invalidArgument("\(violations) foreign-key violations") }
                    try db.execute("PRAGMA user_version = \(m.version)")
                }
            } catch let e as SQLiteFailure where e.indicatesCorruption {
                throw e
            } catch {
                throw PersistenceError.migrationFailed(fromVersion: m.version - 1, toVersion: m.version,
                                                       reason: String(describing: error))
            }
        }
        return Outcome(from: start, to: target)
    }
}

/// The app's schema history.
enum Schema {
    static var currentVersion: Int { migrations.count }

    static let migrations: [Migration] = [
        Migration(version: 1, name: "initial", migrate: { db in try db.execute(v1) }),
    ]

    /// Version 1. Times are seconds since 1970 (REAL); UUIDs are uppercase text.
    static let v1 = """
        CREATE TABLE waypoint (
            key INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            symbol TEXT,
            notes TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL
        );
        CREATE INDEX waypoint_lat ON waypoint(lat, lon);
        CREATE INDEX waypoint_name ON waypoint(name COLLATE NOCASE);

        CREATE TABLE route (
            key INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            metadata_version INTEGER,
            metadata BLOB,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL
        );
        CREATE INDEX route_name ON route(name COLLATE NOCASE);
        CREATE TABLE route_point (
            route_key INTEGER NOT NULL REFERENCES route(key) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            name TEXT,
            PRIMARY KEY (route_key, position)
        ) WITHOUT ROWID;

        CREATE TABLE track (
            key INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            color TEXT NOT NULL,
            state INTEGER NOT NULL DEFAULT 0,
            start_time REAL,
            end_time REAL,
            point_count INTEGER NOT NULL DEFAULT 0,
            segment_count INTEGER NOT NULL DEFAULT 0,
            distance_m REAL NOT NULL DEFAULT 0,
            duration_s REAL NOT NULL DEFAULT 0,
            max_speed REAL,
            min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL
        );
        CREATE INDEX track_open ON track(state) WHERE state <> 0;
        CREATE INDEX track_bounds ON track(min_lat, max_lat);
        CREATE INDEX track_start ON track(start_time);
        -- Points are packed into chunks (see TrackPointCodec); one chunk never spans segments.
        CREATE TABLE track_chunk (
            track_key INTEGER NOT NULL REFERENCES track(key) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            segment INTEGER NOT NULL,
            point_count INTEGER NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (track_key, seq)
        ) WITHOUT ROWID;

        CREATE TABLE boat_profile (
            key INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            draft_m REAL NOT NULL,
            safety_margin_m REAL NOT NULL,
            air_draft_m REAL,
            beam_m REAL,
            cruising_speed_mps REAL,
            use_maintained_channels INTEGER NOT NULL DEFAULT 0,
            accept_unknown_clearance INTEGER NOT NULL DEFAULT 0,
            is_default INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX boat_profile_one_default ON boat_profile(is_default) WHERE is_default = 1;

        CREATE TABLE setting (
            name TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            modified_at REAL NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE anchor_watch (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            state BLOB NOT NULL,
            modified_at REAL NOT NULL
        );
        """
}

/// Which structure answers bounding-box queries.
public enum SpatialIndexKind: String, Sendable, Hashable {
    /// SQLite R*Tree virtual tables, kept in sync by triggers.
    case rtree
    /// Plain B-tree indexes on latitude ranges (used when the linked SQLite lacks R*Tree, or when forced).
    case rangeIndex
}

/// The R*Tree side tables. They are derived data, outside the migration history: created (and filled)
/// when R*Tree is available, dropped when it is not, and rebuilt after any migration.
enum SpatialIndex {
    static let create = """
        CREATE VIRTUAL TABLE IF NOT EXISTS waypoint_rtree USING rtree(key, min_lat, max_lat, min_lon, max_lon);
        CREATE VIRTUAL TABLE IF NOT EXISTS track_rtree USING rtree(key, min_lat, max_lat, min_lon, max_lon);
        CREATE TRIGGER IF NOT EXISTS waypoint_rtree_ai AFTER INSERT ON waypoint BEGIN
            INSERT OR REPLACE INTO waypoint_rtree VALUES (new.key, new.lat, new.lat, new.lon, new.lon);
        END;
        CREATE TRIGGER IF NOT EXISTS waypoint_rtree_au AFTER UPDATE OF lat, lon ON waypoint BEGIN
            INSERT OR REPLACE INTO waypoint_rtree VALUES (new.key, new.lat, new.lat, new.lon, new.lon);
        END;
        CREATE TRIGGER IF NOT EXISTS waypoint_rtree_ad AFTER DELETE ON waypoint BEGIN
            DELETE FROM waypoint_rtree WHERE key = old.key;
        END;
        CREATE TRIGGER IF NOT EXISTS track_rtree_ai AFTER INSERT ON track WHEN new.min_lat IS NOT NULL BEGIN
            INSERT OR REPLACE INTO track_rtree VALUES (new.key, new.min_lat, new.max_lat, new.min_lon, new.max_lon);
        END;
        CREATE TRIGGER IF NOT EXISTS track_rtree_au AFTER UPDATE OF min_lat, max_lat, min_lon, max_lon ON track BEGIN
            DELETE FROM track_rtree WHERE key = old.key;
            INSERT INTO track_rtree SELECT new.key, new.min_lat, new.max_lat, new.min_lon, new.max_lon
                WHERE new.min_lat IS NOT NULL;
        END;
        CREATE TRIGGER IF NOT EXISTS track_rtree_ad AFTER DELETE ON track BEGIN
            DELETE FROM track_rtree WHERE key = old.key;
        END;
        """

    static let drop = """
        DROP TRIGGER IF EXISTS waypoint_rtree_ai;
        DROP TRIGGER IF EXISTS waypoint_rtree_au;
        DROP TRIGGER IF EXISTS waypoint_rtree_ad;
        DROP TRIGGER IF EXISTS track_rtree_ai;
        DROP TRIGGER IF EXISTS track_rtree_au;
        DROP TRIGGER IF EXISTS track_rtree_ad;
        DROP TABLE IF EXISTS waypoint_rtree;
        DROP TABLE IF EXISTS track_rtree;
        """

    static let refill = """
        DELETE FROM waypoint_rtree;
        INSERT INTO waypoint_rtree SELECT key, lat, lat, lon, lon FROM waypoint;
        DELETE FROM track_rtree;
        INSERT INTO track_rtree SELECT key, min_lat, max_lat, min_lon, max_lon FROM track WHERE min_lat IS NOT NULL;
        """

    static func exists(_ db: SQLiteConnection) throws -> Bool {
        try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = 'waypoint_rtree'") ?? 0 > 0
    }

    /// Brings the side tables in line with `kind`. `forceRebuild` refills the R*Tree from the base tables.
    static func configure(_ db: SQLiteConnection, kind: SpatialIndexKind, forceRebuild: Bool) throws {
        switch kind {
        case .rtree:
            try db.transaction {
                let existed = try exists(db)
                try db.execute(create)
                if !existed || forceRebuild { try db.execute(refill) }
            }
        case .rangeIndex:
            if try exists(db) { try db.transaction { try db.execute(drop) } }
        }
    }
}
