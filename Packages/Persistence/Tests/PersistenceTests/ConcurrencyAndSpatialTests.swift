import Foundation
import NavCore
import Testing
@testable import Persistence

@Suite("Concurrent access")
struct ConcurrencyTests {
    @Test func manyTasksOneStore() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try PersistenceStore(url: dir.file("c.sqlite"))
        let track = try await store.startTrack(name: "shared")
        let pts = syntheticTrack(count: 2000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<20 {
                group.addTask {
                    for i in 0..<25 {
                        try await store.save(Waypoint(name: "T\(task)-\(i)", coordinate: Coordinate(latitude: 27, longitude: -82)))
                        _ = try await store.waypoints(in: BoundingBox(south: 26, west: -83, north: 28, east: -81))
                    }
                }
            }
            // Writers to one track from several tasks: each batch is atomic.
            for b in 0..<4 {
                group.addTask {
                    for i in stride(from: b * 500, to: (b + 1) * 500, by: 50) {
                        try await store.appendTrackPoints(Array(pts[i..<i + 50]), to: track.id)
                    }
                }
            }
            for _ in 0..<5 {
                group.addTask {
                    for _ in 0..<20 { _ = try await store.tracks() }
                    try await store.setSetting(.trackRecordingInterval, to: Double.random(in: 1...10))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.waypointCount() == 500)
        let t = try #require(try await store.track(track.id))
        #expect(t.statistics.pointCount == 2000)
        #expect(try await store.checkIntegrity() == ["ok"])
    }

    @Test func twoStoresOnOneFile() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("shared.sqlite")
        let a = try PersistenceStore(url: url)
        let b = try PersistenceStore(url: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (s, tag) in [(a, "a"), (b, "b")] {
                group.addTask {
                    for i in 0..<100 {
                        try await s.save(Waypoint(name: "\(tag)\(i)", coordinate: Coordinate(latitude: 27, longitude: -82)))
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await a.waypointCount() == 200)
        #expect(try await b.waypointCount() == 200)
    }
}

@Suite("Bounding-box queries")
struct SpatialTests {
    static let preferences: [PersistenceStore.Options.SpatialIndexPreference] = [.automatic, .rangeIndexOnly]

    @Test func linkedSQLiteHasRTree() throws {
        // Not a requirement (the fallback exists), but CI should tell us which path the automatic mode takes.
        let store = try PersistenceStore(inMemoryWith: .init())
        print("[info] SQLite \(store.openReport.sqliteVersion); automatic spatial index: \(store.spatialIndex.rawValue)")
        let forced = try PersistenceStore(inMemoryWith: .init(spatialIndex: .rangeIndexOnly))
        #expect(forced.spatialIndex == .rangeIndex)
    }

    @Test(arguments: preferences)
    func waypointsInBox(_ pref: PersistenceStore.Options.SpatialIndexPreference) async throws {
        let store = try PersistenceStore(inMemoryWith: .init(spatialIndex: pref))
        // A 20 x 20 grid of waypoints, 0.1 degree apart, around Tampa Bay.
        var all: [Waypoint] = []
        for i in 0..<20 {
            for j in 0..<20 {
                all.append(Waypoint(name: String(format: "G%02d-%02d", i, j),
                                    coordinate: Coordinate(latitude: 26 + Double(i) * 0.1, longitude: -83 + Double(j) * 0.1)))
            }
        }
        try await store.save(all)
        let box = BoundingBox(south: 26.95, west: -82.55, north: 27.35, east: -82.25)
        let expected = all.filter { box.contains($0.coordinate) }.map(\.name).sorted()
        let got = try await store.waypoints(in: box).map(\.name)
        #expect(got == expected)
        #expect(got.count == 4 * 3)

        // Edges are inclusive; a degenerate box finds the point on it.
        let exact = all[0].coordinate
        #expect(try await store.waypoints(in: BoundingBox(south: exact.latitude, west: exact.longitude,
                                                          north: exact.latitude, east: exact.longitude)).count == 1)

        // Moves and deletes are reflected (R*Tree kept in sync by triggers).
        var moved = all[0]
        moved.coordinate = Coordinate(latitude: 27.1, longitude: -82.4)
        try await store.save(moved)
        #expect(try await store.waypoints(in: box).contains { $0.id == moved.id })
        try await store.deleteWaypoint(moved.id)
        #expect(try await store.waypoints(in: box).count == 12)
    }

    @Test(arguments: preferences)
    func tracksInBox(_ pref: PersistenceStore.Options.SpatialIndexPreference) async throws {
        let store = try PersistenceStore(inMemoryWith: .init(spatialIndex: pref))
        let tampa = try await store.saveTrack(name: "tampa", segments: [syntheticTrack(count: 500, origin: Coordinate(latitude: 27.6, longitude: -82.7))])
        let keys = try await store.saveTrack(name: "keys", segments: [syntheticTrack(count: 500, origin: Coordinate(latitude: 24.6, longitude: -81.8))])
        _ = try await store.startTrack(name: "empty")  // no bounds, never matches
        let tampaBox = BoundingBox(south: 27.5, west: -82.8, north: 27.7, east: -82.6)
        #expect(try await store.tracks(in: tampaBox).map(\.id) == [tampa.id])
        let gulf = BoundingBox(south: 24, west: -84, north: 28, east: -80)
        #expect(Set(try await store.tracks(in: gulf).map(\.id)) == [tampa.id, keys.id])
        // A box inside a track's bounds but touching none of its points still matches (bounds test only).
        #expect(try await store.tracks(in: BoundingBox(south: 27.6001, west: -82.69, north: 27.6002, east: -82.68)).count == 1)
        #expect(try await store.tracks(in: BoundingBox(south: 30, west: -90, north: 31, east: -89)).isEmpty)

        // Appending to the track grows its bounds and the index follows.
        let t = try await store.startTrack(name: "growing")
        try await store.appendTrackPoints(syntheticTrack(count: 10, origin: Coordinate(latitude: 29.0, longitude: -94.8)), to: t.id)
        let galveston = BoundingBox(south: 28.9, west: -95, north: 29.1, east: -94.5)
        #expect(try await store.tracks(in: galveston).map(\.id) == [t.id])
        try await store.appendTrackPoints(syntheticTrack(count: 10, origin: Coordinate(latitude: 30.3, longitude: -88.0)), to: t.id)
        #expect(try await store.tracks(in: BoundingBox(south: 30.2, west: -88.1, north: 30.4, east: -87.9)).map(\.id) == [t.id])
        try await store.deleteTrack(t.id)
        #expect(try await store.tracks(in: galveston).isEmpty)
    }

    @Test(arguments: preferences)
    func antimeridianBox(_ pref: PersistenceStore.Options.SpatialIndexPreference) async throws {
        let store = try PersistenceStore(inMemoryWith: .init(spatialIndex: pref))
        try await store.save([Waypoint(name: "east", coordinate: Coordinate(latitude: 0, longitude: 179.5)),
                              Waypoint(name: "west", coordinate: Coordinate(latitude: 0, longitude: -179.5)),
                              Waypoint(name: "far", coordinate: Coordinate(latitude: 0, longitude: 0))])
        let box = BoundingBox(south: -1, west: 179, north: 1, east: -179)
        #expect(try await store.waypoints(in: box).map(\.name) == ["east", "west"])
    }

    @Test func switchingIndexModesOnOneFileStaysCorrect() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("s.sqlite")
        let box = BoundingBox(south: 26.5, west: -83, north: 27.5, east: -82)
        do {
            let s = try PersistenceStore(url: url)
            try await s.save(Waypoint(name: "one", coordinate: Coordinate(latitude: 27, longitude: -82.5)))
            await s.close()
        }
        do {
            // Fallback mode drops the R*Tree; writes made now are not indexed by it…
            let s = try PersistenceStore(url: url, options: .init(spatialIndex: .rangeIndexOnly))
            #expect(try await s.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'waypoint_rtree'") == 0)
            try await s.save(Waypoint(name: "two", coordinate: Coordinate(latitude: 27.1, longitude: -82.5)))
            #expect(try await s.waypoints(in: box).count == 2)
            await s.close()
        }
        // …so reopening with R*Tree rebuilds it from the tables.
        let s = try PersistenceStore(url: url)
        #expect(try await s.waypoints(in: box).map(\.name) == ["one", "two"])
    }
}
