import Foundation

/// A WGS84 longitude/latitude box. JSON form: `{"west":..,"south":..,"east":..,"north":..}`.
public struct BoundingBox: Codable, Hashable, Sendable, CustomStringConvertible {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    /// Parses the MBTiles / TileJSON `bounds` string form `"west,south,east,north"`.
    public init?(mbtilesString: String) {
        let parts = mbtilesString.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let w = parts[0], let s = parts[1], let e = parts[2], let n = parts[3] else { return nil }
        self.init(west: w, south: s, east: e, north: n)
    }

    /// `[west, south, east, north]`, the TileJSON / MapLibre array form.
    public var array: [Double] { [west, south, east, north] }

    public var isValid: Bool {
        west.isFinite && south.isFinite && east.isFinite && north.isFinite
            && west >= -180 && east <= 180 && south >= -90 && north <= 90
            && west < east && south < north
    }

    /// Area in square degrees; only used to rank boxes against each other.
    public var areaDegrees: Double { max(0, east - west) * max(0, north - south) }

    public func intersects(_ other: BoundingBox) -> Bool {
        west < other.east && other.west < east && south < other.north && other.south < north
    }

    public func intersection(_ other: BoundingBox) -> BoundingBox? {
        guard intersects(other) else { return nil }
        return BoundingBox(west: max(west, other.west), south: max(south, other.south),
                           east: min(east, other.east), north: min(north, other.north))
    }

    public func contains(longitude: Double, latitude: Double) -> Bool {
        longitude >= west && longitude <= east && latitude >= south && latitude <= north
    }

    public var description: String { "[\(west), \(south), \(east), \(north)]" }
}

/// A tile address in the XYZ (slippy map / Google) scheme, where y = 0 is the northernmost row.
public struct TileCoordinate: Hashable, Sendable, CustomStringConvertible {
    public var zoom: Int
    public var x: Int
    public var y: Int

    public init(zoom: Int, x: Int, y: Int) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    /// Maximum zoom ChartKit accepts (keeps `1 << zoom` safe).
    public static let maximumZoom = 30

    public var isValid: Bool {
        guard zoom >= 0, zoom <= Self.maximumZoom else { return false }
        let n = 1 << zoom
        return x >= 0 && x < n && y >= 0 && y < n
    }

    /// The MBTiles (TMS) row for this tile: rows count up from the south.
    public var tmsRow: Int { TileMath.flipRow(y, zoom: zoom) }

    public var description: String { "\(zoom)/\(x)/\(y)" }
}

/// An inclusive range of XYZ tiles at one zoom.
public struct TileRange: Hashable, Sendable {
    public var zoom: Int
    public var minX: Int
    public var maxX: Int
    public var minY: Int
    public var maxY: Int

    public var count: Int { (maxX - minX + 1) * (maxY - minY + 1) }
}

public enum TileMath {
    /// Converts between XYZ and TMS rows (the operation is its own inverse).
    public static func flipRow(_ row: Int, zoom: Int) -> Int { (1 << zoom) - 1 - row }

    /// Web Mercator latitude limit.
    public static let maxLatitude = 85.0511287798066

    /// XYZ tile containing a coordinate, clamped to the valid range.
    public static func tile(longitude: Double, latitude: Double, zoom: Int) -> TileCoordinate {
        let n = Double(1 << zoom)
        let lat = min(max(latitude, -maxLatitude), maxLatitude)
        let lon = min(max(longitude, -180), 180)
        let latRad = lat * .pi / 180
        var x = Int(floor((lon + 180) / 360 * n))
        var y = Int(floor((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n))
        let maxIndex = (1 << zoom) - 1
        x = min(max(x, 0), maxIndex)
        y = min(max(y, 0), maxIndex)
        return TileCoordinate(zoom: zoom, x: x, y: y)
    }

    /// XYZ tiles covering a bounding box at a zoom.
    public static func tileRange(for box: BoundingBox, zoom: Int) -> TileRange {
        let nw = tile(longitude: box.west, latitude: box.north, zoom: zoom)
        // Nudge the east/south edges inward so a box ending exactly on a tile edge does not
        // pull in the neighbouring tile.
        let epsilon = 1e-9
        let se = tile(longitude: box.east - epsilon, latitude: box.south + epsilon, zoom: zoom)
        return TileRange(zoom: zoom, minX: min(nw.x, se.x), maxX: max(nw.x, se.x),
                         minY: min(nw.y, se.y), maxY: max(nw.y, se.y))
    }
}
