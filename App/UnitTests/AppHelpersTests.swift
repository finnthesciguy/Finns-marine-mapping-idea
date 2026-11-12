import XCTest
@testable import GulfNav

/// App-target helpers that only exist in the iOS target (bundled resources, map helpers). Logic lives in the
/// packages and is tested there; this checks what the app bundle itself contributes.
final class AppHelpersTests: XCTestCase {
    func testBundledManifestLoadsTheFiveGulfRegions() {
        let loaded: ManifestLoader.Loaded = ManifestLoader.loadBundled()
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.regions.count, 5)
    }

    func testBundledOfflineStyleIsValidJSONWithoutNetworkSources() throws {
        let text: String = OfflineStyle.load()
        XCTAssertNotEqual(text, OfflineStyle.fallbackJSON, "the bundled style file should be found")
        let data: Data = Data(text.utf8)
        let object: Any = try JSONSerialization.jsonObject(with: data)
        let style: [String: Any] = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(style["version"] as? Int, 8)
        let sources: [String: Any] = try XCTUnwrap(style["sources"] as? [String: Any])
        XCTAssertTrue(sources.isEmpty)
        XCTAssertFalse(text.contains("http://") || text.contains("https://"))
    }

    func testDebugBuildBundlesTheFixtureChart() throws {
        let url: URL? = Bundle.main.url(forResource: "tiny-a", withExtension: "mbtiles")
        let file: URL = try XCTUnwrap(url, "debug builds bundle the UI-test chart")
        let size: Int = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertEqual(size, 16_384)
    }

    func testMapStatusValueFormat() {
        XCTAssertEqual(MapAccessibility.statusValue(styleLoaded: true, chartLayers: 2), "style=loaded; chartLayers=2")
        XCTAssertEqual(MapAccessibility.statusValue(styleLoaded: false, chartLayers: 0), "style=pending; chartLayers=0")
    }

    @MainActor
    func testAngleBetweenBearings() {
        XCTAssertEqual(ChartMapCoordinator.angleBetween(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(ChartMapCoordinator.angleBetween(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(ChartMapCoordinator.angleBetween(0, 180), 180, accuracy: 1e-9)
        XCTAssertEqual(ChartMapCoordinator.angleBetween(-90, 270), 0, accuracy: 1e-9)
    }
}
