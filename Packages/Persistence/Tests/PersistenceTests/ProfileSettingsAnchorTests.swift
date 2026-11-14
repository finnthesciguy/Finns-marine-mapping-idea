import Foundation
import NavCore
import Testing
@testable import Persistence

@Suite("Boat profiles, settings, anchor watch")
struct ProfileSettingsAnchorTests {
    @Test func boatProfilesKeepExactlyOneDefault() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        #expect(try await store.defaultBoatProfile() == nil)
        let a = try await store.save(BoatProfile(name: "Skiff", draft: .feet(1.5), safetyMargin: .feet(0.5)))
        #expect(a.isDefault, "the first profile becomes the default")
        let b = try await store.save(BoatProfile(name: "Cruiser", draft: .feet(5), safetyMargin: .feet(1), airDraft: .feet(45),
                                                 beam: .feet(13), cruisingSpeed: .knots(6.5),
                                                 useMaintainedChannels: true, acceptUnknownClearance: true))
        #expect(!b.isDefault)
        let loaded = try #require(try await store.boatProfile(b.id))
        #expect(abs(loaded.draft.feet - 5) < 1e-9)
        #expect(abs((loaded.airDraft?.feet ?? 0) - 45) < 1e-9)
        #expect(abs((loaded.cruisingSpeed?.knots ?? 0) - 6.5) < 1e-9)
        #expect(loaded.useMaintainedChannels && loaded.acceptUnknownClearance)
        #expect(abs(loaded.requiredDepth.feet - 6) < 1e-9)

        try await store.setDefaultBoatProfile(b.id)
        #expect(try await store.defaultBoatProfile()?.id == b.id)
        #expect(try await store.boatProfiles().filter(\.isDefault).count == 1)

        var c = BoatProfile(name: "Trawler", draft: .feet(4), isDefault: true)
        c = try await store.save(c)
        #expect(try await store.defaultBoatProfile()?.id == c.id)
        #expect(try await store.boatProfiles().map(\.name) == ["Trawler", "Cruiser", "Skiff"])

        try await store.deleteBoatProfile(c.id)
        // The oldest remaining profile takes over.
        #expect(try await store.defaultBoatProfile()?.id == a.id)

        await #expect(throws: PersistenceError.self) {
            try await store.save(BoatProfile(name: "bad", draft: .meters(-1)))
        }
        await #expect(throws: PersistenceError.notFound(.boatProfile, UUIDs.missing)) {
            try await store.setDefaultBoatProfile(UUIDs.missing)
        }
    }

    @Test func typedSettings() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("s.sqlite")
        do {
            let store = try PersistenceStore(url: url)
            #expect(try await store.setting(.distanceUnit) == .nauticalMiles)
            #expect(try await store.setting(.disclaimerAcknowledgement) == nil)
            try await store.setSetting(.distanceUnit, to: .kilometers)
            try await store.setSetting(.depthUnit, to: .meters)
            try await store.setSetting(.mapOrientation, to: .headingUp)
            try await store.setSetting(.trackRecordingInterval, to: 2.5)
            let ack = DisclaimerAcknowledgement(version: 3, date: Date(timeIntervalSince1970: 1_800_000_000))
            try await store.setSetting(.disclaimerAcknowledgement, to: ack)
            let custom = SettingKey<[String]>("test.recentSearches", default: [])
            try await store.setSetting(custom, to: ["Venice", "Boca Grande"])
            await store.close()
        }
        let store = try PersistenceStore(url: url)
        #expect(try await store.setting(.distanceUnit) == .kilometers)
        #expect(try await store.setting(.depthUnit) == .meters)
        #expect(try await store.setting(.mapOrientation) == .headingUp)
        #expect(try await store.setting(.trackRecordingInterval) == 2.5)
        #expect(try await store.setting(.disclaimerAcknowledgement)?.version == 3)
        #expect(try await store.setting(.disclaimerAcknowledgement)?.date == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try await store.setting(SettingKey<[String]>("test.recentSearches", default: [])) == ["Venice", "Boca Grande"])
        // A value of the wrong type (e.g. written by a newer app) falls back to the default instead of throwing.
        #expect(try await store.setting(SettingKey<Int>("units.distance", default: 7)) == 7)
        try await store.resetSetting(.distanceUnit)
        #expect(try await store.setting(.distanceUnit) == .nauticalMiles)
        // Setting nil stores an explicit nil.
        try await store.setSetting(.disclaimerAcknowledgement, to: nil)
        #expect(try await store.setting(.disclaimerAcknowledgement) == nil)
        #expect(try await store.storedSettingNames().contains("legal.disclaimerAcknowledgement"))
    }

    @Test func anchorWatchSurvivesRelaunch() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("a.sqlite")
        let anchor = Coordinate(latitude: 27.55, longitude: -82.72)
        var alarm = AnchorAlarm(anchor: anchor, configuration: AnchorAlarmConfiguration(radius: 40, confirmationFixes: 2, confirmationInterval: 1))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 {
            let far = Geodesy.destination(from: anchor, bearing: 90, distance: 80)
            alarm.update(with: Fix(coordinate: far, timestamp: t0.addingTimeInterval(Double(i)), horizontalAccuracy: 5))
        }
        #expect(alarm.state == .dragging)
        do {
            let store = try PersistenceStore(url: url)
            #expect(try await store.anchorWatch() == nil)
            try await store.saveAnchorWatch(AnchorWatchState(alarm, droppedAt: t0, lastFixAt: t0.addingTimeInterval(4)))
            await store.close()
        }
        let store = try PersistenceStore(url: url)
        let restored = try #require(try await store.anchorWatch())
        #expect(restored.anchor == anchor)
        #expect(restored.configuration == alarm.configuration)
        #expect(restored.lastState == .dragging)
        #expect(abs(restored.maximumDistance - 80) < 0.5)
        #expect(restored.droppedAt == t0)
        try await store.clearAnchorWatch()
        #expect(try await store.anchorWatch() == nil)
    }
}
