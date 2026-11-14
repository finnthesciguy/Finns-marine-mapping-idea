import Foundation
import Testing
@testable import ChartKit

@Suite struct GeometryTests {
    @Test func tmsFlip() {
        #expect(TileMath.flipRow(0, zoom: 3) == 7)
        #expect(TileMath.flipRow(7, zoom: 3) == 0)
        #expect(TileMath.flipRow(0, zoom: 0) == 0)
        #expect(TileCoordinate(zoom: 16, x: 16514, y: 27239).tmsRow == 38296)
    }

    @Test func tileForCoordinate() {
        #expect(TileMath.tile(longitude: 0, latitude: 0, zoom: 1) == TileCoordinate(zoom: 1, x: 1, y: 1))
        #expect(TileMath.tile(longitude: -180, latitude: 85, zoom: 2) == TileCoordinate(zoom: 2, x: 0, y: 0))
        #expect(TileMath.tile(longitude: 180, latitude: -90, zoom: 2) == TileCoordinate(zoom: 2, x: 3, y: 3))
        // New Orleans at z10 (reference: standard slippy-map formula).
        #expect(TileMath.tile(longitude: -90.0715, latitude: 29.9511, zoom: 10) == TileCoordinate(zoom: 10, x: 255, y: 422))
    }

    @Test func bboxParsingAndOverlap() throws {
        let b = try #require(BoundingBox(mbtilesString: "-92.457141,17.600000,-89.069253,29.333333"))
        #expect(b.west == -92.457141 && b.north == 29.333333)
        #expect(b.isValid)
        #expect(BoundingBox(mbtilesString: "1,2,3") == nil)
        #expect(BoundingBox(mbtilesString: "a,b,c,d") == nil)
        let other = BoundingBox(west: -90, south: 29, east: -88, north: 31)
        #expect(b.intersects(other))
        #expect(b.intersection(other) == BoundingBox(west: -90, south: 29, east: -89.069253, north: 29.333333))
        #expect(!b.intersects(BoundingBox(west: 0, south: 0, east: 1, north: 1)))
        #expect(!BoundingBox(west: 1, south: 0, east: 0, north: 1).isValid)
    }

    @Test func coordinateValidity() {
        #expect(TileCoordinate(zoom: 2, x: 3, y: 3).isValid)
        #expect(!TileCoordinate(zoom: 2, x: 4, y: 0).isValid)
        #expect(!TileCoordinate(zoom: -1, x: 0, y: 0).isValid)
        #expect(!TileCoordinate(zoom: 31, x: 0, y: 0).isValid)
    }
}

@Suite struct MBTilesReaderTests {
    @Test(arguments: [Fixtures.Schema.flat, .normalized])
    func readsMetadataAndTiles(schema: Fixtures.Schema) async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = try Fixtures.makeMBTiles(at: dir.file("a.mbtiles"), schema: schema)
        let reader = try MBTilesReader(url: url)

        let meta = try await reader.metadata()
        #expect(meta.name == "Test Region")
        #expect(meta.format == .png)
        #expect(meta.bounds == BoundingBox(west: -90, south: 28, east: -89, north: 29))
        #expect(meta.minZoom == 0 && meta.maxZoom == 8)
        #expect(meta.center == [-89.5, 28.5, 6])
        #expect(meta.attribution == "NOAA")
        #expect(meta.all.count == 7)

        // XYZ lookup does the TMS flip; TMS lookup is raw.
        #expect(try await reader.tile(zoom: 0, x: 0, y: 0) == Fixtures.png(1))
        #expect(try await reader.tile(zoom: 1, x: 0, y: 0) == Fixtures.png(2))
        #expect(try await reader.tile(zoom: 1, column: 0, tmsRow: 1) == Fixtures.png(2))
        #expect(try await reader.tile(zoom: 1, column: 0, tmsRow: 0) == nil)
        #expect(try await reader.tile(zoom: 1, x: 1, y: 1) == nil)

        let z8 = TileMath.tile(longitude: -89.5, latitude: 28.5, zoom: 8)
        #expect(try await reader.tile(z8) == Fixtures.png(3))

        #expect(try await reader.tileCountsByZoom() == [0: 1, 1: 1, 8: 2])
        #expect(try await reader.zoomRange() == 0...8)

        let report = try await reader.checkIntegrity(deep: true)
        #expect(report.schema == (schema == .flat ? .tilesTable : .tilesView))
        #expect(report.sampleTileFormat == .png)
        #expect(report.deepCheckPerformed)
    }

    @Test func coverage() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let reader = try MBTilesReader(url: try Fixtures.makeMBTiles(at: dir.file("a.mbtiles")))
        let near = BoundingBox(west: -89.6, south: 28.4, east: -89.4, north: 28.6)
        let far = BoundingBox(west: -95, south: 29, east: -94.5, north: 29.5)
        #expect(try await reader.hasTiles(zoom: 8, in: near))
        #expect(try await !reader.hasTiles(zoom: 8, in: far))
        #expect(try await !reader.hasTiles(zoom: 5, in: near))
        #expect(try await reader.hasTiles(zoom: 0, in: far))
        let wide = BoundingBox(west: -90, south: 28, east: -88, north: 29)
        let cov = try await reader.coverage(zoom: 8, in: wide)
        #expect(cov.present == 2)
        #expect(cov.expected >= 2)
        await #expect(throws: MBTilesError.self) { try await reader.hasTiles(zoom: 40, in: near) }
    }

    @Test func zoomRangeFallsBackToTiles() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        var meta = Fixtures.defaultMetadata
        meta["minzoom"] = nil
        meta["maxzoom"] = nil
        let reader = try MBTilesReader(url: try Fixtures.makeMBTiles(at: dir.file("a.mbtiles"), metadata: meta))
        #expect(try await reader.zoomRange() == 0...8)
    }

    @Test func invalidCoordinatesThrow() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let reader = try MBTilesReader(url: try Fixtures.makeMBTiles(at: dir.file("a.mbtiles")))
        await #expect(throws: MBTilesError.invalidTileCoordinate(zoom: 2, x: 9, y: 0)) {
            try await reader.tile(zoom: 2, x: 9, y: 0)
        }
        await #expect(throws: MBTilesError.self) { try await reader.tile(zoom: -1, column: 0, tmsRow: 0) }
    }

    @Test func closedReaderThrows() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let reader = try MBTilesReader(url: try Fixtures.makeMBTiles(at: dir.file("a.mbtiles")))
        await reader.close()
        await #expect(throws: MBTilesError.closed) { try await reader.metadata() }
    }

    @Test func concurrentReadsAreSafe() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let reader = try MBTilesReader(url: try Fixtures.makeMBTiles(at: dir.file("a.mbtiles")))
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if i % 2 == 0 { return try await reader.tile(zoom: 0, x: 0, y: 0) == Fixtures.png(1) }
                    return try await reader.tileCountsByZoom()[8] == 2
                }
            }
            for try await ok in group { #expect(ok) }
        }
    }

    // MARK: Bad files never crash

    @Test func missingFile() async throws {
        #expect(throws: MBTilesError.fileNotFound(path: "/nonexistent/x.mbtiles")) {
            _ = try MBTilesReader(url: URL(fileURLWithPath: "/nonexistent/x.mbtiles"))
        }
    }

    @Test func randomBytesAreNotSQLite() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("junk.mbtiles")
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: url)
        #expect(throws: MBTilesError.notSQLiteDatabase(path: url.path)) { _ = try MBTilesReader(url: url) }
        await #expect(throws: MBTilesError.self) { _ = try await MBTilesReader.checkIntegrity(at: url) }
        try Data().write(to: url)
        #expect(throws: MBTilesError.notSQLiteDatabase(path: url.path)) { _ = try MBTilesReader(url: url) }
    }

    @Test func truncatedDatabaseFailsCleanly() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        var tiles = Fixtures.defaultTiles
        // Enough data to span several pages so truncation removes real content.
        for x in 0..<64 { tiles.append((TileCoordinate(zoom: 6, x: x, y: 10), Data(repeating: UInt8(x), count: 3000))) }
        let good = try Fixtures.makeMBTiles(at: dir.file("good.mbtiles"), schema: .flat, tiles: tiles)
        let data = try Data(contentsOf: good)
        let cut = dir.file("cut.mbtiles")
        try data.prefix(data.count / 3).write(to: cut)
        // Either open or the checks must throw an MBTilesError — never trap.
        do {
            let reader = try MBTilesReader(url: cut)
            _ = try await reader.checkIntegrity(deep: true)
            _ = try await reader.tileCountsByZoom()
            Issue.record("truncated database passed the integrity check")
        } catch is MBTilesError {
        }
    }

    @Test func garbagePagesFailDeepCheck() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        var tiles = Fixtures.defaultTiles
        for x in 0..<64 { tiles.append((TileCoordinate(zoom: 6, x: x, y: 10), Data(repeating: UInt8(x), count: 3000))) }
        let url = try Fixtures.makeMBTiles(at: dir.file("g.mbtiles"), schema: .flat, tiles: tiles)
        var data = try Data(contentsOf: url)
        // Overwrite everything after the first page with noise.
        for i in 4096..<data.count { data[i] = UInt8(truncatingIfNeeded: i &* 131 &+ 17) }
        try data.write(to: url)
        await #expect(throws: MBTilesError.self) {
            let reader = try MBTilesReader(url: url)
            _ = try await reader.checkIntegrity(deep: true)
        }
    }

    @Test func validSQLiteButNotMBTiles() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("other.sqlite")
        let db = try SQLiteConnection(path: url.path, mode: .readWriteCreate)
        try db.execute("CREATE TABLE waypoints (name text)")
        db.close()
        await #expect(throws: MBTilesError.missingTiles) { _ = try await MBTilesReader.checkIntegrity(at: url) }
        let reader = try MBTilesReader(url: url)
        await #expect(throws: MBTilesError.missingMetadata) { _ = try await reader.metadata() }
        await #expect(throws: MBTilesError.missingTiles) { _ = try await reader.tile(zoom: 0, x: 0, y: 0) }
    }

    @Test func missingColumnsAndEmptyPackages() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("cols.mbtiles")
        let db = try SQLiteConnection(path: url.path, mode: .readWriteCreate)
        try db.execute("CREATE TABLE metadata (name text, value text)")
        try db.execute("CREATE TABLE tiles (zoom_level integer, tile_column integer, data blob)")
        db.close()
        await #expect(throws: MBTilesError.missingColumns(table: "tiles", columns: ["tile_row", "tile_data"])) {
            _ = try await MBTilesReader.checkIntegrity(at: url)
        }

        let empty = try Fixtures.makeMBTiles(at: dir.file("empty.mbtiles"), tiles: [])
        await #expect(throws: MBTilesError.noTiles) { _ = try await MBTilesReader.checkIntegrity(at: empty) }

        let noMeta = dir.file("nometa.mbtiles")
        let db2 = try SQLiteConnection(path: noMeta.path, mode: .readWriteCreate)
        try db2.execute("CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob)")
        db2.close()
        await #expect(throws: MBTilesError.missingMetadata) { _ = try await MBTilesReader.checkIntegrity(at: noMeta) }
    }

    @Test func formatMismatchIsDetected() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        var meta = Fixtures.defaultMetadata
        meta["format"] = "jpg"
        let url = try Fixtures.makeMBTiles(at: dir.file("a.mbtiles"), metadata: meta)
        await #expect(throws: MBTilesError.tileFormatMismatch(declared: .jpg, found: .png)) {
            _ = try await MBTilesReader.checkIntegrity(at: url)
        }
    }

    @Test func tileFormatSniffing() {
        #expect(TileFormat.sniff(Fixtures.png()) == .png)
        #expect(TileFormat.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpg)
        #expect(TileFormat.sniff(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBP".utf8)) == .webp)
        #expect(TileFormat.sniff(Data([0x1F, 0x8B, 8])) == .pbf)
        #expect(TileFormat.sniff(Data([1, 2, 3])) == nil)
        #expect(TileFormat(rawValue: "JPEG") == .jpg)
    }
}
