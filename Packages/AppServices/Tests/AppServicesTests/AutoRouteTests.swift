import ChartKit
import Foundation
import NavCore
import Persistence
@testable import RoutingKit
import XCTest
@testable import AppServices

/// The repository's routing test packs (`testdata/routing`), found relative to this file.
enum RoutingFixtures {
    static let directory: URL = {
        let here = URL(fileURLWithPath: #filePath)
        // .../Packages/AppServices/Tests/AppServicesTests/AutoRouteTests.swift → repository root is 5 levels up.
        return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdata").appendingPathComponent("routing")
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// 13 Nov 2026 12:00 UTC: the Sarasota pack (data 23 Oct 2026) is 21 days old.
    static let now: Date = Date(timeIntervalSince1970: 1_794_571_200)

    static func profile(name: String = "Test boat", draftFeet: Double, marginFeet: Double, airFeet: Double?,
                        maintained: Bool = false, unknown: Bool = false, speedKnots: Double? = 6) -> Persistence.BoatProfile {
        Persistence.BoatProfile(name: name, draft: .feet(draftFeet), safetyMargin: .feet(marginFeet),
                                airDraft: airFeet.map(Distance.feet), cruisingSpeed: speedKnots.map(Speed.knots),
                                useMaintainedChannels: maintained, acceptUnknownClearance: unknown)
    }

    static func endpoint(_ name: String, lon: Double, lat: Double) -> AutoRouteEndpoint {
        AutoRouteEndpoint(kind: .waypoint, coordinate: Coordinate(latitude: lat, longitude: lon), name: name)
    }

    // Points from sarasota.vectors.json and synthetic.vectors.json.
    static let longboat = endpoint("Longboat", lon: -82.603, lat: 27.403)
    static let marinaJack = endpoint("Marina Jack", lon: -82.5465, lat: 27.333)
    static let robertsBay = endpoint("Roberts Bay", lon: -82.539, lat: 27.262)
    static let onLand = endpoint("On land", lon: -82.53, lat: 27.34)
    static let ringlingNorth = endpoint("North of Ringling", lon: -82.6, lat: 27.38)
    static let southOfRingling = endpoint("South", lon: -82.545, lat: 27.3)
    static let smallWater = endpoint("Small water", lon: -82.5454965, lat: 27.3326002)
    static let synWest = endpoint("West", lon: -81.9995, lat: 27.0015)
    static let synEast = endpoint("East", lon: -81.9925, lat: 27.0015)
}

/// A library with copies of the test packs in a temporary side-load directory.
final class PackFixture {
    let dir: TempDir
    let library: RoutingPackLibrary
    let store: PersistenceStore

    init(packs: [String] = ["sarasota.pack"]) throws {
        dir = try TempDir()
        library = RoutingPackLibrary(sideLoadDirectory: dir.url.appendingPathComponent("RoutingPacks"))
        for name in packs { try library.sideLoad(from: RoutingFixtures.url(name)) }
        store = try PersistenceStore(inMemoryWith: PersistenceStore.Options())
    }

    deinit { dir.cleanup() }

    func planner(acknowledged: Bool = true) async throws -> AutoRoutePlanner {
        let gate = AutoRouteNoticeGate(store: store)
        if acknowledged { try await gate.acknowledge(now: RoutingFixtures.now) }
        return AutoRoutePlanner(library: library, noticeGate: gate)
    }
}

final class BoatProfileTests: XCTestCase {
    func testConversionToRoutingKitUsesFeetAndRoundsUpToWholeFeet() throws {
        // 4.5 ft + 1.5 ft and 20 ft, stored in metres by Persistence: RoutingKit needs exactly 6 ft = 18 dm, air 60 dm.
        let p = RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: 20)
        XCTAssertEqual(p.draft.meters, 1.3716, accuracy: 1e-12)
        let boat = try XCTUnwrap(EffectiveBoat(profile: p, options: AutoRouteOptions()))
        let rk = boat.routingProfile
        XCTAssertEqual(rk.draftFeet, 4.5, accuracy: 1e-9)
        XCTAssertEqual(rk.safetyMarginFeet, 1.5, accuracy: 1e-9)
        XCTAssertEqual(rk.airDraftFeet, 20, accuracy: 1e-9)
        XCTAssertEqual(rk.requiredDepthDm, 18)
        XCTAssertEqual(rk.requiredAirDm, 60)
        XCTAssertFalse(rk.useMaintainedChannels)
        XCTAssertFalse(rk.avoidOpenGulf)

        // Metric boat: 1.2 m + 0.3 m = 4.92 ft → 5 ft → 15 dm; air draft 6 m = 19.69 ft → 20 ft → 60 dm.
        let metric = Persistence.BoatProfile(name: "Metric", draft: .meters(1.2), safetyMargin: .meters(0.3), airDraft: .meters(6))
        let mk = try XCTUnwrap(EffectiveBoat(profile: metric, options: AutoRouteOptions())).routingProfile
        XCTAssertEqual(mk.draftFeet, 1.2 / 0.3048, accuracy: 1e-9)
        XCTAssertEqual(mk.requiredDepthDm, 15)
        XCTAssertEqual(mk.requiredAirDm, 60)

        // Exactly 3 ft (stored as 0.9144 m) must not round up to 4 ft.
        let three = RoutingFixtures.profile(draftFeet: 2, marginFeet: 1, airFeet: 10)
        XCTAssertEqual(try XCTUnwrap(EffectiveBoat(profile: three, options: AutoRouteOptions())).routingProfile.requiredDepthDm, 9)

        // Plan options override the profile flags for that plan only.
        let opts = AutoRouteOptions(useMaintainedChannels: true, acceptUnknownClearance: true, avoidOpenGulf: true)
        let over = try XCTUnwrap(EffectiveBoat(profile: p, options: opts))
        XCTAssertTrue(over.routingProfile.useMaintainedChannels)
        XCTAssertTrue(over.routingProfile.acceptUnknownClearance)
        XCTAssertTrue(over.routingProfile.avoidOpenGulf)
        XCTAssertFalse(p.useMaintainedChannels)
        XCTAssertEqual(over.snapshot.draftMeters, 1.3716, accuracy: 1e-12)
        XCTAssertEqual(over.snapshot.airDraftMeters ?? 0, 6.096, accuracy: 1e-12)
        XCTAssertTrue(over.snapshot.useMaintainedChannels)
    }

    func testConversionSurvivesAStoreRoundTrip() async throws {
        let store = try PersistenceStore(inMemoryWith: PersistenceStore.Options())
        let saved = try await store.save(RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: 20))
        let loaded = try await XCTUnwrapAsync(await store.boatProfile(saved.id))
        let rk = try XCTUnwrap(EffectiveBoat(profile: loaded, options: AutoRouteOptions())).routingProfile
        XCTAssertEqual(rk.requiredDepthDm, 18)
        XCTAssertEqual(rk.requiredAirDm, 60)
        XCTAssertTrue(loaded.isDefault, "the first profile saved becomes the default")
    }

    func testProfileCheckRequiresAirDraftAndSaneValues() {
        XCTAssertEqual(AutoRouteProfileCheck.problems(RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: 20)), [])
        let noAir = AutoRouteProfileCheck.problems(RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: nil))
        XCTAssertEqual(noAir.count, 1)
        XCTAssertTrue(noAir[0].contains("air draft"))
        XCTAssertNil(EffectiveBoat(profile: RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: nil), options: AutoRouteOptions()))
        XCTAssertEqual(AutoRouteProfileCheck.problems(RoutingFixtures.profile(draftFeet: 0, marginFeet: 1, airFeet: 10)).count, 1)
        XCTAssertEqual(AutoRouteProfileCheck.problems(RoutingFixtures.profile(draftFeet: 200, marginFeet: -1, airFeet: 900)).count, 3)
    }

    func testNewProfileFormHasDefaultsAndBuildsTheProfile() throws {
        let form = BoatProfileForm(profile: nil, units: UnitPreferences(), makeDefault: true)
        XCTAssertEqual(form.name, "My boat")
        XCTAssertEqual(form.draft, "4.5")
        XCTAssertEqual(form.safetyMargin, "1.5")
        XCTAssertEqual(form.airDraft, "20")
        XCTAssertEqual(form.beam, "")
        XCTAssertEqual(form.cruisingSpeed, "6")
        XCTAssertEqual(form.lengthUnitSymbol, "ft")
        XCTAssertEqual(form.speedUnitSymbol, "kn")
        XCTAssertTrue(form.isDefault)
        XCTAssertEqual(form.problems, [])
        let profile = try form.profile(updating: nil).get()
        XCTAssertEqual(profile.draft.feet, 4.5, accuracy: 1e-9)
        XCTAssertEqual(profile.airDraft?.feet ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(profile.cruisingSpeed?.knots ?? 0, 6, accuracy: 1e-9)
        XCTAssertNil(profile.beam)
        XCTAssertTrue(profile.isDefault)
    }

    func testFormParsesUnitsAndCommasAndKeepsIdentityWhenEditing() throws {
        let existing = Persistence.BoatProfile(name: "Old", draft: .meters(1), createdAt: Date(timeIntervalSince1970: 0))
        var form = BoatProfileForm(profile: existing, units: UnitPreferences(distance: .kilometers, depth: .meters, speed: .kilometersPerHour))
        XCTAssertEqual(form.draft, "1")
        XCTAssertEqual(form.safetyMargin, "0.3", "Persistence's default margin is 1 ft = 0.3048 m")
        XCTAssertEqual(form.airDraft, "")
        form.name = "  Sea Breeze  "
        form.draft = "1,4"
        form.safetyMargin = "0.5"
        form.airDraft = "12.5"
        form.beam = "3"
        form.cruisingSpeed = "11.1"
        form.useMaintainedChannels = true
        let p = try form.profile(updating: existing).get()
        XCTAssertEqual(p.id, existing.id)
        XCTAssertEqual(p.createdAt, existing.createdAt)
        XCTAssertEqual(p.name, "Sea Breeze")
        XCTAssertEqual(p.draft.meters, 1.4, accuracy: 1e-12)
        XCTAssertEqual(p.airDraft?.meters ?? 0, 12.5, accuracy: 1e-12)
        XCTAssertEqual(p.beam?.meters ?? 0, 3, accuracy: 1e-12)
        XCTAssertEqual(p.cruisingSpeed?.kilometersPerHour ?? 0, 11.1, accuracy: 1e-9)
        XCTAssertTrue(p.useMaintainedChannels)

        // Back into a form in feet and knots.
        let feet = BoatProfileForm(profile: p, units: UnitPreferences())
        XCTAssertEqual(feet.draft, "4.59")
        XCTAssertEqual(feet.cruisingSpeed, "5.99")
    }

    func testFormReportsEachProblem() {
        var form = BoatProfileForm(profile: nil, units: UnitPreferences())
        form.name = " "
        form.draft = "abc"
        form.safetyMargin = "-1"
        form.airDraft = ""
        form.beam = "500"
        form.cruisingSpeed = "0"
        let problems = form.problems
        XCTAssertEqual(problems.map(\.field), [.name, .draft, .safetyMargin, .airDraft, .beam, .cruisingSpeed])
        XCTAssertEqual(problems[0].message, "Enter a name for the boat.")
        XCTAssertEqual(problems[1].message, "Draft must be a number above 0 ft.")
        XCTAssertEqual(problems[2].message, "Safety margin must be a number 0 or more ft.")
        XCTAssertEqual(problems[3].message, "Enter the air draft in ft.")
        XCTAssertEqual(problems[4].message, "Beam looks too large (at most 100 ft). Check the unit.")
        XCTAssertEqual(problems[5].message, "Cruising speed must be a number above 0 kn, or left empty.")
        form = BoatProfileForm(profile: nil, units: UnitPreferences())
        form.safetyMargin = "0"
        form.cruisingSpeed = ""
        XCTAssertEqual(form.problems, [], "a zero margin and no cruising speed are allowed")
        form.draft = "50"
        XCTAssertEqual(form.problems.map(\.field), [.draft])
    }

    func testProfileRowsAndStoreDefaultFlag() async throws {
        let store = try PersistenceStore(inMemoryWith: PersistenceStore.Options())
        let a = try await store.save(RoutingFixtures.profile(name: "Alpha", draftFeet: 4.5, marginFeet: 1.5, airFeet: 20))
        var bProfile = RoutingFixtures.profile(name: "Bravo", draftFeet: 3, marginFeet: 1, airFeet: nil, maintained: true, speedKnots: nil)
        bProfile.isDefault = true
        let b = try await store.save(bProfile)
        let all = try await store.boatProfiles()
        XCTAssertEqual(all.map(\.name), ["Bravo", "Alpha"], "default first")
        XCTAssertEqual(all.filter(\.isDefault).map(\.id), [b.id])
        let rows = all.map { BoatProfileRow(profile: $0, units: UnitPreferences()) }
        XCTAssertEqual(rows[0].detail, "Draft 3.0 ft + 1.0 ft margin · no air draft")
        XCTAssertEqual(rows[0].options, ["Uses maintained channels"])
        XCTAssertEqual(rows[1].detail, "Draft 4.5 ft + 1.5 ft margin · air draft 20.0 ft · 6.0 kn")
        try await store.setDefaultBoatProfile(a.id)
        let defaultProfile = try await store.defaultBoatProfile()
        XCTAssertEqual(defaultProfile?.id, a.id)
    }
}

final class AutoRouteNoticeTests: XCTestCase {
    func testNoticeMustBeAcknowledgedAndIsAskedAgainForANewVersion() async throws {
        let store = try PersistenceStore(inMemoryWith: PersistenceStore.Options())
        let gate = AutoRouteNoticeGate(store: store)
        let before = await gate.needsAcknowledgement()
        XCTAssertTrue(before)
        try await gate.acknowledge(now: RoutingFixtures.now)
        let after = await gate.needsAcknowledgement()
        XCTAssertFalse(after)
        let stored = try await store.setting(.autoRouteNoticeAcknowledgement)
        XCTAssertEqual(stored, DisclaimerAcknowledgement(version: AutoRouteNotice.version, date: RoutingFixtures.now))
        let newer = AutoRouteNoticeGate(store: store, currentVersion: AutoRouteNotice.version + 1)
        let again = await newer.needsAcknowledgement()
        XCTAssertTrue(again, "a new notice text is asked again")
        XCTAssertTrue(AutoRouteNotice.fullText.contains("chart datum"))
        XCTAssertTrue(AutoRouteNotice.fullText.contains("No tide is added"))
        XCTAssertTrue(AutoRouteNotice.fullText.contains("Review every leg"))
        XCTAssertTrue(AutoRouteNotice.fullText.contains("date of the chart data"))
    }

    func testPlannerRefusesUntilTheNoticeIsAcknowledged() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner(acknowledged: false)
        let request = AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
                                           profile: RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: 20))
        let outcome = await planner.plan(request, now: RoutingFixtures.now)
        XCTAssertEqual(outcome.statusCode, "noticeNotAcknowledged")
        XCTAssertNil(fixture.library.loadedPackID, "nothing is loaded before the notice is acknowledged")
        try await AutoRouteNoticeGate(store: fixture.store).acknowledge()
        let second = await planner.plan(request, now: RoutingFixtures.now)
        XCTAssertEqual(second.statusCode, "proposal")
    }
}

final class RoutingPackLibraryTests: XCTestCase {
    func testCatalogReadsHeadersAndSelectsTheCoveringPack() async throws {
        let fixture = try PackFixture(packs: ["sarasota.pack", "synthetic.pack"])
        let catalog = await fixture.library.catalog()
        XCTAssertEqual(catalog.problems, [])
        XCTAssertEqual(catalog.entries.map(\.packRegionID).sorted(), ["pilot-sarasota", "synthetic"])
        let sarasota = try XCTUnwrap(catalog.entries.first { $0.packRegionID == "pilot-sarasota" })
        XCTAssertEqual(sarasota.origin, .sideLoaded)
        XCTAssertEqual(sarasota.id, "file:pilot-sarasota.pack")
        XCTAssertEqual(sarasota.dataDateRaw, 20261023)
        XCTAssertEqual(sarasota.version, "pilot-sarasota-20261023")
        XCTAssertEqual(sarasota.formatVersion, "1.1")
        XCTAssertEqual(sarasota.coverage, RoutingPackCoverage(south: 27.24, west: -82.62, north: 27.42, east: -82.5))
        let size = try FileManager.default.attributesOfItem(atPath: RoutingFixtures.url("sarasota.pack").path)[.size] as? NSNumber
        XCTAssertEqual(sarasota.byteSize, size?.int64Value)
        XCTAssertEqual(sarasota.descriptionLine, "pilot-sarasota (side-loaded) · chart data 23 Oct 2026 · \(ByteFormat.string(sarasota.byteSize))")
        XCTAssertNil(fixture.library.loadedPackID, "listing reads headers only")

        let both = await fixture.library.select(start: RoutingFixtures.longboat.coordinate, goal: RoutingFixtures.marinaJack.coordinate)
        XCTAssertEqual(both, .pack(sarasota))
        let split = await fixture.library.select(start: RoutingFixtures.synWest.coordinate, goal: RoutingFixtures.marinaJack.coordinate)
        guard case .differentPacks(let a, let b) = split else { return XCTFail("\(split)") }
        XCTAssertEqual(a.packRegionID, "synthetic")
        XCTAssertEqual(b.packRegionID, "pilot-sarasota")
        let far = Coordinate(latitude: 30.4, longitude: -87.2)
        let none = await fixture.library.select(start: far, goal: RoutingFixtures.marinaJack.coordinate)
        XCTAssertEqual(none, .notCovered(start: true, goal: false))

        let empty = RoutingPackLibrary(sideLoadDirectory: fixture.dir.url.appendingPathComponent("nothing-here"))
        let nothing = await empty.select(start: far, goal: far)
        XCTAssertEqual(nothing, .noPacksInstalled)
    }

    func testSelectionPrefersNewestThenChartRegionPacks() {
        func entry(_ id: String, _ origin: RoutingPackEntry.Origin, _ date: UInt32) -> RoutingPackEntry {
            RoutingPackEntry(id: id, origin: origin, chartRegionID: origin == .chartRegion ? id : nil, title: id, packRegionID: id,
                             fileURL: URL(fileURLWithPath: "/x/\(id)"), byteSize: 1, dataDate: nil, dataDateRaw: date,
                             version: id, formatVersion: "1.1",
                             coverage: RoutingPackCoverage(south: 27, west: -83, north: 28, east: -82))
        }
        let p = Coordinate(latitude: 27.5, longitude: -82.5)
        let old = entry("a-old", .chartRegion, 20260101)
        let newSide = entry("b-side", .sideLoaded, 20261001)
        let newRegion = entry("c-region", .chartRegion, 20261001)
        XCTAssertEqual(RoutingPackSelection.choose(from: [old, newSide, newRegion], start: p, goal: p), .pack(newRegion))
        XCTAssertEqual(RoutingPackSelection.choose(from: [old, newSide], start: p, goal: p), .pack(newSide))
    }

    func testOnlyOnePackIsHeldAndCorruptPacksAreRejected() async throws {
        let fixture = try PackFixture(packs: ["sarasota.pack", "synthetic.pack"])
        let catalog = await fixture.library.catalog()
        let s = try XCTUnwrap(catalog.entries.first { $0.packRegionID == "pilot-sarasota" })
        let y = try XCTUnwrap(catalog.entries.first { $0.packRegionID == "synthetic" })
        let first = try fixture.library.open(s)
        XCTAssertEqual(fixture.library.loadedPackID, s.id)
        XCTAssertTrue(try fixture.library.open(s) === first, "the same entry reuses the loaded pack")
        _ = try fixture.library.open(y)
        XCTAssertEqual(fixture.library.loadedPackID, y.id, "opening another pack replaces the first")
        fixture.library.release()
        XCTAssertNil(fixture.library.loadedPackID)

        // A corrupt copy: listing reports it (header CRC), side-loading and the install validator reject it.
        var bytes = [UInt8](try Data(contentsOf: RoutingFixtures.url("synthetic.pack")))
        bytes[bytes.count - 9] ^= 0x10
        let bad = fixture.dir.url.appendingPathComponent("bad.pack")
        try Data(bytes).write(to: bad)
        XCTAssertThrowsError(try fixture.library.validate(fileAt: bad)) { error in
            XCTAssertTrue(error is RoutingPackRejection, "\(error)")
        }
        XCTAssertThrowsError(try fixture.library.sideLoad(from: bad))
        _ = try fixture.library.open(s)
        XCTAssertNoThrow(try fixture.library.installValidator(RoutingFixtures.url("sarasota.pack")))
        XCTAssertNil(fixture.library.loadedPackID, "validating releases the loaded pack first")

        let junk = fixture.library.sideLoadDirectory.appendingPathComponent("junk.pack")
        try Data(repeating: 7, count: 300).write(to: junk)
        let withJunk = await fixture.library.catalog()
        XCTAssertEqual(withJunk.entries.count, 2)
        XCTAssertEqual(withJunk.problems.map(\.id), ["file:junk.pack"])
        XCTAssertEqual(withJunk.problems.first?.message, "not a routing pack (bad magic)")

        try fixture.library.removeSideLoaded(y)
        let after = await fixture.library.catalog()
        XCTAssertEqual(after.entries.map(\.packRegionID), ["pilot-sarasota"])
    }

    /// Routing packs installed with a chart region through ChartKit: the validator hook rejects a corrupt pack,
    /// and an installed pack is listed against its region.
    func testChartKitInstallUsesTheValidatorAndListsTheRegionPack() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        guard let chartFile = Bundle.module.url(forResource: "tiny-a.mbtiles", withExtension: nil, subdirectory: "Resources") else {
            return XCTFail("missing tiny-a.mbtiles")
        }
        let goodPack = RoutingFixtures.url("sarasota.pack")
        var bytes = [UInt8](try Data(contentsOf: goodPack))
        bytes[bytes.count / 2] ^= 0x01
        let badPack = dir.url.appendingPathComponent("corrupt.pack")
        try Data(bytes).write(to: badPack)
        let goodURL = URL(string: "https://fixtures.gulfnav.invalid/routing-good.pack")!
        let badURL = URL(string: "https://fixtures.gulfnav.invalid/routing-bad.pack")!
        let transport = LocalFileChartTransport(files: [FixtureChart.packageURL: chartFile, goodURL: goodPack, badURL: badPack],
                                                fallback: nil)
        let env = try AppEnvironment.make(paths: AppPaths(libraryDirectory: dir.url.appendingPathComponent("lib")),
                                          transport: transport, diskSpace: FixedDiskSpace(bytes: 10_000_000_000),
                                          configuration: ChartInstaller.Configuration(freeSpaceMargin: 0))
        func region(_ url: URL, _ file: URL) throws -> ChartRegion {
            var r = FixtureChart.region
            let data = try Data(contentsOf: file)
            r.routingPack = RoutingPackArtifact(url: url, byteSize: Int64(data.count), sha256: StreamingSHA256.hash(data),
                                                version: "sarasota-1", dataDate: ChartDates.day(2026, 10, 23), formatVersion: 1)
            return r
        }
        do {
            _ = try await env.charts.install(try region(badURL, badPack))
            XCTFail("a corrupt routing pack must be rejected")
        } catch let failure as InstallFailure {
            guard case .corruptPackage(let message) = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(message.contains("routing pack rejected"), message)
        }
        let before = await env.routingPacks.catalog()
        XCTAssertEqual(before.entries, [], "nothing installed after the rejection")

        _ = try await env.charts.install(try region(goodURL, goodPack))
        let catalog = await env.routingPacks.catalog()
        let entry = try XCTUnwrap(catalog.entry(forChartRegion: FixtureChart.regionID))
        XCTAssertEqual(entry.origin, .chartRegion)
        XCTAssertEqual(entry.title, FixtureChart.title)
        XCTAssertEqual(entry.version, "sarasota-1")
        XCTAssertEqual(entry.packRegionID, "pilot-sarasota")
        XCTAssertTrue(entry.fileURL.path.hasSuffix(".routingpack"))
        try await AutoRouteNoticeGate(store: env.store).acknowledge()
        let outcome = await env.planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
                                                                  profile: RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: 20)))
        XCTAssertEqual(outcome.proposal?.pack.id, "region:\(FixtureChart.regionID)")
    }
}

final class AutoRoutePlannerTests: XCTestCase {
    let defaultBoat = RoutingFixtures.profile(name: "Test boat", draftFeet: 4.5, marginFeet: 1.5, airFeet: 20)

    /// sarasota.vectors.json q1: 28 green legs.
    func testSuccessPresentsLegsAndSummary() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        let phases = LockedPhases()
        let outcome = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
                                                              profile: defaultBoat),
                                         now: RoutingFixtures.now, progress: { phases.add($0.phase) })
        let p = try XCTUnwrap(outcome.proposal, "\(outcome)")
        XCTAssertEqual(p.legs.count, 28)
        XCTAssertEqual(p.greenLegs, 28)
        XCTAssertEqual(p.yellowLegs, 0)
        XCTAssertEqual(p.points.count, 29)
        XCTAssertEqual(p.distanceMeters, 10559.349388729319, accuracy: 1e-6)
        XCTAssertEqual(p.safety, .allowed)
        XCTAssertEqual(p.suggestedName, "Longboat to Marina Jack")
        XCTAssertEqual(Array(phases.all.prefix(2)), [.openingPack, .searching])
        XCTAssertEqual(fixture.library.loadedPackID, "file:pilot-sarasota.pack")

        let leg0 = p.legs[0]
        XCTAssertEqual(leg0.title, "Leg 1")
        XCTAssertEqual(leg0.grade, .green)
        XCTAssertEqual(leg0.reasons, [])
        XCTAssertEqual(leg0.lengthMeters, 971.329032560351, accuracy: 1e-6)
        XCTAssertTrue(leg0.detail.hasPrefix("0.52 nm · "), leg0.detail)
        XCTAssertTrue(leg0.detail.hasSuffix(" · least depth 5.9 ft"), leg0.detail)

        let lines = Dictionary(uniqueKeysWithValues: p.summary.map { ($0.id, $0) })
        XCTAssertEqual(lines["distance"]?.value, "5.70 nm")
        XCTAssertEqual(lines["time"]?.label, "Time at 6.0 kn")
        XCTAssertEqual(lines["time"]?.value, "57 min")
        XCTAssertEqual(lines["legs"]?.value, "28 legs: 28 green, 0 yellow")
        XCTAssertEqual(lines["legs"]?.isWarning, false)
        XCTAssertEqual(lines["shallowest"]?.value, "5.9 ft at " + NavFormat.position(Coordinate(latitude: 27.4024097, longitude: -82.6022451)))
        XCTAssertEqual(lines["clearance"]?.value, "Ringling Causeway Bridge A / SR 789: 65.0 ft")
        XCTAssertEqual(lines["openings"]?.value, "None")
        XCTAssertNil(lines["unknownClearance"])
        XCTAssertEqual(lines["startSnap"]?.value, "On the chosen point")
        XCTAssertEqual(lines["goalSnap"]?.value, "Moved 14 ft to navigable water")
        XCTAssertEqual(lines["data"]?.value, "23 Oct 2026 (21 days old)")
        XCTAssertEqual(lines["data"]?.isWarning, false)
        XCTAssertEqual(lines["boat"]?.value, "Test boat: needs 6.0 ft (draft 4.5 ft + 1.5 ft margin), air draft 20.0 ft")
        XCTAssertTrue(lines["pack"]?.value.hasPrefix("pilot-sarasota (side-loaded) · chart data 23 Oct 2026") ?? false)
        XCTAssertEqual(p.summary.map(\.id), ["distance", "time", "legs", "shallowest", "clearance", "openings", "startSnap",
                                             "goalSnap", "data", "pack", "boat"])

        // Metric units.
        let metric = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
                                                             profile: defaultBoat),
                                        units: UnitPreferences(distance: .kilometers, depth: .meters, speed: .kilometersPerHour),
                                        now: RoutingFixtures.now)
        let m = try XCTUnwrap(metric.proposal)
        let mlines = Dictionary(uniqueKeysWithValues: m.summary.map { ($0.id, $0.value) })
        XCTAssertEqual(mlines["distance"], "10.6 km")
        XCTAssertEqual(mlines["goalSnap"], "Moved 4 m to navigable water")
        XCTAssertEqual(mlines["clearance"], "Ringling Causeway Bridge A / SR 789: 19.8 m")
    }

    /// sarasota q4 (strict: no route at the Roberts Bay gap, hint "use maintained channels"), then the hint applied
    /// gives the q3 route (55 legs, 16 yellow).
    func testNoRouteOffersTheHintAndApplyingItPlans() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        let request = AutoRoutePlanRequest(start: RoutingFixtures.marinaJack, goal: RoutingFixtures.robertsBay, profile: defaultBoat)
        let outcome = await planner.plan(request, now: RoutingFixtures.now)
        let n = try XCTUnwrap(outcome.noRoute, "\(outcome)")
        XCTAssertEqual(outcome.statusCode, "noRoute")
        XCTAssertEqual(n.reasonCode, "DEPTH")
        XCTAssertEqual(n.title, "No route for this boat")
        XCTAssertEqual(n.message, "No route for Test boat: the water is too shallow at the place marked on the chart. Your boat needs 6.0 ft of charted depth (draft plus safety margin).")
        XCTAssertEqual(n.blocked.count, 1)
        XCTAssertEqual(n.blocked[0].coordinate.latitude, 27.2762785, accuracy: 1e-9)
        XCTAssertEqual(n.blocked[0].coordinate.longitude, -82.5438497, accuracy: 1e-9)
        XCTAssertEqual(n.blocked[0].reason.title, "Too shallow")
        XCTAssertEqual(n.blocked[0].description,
                       "Too shallow: charted 0.0 ft, your boat needs 6.0 ft (maintained channel depth 8.9 ft) at " + NavFormat.position(n.blocked[0].coordinate))
        XCTAssertEqual(n.hints.map(\.kind), [.useMaintainedChannels])
        XCTAssertEqual(n.hints[0].title, "Allow maintained channels")
        XCTAssertNil(n.noHintText)
        XCTAssertFalse(defaultBoat.useMaintainedChannels, "the hint is never applied by itself")

        let replan = AutoRoutePlanRequest(start: request.start, goal: request.goal, profile: request.profile,
                                          options: n.hints[0].apply(to: request.options))
        XCTAssertEqual(replan.options.useMaintainedChannels, true)
        let second = await planner.plan(replan, now: RoutingFixtures.now)
        let p = try XCTUnwrap(second.proposal, "\(second)")
        XCTAssertEqual(p.legs.count, 55)
        XCTAssertEqual(p.greenLegs, 39)
        XCTAssertEqual(p.yellowLegs, 16)
        for leg in p.legs where leg.grade == .yellow { XCTAssertFalse(leg.reasons.isEmpty, "every yellow leg states a reason") }
        let reasonCodes = Set(p.legs.flatMap { $0.reasons.map(\.code) })
        XCTAssertEqual(reasonCodes, ["MAINTAINED_DEPTH", "LOW_DATA_QUALITY"])
        let lines = Dictionary(uniqueKeysWithValues: p.summary.map { ($0.id, $0) })
        XCTAssertEqual(lines["legs"]?.isWarning, true)
        XCTAssertTrue(lines["shallowest"]?.value.hasPrefix("0.0 ft at ") ?? false)
        XCTAssertTrue(lines["shallowest"]?.value.hasSuffix("(the route uses the maintained channel depth there)") ?? false)
        XCTAssertTrue(lines["boat"]?.value.hasSuffix("; maintained channels allowed") ?? false)
        guard case .needsConfirmation(let c) = p.safety else { return XCTFail("\(p.safety)") }
        XCTAssertEqual(c.title, "16 legs need caution")
        XCTAssertEqual(Set(c.reasons), ["Maintained channel depth (14 legs)", "Poor survey data (2 legs)"])
        XCTAssertEqual(c.confirmLabel, "I have reviewed the yellow legs")
    }

    func testSnapFailureSaysWhichEndAndWhy() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        // q6: the start is on land.
        let outcome = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.onLand, goal: RoutingFixtures.marinaJack,
                                                              profile: defaultBoat), now: RoutingFixtures.now)
        guard case .snapFailed(let s) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(s.end, .start)
        XCTAssertEqual(s.code, "START_NO_WATER_NEARBY")
        XCTAssertEqual(s.title, "Start not on navigable water")
        XCTAssertTrue(s.message.hasPrefix("The start (On land) is not on water deep enough for Test boat (6.0 ft), and there is none within 0.40 nm."), s.message)
        XCTAssertTrue(s.message.hasSuffix("Choose a start on open water."))
        // q7: a 15 ft boat finds no water near the start; the goal fails the same way when swapped.
        let deep = RoutingFixtures.profile(draftFeet: 15, marginFeet: 1.5, airFeet: 20)
        let swapped = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.marinaJack, goal: RoutingFixtures.ringlingNorth,
                                                              profile: deep), now: RoutingFixtures.now)
        guard case .snapFailed(let g) = swapped else { return XCTFail("\(swapped)") }
        XCTAssertEqual(g.end, .start, "Marina Jack itself is too shallow for 16.5 ft")
        XCTAssertTrue(g.message.contains("(16.5 ft)"), g.message)
    }

    /// q5: 66 ft air draft cannot pass the Ringling bridge, and no option helps. q9: separate water.
    func testNoRouteWithoutHelpfulHints() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        let tall = RoutingFixtures.profile(name: "Tall", draftFeet: 4.5, marginFeet: 1.5, airFeet: 66, maintained: true)
        let outcome = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.ringlingNorth, goal: RoutingFixtures.southOfRingling,
                                                              profile: tall), now: RoutingFixtures.now)
        let n = try XCTUnwrap(outcome.noRoute, "\(outcome)")
        XCTAssertEqual(n.reasonCode, "CLEARANCE")
        XCTAssertEqual(n.message, "No route for Tall: a bridge or cable is lower than your air draft of 66.0 ft at the place marked on the chart.")
        XCTAssertEqual(n.blocked.count, 1)
        XCTAssertTrue(n.blocked[0].description.hasPrefix("Too low: Ringling Causeway Bridge A / SR 789, clearance 65.0 ft, your air draft 66.0 ft at "),
                      n.blocked[0].description)
        XCTAssertEqual(n.hints, [])
        XCTAssertEqual(n.noHintText, "Turning on \"accept unknown clearance\" would not give a route either.")

        let separate = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.smallWater, goal: RoutingFixtures.longboat,
                                                               profile: defaultBoat), now: RoutingFixtures.now)
        let s = try XCTUnwrap(separate.noRoute)
        XCTAssertEqual(s.reasonCode, "NOT_CONNECTED")
        XCTAssertEqual(s.title, "No water connection")
        XCTAssertEqual(s.blocked, [])
        XCTAssertEqual(s.hints, [])
        XCTAssertEqual(s.noHintText, "Turning on \"use maintained channels\" or \"accept unknown clearance\" would not give a route either.")
    }

    /// synthetic.pack s2 (bridge opening, maintained depth), s3 (unknown clearance, restricted area, hazard), s1 hints.
    func testSyntheticBridgeOpeningsAndRestrictedAreas() async throws {
        let fixture = try PackFixture(packs: ["synthetic.pack"])
        let planner = try await fixture.planner()
        let s2 = await planner.plan(AutoRoutePlanRequest(
            start: RoutingFixtures.synWest, goal: RoutingFixtures.synEast,
            profile: RoutingFixtures.profile(draftFeet: 4, marginFeet: 1, airFeet: 20, maintained: true)), now: RoutingFixtures.now)
        let p2 = try XCTUnwrap(s2.proposal, "\(s2)")
        XCTAssertEqual(p2.legs.count, 1)
        XCTAssertEqual(p2.legs[0].grade, .yellow)
        XCTAssertEqual(p2.legs[0].reasons.map(\.title), ["Maintained channel depth", "Bridge must open"])
        XCTAssertEqual(p2.legs[0].overheads, ["Under Test Opening Bridge (5.9 ft closed, must open)"])
        let l2 = Dictionary(uniqueKeysWithValues: p2.summary.map { ($0.id, $0) })
        XCTAssertEqual(l2["openings"]?.value, "1: Test Opening Bridge")
        XCTAssertEqual(l2["openings"]?.isWarning, true)
        XCTAssertEqual(l2["clearance"]?.value, "Test Opening Bridge: 5.9 ft closed (opening bridge)")
        XCTAssertEqual(l2["data"]?.value, "1 Nov 2026 (12 days old)")
        XCTAssertEqual(p2.storedLegs, [AutoRouteInfo.Leg(index: 0, grade: .yellow, reasonCodes: ["MAINTAINED_DEPTH", "BRIDGE_OPENING"],
                                                         leastDepthMeters: 0.9, leastClearanceMeters: nil)])
        guard case .needsConfirmation(let c2) = p2.safety else { return XCTFail() }
        XCTAssertEqual(c2.reasons, ["Maintained channel depth (1 leg)", "Bridge must open (1 leg)"])
        XCTAssertEqual(c2.title, "1 leg needs caution")

        let s3 = await planner.plan(AutoRoutePlanRequest(
            start: RoutingFixtures.synWest, goal: RoutingFixtures.synEast,
            profile: RoutingFixtures.profile(draftFeet: 4, marginFeet: 1, airFeet: 8, unknown: true)), now: RoutingFixtures.now)
        let p3 = try XCTUnwrap(s3.proposal, "\(s3)")
        XCTAssertEqual(p3.legs.count, 3)
        XCTAssertEqual(p3.greenLegs, 1)
        XCTAssertEqual(p3.yellowLegs, 2)
        XCTAssertEqual(Set(p3.legs.flatMap { $0.reasons.map(\.title) }), ["Clearance not charted", "Restricted area", "Near a charted hazard"])
        let l3 = Dictionary(uniqueKeysWithValues: p3.summary.map { ($0.id, $0) })
        XCTAssertEqual(l3["unknownClearance"]?.value, "1: Test Cable")
        XCTAssertEqual(l3["clearance"]?.value, "Test Fixed Bridge: 9.8 ft")
        XCTAssertEqual(l3["openings"]?.value, "None")

        let s1 = await planner.plan(AutoRoutePlanRequest(
            start: RoutingFixtures.synWest, goal: RoutingFixtures.synEast,
            profile: RoutingFixtures.profile(draftFeet: 4, marginFeet: 1, airFeet: 20)), now: RoutingFixtures.now)
        let n1 = try XCTUnwrap(s1.noRoute)
        XCTAssertEqual(n1.hints.map(\.kind), [.useMaintainedChannels, .acceptUnknownClearance])
        XCTAssertEqual(n1.hints.map(\.title), ["Allow maintained channels", "Accept unknown clearance"])

        // Start outside the pack's box (s6) is caught by pack selection, before routing.
        let outside = await planner.plan(AutoRoutePlanRequest(
            start: RoutingFixtures.endpoint("Far west", lon: -82.01, lat: 27.0015), goal: RoutingFixtures.synEast,
            profile: RoutingFixtures.profile(draftFeet: 4, marginFeet: 1, airFeet: 20)), now: RoutingFixtures.now)
        guard case .failed(let f) = outside else { return XCTFail("\(outside)") }
        XCTAssertEqual(f.kind, .notCovered)
        XCTAssertEqual(f.message, "The start (Far west) is not inside an installed routing pack. Install the chart region that covers it.")
    }

    func testFailuresBeforeRouting() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        let noAir = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
                                                            profile: RoutingFixtures.profile(name: "Skiff", draftFeet: 1, marginFeet: 1, airFeet: nil)))
        guard case .failed(let f) = noAir else { return XCTFail() }
        XCTAssertEqual(f.kind, .invalidProfile)
        XCTAssertEqual(f.message, "Skiff cannot be used for routing yet.")
        XCTAssertEqual(f.details.count, 1)

        let emptyDir = try TempDir()
        defer { emptyDir.cleanup() }
        let emptyLibrary = RoutingPackLibrary(sideLoadDirectory: emptyDir.url)
        let emptyPlanner = AutoRoutePlanner(library: emptyLibrary, noticeGate: nil)
        let none = await emptyPlanner.plan(AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
                                                                profile: defaultBoat))
        XCTAssertEqual(none.statusCode, "noPacksInstalled")

        // Cancelled before it starts.
        let cancelRequest = AutoRoutePlanRequest(start: RoutingFixtures.marinaJack, goal: RoutingFixtures.robertsBay,
                                                 profile: defaultBoat)
        let task = Task { [planner] () async -> AutoRoutePlanOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await planner.plan(cancelRequest)
        }
        let cancelled = await task.value
        XCTAssertEqual(cancelled.statusCode, "cancelled")
        guard case .failed(let cf) = cancelled else { return XCTFail() }
        XCTAssertEqual(cf.message, "Planning was cancelled. Nothing was changed.")

        // A damaged pack file that still has a readable header.
        let catalog = await fixture.library.catalog()
        let entry = try XCTUnwrap(catalog.entries.first)
        fixture.library.release()
        var bytes = [UInt8](try Data(contentsOf: entry.fileURL))
        bytes[bytes.count - 9] ^= 0x10
        try Data(bytes).write(to: entry.fileURL)
        let damaged = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
                                                              profile: defaultBoat))
        guard case .failed(let d) = damaged else { return XCTFail("\(damaged)") }
        XCTAssertEqual(d.kind, .packUnreadable)
        XCTAssertEqual(d.title, "Routing pack damaged")
        XCTAssertEqual(d.details.count, 1)
    }

    func testRoutingErrorsWithoutAPackRunAreWorded() throws {
        let entry = RoutingPackEntry(id: "file:x.pack", origin: .sideLoaded, chartRegionID: nil, title: "X", packRegionID: "x",
                                     fileURL: URL(fileURLWithPath: "/x.pack"), byteSize: 1, dataDate: nil, dataDateRaw: 0,
                                     version: "x-0", formatVersion: "1.1",
                                     coverage: RoutingPackCoverage(south: 0, west: 0, north: 1, east: 1))
        let request = AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack, profile: defaultBoat,
                                           options: AutoRouteOptions(timeLimitSeconds: 20))
        let context = AutoRoutePresenter.Context(request: request, boat: try XCTUnwrap(EffectiveBoat(profile: defaultBoat, options: request.options)),
                                                 pack: entry, units: UnitPreferences(), now: RoutingFixtures.now)
        let timed = AutoRoutePresenter.outcome(for: .timedOut(expanded: 5), context: context)
        guard case .failed(let t) = timed else { return XCTFail() }
        XCTAssertEqual(t.kind, .timedOut)
        XCTAssertEqual(t.message, "Planning stopped after 20 seconds without an answer. Try a shorter trip, or plan it in parts.")
        let violation = LegViolation(kind: .hazard, leg: 2, record: 7, distanceMeters: 3, valsouDm: 5, clearanceDm: nil)
        let lv = AutoRoutePresenter.outcome(for: .legValidation(LegValidationReport(violations: [violation], corridor: [1, 2])), context: context)
        guard case .failed(let l) = lv else { return XCTFail() }
        XCTAssertEqual(l.kind, .legValidation)
        XCTAssertEqual(l.title, "Route failed its safety check")
        XCTAssertTrue(l.message.contains("(1 problem)"))
        XCTAssertEqual(l.details, ["Leg 3: hazard"])
        let invalid = AutoRoutePresenter.outcome(for: .invalidRequest("bad"), context: context)
        XCTAssertEqual(invalid.statusCode, "invalidRequest")
        XCTAssertEqual(AutoRoutePresenter.outcome(for: .cancelled, context: context).statusCode, "cancelled")
        XCTAssertEqual(AutoRoutePresenter.ageText(days: 0), "today")
        XCTAssertEqual(AutoRoutePresenter.ageText(days: 1), "1 day old")
        let stale = AutoRoutePresenter.dataLine(ChartDates.day(2026, 1, 1), now: RoutingFixtures.now)
        XCTAssertEqual(stale.value, "1 Jan 2026 (316 days old)")
        XCTAssertTrue(stale.isWarning)
        XCTAssertEqual(AutoRouteReason.caution("NEW_THING").title, "Check this leg (NEW_THING)")
        for reason in CautionReason.allCases {
            XCTAssertFalse(AutoRouteReason.caution(reason.rawValue).title.hasPrefix("Check this leg"), "\(reason) has wording")
        }
    }
}

final class AutoRouteSafetyAndSavingTests: XCTestCase {
    func testSafetyRules() {
        let green = AutoRouteInfo.Leg(index: 0, grade: .green)
        let yellow = AutoRouteInfo.Leg(index: 1, grade: .yellow, reasonCodes: ["BRIDGE_OPENING"])
        XCTAssertEqual(AutoRouteSafety.decide(legs: [green]), .allowed)
        guard case .needsConfirmation(let c) = AutoRouteSafety.decide(legs: [green, yellow]) else { return XCTFail() }
        XCTAssertEqual(c.reasons, ["Bridge must open (1 leg)"])
        XCTAssertEqual(c.fullText, "This route has 1 yellow leg. Check each one yourself before you use the route:\n• Bridge must open (1 leg)")
        let red = AutoRouteInfo.Leg(index: 2, grade: .red, reasonCodes: ["X"])
        XCTAssertEqual(AutoRouteSafety.decide(legs: [green, yellow, red]),
                       .refused("Leg 3 is graded red. Only green and yellow legs can be saved or followed."))
        let odd = AutoRouteInfo.Leg(index: 0, grade: LegGrade(rawValue: "purple"))
        XCTAssertFalse(AutoRouteSafety.decide(legs: [odd]).canSave)
        let silent = AutoRouteInfo.Leg(index: 1, grade: .yellow)
        XCTAssertEqual(AutoRouteSafety.decide(legs: [green, silent]),
                       .refused("Leg 2 is marked for caution without a stated reason, so the route cannot be used."))
        XCTAssertFalse(AutoRouteSafety.decide(legs: []).canSave)
    }

    func testSavingRoundTripsThroughARealStore() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        let boat = RoutingFixtures.profile(name: "Test boat", draftFeet: 4.5, marginFeet: 1.5, airFeet: 20)
        let request = AutoRoutePlanRequest(start: RoutingFixtures.marinaJack, goal: RoutingFixtures.robertsBay, profile: boat,
                                           options: AutoRouteOptions(useMaintainedChannels: true))
        let planned = await planner.plan(request, now: RoutingFixtures.now)
        let proposal = try XCTUnwrap(planned.proposal)
        let file = fixture.dir.url.appendingPathComponent("store.sqlite")
        let store = try PersistenceStore(url: file)

        do {
            _ = try await AutoRouteSaving.save(proposal, name: "Trip", cautionConfirmed: false, store: store)
            XCTFail("yellow legs need the confirmation")
        } catch {
            guard case .confirmationRequired(let c) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(c.title, "16 legs need caution")
        }
        var forged = proposal
        forged.storedLegs[3].grade = .red
        do {
            _ = try await AutoRouteSaving.save(forged, name: "Trip", cautionConfirmed: true, store: store)
            XCTFail("a red leg is never saved")
        } catch {
            guard case .refused = error else { return XCTFail("\(error)") }
        }
        let countBefore = try await store.routes().count
        XCTAssertEqual(countBefore, 0)

        let saved = try await AutoRouteSaving.save(proposal, name: "  \(proposal.suggestedName) ", cautionConfirmed: true, store: store,
                                                   now: RoutingFixtures.now)
        XCTAssertEqual(saved.name, "Marina Jack to Roberts Bay")
        // Reopen the file: the route comes back as the existing screens read it.
        let reopened = try PersistenceStore(url: file)
        let route = try await XCTUnwrapAsync(await reopened.route(saved.id))
        XCTAssertEqual(route.points.count, 56)
        XCTAssertEqual(route.points.first?.name, "Marina Jack")
        XCTAssertEqual(route.points.last?.name, "Roberts Bay")
        XCTAssertEqual(route.points[1].coordinate, proposal.points[1])
        XCTAssertTrue(route.notes.hasPrefix("Auto-route suggestion from Gulf Nav."))
        XCTAssertTrue(route.notes.contains("Chart data: 23 Oct 2026"))
        let info = try XCTUnwrap(route.metadata?.autoRouteInfo)
        XCTAssertEqual(info.legs.count, 55)
        XCTAssertEqual(info.legs.filter { $0.grade == .yellow }.count, 16)
        XCTAssertEqual(info.legs, proposal.storedLegs)
        XCTAssertEqual(info.summary.worstGrade, .yellow)
        XCTAssertEqual(info.summary.distanceMeters ?? 0, 8545.565739365891, accuracy: 1e-6)
        XCTAssertEqual(info.summary.shallowestDepthMeters, 0)
        XCTAssertEqual(info.summary.lowestClearanceMeters ?? 0, 7.6, accuracy: 1e-9)
        XCTAssertEqual(info.routingPackVersion, "pilot-sarasota-20261023")
        XCTAssertEqual(info.routingPackDataDate, ChartDates.day(2026, 10, 23))
        XCTAssertEqual(info.boat.name, "Test boat")
        XCTAssertEqual(info.boat.profileID, boat.id)
        XCTAssertTrue(info.boat.useMaintainedChannels, "the option actually used is recorded")
        XCTAssertEqual(info.boat.draftMeters, 1.3716, accuracy: 1e-12)
        XCTAssertEqual(info.generatedAt, RoutingFixtures.now)
        let record = try XCTUnwrap(AutoRouteSaving.plannerRecord(of: route))
        XCTAssertEqual(record.packRegionID, "pilot-sarasota")
        XCTAssertEqual(record.yellowLegs, 16)
        XCTAssertEqual(record.goalSnapMeters, proposal.result.goal.snapMeters, accuracy: 1e-9)
        XCTAssertEqual(record.noticeVersion, AutoRouteNotice.version)

        // What the map and the Route check section use.
        let display = RouteDisplay(route: route)
        XCTAssertEqual(display.legs.count, 55)
        XCTAssertEqual(display.legs.filter { $0.grade == "yellow" }.count, 16)
        XCTAssertEqual(display.legs.filter { $0.grade == "green" }.count, 39)
        XCTAssertEqual(display.summary?.worstGrade, .yellow)
        XCTAssertEqual(display.routingPackDataDate, ChartDates.day(2026, 10, 23))
        let legsJSON = String(decoding: MapFeatures.routeLegs([display], activeRouteID: nil, activeLeg: nil), as: UTF8.self)
        XCTAssertTrue(legsJSON.contains("\"grade\":\"yellow\""))

        // And NavigationSession can follow it from the start.
        XCTAssertLessThanOrEqual(NavigationSession.bestStartIndex(points: route.points.map(\.coordinate), position: route.points[0].coordinate), 1)
    }

    func testAllGreenRouteSavesWithoutConfirmation() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        let planned = await planner.plan(AutoRoutePlanRequest(
            start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack,
            profile: RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: 20)), now: RoutingFixtures.now)
        let proposal = try XCTUnwrap(planned.proposal)
        let route = try await AutoRouteSaving.save(proposal, name: "Green", cautionConfirmed: false, store: fixture.store)
        XCTAssertEqual(route.points.count, 29)
        XCTAssertEqual(RouteDisplay(route: route).legs.map(\.grade), Array(repeating: "green", count: 28))
        do {
            _ = try await AutoRouteSaving.save(proposal, name: "  ", cautionConfirmed: false, store: fixture.store)
            XCTFail()
        } catch {
            XCTAssertEqual(error, .emptyName)
        }
    }
}

final class LockedPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [AutoRouteProgress.Phase] = []
    func add(_ p: AutoRouteProgress.Phase) { lock.lock(); phases.append(p); lock.unlock() }
    var all: [AutoRouteProgress.Phase] { lock.lock(); defer { lock.unlock() }; return phases }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

final class AutoRouteDisplayTests: XCTestCase {
    func testLaunchSwitchForTheRoutingFixture() {
        XCTAssertFalse(LaunchConfiguration(environment: [:]).preinstallFixtureRouting)
        XCTAssertTrue(LaunchConfiguration(environment: ["GULFNAV_PREINSTALL_FIXTURE_ROUTING": "1"]).preinstallFixtureRouting)
    }

    func testPlannedLayerAndBlockedMarkersReachTheOverlays() async throws {
        let fixture = try PackFixture()
        let planner = try await fixture.planner()
        let boat = RoutingFixtures.profile(draftFeet: 4.5, marginFeet: 1.5, airFeet: 20)
        let ok = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.longboat, goal: RoutingFixtures.marinaJack, profile: boat),
                                    now: RoutingFixtures.now)
        let layer = PlannedRouteLayer(outcome: ok)
        XCTAssertEqual(layer.legs.count, 28)
        XCTAssertEqual(layer.blocked, [])
        let overlays = MapOverlays.make(waypoints: [], selectedWaypoint: nil, targetWaypoint: nil, routes: [], activeRouteID: nil,
                                        nextPointIndex: nil, editingRouteID: nil, tracks: [], directLine: nil, planned: layer)
        XCTAssertEqual(overlays.counts.plannedLegs, 28)
        XCTAssertEqual(overlays.counts.blocked, 0)
        XCTAssertEqual(overlays.summary, "waypoints:0,routeLegs:0,routePoints:0,tracks:0,direct:0,plannedLegs:28,blocked:0")
        let json = String(decoding: overlays.planned, as: UTF8.self)
        XCTAssertTrue(json.contains("\"grade\":\"green\""))
        XCTAssertTrue(json.hasPrefix("{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"LineString\",\"coordinates\":[[-82.603,27.403],"), json)

        let none = await planner.plan(AutoRoutePlanRequest(start: RoutingFixtures.marinaJack, goal: RoutingFixtures.robertsBay, profile: boat),
                                      now: RoutingFixtures.now)
        let blockedLayer = PlannedRouteLayer(outcome: none)
        XCTAssertEqual(blockedLayer.legs, [])
        XCTAssertEqual(blockedLayer.blocked.map(\.reasonCode), ["DEPTH"])
        let o2 = MapOverlays.make(waypoints: [], selectedWaypoint: nil, targetWaypoint: nil, routes: [], activeRouteID: nil,
                                  nextPointIndex: nil, editingRouteID: nil, tracks: [], directLine: nil, planned: blockedLayer)
        XCTAssertEqual(o2.counts.blocked, 1)
        XCTAssertEqual(String(decoding: o2.blocked, as: UTF8.self),
                       "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[-82.5438497,27.2762785]},\"properties\":{\"index\":0,\"reason\":\"DEPTH\"}}]}")
        XCTAssertEqual(PlannedRouteLayer.focusCoordinates(none).count, 3)
        XCTAssertEqual(PlannedRouteLayer(outcome: nil), .empty)
        XCTAssertEqual(MapOverlays.empty.summary, "waypoints:0,routeLegs:0,routePoints:0,tracks:0,direct:0,plannedLegs:0,blocked:0")
    }

    func testMapFocusFramesCoordinates() throws {
        XCTAssertNil(MapFocus.framing([]))
        let one = try XCTUnwrap(MapFocus.framing([Coordinate(latitude: 27.3, longitude: -82.5)]))
        XCTAssertEqual(one.zoom, 15)
        let q1 = try XCTUnwrap(MapFocus.framing([RoutingFixtures.longboat.coordinate, RoutingFixtures.marinaJack.coordinate]))
        XCTAssertEqual(q1.center.latitude, 27.368, accuracy: 1e-9)
        XCTAssertEqual(q1.center.longitude, -82.57475, accuracy: 1e-9)
        XCTAssertGreaterThan(q1.zoom, 10)
        XCTAssertLessThan(q1.zoom, 13)
        let wide = try XCTUnwrap(MapFocus.framing([Coordinate(latitude: 25, longitude: -97), Coordinate(latitude: 30, longitude: -81)]))
        XCTAssertLessThan(wide.zoom, 5)
        XCTAssertGreaterThanOrEqual(wide.zoom, 4)
    }

    func testRouteCheckLinesOfASavedRoute() async throws {
        let fixture = try PackFixture(packs: ["synthetic.pack"])
        let planner = try await fixture.planner()
        let planned = await planner.plan(AutoRoutePlanRequest(
            start: RoutingFixtures.synWest, goal: RoutingFixtures.synEast,
            profile: RoutingFixtures.profile(name: "Sloop", draftFeet: 4, marginFeet: 1, airFeet: 20, maintained: true)), now: RoutingFixtures.now)
        let proposal = try XCTUnwrap(planned.proposal)
        let route = try await AutoRouteSaving.save(proposal, name: "Syn", cautionConfirmed: true, store: fixture.store)
        let lines = RouteCheckPresentation.lines(route, units: UnitPreferences(), now: RoutingFixtures.now)
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.value) })
        XCTAssertEqual(lines.map(\.id), ["distance", "legs", "shallowest", "clearance", "openings", "worst", "data", "boat"])
        XCTAssertEqual(byID["distance"], "0.37 nm")
        XCTAssertEqual(byID["legs"], "1 leg: 0 green, 1 yellow")
        XCTAssertTrue(byID["shallowest"]?.hasPrefix("3.0 ft at ") ?? false, byID["shallowest"] ?? "")
        XCTAssertEqual(byID["clearance"], "5.9 ft")
        XCTAssertEqual(byID["openings"], "1: Test Opening Bridge")
        XCTAssertEqual(byID["worst"], "yellow")
        XCTAssertEqual(byID["data"], "1 Nov 2026 (12 days old)")
        XCTAssertEqual(byID["boat"], "Sloop: draft 4.0 ft + 1.0 ft margin, air draft 20.0 ft")
        XCTAssertEqual(RouteCheckPresentation.reasonText(["MAINTAINED_DEPTH", "BRIDGE_OPENING"]), "Maintained channel depth, Bridge must open")
        XCTAssertEqual(RouteCheckPresentation.lines(Route(name: "manual"), units: UnitPreferences()), [])
    }

    func testFixtureRoutingPackInstallsOnceAndSeedsWaypoints() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let library = RoutingPackLibrary(sideLoadDirectory: dir.url.appendingPathComponent("RoutingPacks"))
        let store = try PersistenceStore(inMemoryWith: PersistenceStore.Options())
        let first = await FixtureRoutingPack.install(packFile: RoutingFixtures.url("sarasota.pack"), library: library, store: store)
        XCTAssertEqual(first, [])
        let again = await FixtureRoutingPack.install(packFile: nil, library: library, store: store)
        XCTAssertEqual(again, [], "already installed: the missing file is not needed")
        let catalog = await library.catalog()
        XCTAssertEqual(catalog.entries.map(\.packRegionID), [FixtureRoutingPack.packRegionID])
        let names = try await store.waypoints().map(\.name).sorted()
        XCTAssertEqual(names, ["RT Longboat", "RT Marina Jack", "RT Roberts Bay"])
        for c in FixtureRoutingPack.simulatedTrack {
            XCTAssertTrue(try XCTUnwrap(catalog.entries.first).coverage.contains(c))
        }
        let missing = await FixtureRoutingPack.install(packFile: nil, library: RoutingPackLibrary(sideLoadDirectory: dir.url.appendingPathComponent("none")),
                                                       store: store)
        XCTAssertEqual(missing, ["Test routing pack is not in this build."])
    }
}
