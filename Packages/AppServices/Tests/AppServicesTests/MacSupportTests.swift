import ChartKit
import Foundation
import NavCore
import XCTest
@testable import AppServices

/// The Linux-testable parts of the Mac (Mac Catalyst) build: overlay GeoJSON read back with the MapLibre layer
/// styles as data, tile arithmetic for MapKit's tile overlay, the position state and the Mac data folder.
final class OverlayShapesTests: XCTestCase {
    /// The same text `GeoJSON.featureCollection` writes (keys sorted, `[longitude, latitude]`).
    static let waypointsJSON: String = """
    {"type":"FeatureCollection","features":[\
    {"type":"Feature","geometry":{"type":"Point","coordinates":[-82.7000000,27.6000000]},\
    "properties":{"id":"A","name":"WP 001","selected":true,"symbol":"","target":false}},\
    {"type":"Feature","geometry":{"type":"Point","coordinates":[-82.5,27.5]},\
    "properties":{"id":"B","name":"WP 002","selected":false,"symbol":"","target":true}}]}
    """

    static let legsJSON: String = """
    {"type":"FeatureCollection","features":[\
    {"type":"Feature","geometry":{"type":"LineString","coordinates":[[-82.7,27.6],[-82.6,27.7]]},\
    "properties":{"editing":false,"grade":"none","leg":0,"route":"R","state":"active"}},\
    {"type":"Feature","geometry":{"type":"LineString","coordinates":[[-82.6,27.7],[-82.5,27.8]]},\
    "properties":{"editing":true,"grade":"green","leg":1,"route":"R","state":"done"}}]}
    """

    static let tracksJSON: String = """
    {"type":"FeatureCollection","features":[\
    {"type":"Feature","geometry":{"type":"MultiLineString","coordinates":[[[-82.7,27.6],[-82.6,27.7]],[[-82.5,27.5],[-82.4,27.4],[-82.3,27.3]]]},\
    "properties":{"color":"#D12190","id":"T","live":false}},\
    {"type":"Feature","geometry":{"type":"MultiLineString","coordinates":[[[-82.0,27.0],[-82.1,27.1]]]},\
    "properties":{"color":"#D12190","id":"L","live":true}}]}
    """

    func testParsesPointsWithProperties() throws {
        let shapes: [OverlayShape] = try OverlayShapes.parse(Data(OverlayShapesTests.waypointsJSON.utf8))
        XCTAssertEqual(shapes.count, 2)
        XCTAssertEqual(shapes[0].geometry, .point(Coordinate(latitude: 27.6, longitude: -82.7)))
        XCTAssertTrue(shapes[0].flag("selected"))
        XCTAssertFalse(shapes[0].flag("target"))
        XCTAssertEqual(shapes[0].text("name"), "WP 001")
        XCTAssertEqual(shapes[0].properties["symbol"], .string(""))
        XCTAssertFalse(shapes[0].flag("missing"))
    }

    func testParsesLinesAndNumbers() throws {
        let legs: [OverlayShape] = try OverlayShapes.parse(Data(OverlayShapesTests.legsJSON.utf8))
        XCTAssertEqual(legs.count, 2)
        XCTAssertEqual(legs[1].properties["leg"], .number(1))
        XCTAssertEqual(legs[1].properties["editing"], .bool(true))
        guard case .lines(let lines) = legs[0].geometry else { return XCTFail("a line") }
        XCTAssertEqual(lines, [[Coordinate(latitude: 27.6, longitude: -82.7), Coordinate(latitude: 27.7, longitude: -82.6)]])

        let tracks: [OverlayShape] = try OverlayShapes.parse(Data(OverlayShapesTests.tracksJSON.utf8))
        guard case .lines(let parts) = tracks[0].geometry else { return XCTFail("multi line") }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].count, 3)
    }

    func testEmptyCollectionAndGarbage() throws {
        XCTAssertEqual(try OverlayShapes.parse(Data("{\"type\":\"FeatureCollection\",\"features\":[]}".utf8)), [])
        XCTAssertThrowsError(try OverlayShapes.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try OverlayShapes.parse(Data("{\"type\":\"Feature\",\"features\":[]}".utf8)))
    }

    func testRouteLegStylesFollowTheMapLibreLayers() throws {
        let legs: [OverlayShape] = try OverlayShapes.parse(Data(OverlayShapesTests.legsJSON.utf8))
        let styled: [StyledOverlayLines] = OverlayStyling.lines(legs, source: .routeLegs)
        // Leg 0: active casing + blue ("none"); leg 1: green + done (grey) + editing (orange dashes).
        XCTAssertEqual(styled.map(\.style.layerID),
                       ["gn-route-active-casing", "gn-route-none", "gn-route-green", "gn-route-done", "gn-route-editing"])
        XCTAssertEqual(styled.map(\.lines.count), [1, 1, 1, 1, 1])
        XCTAssertEqual(styled[0].style.width, 9)
        XCTAssertEqual(styled[0].style.color, .white)
        XCTAssertEqual(styled[3].style.opacity, 0.8)
        XCTAssertEqual(styled[4].style.dash, [2, 1.5])
        // Orders increase bottom to top.
        XCTAssertEqual(styled.map(\.order), styled.map(\.order).sorted())
    }

    func testTrackStylesSplitLiveAndSaved() throws {
        let tracks: [OverlayShape] = try OverlayShapes.parse(Data(OverlayShapesTests.tracksJSON.utf8))
        let styled: [StyledOverlayLines] = OverlayStyling.lines(tracks, source: .tracks)
        XCTAssertEqual(styled.map(\.style.layerID), ["gn-tracks-saved", "gn-tracks-live"])
        XCTAssertEqual(styled[0].lines.count, 2, "both parts of the saved track")
        XCTAssertEqual(styled[1].style.color, .systemRed)
        XCTAssertTrue(OverlayStyling.lines(tracks, source: .routeLegs).isEmpty, "only the asked source")
    }

    func testWaypointCirclesStackSelectionAndTarget() throws {
        let shapes: [OverlayShape] = try OverlayShapes.parse(Data(OverlayShapesTests.waypointsJSON.utf8))
        let points: [StyledOverlayPoint] = OverlayStyling.points(shapes, source: .waypoints)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].circles.map(\.layerID), ["gn-waypoints", "gn-waypoints-selected"])
        XCTAssertEqual(points[1].circles.map(\.layerID), ["gn-waypoints", "gn-waypoints-target"])
        XCTAssertEqual(points[0].label, "WP 001")
        // Selected ring: radius 12, stroke 3 -> 27, rounded up, plus 2.
        XCTAssertEqual(OverlayStyling.imageSide(for: points[0].circles), 29)
        XCTAssertTrue(OverlayStyling.points(shapes, source: .routePoints).isEmpty == false,
                      "route-point layers draw every point of their source")
    }

    func testEverySourceHasLayersAndCountMatchesMapLibre() {
        // MapOverlayLayers.build() has 14 line layers and 6 circle layers.
        XCTAssertEqual(OverlayStyling.layerCount, 20)
        for source in OverlaySource.allCases {
            let lines: Int = OverlayStyling.lineLayers.filter { $0.source == source }.count
            let circles: Int = OverlayStyling.circleLayers.filter { $0.source == source }.count
            XCTAssertEqual(source.isPoints, circles > 0, source.rawValue)
            XCTAssertEqual(!source.isPoints, lines > 0, source.rawValue)
        }
    }
}

final class ChartTileMathTests: XCTestCase {
    func testSourceAtOrBelowMaxZoomIsTheTileItself() {
        let tile = ChartTileMath.Tile(zoom: 10, x: 275, y: 430)
        let source = ChartTileMath.source(for: tile, maxZoom: 12)
        XCTAssertEqual(source?.tile, tile)
        XCTAssertEqual(source?.isWholeTile, true)
    }

    func testOverzoomUsesTheAncestorQuadrant() {
        // z12 (5, 6) above max zoom 10: ancestor (1, 1) at z10, 1/4 of it, column 1 row 2 of 4.
        let source = ChartTileMath.source(for: ChartTileMath.Tile(zoom: 12, x: 5, y: 6), maxZoom: 10)
        XCTAssertEqual(source?.tile, ChartTileMath.Tile(zoom: 10, x: 1, y: 1))
        XCTAssertEqual(source?.cropSize, 0.25)
        XCTAssertEqual(source?.cropX, 0.25)
        XCTAssertEqual(source?.cropY, 0.5)
        XCTAssertEqual(source?.isWholeTile, false)
        XCTAssertNil(ChartTileMath.source(for: ChartTileMath.Tile(zoom: 2, x: 4, y: 0), maxZoom: 10), "x out of range")
    }

    func testTileBoundsAndOverlap() {
        let world = ChartTileMath.bounds(of: ChartTileMath.Tile(zoom: 0, x: 0, y: 0))
        XCTAssertEqual(world.west, -180, accuracy: 1e-9)
        XCTAssertEqual(world.east, 180, accuracy: 1e-9)
        XCTAssertEqual(world.north, 85.0511287798, accuracy: 1e-6)
        XCTAssertEqual(world.south, -85.0511287798, accuracy: 1e-6)
        // Tampa Bay at z10: the tile holding 27.7 N, 82.6 W.
        let x: Int = Int(((-82.6 + 180.0) / 360.0) * 1024.0)
        let latRad: Double = 27.7 * Double.pi / 180.0
        let y: Int = Int((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / Double.pi) / 2.0 * 1024.0)
        let tile = ChartTileMath.Tile(zoom: 10, x: x, y: y)
        let tampa = BoundingBox(west: -83.0, south: 27.3, east: -82.3, north: 28.1)
        XCTAssertTrue(ChartTileMath.tile(tile, overlaps: tampa))
        let mobile = BoundingBox(west: -88.5, south: 30.2, east: -87.8, north: 30.8)
        XCTAssertFalse(ChartTileMath.tile(tile, overlaps: mobile))
    }

    func testZoomLevelRoundTrip() {
        // The whole world (360 degrees) in 256 points is zoom 0; in 1024 points, zoom 2.
        XCTAssertEqual(ChartTileMath.zoomLevel(longitudeDelta: 360, widthPoints: 256), 0, accuracy: 1e-9)
        XCTAssertEqual(ChartTileMath.zoomLevel(longitudeDelta: 360, widthPoints: 1024), 2, accuracy: 1e-9)
        let delta: Double = ChartTileMath.longitudeDelta(zoom: 9.5, widthPoints: 800)
        XCTAssertEqual(ChartTileMath.zoomLevel(longitudeDelta: delta, widthPoints: 800), 9.5, accuracy: 1e-9)
        XCTAssertEqual(ChartTileMath.zoomLevel(longitudeDelta: 0, widthPoints: 800), 0)
    }

    func testFilePathFromSourceURL() {
        XCTAssertEqual(ChartTileMath.filePath(fromSourceURL: "mbtiles:///var/x/chart-a.mbtiles"), "/var/x/chart-a.mbtiles")
        XCTAssertEqual(ChartTileMath.filePath(fromSourceURL: "mbtiles:///var/x/chart-a.mbtiles?file={x}/{y}/{z}.png"),
                       "/var/x/chart-a.mbtiles")
        XCTAssertEqual(ChartTileMath.filePath(fromSourceURL: "mbtiles:///Users/a/Application%20Support/c.mbtiles"),
                       "/Users/a/Application Support/c.mbtiles")
        XCTAssertNil(ChartTileMath.filePath(fromSourceURL: "https://example.com/c.mbtiles"))
        XCTAssertNil(ChartTileMath.filePath(fromSourceURL: "mbtiles://relative.mbtiles"))
        // Round trip with ChartKit's own URL builder, including a path with a space.
        let url = URL(fileURLWithPath: "/Users/a/Library/Application Support/com.example.gulfnav/Charts/x.mbtiles")
        XCTAssertEqual(ChartTileMath.filePath(fromSourceURL: MapLibreSources.sourceURL(forFileAt: url)), url.path)
        XCTAssertEqual(ChartTileMath.filePath(fromSourceURL: MapLibreSources.sourceURL(forFileAt: url, percentEncoded: true)),
                       url.path)
    }
}

final class PositionStatusTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func fix(ageSeconds: Double) -> Fix {
        Fix(coordinate: Coordinate(latitude: 27.6, longitude: -82.7), timestamp: now.addingTimeInterval(-ageSeconds),
            speed: 3, course: 10, horizontalAccuracy: 65)
    }

    func testStates() {
        XCTAssertEqual(PositionStatus.state(lastFix: nil, authorization: .notDetermined, now: now), .waiting)
        XCTAssertEqual(PositionStatus.state(lastFix: nil, authorization: .authorizedAlways, now: now), .waiting)
        XCTAssertEqual(PositionStatus.state(lastFix: fix(ageSeconds: 2), authorization: .authorizedWhenInUse, now: now), .current)
        XCTAssertEqual(PositionStatus.state(lastFix: fix(ageSeconds: 30), authorization: .authorizedWhenInUse, now: now), .current)
        XCTAssertEqual(PositionStatus.state(lastFix: fix(ageSeconds: 95), authorization: .authorizedWhenInUse, now: now),
                       .stale(seconds: 95))
        XCTAssertEqual(PositionStatus.state(lastFix: fix(ageSeconds: 2), authorization: .denied, now: now), .off)
        XCTAssertEqual(PositionStatus.state(lastFix: nil, authorization: .restricted, now: now), .off)
    }

    func testMessagesAndValues() {
        XCTAssertNil(PositionStatus.message(.current))
        XCTAssertTrue(PositionStatus.showsValues(.current))
        XCTAssertFalse(PositionStatus.showsValues(.waiting))
        XCTAssertFalse(PositionStatus.showsValues(.stale(seconds: 40)))
        XCTAssertEqual(PositionStatus.message(.stale(seconds: 45)), "No position for 45 s.")
        XCTAssertEqual(PositionStatus.message(.stale(seconds: 600)), "No position for 10 min.")
        XCTAssertEqual(PositionStatus.message(.stale(seconds: 7_500)), "No position for 2 h 05 min.")
        XCTAssertTrue(PositionStatus.message(.off)?.hasPrefix("No position: location access is off") ?? false)
        XCTAssertTrue(PositionStatus.message(.waiting)?.hasPrefix("No position yet") ?? false)
    }
}

final class MacPathsTests: XCTestCase {
    func testMacRootIsTheAppsFolderInApplicationSupport() {
        let support = URL(fileURLWithPath: "/Users/a/Library/Containers/com.example.gulfnav/Data/Library/Application Support",
                          isDirectory: true)
        let root: URL = AppPaths.macRoot(applicationSupport: support, bundleIdentifier: "com.example.gulfnav")
        XCTAssertEqual(root.lastPathComponent, "com.example.gulfnav")
        let paths = AppPaths(libraryDirectory: root)
        XCTAssertEqual(paths.storeURL.path,
                       "/Users/a/Library/Containers/com.example.gulfnav/Data/Library/Application Support/com.example.gulfnav/AppData/gulfnav.sqlite")
        XCTAssertTrue(paths.chartsDirectory.path.hasSuffix("/com.example.gulfnav/Charts"))
        XCTAssertEqual(AppPaths.macRoot(applicationSupport: support, bundleIdentifier: nil).lastPathComponent, "GulfNav")
        XCTAssertEqual(AppPaths.macRoot(applicationSupport: support, bundleIdentifier: "").lastPathComponent, "GulfNav")
        XCTAssertEqual(AppPaths.macRoot(applicationSupport: support, bundleIdentifier: "a/b").lastPathComponent, "GulfNav")
    }

    func testMacRootPrepares() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("macroot-\(UUID().uuidString)",
                                                                                   isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(libraryDirectory: AppPaths.macRoot(applicationSupport: support, bundleIdentifier: "com.example.gulfnav"))
        try paths.prepare()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.chartsDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.dataDirectory.path))
    }
}
