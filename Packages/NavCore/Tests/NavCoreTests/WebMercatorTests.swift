import Foundation
import Testing
@testable import NavCore

@Suite("Web Mercator tiles")
struct WebMercatorTests {
    // Tile indices computed by hand from the OSM slippy-map formulae:
    // x = ⌊(λ + 180)/360 · 2^z⌋, y = ⌊(1 − asinh(tan φ)/π)/2 · 2^z⌋.
    @Test(arguments: [
        (27.95, -82.46, 10, 277, 429),       // Tampa
        (27.7676, -82.6403, 14, 4430, 6875), // St Petersburg
        (30.4213, -87.2169, 12, 1055, 1684), // Pensacola
        (29.3013, -94.7977, 8, 60, 106),     // Galveston
        (-33.8688, 151.2093, 12, 3768, 2457),// Sydney (southern/eastern hemispheres)
        (0.0, 0.0, 1, 1, 1),
        (10.0, -10.0, 0, 0, 0),
    ])
    func tileForCoordinate(_ c: (Double, Double, Int, Int, Int)) {
        #expect(WebMercator.tile(for: Coordinate(latitude: c.0, longitude: c.1), zoom: c.2) == TileID(z: c.2, x: c.3, y: c.4))
    }

    @Test func pixelPositions() {
        // Tampa at z = 10: global pixel (71 026.460, 109 860.609).
        let p = WebMercator.pixel(for: Coordinate(latitude: 27.95, longitude: -82.46), zoom: 10)
        #expect(close(p.x, 71_026.460_444, 1e-3) && close(p.y, 109_860.608_953, 1e-3))
        let back = WebMercator.coordinate(for: p, zoom: 10)
        #expect(close(back.latitude, 27.95, 1e-10) && close(back.longitude, -82.46, 1e-10))
        // World centre and corners at z = 0.
        let centre = WebMercator.pixel(for: Coordinate(latitude: 0, longitude: 0), zoom: 0)
        #expect(close(centre.x, 128, 1e-9) && close(centre.y, 128, 1e-9))
        let topLeft = WebMercator.coordinate(for: MercatorPixel(x: 0, y: 0), zoom: 0)
        #expect(close(topLeft.latitude, WebMercator.maximumLatitude, 1e-9) && topLeft.longitude == -180)
        // 512-px tiles double the pixel coordinates.
        let p512 = WebMercator.pixel(for: Coordinate(latitude: 27.95, longitude: -82.46), zoom: 10, tileSize: 512)
        #expect(close(p512.x, 2 * p.x, 1e-6))
    }

    @Test func tmsFlip() {
        let t = TileID(z: 10, x: 277, y: 429)
        #expect(t.tmsY == 594)                    // 2^10 − 1 − 429
        #expect(TileID(z: 10, x: 277, tmsY: 594) == t)
        #expect(TileID(z: 0, x: 0, y: 0).tmsY == 0)
        #expect(WebMercator.flipY(WebMercator.flipY(12_345, zoom: 16), zoom: 16) == 12_345)
    }

    @Test func tileBounds() {
        let b = WebMercator.bounds(of: TileID(z: 10, x: 277, y: 429))
        #expect(close(b.west, -82.617_187_5, 1e-12) && close(b.east, -82.265_625, 1e-12))
        #expect(close(b.south, 27.683_528_083_787_76, 1e-9) && close(b.north, 27.994_401_411_046_15, 1e-9))
        let world = WebMercator.bounds(of: TileID(z: 0, x: 0, y: 0))
        #expect(close(world.north, 85.051_128_78, 1e-8) && close(world.south, -85.051_128_78, 1e-8))
        #expect(world.west == -180 && world.east == 180)
    }

    @Test func tilesCoveringBox() {
        // Tampa Bay box at z = 10: x 275.91…277.62 and y 428.98…430.59 → 3 × 3 tiles.
        let box = BoundingBox(south: 27.5, west: -83, north: 28, east: -82.4)
        let tiles = WebMercator.tiles(covering: box, zoom: 10)
        #expect(tiles.count == 9 && WebMercator.tileCount(covering: box, zoom: 10) == 9)
        #expect(tiles.first == TileID(z: 10, x: 275, y: 428) && tiles.last == TileID(z: 10, x: 277, y: 430))
        // A tile's own bounds are covered by exactly that tile (shared edges don't leak).
        let t = TileID(z: 12, x: 1100, y: 1700)
        #expect(WebMercator.tiles(covering: WebMercator.bounds(of: t), zoom: 12) == [t])
        // Zoom 0 always one tile; a single point gives one tile; the whole world at z=2 is 16.
        #expect(WebMercator.tiles(covering: box, zoom: 0) == [TileID(z: 0, x: 0, y: 0)])
        let pt = BoundingBox(south: 27.95, west: -82.46, north: 27.95, east: -82.46)
        #expect(WebMercator.tiles(covering: pt, zoom: 10) == [TileID(z: 10, x: 277, y: 429)])
        #expect(WebMercator.tileCount(covering: BoundingBox(south: -90, west: -180, north: 90, east: 180), zoom: 2) == 16)
    }

    @Test func extremesDoNotCrash() {
        #expect(WebMercator.tile(for: Coordinate(latitude: 90, longitude: 180), zoom: 3) == TileID(z: 3, x: 7, y: 0))
        #expect(WebMercator.tile(for: Coordinate(latitude: -90, longitude: -180), zoom: 3) == TileID(z: 3, x: 0, y: 7))
        #expect(WebMercator.tile(for: Coordinate(latitude: .nan, longitude: .nan), zoom: 3).isValid)
        #expect(WebMercator.tile(for: Coordinate(latitude: 0, longitude: 0), zoom: 99).z == 30)
        #expect(WebMercator.tile(for: Coordinate(latitude: 0, longitude: 0), zoom: -4) == TileID(z: 0, x: 0, y: 0))
        let wrap = BoundingBox(south: -1, west: 179, north: 1, east: -179)
        #expect(WebMercator.tileCount(covering: wrap, zoom: 2) == 4 * 2)
        // Reversed latitudes are tolerated.
        #expect(WebMercator.tileCount(covering: BoundingBox(south: 28, west: -83, north: 27.5, east: -82.4), zoom: 10) == 9)
    }

    @Test func tileHierarchyAndResolution() {
        let t = TileID(z: 10, x: 277, y: 429)
        #expect(t.parent == TileID(z: 9, x: 138, y: 214))
        #expect(t.children.allSatisfy { $0.parent == t })
        #expect(TileID(z: 0, x: 0, y: 0).parent == nil)
        #expect(!TileID(z: 2, x: 4, y: 0).isValid)
        #expect(t.description == "10/277/429")
        // Equatorial ground resolution at z = 0 with 256-px tiles: 156 543.034 m/px.
        #expect(close(WebMercator.metersPerPixel(latitude: 0, zoom: 0), 156_543.033_928, 1e-5))
    }
}
