import Foundation
import GPXKit
import NavCore
import Testing
@testable import Persistence

@Suite("GPX bridge")
struct GPXBridgeTests {
    static func sampleDocument() -> GPXDocument {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        return GPXDocument(
            creator: "Test",
            waypoints: [
                GPXWaypoint(coordinate: Coordinate(latitude: 27.6, longitude: -82.76), time: t0, name: "Egmont Key",
                            description: "anchorage", symbol: "anchor"),
                GPXWaypoint(coordinate: Coordinate(latitude: 27.1, longitude: -82.46), name: nil),
            ],
            routes: [GPXRoute(name: "Out", points: [
                GPXWaypoint(coordinate: Coordinate(latitude: 27.7, longitude: -82.6), name: "Start"),
                GPXWaypoint(coordinate: Coordinate(latitude: 27.65, longitude: -82.7)),
                GPXWaypoint(coordinate: Coordinate(latitude: 27.6, longitude: -82.8), name: "End"),
            ])],
            tracks: [GPXTrack(name: "Sail", segments: [
                GPXTrackSegment(points: syntheticTrack(count: 30).map { GPXWaypoint(coordinate: $0.coordinate, time: $0.timestamp) }),
                GPXTrackSegment(points: syntheticTrack(count: 20, start: t0.addingTimeInterval(3600))
                    .map { GPXWaypoint(coordinate: $0.coordinate, time: $0.timestamp) }),
            ])])
    }

    @Test func roundTripThroughTheStoreAndGPXText() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let plan = try await store.planGPXImport(Self.sampleDocument())
        #expect(plan.duplicateCount == 0)
        #expect(plan.waypoints.map(\.value.name) == ["Egmont Key", "Waypoint 2"])
        let result = try await store.applyGPXImport(plan)
        #expect(result.insertedWaypoints.count == 2)
        #expect(result.insertedRoutes.count == 1)
        #expect(result.insertedTracks.count == 1)

        let track = try #require(try await store.track(result.insertedTracks[0]))
        #expect(track.statistics.segmentCount == 2)
        #expect(track.statistics.pointCount == 50)

        // Export, serialise, parse, and import into a second store: same content.
        let exported = try await store.exportGPX()
        let text = GPXWriter.string(from: exported)
        let reparsed = try GPXParser.parse(string: text)
        #expect(reparsed.waypoints.count == 2)
        #expect(reparsed.routes.first?.points.map(\.name) == ["Start", nil, "End"])
        #expect(reparsed.tracks.first?.segments.map(\.points.count) == [30, 20])

        let other = try PersistenceStore(inMemoryWith: TestClock().options)
        try await other.applyGPXImport(try await other.planGPXImport(reparsed))
        let w1 = try await store.waypoints(), w2 = try await other.waypoints()
        #expect(w1.map(\.name) == w2.map(\.name))
        #expect(w1.map(\.symbol) == w2.map(\.symbol))
        #expect(w1.map(\.notes) == w2.map(\.notes))
        for (a, b) in zip(w1, w2) { #expect(Geodesy.distance(from: a.coordinate, to: b.coordinate) < 0.01) }
        let r1 = try await store.routes(), r2 = try await other.routes()
        #expect(r1.map(\.points.count) == r2.map(\.points.count))
        let p1 = try await store.trackPoints(track.id)
        let t2 = try #require(try await other.tracks().first)
        let p2 = try await other.trackPoints(t2.id)
        #expect(p1.map(\.count) == p2.map(\.count))
        #expect(zip(p1.joined(), p2.joined()).allSatisfy { $0.timestamp == $1.timestamp })
        #expect(abs(t2.statistics.distance.meters - track.statistics.distance.meters) < 0.5)
    }

    @Test func duplicatesAreReportedNotSilentlyApplied() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        try await store.applyGPXImport(try await store.planGPXImport(Self.sampleDocument()))
        let existingEgmont = try #require(try await store.waypoints().first { $0.name == "Egmont Key" })

        var doc = Self.sampleDocument()
        doc.waypoints[0].coordinate.latitude += 0.00002          // ~2 m: duplicate
        doc.waypoints[0].name = "  egmont key "                  // name compared trimmed, case-insensitive
        doc.waypoints.append(GPXWaypoint(coordinate: Coordinate(latitude: 27.601, longitude: -82.76), name: "Egmont Key"))  // ~110 m: not
        doc.waypoints.append(GPXWaypoint(coordinate: Coordinate(latitude: 25, longitude: -81), name: "Twice"))
        doc.waypoints.append(GPXWaypoint(coordinate: Coordinate(latitude: 25, longitude: -81.00001), name: "twice"))  // dup within file
        doc.waypoints.append(GPXWaypoint(coordinate: Coordinate(latitude: 99, longitude: 0), name: "broken"))

        let plan = try await store.planGPXImport(doc)
        #expect(plan.waypoints.count == 5)   // "broken" dropped with a warning
        #expect(plan.warnings.contains { $0.contains("broken") })
        guard case .existing(let id, _, let d)? = plan.waypoints[0].duplicate else {
            Issue.record("expected duplicate of existing waypoint"); return
        }
        #expect(id == existingEgmont.id)
        #expect(d > 1 && d < 3)
        #expect(plan.waypoints[0].decision == .skip)
        #expect(plan.waypoints[1].duplicate != nil)   // "Waypoint 2" again at same place
        #expect(plan.waypoints[2].duplicate == nil)
        #expect(plan.waypoints[3].duplicate == nil)
        #expect(plan.waypoints[4].duplicate == .earlierInFile(index: 3))
        #expect(plan.routes[0].duplicate != nil)
        #expect(plan.tracks[0].duplicate != nil)
        #expect(plan.duplicateCount == 5)

        // Nothing was written by planning.
        #expect(try await store.waypointCount() == 2)

        // Default decisions skip duplicates.
        var p = plan
        let r = try await store.applyGPXImport(p)
        #expect(r.skipped == 5)
        #expect(r.insertedWaypoints.count == 2)
        #expect(try await store.waypointCount() == 4)
        #expect(try await store.routes().count == 1)
        #expect(try await store.tracks().count == 1)

        // The caller can choose to replace: the existing id is kept, contents updated.
        p = try await store.planGPXImport(doc)
        p.waypoints[0].decision = .replaceExisting
        p.tracks[0].decision = .replaceExisting
        let r2 = try await store.applyGPXImport(p)
        #expect(r2.replacedWaypoints == [existingEgmont.id])
        #expect(try await store.waypoint(existingEgmont.id)?.name == "egmont key")
        #expect(r2.replacedTracks.count == 1)
        #expect(try await store.tracks().count == 1)
    }
}

@Suite("Change feed")
struct ChangeFeedTests {
    @Test func deliversCommittedChangesPerKind() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let waypointFeed = store.changes(of: .waypoint)
        let trackFeed = store.changes(of: .track)
        let settingsFeed = store.changes([.setting, .boatProfile])

        let w = Waypoint(name: "a", coordinate: Coordinate(latitude: 27, longitude: -82))
        try await store.save(w)
        try await store.save(w)
        try await store.deleteWaypoint(w.id)
        let t = try await store.startTrack(name: "t")
        try await store.appendTrackPoints(syntheticTrack(count: 3), to: t.id)
        try await store.setSetting(.mapOrientation, to: .courseUp)
        try await store.setSetting(.mapOrientation, to: .courseUp)   // unchanged: no event
        try await store.save(BoatProfile(name: "boat", draft: .feet(4)))

        let ws = await collect(waypointFeed, count: 3)
        #expect(ws.map(\.operation) == [.inserted, .updated, .deleted])
        #expect(ws.allSatisfy { $0.ids == [w.id] && $0.kind == .waypoint })
        let ts = await collect(trackFeed, count: 2)
        #expect(ts.map(\.operation) == [.inserted, .updated])
        let ss = await collect(settingsFeed, count: 2)
        #expect(ss.map(\.kind) == [.setting, .boatProfile])
        #expect(ss.first?.keys == ["map.orientation"])
    }

    @Test func rolledBackWritesAreNotDelivered() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let feed = store.changes(of: .waypoint)
        await #expect(throws: PersistenceError.self) {
            try await store.save([Waypoint(name: "ok", coordinate: Coordinate(latitude: 27, longitude: -82)),
                                  Waypoint(name: "bad", coordinate: Coordinate(latitude: .infinity, longitude: 0))])
        }
        try await store.save(Waypoint(name: "after", coordinate: Coordinate(latitude: 27, longitude: -82)))
        let got = await collect(feed, count: 1)
        #expect(got.count == 1)
        #expect(got.first?.operation == .inserted)
        #expect(try await store.waypoints().map(\.name) == ["after"])
    }

    @Test func cancellingTheConsumerUnsubscribes() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let consumer = Task {
            var n = 0
            for await _ in store.changes(of: .waypoint) { n += 1 }
            return n
        }
        while store.feed.subscriberCount == 0 { await Task.yield() }
        consumer.cancel()
        _ = await consumer.value
        #expect(store.feed.subscriberCount == 0)
    }

    @Test func closingFinishesStreams() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let feed = store.changes(of: .route)
        await store.close()
        var count = 0
        for await _ in feed { count += 1 }
        #expect(count == 0)
    }
}
