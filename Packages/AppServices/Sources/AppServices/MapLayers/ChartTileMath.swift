import ChartKit
import Foundation

/// Web Mercator tile arithmetic for map engines that ask the app for chart tiles one by one (MapKit's
/// `MKTileOverlay` on the Mac). MapLibre does all of this itself through its `mbtiles://` file source.
public enum ChartTileMath {
    /// An XYZ tile address (y = 0 at the north, as map engines and ChartKit's `MBTilesReader.tile(zoom:x:y:)` use).
    public struct Tile: Sendable, Equatable, Hashable {
        public var zoom: Int
        public var x: Int
        public var y: Int

        public init(zoom: Int, x: Int, y: Int) {
            self.zoom = zoom
            self.x = x
            self.y = y
        }

        public var isValid: Bool {
            guard zoom >= 0, zoom <= 30 else { return false }
            let count: Int = 1 << zoom
            return x >= 0 && x < count && y >= 0 && y < count
        }
    }

    /// Where to get the image for a requested tile: the tile itself, or (above the package's highest zoom) the
    /// part of an ancestor tile that covers it, to be scaled up. `cropX`, `cropY` and `cropSize` are fractions
    /// of the source tile (0...1, measured from its top-left corner).
    public struct Source: Sendable, Equatable {
        public var tile: Tile
        public var cropX: Double
        public var cropY: Double
        public var cropSize: Double

        public var isWholeTile: Bool { cropSize >= 1 }
    }

    /// The source for `tile` given the package's highest zoom; nil for an invalid address.
    public static func source(for tile: Tile, maxZoom: Int) -> Source? {
        guard tile.isValid, maxZoom >= 0 else { return nil }
        if tile.zoom <= maxZoom {
            return Source(tile: tile, cropX: 0, cropY: 0, cropSize: 1)
        }
        let levels: Int = tile.zoom - maxZoom
        let factor: Int = 1 << levels
        let parent = Tile(zoom: maxZoom, x: tile.x / factor, y: tile.y / factor)
        let size: Double = 1.0 / Double(factor)
        return Source(tile: parent,
                      cropX: Double(tile.x % factor) * size,
                      cropY: Double(tile.y % factor) * size,
                      cropSize: size)
    }

    /// The geographic box a tile covers.
    public static func bounds(of tile: Tile) -> BoundingBox {
        let count: Double = Double(1 << tile.zoom)
        let west: Double = Double(tile.x) / count * 360.0 - 180.0
        let east: Double = Double(tile.x + 1) / count * 360.0 - 180.0
        let north: Double = latitude(forMercatorY: Double(tile.y) / count)
        let south: Double = latitude(forMercatorY: Double(tile.y + 1) / count)
        return BoundingBox(west: west, south: south, east: east, north: north)
    }

    /// Whether the tile overlaps `box` (touching edges count as no overlap).
    public static func tile(_ tile: Tile, overlaps box: BoundingBox) -> Bool {
        let t: BoundingBox = bounds(of: tile)
        return t.west < box.east && t.east > box.west && t.south < box.north && t.north > box.south
    }

    /// Latitude of a normalised Web Mercator y (0 at the north edge, 1 at the south edge).
    static func latitude(forMercatorY y: Double) -> Double {
        let n: Double = Double.pi * (1.0 - 2.0 * y)
        return atan(sinh(n)) * 180.0 / Double.pi
    }

    // MARK: Zoom levels

    /// MapLibre-style zoom level for a view `widthPoints` wide showing `longitudeDelta` degrees of longitude
    /// (256-point tiles: the whole world is 256 points wide at zoom 0).
    public static func zoomLevel(longitudeDelta: Double, widthPoints: Double) -> Double {
        guard longitudeDelta > 0, widthPoints > 0 else { return 0 }
        return log2(360.0 * widthPoints / (256.0 * longitudeDelta))
    }

    /// The longitude span a view `widthPoints` wide shows at `zoom` (inverse of `zoomLevel`).
    public static func longitudeDelta(zoom: Double, widthPoints: Double) -> Double {
        360.0 * widthPoints / (256.0 * pow(2.0, zoom))
    }

    // MARK: Files

    /// The file path in a ChartKit `mbtiles://` source URL (`MapLibreSources.sourceURL(forFileAt:)`), which
    /// is either the verbatim absolute path or its percent-encoded form. Nil for anything else.
    public static func filePath(fromSourceURL url: String) -> String? {
        let prefix: String = "mbtiles://"
        guard url.hasPrefix(prefix) else { return nil }
        var path: String = String(url.dropFirst(prefix.count))
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        guard path.hasPrefix("/") else { return nil }
        if path.contains("%"), let decoded = path.removingPercentEncoding {
            return decoded
        }
        return path
    }
}
