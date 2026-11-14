import Foundation

/// A slippy-map tile address in the XYZ (Google/OSM) scheme: `y = 0` is the northernmost row.
public struct TileID: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    /// Zoom level (0...30).
    public var z: Int
    /// Column, 0 at 180°W, increasing east.
    public var x: Int
    /// Row in XYZ order, 0 at the top (≈85.05°N).
    public var y: Int

    /// Creates a tile id.
    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    /// Creates a tile id from a TMS row (as stored in MBTiles, `tile_row`), where row 0 is the bottom.
    public init(z: Int, x: Int, tmsY: Int) {
        self.init(z: z, x: x, y: WebMercator.flipY(tmsY, zoom: z))
    }

    /// Row in TMS order (as used by MBTiles `tile_row`): 0 at the bottom.
    public var tmsY: Int { WebMercator.flipY(y, zoom: z) }

    /// True when x and y are within range for the zoom.
    public var isValid: Bool {
        guard (0...30).contains(z) else { return false }
        let n = 1 << z
        return (0..<n).contains(x) && (0..<n).contains(y)
    }

    /// The tile one zoom level up that contains this one.
    public var parent: TileID? { z > 0 ? TileID(z: z - 1, x: x >> 1, y: y >> 1) : nil }

    /// The four tiles one zoom level down, in order NW, NE, SW, SE.
    public var children: [TileID] {
        let (cx, cy) = (x << 1, y << 1)
        return [TileID(z: z + 1, x: cx, y: cy), TileID(z: z + 1, x: cx + 1, y: cy),
                TileID(z: z + 1, x: cx, y: cy + 1), TileID(z: z + 1, x: cx + 1, y: cy + 1)]
    }

    /// `z/x/y`.
    public var description: String { "\(z)/\(x)/\(y)" }

    /// Orders by zoom, then row, then column.
    public static func < (a: TileID, b: TileID) -> Bool { (a.z, a.y, a.x) < (b.z, b.y, b.x) }
}

/// A position in global Web-Mercator pixel space at some zoom: `(0, 0)` is the top-left
/// (180°W, ≈85.05°N) and the world is `tileSize × 2^zoom` pixels square.
public struct MercatorPixel: Hashable, Sendable {
    /// Horizontal pixel coordinate, increasing east.
    public var x: Double
    /// Vertical pixel coordinate, increasing south.
    public var y: Double

    /// Creates a pixel position.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Spherical Web-Mercator (EPSG:3857) tile maths.
public enum WebMercator {
    /// Latitude limit of the projection, degrees (`atan(sinh(π))`).
    public static let maximumLatitude = 85.051_128_779_806_59
    /// Default tile size in pixels.
    public static let defaultTileSize = 256.0
    /// Highest zoom accepted by the tile functions.
    public static let maximumZoom = 30

    /// Converts between XYZ and TMS rows (the operation is its own inverse).
    public static func flipY(_ y: Int, zoom: Int) -> Int {
        let z = min(max(zoom, 0), maximumZoom)
        return (1 << z) - 1 - y
    }

    /// Normalised Mercator position of a coordinate: x and y in 0...1 with (0, 0) top-left.
    /// Latitudes are clamped to ±``maximumLatitude``; longitudes are wrapped.
    public static func normalizedPosition(of c: Coordinate) -> (x: Double, y: Double) {
        let lat = min(max(c.latitude.isFinite ? c.latitude : 0, -maximumLatitude), maximumLatitude)
        var lon = c.longitude.isFinite ? c.longitude : 0
        if lon != 180 { lon = Angle.normalizeLongitude(lon) }
        let x = (lon + 180) / 360
        let phi = Angle.radians(lat)
        let y = (1 - log(tan(phi) + 1 / cos(phi)) / .pi) / 2
        return (x, min(max(y, 0), 1))
    }

    /// Coordinate at a normalised Mercator position (inverse of ``normalizedPosition(of:)``).
    public static func coordinate(normalizedX x: Double, normalizedY y: Double) -> Coordinate {
        let lon = x * 360 - 180
        let lat = Angle.degrees(atan(sinh(.pi * (1 - 2 * y))))
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// Global pixel position of a coordinate at `zoom`.
    public static func pixel(for c: Coordinate, zoom: Double, tileSize: Double = defaultTileSize) -> MercatorPixel {
        let scale = tileSize * pow(2, zoom)
        let p = normalizedPosition(of: c)
        return MercatorPixel(x: p.x * scale, y: p.y * scale)
    }

    /// Coordinate at a global pixel position at `zoom`.
    public static func coordinate(for pixel: MercatorPixel, zoom: Double, tileSize: Double = defaultTileSize) -> Coordinate {
        let scale = tileSize * pow(2, zoom)
        return coordinate(normalizedX: pixel.x / scale, normalizedY: pixel.y / scale)
    }

    /// The XYZ tile containing a coordinate at `zoom` (clamped to 0...``maximumZoom``).
    /// Points on the east edge (180°) or south limit are placed in the last column/row.
    public static func tile(for c: Coordinate, zoom: Int) -> TileID {
        let z = min(max(zoom, 0), maximumZoom)
        let n = Double(1 << z)
        let p = normalizedPosition(of: c)
        let maxIndex = (1 << z) - 1
        let x = min(max(Int((p.x * n).rounded(.down)), 0), maxIndex)
        let y = min(max(Int((p.y * n).rounded(.down)), 0), maxIndex)
        return TileID(z: z, x: x, y: y)
    }

    /// Geographic bounds of a tile.
    public static func bounds(of tile: TileID) -> BoundingBox {
        let n = Double(1 << min(max(tile.z, 0), maximumZoom))
        let nw = coordinate(normalizedX: Double(tile.x) / n, normalizedY: Double(tile.y) / n)
        let se = coordinate(normalizedX: Double(tile.x + 1) / n, normalizedY: Double(tile.y + 1) / n)
        return BoundingBox(south: se.latitude, west: nw.longitude, north: nw.latitude, east: se.longitude)
    }

    /// Range of tile columns and rows covering a bounding box at `zoom`.
    /// A box edge lying exactly on a tile boundary does not pull in the neighbouring tile.
    /// Antimeridian-crossing boxes are treated as spanning every column.
    public static func tileRange(covering box: BoundingBox, zoom: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let z = min(max(zoom, 0), maximumZoom)
        let maxIndex = (1 << z) - 1
        let n = Double(1 << z)
        let north = max(box.north, box.south), south = min(box.north, box.south)
        let nw = normalizedPosition(of: Coordinate(latitude: north, longitude: box.west))
        let se = normalizedPosition(of: Coordinate(latitude: south, longitude: box.east))
        func clamp(_ v: Int) -> Int { min(max(v, 0), maxIndex) }
        // Snap values within floating-point noise of a tile edge onto the edge.
        func scaled(_ v: Double) -> Double {
            let t = v * n, r = t.rounded()
            return abs(t - r) < 1e-7 ? r : t
        }
        func lower(_ v: Double) -> Int { clamp(Int(scaled(v).rounded(.down))) }
        func upper(_ v: Double) -> Int {
            let t = scaled(v), f = t.rounded(.down)
            return clamp(Int(f == t ? f - 1 : f))
        }
        let x0 = lower(nw.x), y0 = lower(nw.y)
        let xr = box.crossesAntimeridian ? 0...maxIndex : x0...max(x0, upper(se.x))
        return (xr, y0...max(y0, upper(se.y)))
    }

    /// Number of tiles covering a box at `zoom`, without materialising them.
    public static func tileCount(covering box: BoundingBox, zoom: Int) -> Int {
        let r = tileRange(covering: box, zoom: zoom)
        return r.x.count * r.y.count
    }

    /// All XYZ tiles intersecting a bounding box at `zoom`, row by row from the north-west.
    ///
    /// Check ``tileCount(covering:zoom:)`` first for large boxes at high zoom.
    public static func tiles(covering box: BoundingBox, zoom: Int) -> [TileID] {
        let z = min(max(zoom, 0), maximumZoom)
        let r = tileRange(covering: box, zoom: z)
        var result: [TileID] = []
        result.reserveCapacity(r.x.count * r.y.count)
        for y in r.y {
            for x in r.x { result.append(TileID(z: z, x: x, y: y)) }
        }
        return result
    }

    /// Ground resolution at a latitude and zoom, metres per pixel (equatorial radius sphere).
    public static func metersPerPixel(latitude: Double, zoom: Double, tileSize: Double = defaultTileSize) -> Double {
        cos(Angle.radians(latitude)) * 2 * .pi * WGS84.semiMajorAxis / (tileSize * pow(2, zoom))
    }
}
