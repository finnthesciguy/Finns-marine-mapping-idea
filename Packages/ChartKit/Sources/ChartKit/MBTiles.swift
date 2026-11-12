import Foundation

/// Tile image encoding, as named by the MBTiles `format` metadata key.
/// Stored as a free string so unexpected values survive decoding.
public struct TileFormat: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        let lower = rawValue.lowercased()
        self.rawValue = lower == "jpeg" ? "jpg" : lower
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let png = TileFormat(rawValue: "png")
    public static let jpg = TileFormat(rawValue: "jpg")
    public static let webp = TileFormat(rawValue: "webp")
    public static let pbf = TileFormat(rawValue: "pbf")

    public var isRaster: Bool { self == .png || self == .jpg || self == .webp }

    /// Guesses the format from a tile's leading bytes (nil if unrecognised).
    public static func sniff(_ data: Data) -> TileFormat? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpg }
        if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x45, 0x42, 0x50] { return .webp }
        if b.count >= 2, b[0] == 0x1F, b[1] == 0x8B { return .pbf } // gzip-compressed vector tile
        return nil
    }

    public var description: String { rawValue }
}

/// Everything that can go wrong reading an MBTiles file. ChartKit never traps on bad input.
public enum MBTilesError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileNotFound(path: String)
    case notSQLiteDatabase(path: String)
    case openFailed(String)
    case missingTiles
    case missingMetadata
    case missingColumns(table: String, columns: [String])
    case noTiles
    case tileFormatMismatch(declared: TileFormat?, found: TileFormat?)
    case integrityCheckFailed(String)
    case queryFailed(String)
    case invalidTileCoordinate(zoom: Int, x: Int, y: Int)
    case closed

    public var description: String {
        switch self {
        case .fileNotFound(let p): return "MBTiles file not found at \(p)"
        case .notSQLiteDatabase(let p): return "\(p) is not an SQLite database"
        case .openFailed(let m): return "could not open MBTiles: \(m)"
        case .missingTiles: return "no `tiles` table or view"
        case .missingMetadata: return "no `metadata` table"
        case .missingColumns(let t, let c): return "`\(t)` is missing columns \(c.joined(separator: ", "))"
        case .noTiles: return "package contains no tiles"
        case .tileFormatMismatch(let d, let f):
            return "tile data is \(f?.rawValue ?? "unrecognised") but metadata says \(d?.rawValue ?? "nothing")"
        case .integrityCheckFailed(let m): return "SQLite integrity check failed: \(m)"
        case .queryFailed(let m): return "MBTiles query failed: \(m)"
        case .invalidTileCoordinate(let z, let x, let y): return "invalid tile \(z)/\(x)/\(y)"
        case .closed: return "MBTiles reader is closed"
        }
    }
}

/// Parsed MBTiles `metadata` table.
public struct MBTilesMetadata: Sendable, Equatable {
    public var name: String?
    public var format: TileFormat?
    public var bounds: BoundingBox?
    /// `center` as (longitude, latitude, zoom) when present.
    public var center: [Double]?
    public var minZoom: Int?
    public var maxZoom: Int?
    public var attribution: String?
    public var description: String?
    public var version: String?
    public var type: String?
    /// Every key/value in the table, including the ones parsed above.
    public var all: [String: String]

    public init(all: [String: String]) {
        self.all = all
        name = all["name"]
        format = all["format"].flatMap { $0.isEmpty ? nil : TileFormat(rawValue: $0) }
        bounds = all["bounds"].flatMap(BoundingBox.init(mbtilesString:))
        center = all["center"].map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        minZoom = all["minzoom"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        maxZoom = all["maxzoom"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        attribution = all["attribution"]
        description = all["description"]
        version = all["version"]
        type = all["type"]
    }
}

/// How the package stores its tiles.
public enum MBTilesSchema: String, Sendable, Equatable {
    /// `tiles` is a plain table.
    case tilesTable
    /// `tiles` is a view (typically over `map` + `images`, as in NOAA's NCDS packages).
    case tilesView
}

/// Result of a successful integrity check.
public struct MBTilesIntegrityReport: Sendable, Equatable {
    public var schema: MBTilesSchema
    public var metadata: MBTilesMetadata
    /// Format sniffed from one sample tile.
    public var sampleTileFormat: TileFormat?
    /// True when SQLite's `quick_check` was also run (and passed).
    public var deepCheckPerformed: Bool
}

/// Read-only access to one MBTiles package. An actor, so it is safe to share across tasks;
/// the underlying SQLite handle is only ever touched from the actor's executor.
public actor MBTilesReader {
    public nonisolated let url: URL
    private var connection: SQLiteConnection?
    private var cachedMetadata: MBTilesMetadata?

    /// Opens the file read-only. Throws `MBTilesError` for a missing, non-SQLite or unreadable file.
    /// Opening does not prove the schema; call `checkIntegrity()` for that.
    public init(url: URL) throws {
        self.url = url
        self.connection = try MBTilesReader.openConnection(url)
    }

    public func close() {
        connection?.close()
        connection = nil
    }

    // MARK: Metadata

    public func metadata() throws -> MBTilesMetadata {
        if let cachedMetadata { return cachedMetadata }
        let db = try open()
        let rows: [(String, String)]
        do {
            rows = try db.query("SELECT name, value FROM metadata") { stmt in
                (stmt.text(0) ?? "", stmt.text(1) ?? "")
            }
        } catch let e as SQLiteError {
            throw Self.classify(e, missing: .missingMetadata)
        }
        var dict: [String: String] = [:]
        for (k, v) in rows where !k.isEmpty { dict[k] = v }
        let meta = MBTilesMetadata(all: dict)
        cachedMetadata = meta
        return meta
    }

    /// Min/max zoom from metadata, falling back to the tile table when metadata lacks them.
    public func zoomRange() throws -> ClosedRange<Int>? {
        let meta = try metadata()
        if let lo = meta.minZoom, let hi = meta.maxZoom, lo <= hi { return lo...hi }
        let rows = try run("SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles") { stmt -> (Int, Int)? in
            if stmt.isNull(0) || stmt.isNull(1) { return nil }
            return (Int(stmt.int(0)), Int(stmt.int(1)))
        }
        guard let pair = rows.first ?? nil else { return nil }
        return pair.0...pair.1
    }

    // MARK: Tiles

    /// Tile data for an XYZ address (ChartKit performs the TMS row flip). Nil when absent.
    public func tile(_ coordinate: TileCoordinate) throws -> Data? {
        guard coordinate.isValid else {
            throw MBTilesError.invalidTileCoordinate(zoom: coordinate.zoom, x: coordinate.x, y: coordinate.y)
        }
        return try tile(zoom: coordinate.zoom, column: coordinate.x, tmsRow: coordinate.tmsRow)
    }

    public func tile(zoom: Int, x: Int, y: Int) throws -> Data? {
        try tile(TileCoordinate(zoom: zoom, x: x, y: y))
    }

    /// Tile data addressed exactly as stored in MBTiles (TMS rows, y = 0 at the south).
    public func tile(zoom: Int, column: Int, tmsRow: Int) throws -> Data? {
        guard TileCoordinate(zoom: zoom, x: column, y: tmsRow).isValid else {
            throw MBTilesError.invalidTileCoordinate(zoom: zoom, x: column, y: tmsRow)
        }
        let rows = try run(
            "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1",
            [.int(Int64(zoom)), .int(Int64(column)), .int(Int64(tmsRow))]
        ) { $0.blob(0) }
        return rows.first ?? nil
    }

    /// Number of tiles at each zoom level present in the package.
    public func tileCountsByZoom() throws -> [Int: Int] {
        let rows = try run("SELECT zoom_level, COUNT(*) FROM tiles GROUP BY zoom_level") {
            (Int($0.int(0)), Int($0.int(1)))
        }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    /// True if the package has at least one tile at `zoom` intersecting `box`.
    public func hasTiles(zoom: Int, in box: BoundingBox) throws -> Bool {
        try coverageQuery(zoom: zoom, box: box, countOnly: false) > 0
    }

    /// Tiles present at `zoom` inside `box`, and how many tiles the box spans at that zoom.
    public func coverage(zoom: Int, in box: BoundingBox) throws -> (present: Int, expected: Int) {
        guard zoom >= 0, zoom <= TileCoordinate.maximumZoom else {
            throw MBTilesError.invalidTileCoordinate(zoom: zoom, x: 0, y: 0)
        }
        let range = TileMath.tileRange(for: box, zoom: zoom)
        return (try coverageQuery(zoom: zoom, box: box, countOnly: true), range.count)
    }

    // MARK: Integrity

    /// Checks this open package. See `MBTilesReader.checkIntegrity(at:deep:)`.
    public func checkIntegrity(deep: Bool = false) throws -> MBTilesIntegrityReport {
        let db = try open()
        let schema: MBTilesSchema
        do {
            let kinds = try db.query("SELECT type FROM sqlite_master WHERE name = 'tiles' AND type IN ('table','view')") {
                $0.text(0) ?? ""
            }
            guard let kind = kinds.first else { throw MBTilesError.missingTiles }
            schema = kind == "view" ? .tilesView : .tilesTable

            let metaTables = try db.query("SELECT 1 FROM sqlite_master WHERE name = 'metadata' AND type IN ('table','view')") { _ in 1 }
            guard !metaTables.isEmpty else { throw MBTilesError.missingMetadata }

            try requireColumns(db, table: "tiles", ["zoom_level", "tile_column", "tile_row", "tile_data"])
            try requireColumns(db, table: "metadata", ["name", "value"])
        } catch let e as SQLiteError {
            throw Self.classify(e, missing: .missingTiles)
        }

        let meta = try metadata()
        let sample = try run("SELECT tile_data FROM tiles WHERE tile_data IS NOT NULL LIMIT 1") { $0.blob(0) }
        guard let first = sample.first, let data = first, !data.isEmpty else { throw MBTilesError.noTiles }
        let sniffed = TileFormat.sniff(data)
        if let declared = meta.format, declared.isRaster, sniffed != declared {
            throw MBTilesError.tileFormatMismatch(declared: declared, found: sniffed)
        }

        if deep {
            let result = try run("PRAGMA quick_check") { $0.text(0) ?? "" }
            if result.first != "ok" {
                throw MBTilesError.integrityCheckFailed(result.prefix(5).joined(separator: "; "))
            }
        }
        return MBTilesIntegrityReport(schema: schema, metadata: meta, sampleTileFormat: sniffed, deepCheckPerformed: deep)
    }

    /// Opens `url`, checks it is a valid MBTiles package (SQLite header, `tiles` table/view with the
    /// standard columns, `metadata` table, at least one tile whose bytes match the declared format)
    /// and closes it again. `deep` additionally runs SQLite `PRAGMA quick_check`, which reads the
    /// whole file (seconds for a 600 MB package).
    public static func checkIntegrity(at url: URL, deep: Bool = false) async throws -> MBTilesIntegrityReport {
        // The connection closes when the reader is released, on success or failure.
        let reader = try MBTilesReader(url: url)
        return try await reader.checkIntegrity(deep: deep)
    }

    // MARK: Internals

    private func open() throws -> SQLiteConnection {
        guard let connection else { throw MBTilesError.closed }
        return connection
    }

    private func run<T>(_ sql: String, _ bindings: [SQLiteValue] = [], map: (SQLiteStatement) throws -> T) throws -> [T] {
        let db = try open()
        do {
            return try db.query(sql, bindings, map: map)
        } catch let e as SQLiteError {
            throw Self.classify(e, missing: .missingTiles)
        }
    }

    private func coverageQuery(zoom: Int, box: BoundingBox, countOnly: Bool) throws -> Int {
        guard zoom >= 0, zoom <= TileCoordinate.maximumZoom else {
            throw MBTilesError.invalidTileCoordinate(zoom: zoom, x: 0, y: 0)
        }
        let r = TileMath.tileRange(for: box, zoom: zoom)
        // XYZ y range -> TMS row range (flip swaps min and max).
        let tmsMin = TileMath.flipRow(r.maxY, zoom: zoom)
        let tmsMax = TileMath.flipRow(r.minY, zoom: zoom)
        let sql = countOnly
            ? "SELECT COUNT(*) FROM tiles WHERE zoom_level = ? AND tile_column BETWEEN ? AND ? AND tile_row BETWEEN ? AND ?"
            : "SELECT 1 FROM tiles WHERE zoom_level = ? AND tile_column BETWEEN ? AND ? AND tile_row BETWEEN ? AND ? LIMIT 1"
        let rows = try run(sql, [.int(Int64(zoom)), .int(Int64(r.minX)), .int(Int64(r.maxX)), .int(Int64(tmsMin)), .int(Int64(tmsMax))]) {
            Int($0.int(0))
        }
        return rows.first ?? 0
    }

    private func requireColumns(_ db: SQLiteConnection, table: String, _ required: [String]) throws {
        let cols = Set(try db.query("PRAGMA table_info(\(table))") { ($0.text(1) ?? "").lowercased() })
        let missing = required.filter { !cols.contains($0) }
        if !missing.isEmpty { throw MBTilesError.missingColumns(table: table, columns: missing) }
    }

    private static func openConnection(_ url: URL) throws -> SQLiteConnection {
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw MBTilesError.fileNotFound(path: path)
        }
        // Check the 16-byte SQLite header ourselves so a random file gives a clear error.
        guard let handle = FileHandle(forReadingAtPath: path) else { throw MBTilesError.openFailed("unreadable file \(path)") }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        guard header == Data("SQLite format 3\0".utf8) else { throw MBTilesError.notSQLiteDatabase(path: path) }
        do {
            let db = try SQLiteConnection(path: path, mode: .readOnly)
            // Touch the schema now so a corrupt file fails here rather than on first use.
            _ = try db.query("SELECT COUNT(*) FROM sqlite_master") { $0.int(0) }
            return db
        } catch let e as SQLiteError {
            if e.code == 26 /* SQLITE_NOTADB */ { throw MBTilesError.notSQLiteDatabase(path: path) }
            throw MBTilesError.openFailed(e.description)
        }
    }

    private static func classify(_ e: SQLiteError, missing: MBTilesError) -> MBTilesError {
        if e.message.contains("no such table") { return missing }
        if e.code == 11 /* SQLITE_CORRUPT */ || e.code == 26 /* SQLITE_NOTADB */ {
            return .integrityCheckFailed(e.description)
        }
        return .queryFailed(e.description)
    }
}
