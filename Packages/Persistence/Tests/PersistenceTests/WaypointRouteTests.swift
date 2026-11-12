import Foundation
import NavCore
import Testing
@testable import Persistence

@Suite("Waypoints and routes")
struct WaypointRouteTests {
    @Test func waypointCRUD() async throws {
        let clock = TestClock()
        let store = try PersistenceStore(inMemoryWith: clock.options)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var w = Waypoint(name: "Egmont Key", coordinate: Coordinate(latitude: 27.6, longitude: -82.76),
                         symbol: "anchor", notes: "Lee of the island", createdAt: created)
        let saved = try await store.save(w)
        #expect(saved.createdAt == created)
        #expect(saved.modifiedAt > created)
        #expect(try await store.waypoint(w.id) == saved)

        w.name = "Egmont Key North"
        w.notes = ""
        w.symbol = nil
        w.createdAt = Date()  // ignored on update
        let updated = try await store.save(w)
        #expect(updated.createdAt == created)
        #expect(updated.modifiedAt > saved.modifiedAt)
        let fetched = try #require(try await store.waypoint(w.id))
        #expect(fetched.name == "Egmont Key North")
        #expect(fetched.symbol == nil)
        #expect(fetched.notes == "")
        #expect(try await store.waypointCount() == 1)

        #expect(try await store.deleteWaypoint(w.id))
        #expect(try await store.deleteWaypoint(w.id) == false)
        #expect(try await store.waypoint(w.id) == nil)
    }

    @Test func waypointOrdering() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let names = ["bravo", "Alpha", "charlie", "alpha"]
        for (i, n) in names.enumerated() {
            try await store.save(Waypoint(name: n, coordinate: Coordinate(latitude: 27, longitude: -82),
                                          createdAt: base.addingTimeInterval(Double(i))))
        }
        #expect(try await store.waypoints(order: .name).map(\.name) == ["Alpha", "alpha", "bravo", "charlie"])
        #expect(try await store.waypoints(order: .newestFirst).map(\.name) == ["alpha", "charlie", "Alpha", "bravo"])
        // Re-saving "bravo" makes it the most recently modified.
        var bravo = try #require(try await store.waypoints().first { $0.name == "bravo" })
        bravo.notes = "touched"
        try await store.save(bravo)
        #expect(try await store.waypoints(order: .recentlyModified).first?.name == "bravo")
    }

    @Test func invalidCoordinatesAreRejected() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        await #expect(throws: PersistenceError.self) {
            try await store.save(Waypoint(name: "bad", coordinate: Coordinate(latitude: .nan, longitude: 0)))
        }
        await #expect(throws: PersistenceError.self) {
            try await store.save(Route(name: "bad", points: [RoutePoint(coordinate: Coordinate(latitude: 95, longitude: 0))]))
        }
        // A batch with one bad waypoint stores nothing.
        await #expect(throws: PersistenceError.self) {
            try await store.save([Waypoint(name: "ok", coordinate: Coordinate(latitude: 27, longitude: -82)),
                                  Waypoint(name: "bad", coordinate: Coordinate(latitude: 0, longitude: 200))])
        }
        #expect(try await store.waypointCount() == 0)
    }

    @Test func routePointsKeepTheirOrder() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let pts = (0..<50).map { i in
            RoutePoint(coordinate: Coordinate(latitude: 27 + Double(i) * 0.01, longitude: -82.5 - Double(i % 7) * 0.003),
                       name: i % 3 == 0 ? "P\(i)" : nil)
        }
        var r = Route(name: "Tampa to Venice", notes: "ICW", points: pts)
        try await store.save(r)
        let loaded = try #require(try await store.route(r.id))
        #expect(loaded.points == pts)
        #expect(loaded.notes == "ICW")
        #expect(loaded.metadata == nil)

        r.points.reverse()
        r.points.removeLast(10)
        try await store.save(r)
        #expect(try await store.route(r.id)?.points == r.points)

        try await store.save(Route(name: "a route", points: []))
        #expect(try await store.routes(order: .name).map(\.name) == ["a route", "Tampa to Venice"])
        #expect(try await store.deleteRoute(r.id))
        #expect(try await store.routes().count == 1)
        // Points were removed by the cascade.
        let orphans = try await store.scalar("SELECT count(*) FROM route_point")
        #expect(orphans == 0)
    }

    @Test func autoRouteMetadataRoundTrips() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let boat = BoatProfile(name: "Sea Ray", draft: .feet(3), safetyMargin: .feet(1), airDraft: .feet(12),
                               useMaintainedChannels: true)
        let info = AutoRouteInfo(
            boat: .init(boat),
            legs: [.init(index: 0, grade: .green, leastDepthMeters: 3.6),
                   .init(index: 1, grade: .yellow, reasonCodes: ["maintained-channel-depth"], leastDepthMeters: 2.7),
                   .init(index: 2, grade: LegGrade(rawValue: "purple"), reasonCodes: ["future-grade"])],
            summary: .init(distanceMeters: 12_000, shallowestDepthMeters: 2.7, lowestClearanceMeters: 6.4, worstGrade: .yellow),
            routingPackDataDate: Date(timeIntervalSince1970: 1_799_000_000), routingPackVersion: "pilot-1",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let r = Route(name: "Auto", points: [RoutePoint(coordinate: Coordinate(latitude: 27, longitude: -82.6)),
                                             RoutePoint(coordinate: Coordinate(latitude: 27.1, longitude: -82.6))],
                      metadata: try RouteMetadata(info))
        try await store.save(r)
        let loaded = try #require(try await store.route(r.id))
        #expect(loaded.metadata?.version == 1)
        #expect(loaded.metadata?.autoRouteInfo == info)
        #expect(loaded.metadata?.autoRouteInfo?.legs[2].grade.rawValue == "purple")

        // A future writer adds fields and bumps the version: the route still loads, the blob is preserved,
        // and version-1 readers decline to interpret it rather than misreading it.
        let futureJSON = Data(#"{"boat":{"name":"x","draftMeters":1,"safetyMarginMeters":0.3,"useMaintainedChannels":false,"acceptUnknownClearance":false},"legs":[],"summary":{},"generatedAt":"2027-01-01T00:00:00Z","tideCredit":0.2}"#.utf8)
        var future = r
        future.id = UUID()
        future.metadata = RouteMetadata(version: 2, json: futureJSON)
        try await store.save(future)
        let f = try #require(try await store.route(future.id))
        #expect(f.metadata?.json == futureJSON)
        #expect(f.metadata?.autoRouteInfo == nil)
        // Unknown keys are ignored when decoding explicitly.
        let decoded = try #require(f.metadata).decode(AutoRouteInfo.self)
        #expect(decoded.boat.name == "x")
    }

    @Test func closedStoreThrows() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        await store.close()
        await #expect(throws: PersistenceError.closed) { try await store.waypoints() }
    }
}
