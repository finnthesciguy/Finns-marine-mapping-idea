import Foundation
import NavCore
import Testing
@testable import Persistence

/// Fixture data written with raw SQL in the shape of each historical schema version.
///
/// To add schema v2: append the migration to `Schema.migrations`, then add an entry here for version 1's data
/// (unchanged) and one for version 2 (written in v2's shape). `migratesFromEveryHistoricalVersion` then
/// proves that a v0 file, a v1 file with data and a v2 file all open at the current version with data intact.
enum SchemaFixtures {
    struct Fixture: Sendable {
        /// Writes data into a database that is exactly at this version.
        let seed: @Sendable (SQLiteConnection) throws -> Void
        /// Checks the data after the store has migrated the file to the current version.
        let verify: @Sendable (PersistenceStore) async throws -> Void
    }

    static let waypointID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let routeID = UUID(uuidString: "21111111-2222-3333-4444-555555555555")!
    static let trackID = UUID(uuidString: "31111111-2222-3333-4444-555555555555")!

    static let byVersion: [Int: Fixture] = [
        0: Fixture(seed: { _ in }, verify: { (store: PersistenceStore) async throws in
            #expect(try await store.waypointCount() == 0)
        }),
        1: Fixture(seed: { db in
            try db.run("INSERT INTO waypoint (id, name, lat, lon, symbol, notes, created_at, modified_at) VALUES (?, 'Old WP', 27.5, -82.5, 'anchor', '', 1700000000, 1700000000)",
                       [.uuid(waypointID)])
            try db.run("INSERT INTO route (id, name, notes, created_at, modified_at) VALUES (?, 'Old route', '', 1700000000, 1700000000)",
                       [.uuid(routeID)])
            try db.run("INSERT INTO route_point (route_key, position, lat, lon) VALUES (1, 0, 27.0, -82.0), (1, 1, 27.1, -82.1)")
            let pts = syntheticTrack(count: 3, wiggle: false)
            try db.run("""
                INSERT INTO track (id, name, color, state, start_time, end_time, point_count, segment_count, distance_m,
                    duration_s, min_lat, max_lat, min_lon, max_lon, created_at, modified_at)
                VALUES (?, 'Old track', '#FF0000', 1, ?, ?, 3, 1, 6, 2, 27.6, 27.6, -82.7, -82.69, 1700000000, 1700000000)
                """, [.uuid(trackID), .date(pts[0].timestamp!), .date(pts[2].timestamp!)])
            try db.run("INSERT INTO track_chunk (track_key, seq, segment, point_count, data) VALUES (1, 0, 0, 3, ?)",
                       [.blob(TrackPointCodec.encode(pts))])
            try db.run("INSERT INTO setting (name, value, modified_at) VALUES ('map.orientation', ?, 1700000000)",
                       [.blob(Data(#"{"v":"courseUp"}"#.utf8))])
        }, verify: { (store: PersistenceStore) async throws in
            let w = try #require(try await store.waypoint(waypointID))
            #expect(w.name == "Old WP")
            #expect(w.symbol == "anchor")
            #expect(try await store.route(routeID)?.points.count == 2)
            #expect(try await store.trackPoints(trackID).flatMap { $0 }.count == 3)
            #expect(store.openReport.interruptedRecordings == [trackID])
            #expect(try await store.setting(.mapOrientation) == .courseUp)
            // The spatial index was (re)built from the migrated tables.
            let box = BoundingBox(south: 27, west: -83, north: 28, east: -82)
            #expect(try await store.waypoints(in: box).map(\.id) == [waypointID])
            #expect(try await store.tracks(in: box).map(\.id) == [trackID])
        }),
    ]

    /// Creates a database file at exactly `version` (by applying the frozen migrations 1...version) and seeds it.
    static func makeDatabase(at url: URL, version: Int, migrations: [Migration] = Schema.migrations) throws {
        let db = try SQLiteConnection(path: url.path)
        defer { db.close() }
        try Migrator.migrate(db, migrations: Array(migrations.prefix(version)))
        #expect(try Migrator.userVersion(db) == version)
        try byVersion[version]?.seed(db)
    }
}

@Suite("Schema migrations")
struct MigrationTests {
    @Test func everyVersionHasAFixture() {
        for v in 0...Schema.currentVersion {
            #expect(SchemaFixtures.byVersion[v] != nil, "add a SchemaFixtures entry for schema version \(v)")
        }
    }

    @Test(arguments: Array(0...Schema.currentVersion))
    func migratesFromEveryHistoricalVersion(_ version: Int) async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("v\(version).sqlite")
        try SchemaFixtures.makeDatabase(at: url, version: version)
        for kind in [PersistenceStore.Options.SpatialIndexPreference.automatic, .rangeIndexOnly] {
            let store = try PersistenceStore(url: url, options: .init(spatialIndex: kind))
            #expect(store.openReport.schemaVersionBefore == (kind == .automatic ? version : Schema.currentVersion))
            #expect(store.openReport.schemaVersionAfter == Schema.currentVersion)
            #expect(try await store.schemaVersion() == Schema.currentVersion)
            #expect(try await store.checkIntegrity() == ["ok"])
            try await SchemaFixtures.byVersion[version]!.verify(store)
            await store.close()
        }
    }

    @Test func refusesNewerSchemaAndLeavesFileUntouched() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("future.sqlite")
        try SchemaFixtures.makeDatabase(at: url, version: Schema.currentVersion)
        do {
            let db = try SQLiteConnection(path: url.path)
            try db.execute("PRAGMA user_version = \(Schema.currentVersion + 5)")
            db.close()
        }
        let before = try Data(contentsOf: url)
        #expect(throws: PersistenceError.schemaTooNew(found: Schema.currentVersion + 5, supported: Schema.currentVersion)) {
            _ = try PersistenceStore(url: url)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(dir.contents.allSatisfy { !$0.contains("corrupt") })
    }

    // MARK: Synthetic history: proves the migrator itself on a schema change of the kind v2 will need.

    /// v1 of a synthetic app: a table with a combined "position" text column.
    static let syntheticV1 = Migration(version: 1, name: "synthetic-v1") { db in
        try db.execute("""
            CREATE TABLE place (key INTEGER PRIMARY KEY, name TEXT NOT NULL, position TEXT NOT NULL);
            CREATE TABLE visit (place_key INTEGER NOT NULL REFERENCES place(key) ON DELETE CASCADE, at REAL NOT NULL);
            """)
    }

    /// v2: splits "position" into lat/lon by rebuilding the table (the 12-step procedure), keeping keys so
    /// the foreign keys from `visit` stay valid.
    static let syntheticV2 = Migration(version: 2, name: "split-position") { db in
        try db.execute("""
            CREATE TABLE place_new (key INTEGER PRIMARY KEY, name TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL);
            INSERT INTO place_new (key, name, lat, lon)
                SELECT key, name,
                       CAST(substr(position, 1, instr(position, ',') - 1) AS REAL),
                       CAST(substr(position, instr(position, ',') + 1) AS REAL)
                FROM place;
            DROP TABLE place;
            ALTER TABLE place_new RENAME TO place;
            """)
    }

    /// v3 that fails half-way, to prove a failed step is rolled back completely.
    static let failingV3 = Migration(version: 3, name: "broken") { db in
        try db.execute("ALTER TABLE place ADD COLUMN depth REAL")
        try db.execute("UPDATE place SET depth = 1")
        try db.execute("THIS IS NOT SQL")
    }

    @Test func syntheticOlderSchemaMigratesWithDataIntact() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("synthetic.sqlite")
        do {
            let db = try SQLiteConnection(path: url.path)
            try Migrator.migrate(db, migrations: [Self.syntheticV1])
            try db.execute("""
                INSERT INTO place (name, position) VALUES ('Egmont', '27.6,-82.76'), ('Venice', '27.1,-82.46');
                INSERT INTO visit (place_key, at) VALUES (1, 1), (2, 2), (2, 3);
                """)
            db.close()
        }
        let db = try SQLiteConnection(path: url.path)
        defer { db.close() }
        let outcome = try Migrator.migrate(db, migrations: [Self.syntheticV1, Self.syntheticV2])
        #expect(outcome == Migrator.Outcome(from: 1, to: 2))
        let rows = try db.query("SELECT name, lat, lon FROM place ORDER BY key") { ($0.text(0), $0.double(1), $0.double(2)) }
        #expect(rows.map(\.0) == ["Egmont", "Venice"])
        #expect(rows[0].1 == 27.6 && rows[0].2 == -82.76)
        #expect(try db.scalarInt("SELECT count(*) FROM visit JOIN place ON place.key = visit.place_key") == 3)
        #expect(try db.query("PRAGMA foreign_key_check") { _ in 1 }.isEmpty)
        #expect(try db.scalarInt("PRAGMA foreign_keys") == 1)
        // Running again is a no-op.
        #expect(try Migrator.migrate(db, migrations: [Self.syntheticV1, Self.syntheticV2]).didMigrate == false)
    }

    @Test func failedMigrationRollsBackThatStep() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let db = try SQLiteConnection(path: dir.file("f.sqlite").path)
        defer { db.close() }
        try Migrator.migrate(db, migrations: [Self.syntheticV1])
        try db.execute("INSERT INTO place (name, position) VALUES ('A', '1,2')")
        #expect(throws: PersistenceError.self) {
            try Migrator.migrate(db, migrations: [Self.syntheticV1, Self.syntheticV2, Self.failingV3])
        }
        // v2 committed, v3 rolled back entirely (no depth column), data intact.
        #expect(try Migrator.userVersion(db) == 2)
        let cols = try db.query("PRAGMA table_info(place)") { $0.text(1) }
        #expect(cols == ["key", "name", "lat", "lon"])
        #expect(try db.scalarInt("SELECT count(*) FROM place") == 1)
    }

    @Test func migrationThatBreaksForeignKeysIsRejected() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let db = try SQLiteConnection(path: dir.file("fk.sqlite").path)
        defer { db.close() }
        try Migrator.migrate(db, migrations: [Self.syntheticV1])
        try db.execute("INSERT INTO place (name, position) VALUES ('A', '1,2'); INSERT INTO visit VALUES (1, 0);")
        let dropsParent = Migration(version: 2, name: "drop-parent") { db in try db.execute("DELETE FROM place") }
        #expect(throws: PersistenceError.self) { try Migrator.migrate(db, migrations: [Self.syntheticV1, dropsParent]) }
        #expect(try Migrator.userVersion(db) == 1)
        #expect(try db.scalarInt("SELECT count(*) FROM place") == 1)
    }
}
