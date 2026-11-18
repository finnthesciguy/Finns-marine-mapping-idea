import ChartKit
import Foundation
import XCTest
@testable import AppServices

final class ChartLibraryTests: XCTestCase {
    var dir: TempDir!

    override func setUpWithError() throws {
        dir = try TempDir()
    }

    override func tearDown() {
        dir.cleanup()
    }

    func makeEnvironment(transport: FakeServerTransport) throws -> AppEnvironment {
        try AppEnvironment.make(paths: AppPaths(libraryDirectory: dir.url), transport: transport,
                                acknowledgements: InMemoryAcknowledgementStore(),
                                diskSpace: FixedDiskSpace(bytes: 10_000_000_000),
                                configuration: ChartInstaller.Configuration(freeSpaceMargin: 0))
    }

    func testStrategy() {
        XCTAssertEqual(InstallStrategy.choose(for: Fixtures.region()), .noaaFallback)
        let real = String(repeating: "ab", count: 32)
        XCTAssertEqual(InstallStrategy.choose(for: Fixtures.region(url: Fixtures.noaaURL, sha256: real)), .noaaFallback,
                       "NOAA-hosted packages always use the fallback in the first app build")
        let ours = URL(string: "https://charts.example.org/ncds_13.mbtiles")!
        XCTAssertEqual(InstallStrategy.choose(for: Fixtures.region(url: ours, sha256: real)), .manifest)
        XCTAssertEqual(InstallStrategy.choose(for: Fixtures.region(url: ours)), .noaaFallback, "placeholder checksum")
        XCTAssertTrue(InstallStrategy.isPlaceholderChecksum(String(repeating: "0", count: 64)))
        XCTAssertFalse(InstallStrategy.isPlaceholderChecksum(real))
    }

    func testNOAAFallbackInstallsWithServerValidatorsAndPlansLayers() async throws {
        let server = FakeServerTransport()
        let package = try Fixtures.data("tiny-a.mbtiles")
        server.publish(package, at: Fixtures.noaaURL, etag: "\"66560a7e-16b4c000\"",
                       lastModified: "Tue, 28 May 2024 18:20:14 GMT")
        let env = try makeEnvironment(transport: server)
        await env.charts.start()
        let updates = env.charts.stateUpdates()

        // The manifest's size is deliberately wrong: the fallback trusts the server's HEAD instead.
        let region = Fixtures.region(byteSize: 999)
        let installed = try await env.charts.install(region)

        XCTAssertEqual(installed.id, "ncds_99")
        XCTAssertEqual(installed.chart.byteSize, Int64(package.count))
        XCTAssertEqual(installed.chart.version, "66560a7e-16b4c000", "version comes from the ETag")
        XCTAssertEqual(DataDateFormat.string(installed.chart.dataDate), "28 May 2024", "data date from Last-Modified")
        XCTAssertEqual(installed.chart.validators?.etag, "\"66560a7e-16b4c000\"")

        let calls = server.recordedCalls
        XCTAssertEqual(calls.first?.method, "HEAD")
        XCTAssertTrue(calls.contains { $0.method == "GET" && $0.headers["Range"] == nil })

        // State changes reached the stream.
        var states: [InstallState] = []
        for await update in updates {
            XCTAssertEqual(update.regionID, "ncds_99")
            states.append(update.state)
            if case .installed = update.state { break }
        }
        XCTAssertTrue(states.contains(.verifying))

        // Layer plan for the map: an mbtiles:// URL to a file under Library/Charts.
        let regions = await env.charts.installer.installedRegions()
        let installer = env.charts.installer
        let plan = MapLibreSources.layerPlan(for: regions, resolveURL: { installer.fileURL(for: $0.chart) })
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(plan[0].sourceURL.hasPrefix("mbtiles:///"))
        XCTAssertTrue(plan[0].sourceURL.contains("/Charts/regions/ncds_99/"))
        XCTAssertTrue(AppPaths.isSafeForMBTilesURL(installer.fileURL(for: regions[0].chart)))
    }

    func testInterruptedDownloadResumesWithRangeAndIfRange() async throws {
        let server = FakeServerTransport()
        let package = try Fixtures.data("tiny-a.mbtiles")
        server.publish(package, at: Fixtures.noaaURL, etag: "\"e1\"", lastModified: "Tue, 28 May 2024 18:20:14 GMT")
        server.interruptNextDownload(after: 5_000)
        let env = try makeEnvironment(transport: server)

        let installed = try await env.charts.install(Fixtures.region())
        XCTAssertEqual(installed.chart.byteSize, Int64(package.count))
        let gets = server.recordedCalls.filter { $0.method == "GET" }
        XCTAssertEqual(gets.count, 2, "one interrupted GET, one resumed GET within the same install")
        XCTAssertEqual(gets[1].headers["Range"], "bytes=5000-")
        XCTAssertEqual(gets[1].headers["If-Range"], "\"e1\"")
    }

    func testUpdateDetectionAndSupersededRelease() async throws {
        let server = FakeServerTransport()
        server.publish(try Fixtures.data("tiny-a.mbtiles"), at: Fixtures.noaaURL, etag: "\"v1\"",
                       lastModified: "Tue, 28 May 2024 18:20:14 GMT")
        let env = try makeEnvironment(transport: server)
        let first = try await env.charts.install(Fixtures.region())
        let firstFile = env.charts.installer.fileURL(for: first.chart)

        let unchanged = try await env.charts.installer.checkRemote(regionID: "ncds_99")
        XCTAssertEqual(unchanged, .unchanged)

        server.publish(try Fixtures.data("tiny-b.mbtiles"), at: Fixtures.noaaURL, etag: "\"v2\"",
                       lastModified: "Wed, 11 Nov 2026 06:00:00 GMT")
        let change = try await env.charts.installer.checkRemote(regionID: "ncds_99")
        guard case .changed = change else { return XCTFail("expected a change, got \(change)") }
        let state = await env.charts.installer.state(for: "ncds_99")
        XCTAssertEqual(state, .updateAvailable(installedVersion: "v1", availableVersion: "v2"))

        let second = try await env.charts.install(Fixtures.region())
        XCTAssertEqual(second.chart.version, "v2")
        XCTAssertEqual(DataDateFormat.string(second.chart.dataDate), "11 Nov 2026")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path), "kept until the map lets go")
        // A plan that still draws the old file must not release it.
        let installer = env.charts.installer
        let stalePlan = MapLibreSources.layerPlan(for: [first], resolveURL: { installer.fileURL(for: $0.chart) })
        let kept = await env.charts.releaseSupersededFiles(notReferencedBy: stalePlan)
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))

        let currentPlan = MapLibreSources.layerPlan(for: [second], resolveURL: { installer.fileURL(for: $0.chart) })
        let released = await env.charts.releaseSupersededFiles(notReferencedBy: currentPlan)
        XCTAssertEqual(released.map(\.lastPathComponent), [firstFile.lastPathComponent])
        let none = await env.charts.releaseSupersededFiles()
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
    }

    func testHeadFailureIsReportedAsInstallFailure() async throws {
        let server = FakeServerTransport() // nothing published: HEAD gives 404
        let env = try makeEnvironment(transport: server)
        do {
            try await env.charts.install(Fixtures.region())
            XCTFail("expected a failure")
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure, .transport("HTTP 404"))
        }
        let state = await env.charts.installer.state(for: "ncds_99")
        XCTAssertEqual(state, .notInstalled, "the installer never started")
    }

    func testRemove() async throws {
        let server = FakeServerTransport()
        server.publish(try Fixtures.data("tiny-a.mbtiles"), at: Fixtures.noaaURL, etag: "\"v1\"",
                       lastModified: "Tue, 28 May 2024 18:20:14 GMT")
        let env = try makeEnvironment(transport: server)
        let installed = try await env.charts.install(Fixtures.region())
        let file = env.charts.installer.fileURL(for: installed.chart)
        try await env.charts.remove(regionID: "ncds_99")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let regions = await env.charts.installer.installedRegions()
        XCTAssertTrue(regions.isEmpty)
        XCTAssertEqual(env.charts.freeBytes(), 10_000_000_000)
    }

    func testBundledSampleManifestDecodes() throws {
        // The app bundles ChartKit's sample manifest; make sure it still decodes and validates.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ChartKit/Samples/gulf-manifest.sample.json")
        let manifest = try ChartManifest.decode(from: Data(contentsOf: url))
        XCTAssertEqual(manifest.regions.map(\.id), ["ncds_10", "ncds_11", "ncds_12", "ncds_13", "ncds_14"])
        for region in manifest.regions {
            XCTAssertEqual(InstallStrategy.choose(for: region), .noaaFallback)
        }
    }
}
