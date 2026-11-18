import ChartKit
import Foundation
import Persistence
import XCTest
@testable import AppServices

final class LaunchConfigurationTests: XCTestCase {
    func testDefaultsAreOff() {
        let launch = LaunchConfiguration(environment: [:])
        XCTAssertEqual(launch, LaunchConfiguration())
        XCTAssertFalse(launch.usesIsolatedData)
        XCTAssertFalse(launch.resetData)
        XCTAssertFalse(launch.simulateGPS)
        XCTAssertFalse(launch.preinstallFixtureChart)
        XCTAssertNil(launch.isolatedLibraryDirectory(temporaryDirectory: URL(fileURLWithPath: "/tmp")))
    }

    func testParsesFlagsAndSanitisesTheRootName() {
        let launch = LaunchConfiguration(environment: [
            "GULFNAV_DATA_ROOT": "../evil name/✓-ok_1",
            "GULFNAV_RESET_DATA": "1",
            "GULFNAV_SIMULATE_GPS": "true",
            "GULFNAV_PREINSTALL_FIXTURE_CHART": "YES",
        ])
        XCTAssertEqual(launch.dataRootName, "evilname-ok_1")
        XCTAssertTrue(launch.resetData)
        XCTAssertTrue(launch.simulateGPS)
        XCTAssertTrue(launch.preinstallFixtureChart)
        let root = launch.isolatedLibraryDirectory(temporaryDirectory: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        XCTAssertEqual(root?.path, "/tmp/x/GulfNavTestData/evilname-ok_1")
        XCTAssertTrue(AppPaths.isSafeForMBTilesURL(root!))
        XCTAssertFalse(LaunchConfiguration(environment: ["GULFNAV_SIMULATE_GPS": "0"]).simulateGPS)
    }

    func testResetNeedsARootAndDeletesIt() throws {
        XCTAssertFalse(LaunchConfiguration(environment: ["GULFNAV_RESET_DATA": "1"]).resetData)
        XCTAssertNil(LaunchConfiguration(dataRootName: "///").dataRootName)

        let dir = try TempDir()
        defer { dir.cleanup() }
        let keep = LaunchConfiguration(dataRootName: "run1")
        let paths = try keep.resolvePaths(temporaryDirectory: dir.url, live: { XCTFail("live used"); return AppPaths(libraryDirectory: dir.url) })
        try paths.prepare()
        let marker = paths.dataDirectory.appendingPathComponent("marker")
        try Data([1]).write(to: marker)
        _ = try keep.resolvePaths(temporaryDirectory: dir.url, live: { AppPaths(libraryDirectory: dir.url) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "no reset: data kept")
        let reset = LaunchConfiguration(dataRootName: "run1", resetData: true)
        let again = try reset.resolvePaths(temporaryDirectory: dir.url, live: { AppPaths(libraryDirectory: dir.url) })
        XCTAssertEqual(again, paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "reset: data deleted")
    }
}

final class FixtureChartTests: XCTestCase {
    func fixtureURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "tiny-a.mbtiles", withExtension: nil, subdirectory: "Resources") else {
            throw NSError(domain: "Fixtures", code: 1)
        }
        return url
    }

    func testChecksumAndSizeMatchTheFile() throws {
        let data = try Data(contentsOf: fixtureURL())
        XCTAssertEqual(Int64(data.count), FixtureChart.byteSize)
        XCTAssertEqual(StreamingSHA256.hash(data), FixtureChart.sha256)
        XCTAssertEqual(InstallStrategy.choose(for: FixtureChart.region), .manifest)
        let manifest = ChartManifest(generatedAt: Date(), regions: [FixtureChart.region])
        XCTAssertNoThrow(try manifest.validate())
    }

    func testInstallsOfflineThroughTheLocalTransportAndPlansOneLayer() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let transport = LocalFileChartTransport(files: [FixtureChart.packageURL: try fixtureURL()], fallback: nil)
        let env = try AppEnvironment.make(paths: AppPaths(libraryDirectory: dir.url), transport: transport,
                                          diskSpace: FixedDiskSpace(bytes: 10_000_000_000),
                                          configuration: ChartInstaller.Configuration(freeSpaceMargin: 0))
        let installed = try await env.charts.install(FixtureChart.region)
        XCTAssertEqual(installed.id, FixtureChart.regionID)
        XCTAssertEqual(DataDateFormat.string(installed.chart.dataDate), "28 May 2024")
        let regions = await env.charts.installer.installedRegions()
        let installer = env.charts.installer
        let plan = MapLibreSources.layerPlan(for: regions, resolveURL: { installer.fileURL(for: $0.chart) })
        XCTAssertEqual(plan.count, 1)

        let rows = RegionCatalog.rows(regions: [FixtureChart.region], installed: regions,
                                      states: await installer.allStates(), pending: [], preparing: [], messages: [:],
                                      now: Date())
        XCTAssertEqual(rows.first?.statusText, "Installed")
        XCTAssertEqual(DataDateFormat.string(rows[0].dataDate), "28 May 2024")
    }

    func testLocalTransportResumesAndFallsBack() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let source = try fixtureURL()
        let full = try Data(contentsOf: source)
        let transport = LocalFileChartTransport(files: [FixtureChart.packageURL: source], fallback: nil)
        let validators = try await transport.head(FixtureChart.packageURL)
        XCTAssertEqual(validators.contentLength, FixtureChart.byteSize)

        let destination = dir.url.appendingPathComponent("partial")
        try full.prefix(1000).write(to: destination)
        let response = try await transport.download(DownloadRequest(url: FixtureChart.packageURL, destination: destination,
                                                                    resumeOffset: 1000, ifRange: validators.etag),
                                                    progress: { _ in })
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(try Data(contentsOf: destination), full)

        do {
            _ = try await transport.head(URL(string: "https://example.invalid/other.mbtiles")!)
            XCTFail("expected 404")
        } catch let error as TransportError {
            XCTAssertEqual(error, .httpStatus(404))
        }
    }
}

final class StoreStartupTests: XCTestCase {
    var dir: TempDir!

    override func setUpWithError() throws {
        dir = try TempDir()
    }

    override func tearDown() {
        dir.cleanup()
    }

    func testOpensACleanStoreWithoutNotices() throws {
        let url = dir.url.appendingPathComponent("a.sqlite")
        let result = try StoreOpener.open(at: url)
        XCTAssertTrue(result.isPersistent)
        XCTAssertEqual(result.notices, [])
        XCTAssertNil(result.report?.recoveredCorruptFile)
    }

    func testCorruptFileIsSetAsideWithANotice() throws {
        let url = dir.url.appendingPathComponent("b.sqlite")
        try Data(repeating: 0x5A, count: 8192).write(to: url)
        let result = try StoreOpener.open(at: url)
        XCTAssertTrue(result.isPersistent)
        XCTAssertNotNil(result.report?.recoveredCorruptFile)
        XCTAssertEqual(result.notices.map(\.kind), [.dataRecovered])
    }

    func testNewerSchemaFallsBackToMemoryAndLeavesTheFile() async throws {
        let url = dir.url.appendingPathComponent("c.sqlite")
        do {
            let store = try PersistenceStore(url: url)
            _ = try await store.save(Waypoint(name: "Keep me", coordinate: .init(latitude: 27.5, longitude: -82.7)))
            try await store.checkpoint()
            await store.close()
        }
        // SQLite keeps user_version at byte offset 60 of the header (big-endian).
        var bytes = try Data(contentsOf: url)
        bytes.replaceSubrange(60..<64, with: [0, 0, 3, 0xE7])
        try bytes.write(to: url)
        let before = try Data(contentsOf: url)

        let result = try StoreOpener.open(at: url)
        XCTAssertFalse(result.isPersistent)
        XCTAssertNil(result.report)
        XCTAssertEqual(result.notices.map(\.kind), [.dataNotSaved])
        XCTAssertTrue(result.notices[0].message.contains("newer version"), result.notices[0].message)
        XCTAssertEqual(try Data(contentsOf: url), before, "the newer file is left untouched")
    }

    func testRecoveryPlanResumesOnlyARecentNewestRecording() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = Track(name: "old", state: .recording, createdAt: now.addingTimeInterval(-86_400),
                        modifiedAt: now.addingTimeInterval(-86_000))
        let recent = Track(name: "recent", state: .recording, createdAt: now.addingTimeInterval(-3_000),
                           modifiedAt: now.addingTimeInterval(-600))
        let plan = RecordingRecovery.plan(interrupted: [old, recent], now: now)
        XCTAssertEqual(plan.resume, recent.id)
        XCTAssertEqual(plan.finish, [old.id])

        let tooOld = RecordingRecovery.plan(interrupted: [old], now: now)
        XCTAssertNil(tooOld.resume)
        XCTAssertEqual(tooOld.finish, [old.id])

        let noRecorder = RecordingRecovery.plan(interrupted: [recent], now: now, allowResume: false)
        XCTAssertNil(noRecorder.resume)
        XCTAssertEqual(noRecorder.finish, [recent.id])
        XCTAssertEqual(RecordingRecovery.plan(interrupted: [], now: now), RecordingRecovery.Plan(resume: nil, finish: []))
    }

    func testRecoveryAfterRelaunchResumesAndCloses() async throws {
        let url = dir.url.appendingPathComponent("d.sqlite")
        let start = Date()
        var stale: UUID
        var live: UUID
        do {
            let clockOld: @Sendable () -> Date = { start.addingTimeInterval(-10 * 3600) }
            let storeOld = try PersistenceStore(url: url, options: .init(clock: clockOld))
            stale = try await storeOld.startTrack(name: "Yesterday").id
            await storeOld.close()
            let store = try PersistenceStore(url: url)
            live = try await store.startTrack(name: "Today").id
            let fix = TrackPoint(timestamp: start, coordinate: .init(latitude: 27.6, longitude: -82.7), speed: 3)
            _ = try await store.appendTrackPoints([fix], to: live)
            await store.close()
        }
        let reopened = try StoreOpener.open(at: url)
        XCTAssertEqual(Set(reopened.report?.interruptedRecordings ?? []), [stale, live])
        let outcome = await RecordingRecovery.recover(store: reopened.store, now: start.addingTimeInterval(60))
        XCTAssertEqual(outcome.resumed?.id, live)
        XCTAssertEqual(outcome.resumed?.state, .recording)
        XCTAssertEqual(outcome.finished.map(\.id), [stale])
        XCTAssertEqual(outcome.notices.count, 2)
        let remaining = try await reopened.store.recordingTracks()
        XCTAssertEqual(remaining.map(\.id), [live])
    }
}

final class AcknowledgementMigrationTests: XCTestCase {
    func testMigratesOnceAndRemovesTheLegacyCopy() async throws {
        let record = DisclaimerRecord(version: 1, date: Date(timeIntervalSince1970: 1_700_000_000))
        let legacy = InMemoryAcknowledgementStore(record: record)
        let store = try PersistenceStore(inMemoryWith: .init())
        let target = PersistenceAcknowledgementStore(store: store)

        let first = await AcknowledgementMigration.run(from: legacy, to: target, removeLegacy: true)
        XCTAssertEqual(first, .migrated(record))
        let stored = try await target.disclaimerAcknowledgement()
        XCTAssertEqual(stored, record)
        let left = try await legacy.disclaimerAcknowledgement()
        XCTAssertNil(left)
        let second = await AcknowledgementMigration.run(from: legacy, to: target, removeLegacy: true)
        XCTAssertEqual(second, .nothingToMigrate)
    }

    func testKeepsANewerTargetAndTheLegacyCopyWhenAskedTo() async throws {
        let old = DisclaimerRecord(version: 1, date: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = DisclaimerRecord(version: 2, date: Date(timeIntervalSince1970: 1_800_000_000))
        let legacy = InMemoryAcknowledgementStore(record: old)
        let target = InMemoryAcknowledgementStore(record: newer)
        let outcome = await AcknowledgementMigration.run(from: legacy, to: target, removeLegacy: false)
        XCTAssertEqual(outcome, .targetAlreadyCurrent)
        let kept = try await legacy.disclaimerAcknowledgement()
        XCTAssertEqual(kept, old)
        let unchanged = try await target.disclaimerAcknowledgement()
        XCTAssertEqual(unchanged, newer)
    }

    func testUserDefaultsLegacyStoreRoundTripsAndRemoves() async throws {
        let suite = "appservices-tests-\(UUID().uuidString)"
        let legacy = UserDefaultsAcknowledgementStore(suiteName: suite)
        let record = DisclaimerRecord(version: 1, date: Date(timeIntervalSince1970: 1_700_000_000))
        try await legacy.acknowledgeDisclaimer(record)
        let read = try await legacy.disclaimerAcknowledgement()
        XCTAssertEqual(read, record)
        try await legacy.removeDisclaimerAcknowledgement()
        let gone = try await legacy.disclaimerAcknowledgement()
        XCTAssertNil(gone)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testLiveEnvironmentOnIsolatedPathsKeepsTheAcknowledgementAcrossLaunches() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let launch = LaunchConfiguration(dataRootName: "ack", resetData: true)
        let legacy = InMemoryAcknowledgementStore(record: DisclaimerRecord(version: 1, date: Date()))
        do {
            let paths = try launch.resolvePaths(temporaryDirectory: dir.url, live: { AppPaths(libraryDirectory: dir.url) })
            let env = try AppEnvironment.open(paths: paths, launch: launch, transport: LocalFileChartTransport(files: [:], fallback: nil),
                                              legacy: legacy)
            XCTAssertTrue(env.storeIsPersistent)
            XCTAssertTrue(env.paths.storeURL.path.contains("GulfNavTestData/ack/AppData/gulfnav.sqlite"))
            let before = try await env.acknowledgements.disclaimerAcknowledgement()
            XCTAssertNil(before)
            let outcome = await env.migrateLegacyAcknowledgement()
            if case .migrated = outcome {} else { XCTFail("\(outcome)") }
            await env.store.close()
        }
        let relaunch = LaunchConfiguration(dataRootName: "ack")
        let paths = try relaunch.resolvePaths(temporaryDirectory: dir.url, live: { AppPaths(libraryDirectory: dir.url) })
        let env = try AppEnvironment.open(paths: paths, launch: relaunch, transport: LocalFileChartTransport(files: [:], fallback: nil),
                                          legacy: nil)
        let after = try await env.acknowledgements.disclaimerAcknowledgement()
        XCTAssertEqual(after?.version, 1)
        XCTAssertFalse(Disclaimer.needsAcknowledgement(after))
    }
}
