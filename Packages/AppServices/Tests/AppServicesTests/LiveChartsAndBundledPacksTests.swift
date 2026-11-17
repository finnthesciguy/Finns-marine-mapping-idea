import ChartKit
import Foundation
import Persistence
import XCTest
@testable import AppServices

/// Online NOAA chart tiles (URL, cache, polite loader) and the routing packs shipped in the app.
final class LiveChartServiceTests: XCTestCase {
    func testMercatorBoundsOfWorldAndATile() {
        let world = LiveChartService.mercatorBounds(ChartTileMath.Tile(zoom: 0, x: 0, y: 0))
        XCTAssertEqual(world.minX, -20_037_508.342789, accuracy: 0.001)
        XCTAssertEqual(world.maxY, 20_037_508.342789, accuracy: 0.001)
        // The probe tile used against NOAA (z12 over Tampa Bay), bbox as sent then.
        let tile = ChartTileMath.Tile(zoom: 12, x: 1108, y: 1719)
        let b = LiveChartService.mercatorBounds(tile)
        XCTAssertEqual(b.minX, -9_196_903.243272, accuracy: 0.001)
        XCTAssertEqual(b.minY, 3_209_132.195525, accuracy: 0.001)
        XCTAssertEqual(b.maxX, -9_187_119.303652, accuracy: 0.001)
        XCTAssertEqual(b.maxY, 3_218_916.135145, accuracy: 0.001)
    }

    func testTileURLAndRetina() throws {
        let tile = ChartTileMath.Tile(zoom: 12, x: 1108, y: 1719)
        let one: String = try XCTUnwrap(LiveChartService.tileURL(tile, scale: 1)).absoluteString
        XCTAssertTrue(one.hasPrefix(LiveChartService.exportURL + "?bbox=-9196903.243272,3209132.195525,-9187119.303652,3218916.135145&"), one)
        XCTAssertTrue(one.contains("&size=256,256&dpi=96&"), one)
        XCTAssertTrue(one.contains("&bboxSR=3857&imageSR=3857&"))
        XCTAssertTrue(one.hasSuffix("&format=png32&transparent=true&layers=show:0,1,2,3,4,5,6,7&f=image"), one)
        let two: String = try XCTUnwrap(LiveChartService.tileURL(tile, scale: 2)).absoluteString
        XCTAssertTrue(two.contains("&size=512,512&dpi=192&"), two)
        XCTAssertTrue(try XCTUnwrap(LiveChartService.tileURL(tile, scale: 5)).absoluteString.contains("size=512,512"), "clamped to 2x")
        let template: String = LiveChartService.mapLibreTemplate(scale: 2)
        XCTAssertTrue(template.contains("bbox={bbox-epsg-3857}&"), template)
        XCTAssertTrue(template.contains("size=512,512&dpi=192"), template)
    }

    func testOnlyGulfTilesAtUsefulZoomsAreRequested() {
        XCTAssertTrue(LiveChartService.shouldRequest(ChartTileMath.Tile(zoom: 12, x: 1108, y: 1719)))
        XCTAssertFalse(LiveChartService.shouldRequest(ChartTileMath.Tile(zoom: 2, x: 0, y: 1)), "below the minimum zoom")
        XCTAssertFalse(LiveChartService.shouldRequest(ChartTileMath.Tile(zoom: 17, x: 34_000, y: 54_000)), "above max zoom")
        // Zoom 10 over Boston (42.36 N, 71.06 W): outside the Gulf box.
        XCTAssertFalse(LiveChartService.shouldRequest(ChartTileMath.Tile(zoom: 10, x: 309, y: 378)))
    }

    func testPNGSniffing() {
        XCTAssertTrue(LiveChartService.isPNG(LiveTestData.png))
        XCTAssertFalse(LiveChartService.isPNG(Data("{\"error\":{\"code\":500}}".utf8)))
    }

    func testSettingAndLaunchSwitches() {
        XCTAssertEqual(SettingKey<Bool>.liveNOAACharts.name, "charts.liveNOAA")
        XCTAssertTrue(SettingKey<Bool>.liveNOAACharts.defaultValue)
        // Release / normal runs: the setting decides; bundled packs are linked.
        let normal = LaunchConfiguration()
        XCTAssertTrue(normal.allowsLiveCharts(setting: true))
        XCTAssertFalse(normal.allowsLiveCharts(setting: false))
        XCTAssertTrue(normal.installsBundledRoutingPacks)
        // Tests with an isolated data root: off unless asked for.
        let test = LaunchConfiguration(environment: ["GULFNAV_DATA_ROOT": "t"])
        XCTAssertFalse(test.allowsLiveCharts(setting: true))
        XCTAssertFalse(test.installsBundledRoutingPacks)
        let asked = LaunchConfiguration(environment: ["GULFNAV_DATA_ROOT": "t", "GULFNAV_LIVE_CHARTS": "1",
                                                      "GULFNAV_BUNDLED_ROUTING": "1"])
        XCTAssertTrue(asked.allowsLiveCharts(setting: false), "the switch wins over the setting")
        XCTAssertTrue(asked.installsBundledRoutingPacks)
        XCTAssertFalse(LaunchConfiguration(environment: ["GULFNAV_LIVE_CHARTS": "0"]).allowsLiveCharts(setting: true))
        XCTAssertNil(LaunchConfiguration(environment: ["GULFNAV_LIVE_CHARTS": "maybe"]).liveCharts)
    }
}

enum LiveTestData {
    /// The 8-byte PNG signature plus a little padding (enough for `TileFormat.sniff`).
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
}

/// A transport that answers from a closure and records requests and peak concurrency.
final class FakeLiveTransport: LiveTileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int = 0
    private(set) var peak: Int = 0
    private(set) var requests: [URL] = []
    let delayNanoseconds: UInt64
    let answer: @Sendable (URL) throws -> (data: Data, status: Int)

    init(delayNanoseconds: UInt64 = 0, answer: @escaping @Sendable (URL) throws -> (data: Data, status: Int)) {
        self.delayNanoseconds = delayNanoseconds
        self.answer = answer
    }

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        lock.withLock {
            requests.append(url)
            current += 1
            peak = max(peak, current)
        }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        defer { lock.withLock { current -= 1 } }
        return try answer(url)
    }

    var requestCount: Int { lock.withLock { requests.count } }
}

struct OfflineError: Error {}

final class LiveChartLoaderTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    let tampa = ChartTileMath.Tile(zoom: 12, x: 1108, y: 1719)

    func testFetchesOnceThenServesFromCache() async {
        let transport = FakeLiveTransport { _ in (LiveTestData.png, 200) }
        let loader = LiveChartTileLoader(cache: LiveChartCache(root: root), transport: transport)
        let first: LiveTileResult = await loader.tile(tampa, scale: 2)
        guard case .image(let data, let source) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(data, LiveTestData.png)
        XCTAssertTrue(source.isWholeTile)
        let second: LiveTileResult = await loader.tile(tampa, scale: 2)
        XCTAssertEqual(second, first)
        XCTAssertEqual(transport.requestCount, 1, "the second request came from the disk cache")
        let status: LiveChartStatus = await loader.status
        XCTAssertEqual(status.connection, .online)
        XCTAssertEqual(status.fetched, 1)
        XCTAssertEqual(status.cacheHits, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: LiveChartCache(root: root).fileURL(tampa, scale: 2).path))
        XCTAssertEqual(status.statusValue, "liveCharts=online; liveFetched=1; liveCached=1; liveFailures=0")
    }

    func testDeepZoomUsesTheZoom16AncestorAndOutsideIsEmpty() async {
        let transport = FakeLiveTransport { _ in (LiveTestData.png, 200) }
        let loader = LiveChartTileLoader(cache: LiveChartCache(root: root), transport: transport)
        let deep = ChartTileMath.Tile(zoom: 18, x: 1108 * 64 + 5, y: 1719 * 64 + 7)
        let result: LiveTileResult = await loader.tile(deep, scale: 1)
        guard case .image(_, let source) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(source.tile.zoom, 16)
        XCTAssertEqual(source.cropSize, 0.25)
        XCTAssertTrue(transport.requests.first?.absoluteString.contains("size=256,256") ?? false)
        let boston = await loader.tile(ChartTileMath.Tile(zoom: 10, x: 309, y: 378), scale: 1)
        XCTAssertEqual(boston, .empty)
        let tooFar = await loader.tile(ChartTileMath.Tile(zoom: 2, x: 0, y: 1), scale: 1)
        XCTAssertEqual(tooFar, .empty)
        XCTAssertEqual(transport.requestCount, 1, "nothing asked for empty tiles")
    }

    func testOfflineUsesStaleTilesAndReportsOffline() async throws {
        let cache = LiveChartCache(root: root, maxAge: 60)
        try cache.store(LiveTestData.png, tile: tampa, scale: 1)
        let transport = FakeLiveTransport { _ in throw OfflineError() }
        let loader = LiveChartTileLoader(cache: cache, transport: transport)
        // An hour later the cached tile is stale: NOAA is asked, fails, and the stale tile is used.
        let later = Date().addingTimeInterval(3600)
        let result: LiveTileResult = await loader.tile(tampa, scale: 1, now: later)
        guard case .image(let data, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(data, LiveTestData.png)
        let other: LiveTileResult = await loader.tile(ChartTileMath.Tile(zoom: 12, x: 1109, y: 1719), scale: 1, now: later)
        XCTAssertEqual(other, .unavailable)
        let status: LiveChartStatus = await loader.status
        XCTAssertEqual(status.connection, .offline)
        XCTAssertEqual(status.failures, 2)
        XCTAssertTrue(status.line.contains("offline"), status.line)
    }

    func testErrorBodiesAreNotCached() async {
        let transport = FakeLiveTransport { _ in (Data("<html>Service unavailable</html>".utf8), 200) }
        let loader = LiveChartTileLoader(cache: LiveChartCache(root: root), transport: transport)
        let result: LiveTileResult = await loader.tile(tampa, scale: 1)
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LiveChartCache(root: root).fileURL(tampa, scale: 1).path))
        let status: LiveChartStatus = await loader.status
        XCTAssertEqual(status.lastError, "HTTP 200, not a PNG")
    }

    func testAtMostTwoRequestsInFlight() async {
        let transport = FakeLiveTransport(delayNanoseconds: 20_000_000) { _ in (LiveTestData.png, 200) }
        let loader = LiveChartTileLoader(cache: LiveChartCache(root: root), transport: transport, maxConcurrent: 2)
        await withTaskGroup(of: Void.self) { group in
            for dx in 0..<8 {
                let tile = ChartTileMath.Tile(zoom: 12, x: 1100 + dx, y: 1719)
                group.addTask { _ = await loader.tile(tile, scale: 1) }
            }
        }
        XCTAssertEqual(transport.requestCount, 8)
        XCTAssertLessThanOrEqual(transport.peak, 2)
        XCTAssertGreaterThanOrEqual(transport.peak, 1)
        let inFlight: Int = await loader.requestsInFlight
        XCTAssertEqual(inFlight, 0)
    }

    func testCachePruneRemovesOldestFirst() throws {
        let cache = LiveChartCache(root: root)
        let payload = Data(repeating: 7, count: 1000)
        for x in 0..<5 {
            try cache.store(payload, tile: ChartTileMath.Tile(zoom: 12, x: 1100 + x, y: 1719), scale: 1)
            let url = cache.fileURL(ChartTileMath.Tile(zoom: 12, x: 1100 + x, y: 1719), scale: 1)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000_000 + x))],
                                                  ofItemAtPath: url.path)
        }
        XCTAssertEqual(cache.totalBytes(), 5000)
        XCTAssertEqual(cache.prune(maxBytes: 2500), 3)
        XCTAssertEqual(cache.totalBytes(), 2000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.fileURL(ChartTileMath.Tile(zoom: 12, x: 1104, y: 1719), scale: 1).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(ChartTileMath.Tile(zoom: 12, x: 1100, y: 1719), scale: 1).path))
        try cache.clear()
        XCTAssertEqual(cache.totalBytes(), 0)
    }
}

final class BundledRoutingPacksTests: XCTestCase {
    var base: URL!
    var bundled: URL!
    var target: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)", isDirectory: true)
        bundled = base.appendingPathComponent("App/RoutingPacks", isDirectory: true)
        target = base.appendingPathComponent("Library/RoutingPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    func write(_ name: String, _ text: String, in directory: URL? = nil) throws {
        try Data(text.utf8).write(to: (directory ?? bundled).appendingPathComponent(name))
    }

    func links() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func testMissingOrEmptyDirectoryIsNotAnError() {
        let none = BundledRoutingPacks.install(from: nil, into: target, validate: { _ in })
        XCTAssertFalse(none.changed)
        XCTAssertTrue(none.problems.isEmpty)
        let empty = BundledRoutingPacks.install(from: bundled, into: target, validate: { _ in })
        XCTAssertFalse(empty.changed)
        let missing = BundledRoutingPacks.install(from: base.appendingPathComponent("nope"), into: target, validate: { _ in })
        XCTAssertFalse(missing.changed)
        XCTAssertEqual(links(), [])
    }

    func testLinksEveryValidPackOnceAndReportsBadOnes() throws {
        try write("ncds_10.pack", "ten")
        try write("ncds_11.pack", "eleven")
        try write("broken.pack", "x")
        try write("manifest.json", "{\"version\":1}")
        try write("README.txt", "not a pack")
        let outcome = BundledRoutingPacks.install(from: bundled, into: target, validate: { url in
            if url.lastPathComponent == "broken.pack" { throw RoutingPackRejection(reason: "truncated") }
        })
        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.linked, ["bundled-ncds_10.pack", "bundled-ncds_11.pack"])
        XCTAssertEqual(outcome.problems, ["broken.pack: truncated"])
        XCTAssertEqual(links(), ["bundled-ncds_10.pack", "bundled-ncds_11.pack"])
        // The links resolve to the bundled files (the library reads through them).
        let text = try String(contentsOf: target.appendingPathComponent("bundled-ncds_11.pack"), encoding: .utf8)
        XCTAssertEqual(text, "eleven")

        // Second launch, same bundle: nothing to do, no validation.
        var validated: Int = 0
        let again = BundledRoutingPacks.install(from: bundled, into: target, validate: { _ in validated += 1 })
        XCTAssertFalse(again.changed)
        XCTAssertEqual(validated, 0)
    }

    func testRemovedPackStaysRemovedUntilTheBundleChanges() throws {
        try write("ncds_10.pack", "ten")
        try write("manifest.json", "{\"version\":1}")
        _ = BundledRoutingPacks.install(from: bundled, into: target, validate: { _ in })
        try FileManager.default.removeItem(at: target.appendingPathComponent("bundled-ncds_10.pack"))
        let same = BundledRoutingPacks.install(from: bundled, into: target, validate: { _ in })
        XCTAssertFalse(same.changed)
        XCTAssertEqual(links(), [], "the user removed it")
        // A newer bundled manifest: everything is linked again.
        try write("manifest.json", "{\"version\":2}")
        try write("ncds_12.pack", "twelve")
        let newer = BundledRoutingPacks.install(from: bundled, into: target, validate: { _ in })
        XCTAssertTrue(newer.changed)
        XCTAssertEqual(links(), ["bundled-ncds_10.pack", "bundled-ncds_12.pack"])
    }

    func testLinksAreRepairedWhenTheBundleMoves() throws {
        try write("ncds_10.pack", "ten")
        try write("manifest.json", "{\"version\":1}")
        _ = BundledRoutingPacks.install(from: bundled, into: target, validate: { _ in })
        // An app update puts the bundle somewhere else: same manifest, old links dangle.
        let moved = base.appendingPathComponent("App2/RoutingPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bundled, to: moved)
        XCTAssertTrue(BundledRoutingPacks.isDanglingLink(target.appendingPathComponent("bundled-ncds_10.pack")))
        let repaired = BundledRoutingPacks.install(from: moved, into: target, validate: { _ in })
        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(repaired.linked, ["bundled-ncds_10.pack"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("bundled-ncds_10.pack"), encoding: .utf8), "ten")
    }

    func testFingerprintWithoutManifestFollowsNamesAndSizes() throws {
        try write("ncds_10.pack", "ten")
        let a: String = BundledRoutingPacks.fingerprint(of: bundled)
        XCTAssertTrue(a.hasPrefix("files:"))
        try write("ncds_10.pack", "ten!")
        XCTAssertNotEqual(BundledRoutingPacks.fingerprint(of: bundled), a)
        try write("manifest.json", "{}")
        XCTAssertTrue(BundledRoutingPacks.fingerprint(of: bundled).hasPrefix("manifest:"))
    }

    func testTheLibraryListsLinkedPacksWithoutTouchingTheBundle() async throws {
        // A real pack would be needed for the header; here only the listing is checked: link names end in .pack
        // and dot files (the state file) are ignored by the library's directory listing.
        try write("ncds_10.pack", "ten")
        let library = RoutingPackLibrary(sideLoadDirectory: target)
        _ = BundledRoutingPacks.install(from: bundled, library: library, validate: { _ in })
        XCTAssertEqual(library.sideLoadedFiles().map(\.lastPathComponent), ["bundled-ncds_10.pack"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(".bundled-routing.json").path))
    }
}
