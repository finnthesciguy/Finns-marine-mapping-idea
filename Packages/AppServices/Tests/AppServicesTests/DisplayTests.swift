import ChartKit
import Foundation
import NavCore
import XCTest
@testable import AppServices

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(ByteFormat.string(0), "0 bytes")
        XCTAssertEqual(ByteFormat.string(999), "999 bytes")
        XCTAssertEqual(ByteFormat.string(16_384), "16.4 KB")
        XCTAssertEqual(ByteFormat.string(621_428_736), "621 MB")
        XCTAssertEqual(ByteFormat.string(2_670_000_000), "2.67 GB")
        XCTAssertEqual(ByteFormat.string(-5), "0 bytes")
    }

    func testDates() {
        XCTAssertEqual(DataDateFormat.string(ChartDates.day(2024, 5, 28)), "28 May 2024")
        XCTAssertEqual(DataDateFormat.string(ChartDates.day(2026, 1, 1)), "1 Jan 2026")
    }

    func testInstruments() {
        XCTAssertEqual(InstrumentFormat.sog(metersPerSecond: nil), "—")
        XCTAssertEqual(InstrumentFormat.sog(metersPerSecond: -1), "—")
        XCTAssertEqual(InstrumentFormat.sog(metersPerSecond: 6 * UnitConversion.metersPerSecondPerKnot), "6.0 kn")
        XCTAssertEqual(InstrumentFormat.cog(degrees: nil), "—")
        XCTAssertEqual(InstrumentFormat.cog(degrees: 5.4), "005°T")
        XCTAssertEqual(InstrumentFormat.cog(degrees: 359.7), "000°T")
        XCTAssertEqual(InstrumentFormat.cog(degrees: 74), "074°T")
        let position = InstrumentFormat.position(Coordinate(latitude: 27.752050, longitude: -82.624267))
        XCTAssertEqual(position.latitude, CoordinateFormat.latitudeDDM(27.752050))
        XCTAssertEqual(position.longitude, CoordinateFormat.longitudeDDM(-82.624267))
        XCTAssertTrue(position.latitude.hasSuffix("N"))
        XCTAssertTrue(position.longitude.hasSuffix("W"))
        XCTAssertEqual(InstrumentFormat.position(nil).latitude, "—")
    }
}

final class NavigationReadoutTests: XCTestCase {
    func testSmoothsSpeedAndCourse() throws {
        var readout = NavigationReadout()
        XCTAssertNil(readout.markerDirection)
        let fixes = SimulatedTrack.tampaBay(start: Date(timeIntervalSince1970: 0)).prefix(30)
        for fix in fixes { readout.update(with: fix) }
        let sog = try XCTUnwrap(readout.speedOverGround)
        XCTAssertEqual(Speed(metersPerSecond: sog).knots, 6, accuracy: 0.01)
        let cog = try XCTUnwrap(readout.courseOverGround)
        XCTAssertEqual(cog, try XCTUnwrap(fixes.last?.course), accuracy: 0.5)
        XCTAssertEqual(readout.lastFix, fixes.last)
        XCTAssertEqual(readout.markerDirection, cog)
    }

    func testStoppedBoatUsesHeadingThenHoldsRotation() {
        var readout = NavigationReadout()
        let still = Fix(coordinate: Coordinate(latitude: 27.6, longitude: -82.7), timestamp: Date(timeIntervalSince1970: 0),
                        speed: 0, course: nil)
        readout.update(with: still)
        XCTAssertNil(readout.courseOverGround)
        XCTAssertEqual(readout.mapDirection(for: .courseUp, current: 33), 33, "hold the last rotation")
        readout.update(heading: 370)
        XCTAssertEqual(readout.heading, 10)
        XCTAssertEqual(readout.markerDirection, 10)
        XCTAssertEqual(readout.mapDirection(for: .courseUp, current: 33), 10)
        XCTAssertEqual(readout.mapDirection(for: .northUp, current: 33), 0)
    }

    func testMarkerRotation() {
        XCTAssertEqual(NavigationReadout.markerScreenRotation(markerDirection: 90, mapDirection: 0), 90)
        XCTAssertEqual(NavigationReadout.markerScreenRotation(markerDirection: 90, mapDirection: 90), 0)
        XCTAssertEqual(NavigationReadout.markerScreenRotation(markerDirection: 10, mapDirection: 350), 20)
        XCTAssertEqual(MapOrientationMode.northUp.toggled, .courseUp)
        XCTAssertEqual(MapOrientationMode.courseUp.toggled, .northUp)
    }
}

final class RegionCatalogTests: XCTestCase {
    let now = ChartDates.day(2026, 11, 12)

    func installed(_ id: String, dataDate: Date) -> InstalledRegion {
        InstalledRegion(id: id, title: "Installed \(id)", bounds: BoundingBox(west: -83, south: 27, east: -82, north: 28),
                        minZoom: 0, maxZoom: 16, tileFormat: .png, source: "NOAA",
                        chart: InstalledArtifact(version: "v1", sha256: "abc", byteSize: 100, dataDate: dataDate,
                                                 sourceURL: Fixtures.noaaURL, relativePath: "regions/\(id)/chart.mbtiles",
                                                 installedAt: now, validators: nil))
    }

    /// ResumeRecord has no public memberwise initialiser, so tests build one through Codable.
    func resumeRecord(regionID: String, bytesReceived: Int64) -> ResumeRecord {
        let json = """
        {"regionID": "\(regionID)", "kind": "chart", "url": "\(Fixtures.noaaURL.absoluteString)", "version": "v",
         "expectedByteSize": 1000, "partialRelativePath": "staging/\(regionID)-chart.partial",
         "bytesReceived": \(bytesReceived), "updatedAt": 0}
        """
        return try! JSONDecoder().decode(ResumeRecord.self, from: Data(json.utf8))
    }

    func row(state: InstallState, installed: InstalledRegion? = nil, partial: Int64 = 0, preparing: Bool = false) -> RegionRow {
        let region = Fixtures.region(id: "r1", byteSize: 1_000)
        let pending: [ResumeRecord] = partial > 0
            ? [resumeRecord(regionID: "r1", bytesReceived: partial)]
            : []
        return RegionCatalog.rows(regions: [region], installed: installed.map { [$0] } ?? [], states: ["r1": state],
                                  pending: pending, preparing: preparing ? ["r1"] : [], messages: [:], now: now)[0]
    }

    func testActionsForEveryState() {
        let have = installed("r1", dataDate: ChartDates.day(2024, 5, 28))
        XCTAssertEqual(row(state: .notInstalled).primaryAction, .download)
        XCTAssertEqual(row(state: .notInstalled, partial: 10).primaryAction, .resume)
        XCTAssertEqual(row(state: .queued).primaryAction, .cancel)
        XCTAssertEqual(row(state: .downloading(DownloadProgress(bytesReceived: 5, totalBytes: 10))).primaryAction, .cancel)
        XCTAssertEqual(row(state: .verifying).primaryAction, .cancel)
        XCTAssertEqual(row(state: .installing).primaryAction, .cancel)
        XCTAssertEqual(row(state: .installed(version: "v1"), installed: have).primaryAction, .none)
        XCTAssertEqual(row(state: .failed(.cancelled), partial: 10).primaryAction, .resume)
        XCTAssertEqual(row(state: .failed(.interrupted(bytesReceived: 10)), partial: 10).primaryAction, .resume)
        XCTAssertEqual(row(state: .failed(.checksumMismatch(expected: "a", actual: "b"))).primaryAction, .download)
        XCTAssertEqual(row(state: .failed(.corruptPackage("x")), installed: have).primaryAction, .update)
        XCTAssertEqual(row(state: .updateAvailable(installedVersion: "v1", availableVersion: "v2"), installed: have).primaryAction,
                       .update)
        XCTAssertEqual(row(state: .notInstalled, preparing: true).primaryAction, .cancel)
    }

    func testRowDetails() {
        let have = installed("r1", dataDate: ChartDates.day(2024, 5, 28))
        let r = row(state: .installed(version: "v1"), installed: have)
        XCTAssertEqual(r.downloadBytes, 1_000)
        XCTAssertEqual(r.age?.level, .critical)
        XCTAssertTrue(r.canDelete)
        XCTAssertEqual(r.statusText, "Installed")
        let downloading = row(state: .downloading(DownloadProgress(bytesReceived: 500, totalBytes: 1_000)))
        XCTAssertEqual(downloading.progressFraction, 0.5)
        XCTAssertEqual(downloading.statusText, "500 bytes of 1.00 KB")
        XCTAssertFalse(downloading.canDelete)
        XCTAssertFalse(row(state: .notInstalled).canDelete)
        XCTAssertTrue(row(state: .notInstalled, partial: 10).canDelete)
    }

    func testInstalledRegionsMissingFromManifestAreListed() {
        let rows = RegionCatalog.rows(regions: [Fixtures.region(id: "r1")], installed: [installed("old", dataDate: now)],
                                      states: [:], pending: [], preparing: [], messages: ["r1": "hello"], now: now)
        XCTAssertEqual(rows.map(\.id), ["r1", "old"])
        XCTAssertEqual(rows[0].message, "hello")
        XCTAssertEqual(rows[1].state, .installed(version: "v1"))
    }

    func testConfirmation() {
        let ok = DownloadConfirmation.make(regionTitle: "Region 13", downloadBytes: 380_833_792, alreadyDownloaded: 0,
                                           freeBytes: 5_000_000_000)
        XCTAssertEqual(ok.title, "Download Region 13?")
        XCTAssertTrue(ok.message.contains("381 MB"))
        XCTAssertTrue(ok.canProceed)
        let resume = DownloadConfirmation.make(regionTitle: "R", downloadBytes: 1_000_000_000, alreadyDownloaded: 400_000_000,
                                               freeBytes: nil)
        XCTAssertTrue(resume.message.contains("600 MB left to download of 1.00 GB"))
        let full = DownloadConfirmation.make(regionTitle: "R", downloadBytes: 1_000_000_000, alreadyDownloaded: 0,
                                             freeBytes: 500_000_000)
        XCTAssertFalse(full.canProceed)
    }

    func testAgeBadgeUsesOldestRegion() throws {
        XCTAssertNil(ChartAgeBadge.make(installed: [], now: now))
        let badge = try XCTUnwrap(ChartAgeBadge.make(installed: [installed("a", dataDate: ChartDates.day(2026, 11, 1)),
                                                                installed("b", dataDate: ChartDates.day(2024, 5, 28))],
                                                    now: now))
        XCTAssertEqual(badge.level, .critical)
        XCTAssertTrue(badge.text.hasPrefix("Charts 28 May 2024 · "))
        let fresh = try XCTUnwrap(ChartAgeBadge.make(installed: [installed("a", dataDate: ChartDates.day(2026, 11, 1))], now: now))
        XCTAssertEqual(fresh, ChartAgeBadge(text: "Charts 1 Nov 2026", level: .current))
    }

    func testFailureDescriptionsCoverEveryCase() {
        let failures: [InstallFailure] = [
            .insufficientDiskSpace(required: 2_000_000, available: 1_000_000), .interrupted(bytesReceived: 5),
            .checksumMismatch(expected: "a", actual: "b"), .sizeMismatch(expected: 1, actual: 2), .corruptPackage("x"),
            .transport("t"), .fileSystem("f"), .cancelled, .invalidRequest("i"), .alreadyInProgress,
        ]
        for failure in failures {
            XCTAssertFalse(RegionRow.describe(failure).isEmpty)
        }
        XCTAssertEqual(RegionRow.describe(.cancelled), "Paused")
    }
}

final class EnvironmentTests: XCTestCase {
    func testPathsAndPreparation() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let paths = AppPaths(libraryDirectory: dir.url)
        XCTAssertEqual(paths.chartsDirectory.lastPathComponent, "Charts")
        XCTAssertEqual(paths.storeURL.lastPathComponent, "gulfnav.sqlite")
        XCTAssertEqual(paths.storeURL.deletingLastPathComponent().lastPathComponent, "AppData")
        try paths.prepare()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.chartsDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.dataDirectory.path))
        #if canImport(Darwin)
        XCTAssertTrue(AppPaths.isExcludedFromBackup(paths.chartsDirectory))
        #endif
        XCTAssertTrue(AppPaths.isSafeForMBTilesURL(paths.chartsDirectory))
    }

    func testMBTilesURLSafety() {
        XCTAssertTrue(AppPaths.isSafeForMBTilesURL(URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Library/Charts/x.mbtiles")))
        XCTAssertFalse(AppPaths.isSafeForMBTilesURL(URL(fileURLWithPath: "/var/mobile/Library/Application Support/x.mbtiles")))
        XCTAssertFalse(AppPaths.isSafeForMBTilesURL(URL(fileURLWithPath: "/tmp/100%/x.mbtiles")))
    }

    func testDisclaimerStores() async throws {
        XCTAssertTrue(Disclaimer.needsAcknowledgement(nil))
        XCTAssertTrue(Disclaimer.needsAcknowledgement(DisclaimerRecord(version: 0, date: Date()), currentVersion: 1))
        XCTAssertFalse(Disclaimer.needsAcknowledgement(DisclaimerRecord(version: 1, date: Date()), currentVersion: 1))
        XCTAssertEqual(Disclaimer.points.count, 5)

        let memory = InMemoryAcknowledgementStore()
        let none = try await memory.disclaimerAcknowledgement()
        XCTAssertNil(none)
        let record = DisclaimerRecord(version: 1, date: Date(timeIntervalSince1970: 1_000))
        try await memory.acknowledgeDisclaimer(record)
        let stored = try await memory.disclaimerAcknowledgement()
        XCTAssertEqual(stored, record)

        let suite = "appservices-tests-\(UUID().uuidString)"
        let defaults = UserDefaultsAcknowledgementStore(suiteName: suite)
        let empty = try await defaults.disclaimerAcknowledgement()
        XCTAssertNil(empty)
        try await defaults.acknowledgeDisclaimer(record)
        let read = try await defaults.disclaimerAcknowledgement()
        XCTAssertEqual(read, record)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
