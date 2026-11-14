import Foundation
import GPXKit
import NavCore
import Persistence
import XCTest
@testable import AppServices

final class UnitFormatTests: XCTestCase {
    func testDistancesSpeedsDepths() {
        XCTAssertEqual(NavFormat.distance(1852, unit: .nauticalMiles), "1.00 nm")
        XCTAssertEqual(NavFormat.distance(1852 * 23.45, unit: .nauticalMiles), "23.4 nm")
        XCTAssertEqual(NavFormat.distance(1852 * 150, unit: .nauticalMiles), "150 nm")
        XCTAssertEqual(NavFormat.distance(1609.344 * 2, unit: .statuteMiles), "2.00 mi")
        XCTAssertEqual(NavFormat.distance(640, unit: .kilometers), "640 m")
        XCTAssertEqual(NavFormat.distance(12_345, unit: .kilometers), "12.3 km")
        XCTAssertEqual(NavFormat.distance(nil, unit: .kilometers), "—")
        XCTAssertEqual(NavFormat.speed(Speed.knots(6).metersPerSecond, unit: .knots), "6.0 kn")
        XCTAssertEqual(NavFormat.speed(10, unit: .kilometersPerHour), "36.0 km/h")
        XCTAssertEqual(NavFormat.speed(10, unit: .milesPerHour), "22.4 mph")
        XCTAssertEqual(InstrumentFormat.sog(metersPerSecond: 10, unit: .kilometersPerHour), "36.0 km/h")
        XCTAssertEqual(NavFormat.depth(3.048, unit: .feet), "10.0 ft")
        XCTAssertEqual(NavFormat.depth(3.6576, unit: .fathoms), "2.0 fm")
        XCTAssertEqual(NavFormat.depth(2.5, unit: .meters), "2.5 m")
    }

    func testCrossTrackDurationClock() {
        XCTAssertEqual(NavFormat.crossTrack(92.6, unit: .nauticalMiles), "0.05 nm R")
        XCTAssertEqual(NavFormat.crossTrack(-185.2, unit: .nauticalMiles), "0.10 nm L")
        XCTAssertEqual(NavFormat.crossTrack(0.1, unit: .nauticalMiles), "0.00 nm")
        XCTAssertEqual(NavFormat.duration(42), "42 s")
        XCTAssertEqual(NavFormat.duration(12 * 60 + 20), "12 min")
        XCTAssertEqual(NavFormat.duration(3600 + 5 * 60), "1 h 05 min")
        XCTAssertEqual(NavFormat.duration(3 * 86_400 + 4 * 3600), "3 d 4 h")
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        XCTAssertEqual(NavFormat.clockTime(date, timeZone: utc), "22:13")
        XCTAssertEqual(NavFormat.dateTime(date, timeZone: utc), "14 Nov 2023 22:13")
        XCTAssertEqual(NavFormat.position(Coordinate(latitude: 27.601, longitude: -82.733)), "27°36.060'N 082°43.980'W")
    }
}

final class MapDiagnosticsTests: XCTestCase {
    func testStatusValueIsParseable() {
        var d = MapDiagnostics()
        XCTAssertTrue(d.statusValue.hasPrefix("style=pending; chartLayers=0;"))
        d.styleVia = .attach
        d.chartLayers = 2
        d.frames = 7
        d.failure = "bad; thing=1\nsecond line"
        let value = d.statusValue
        XCTAssertTrue(value.hasPrefix("style=loaded; chartLayers=2; overlayLayers=0; styleVia=attach;"), value)
        XCTAssertEqual(MapDiagnostics.integer("chartLayers", in: value), 2)
        XCTAssertEqual(MapDiagnostics.integer("frames", in: value), 7)
        XCTAssertEqual(MapDiagnostics.integer("missing", in: value), -1)
        XCTAssertTrue(value.contains("didFailLoading=bad  thing 1 second line"), value)
    }
}

final class NavigationSessionTests: XCTestCase {
    let start = Coordinate(latitude: 27.60, longitude: -82.75)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func target(_ name: String, _ lat: Double, _ lon: Double) -> NavigationTarget {
        NavigationTarget(name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
    }

    func testDirectToGuidanceAndArrival() {
        var session = NavigationSession()
        let mark = target("Mark", 27.65, -82.75)
        session.startDirectTo(mark, from: start)
        XCTAssertTrue(session.isActive)
        let events = session.update(position: start, speedOverGround: Speed.knots(6).metersPerSecond, now: now)
        XCTAssertEqual(events, [])
        let g = try! XCTUnwrap(session.guidance)
        XCTAssertEqual(g.targetName, "Mark")
        XCTAssertEqual(g.bearingToTarget, 0, accuracy: 0.5)
        XCTAssertEqual(g.distanceToTarget, Geodesy.distance(from: start, to: mark.coordinate), accuracy: 1)
        XCTAssertEqual(g.crossTrackError, 0, accuracy: 1)
        XCTAssertNotNil(g.eta)
        XCTAssertEqual(g.timeToGo ?? 0, g.distanceToTarget / Speed.knots(6).metersPerSecond, accuracy: 1)
        XCTAssertFalse(g.arrived)

        // Off to the east of the track: positive (right) cross-track error.
        let offTrack = Coordinate(latitude: 27.62, longitude: -82.74)
        session.update(position: offTrack, speedOverGround: 3, now: now)
        XCTAssertGreaterThan(session.guidance!.crossTrackError, 500)

        // Passing abeam of the destination is not arriving; entering the circle is.
        let abeam = Coordinate(latitude: 27.651, longitude: -82.70)
        XCTAssertEqual(session.update(position: abeam, speedOverGround: 3, now: now), [])
        XCTAssertFalse(session.guidance!.arrived)
        let inside = Coordinate(latitude: 27.6503, longitude: -82.7502)
        XCTAssertEqual(session.update(position: inside, speedOverGround: 3, now: now), [.arrived(name: "Mark")])
        XCTAssertTrue(session.guidance!.arrived)
        XCTAssertEqual(session.update(position: inside, speedOverGround: 3, now: now), [], "arrival announced once")
        session.stop()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.guidance)
    }

    func testDirectToWithoutAFixStartsOnTheFirstFix() {
        var session = NavigationSession()
        session.startDirectTo(target("Mark", 27.65, -82.75), from: nil)
        XCTAssertNil(session.guidance)
        session.update(position: start, speedOverGround: nil, now: now)
        XCTAssertNotNil(session.guidance)
        XCTAssertNil(session.guidance?.eta, "no ETA without speed")
    }

    func testRouteFollowingAdvancesLegsAndFinishes() {
        let id = UUID()
        let points = [target("A", 27.61, -82.75), target("B", 27.63, -82.75), target("C", 27.63, -82.72)]
        var session = NavigationSession()
        session.startRoute(id: id, name: "Run", points: points, from: start)
        session.update(position: start, speedOverGround: 3, now: now)
        XCTAssertEqual(session.guidance?.targetName, "A")
        XCTAssertEqual(session.guidance?.targetIndex, 0)
        XCTAssertEqual(session.guidance?.pointCount, 3)
        let expectedRemaining = Geodesy.distance(from: start, to: points[0].coordinate)
            + Geodesy.distance(from: points[0].coordinate, to: points[1].coordinate)
            + Geodesy.distance(from: points[1].coordinate, to: points[2].coordinate)
        XCTAssertEqual(session.guidance!.remainingDistance, expectedRemaining, accuracy: 1)

        // Crossing the perpendicular past A advances to B.
        let pastA = Coordinate(latitude: 27.6105, longitude: -82.749)
        XCTAssertEqual(session.update(position: pastA, speedOverGround: 3, now: now),
                       [.advanced(reachedName: "A", nextName: "B")])
        XCTAssertEqual(session.activeRoutePointIndex, 1)
        XCTAssertEqual(session.guidance?.targetName, "B")

        session.skipToNext(position: pastA)
        XCTAssertEqual(session.activeRoutePointIndex, 2)
        session.update(position: pastA, speedOverGround: 3, now: now)
        XCTAssertEqual(session.guidance?.targetName, "C")
        XCTAssertEqual(session.guidance?.targetIndex, 2)
        XCTAssertEqual(session.update(position: points[2].coordinate, speedOverGround: 3, now: now), [.arrived(name: "C")])
        XCTAssertEqual(session.activeRouteID, id)
    }

    func testRouteStartingLaterAndEmptyRoute() {
        var session = NavigationSession()
        let points = [target("A", 27.61, -82.75), target("B", 27.63, -82.75), target("C", 27.63, -82.72)]
        session.startRoute(id: UUID(), name: "Run", points: points, from: start, startingAt: 1)
        session.update(position: start, speedOverGround: 3, now: now)
        XCTAssertEqual(session.guidance?.targetName, "B")
        XCTAssertEqual(session.guidance?.targetIndex, 1)
        session.startRoute(id: UUID(), name: "Empty", points: [], from: start)
        XCTAssertFalse(session.isActive)
    }
}

/// In-memory `TrackRecordingStore` that can be told to fail.
actor FakeTrackStore: TrackRecordingStore {
    var tracks: [UUID: Track] = [:]
    var points: [UUID: [[TrackPoint]]] = [:]
    var appendCalls: [(count: Int, newSegment: Bool)] = []
    var failNextAppend = false

    func setFailNextAppend() { failNextAppend = true }

    func startRecording(name: String) async throws -> Track {
        let t = Track(name: name, state: .recording)
        tracks[t.id] = t
        points[t.id] = []
        return t
    }

    func append(_ batch: [TrackPoint], to id: UUID, startNewSegment: Bool) async throws -> Track {
        if failNextAppend {
            failNextAppend = false
            throw PersistenceError.invalidArgument("simulated failure")
        }
        appendCalls.append((batch.count, startNewSegment))
        var segs = points[id] ?? []
        if segs.isEmpty || startNewSegment { segs.append([]) }
        segs[segs.count - 1].append(contentsOf: batch)
        points[id] = segs
        var t = tracks[id]!
        t.statistics.pointCount = segs.reduce(0) { $0 + $1.count }
        t.statistics.segmentCount = segs.count
        tracks[id] = t
        return t
    }

    func finish(_ id: UUID) async throws -> Track {
        var t = tracks[id]!
        t.state = .finished
        tracks[id] = t
        return t
    }

    func geometry(_ id: UUID) async throws -> [[Coordinate]] {
        (points[id] ?? []).map { $0.map(\.coordinate) }
    }
}

final class TrackRecorderTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func fix(_ seconds: Double, north meters: Double, accuracy: Double = 5) -> Fix {
        let base = Coordinate(latitude: 27.6, longitude: -82.7)
        return Fix(coordinate: Geodesy.destination(from: base, bearing: 0, distance: meters),
                   timestamp: t0.addingTimeInterval(seconds), speed: 2, course: 0, horizontalAccuracy: accuracy)
    }

    func testFilter() {
        let filter = TrackPointFilter(minimumInterval: 5, minimumDistance: 10, maximumHorizontalAccuracy: 50,
                                      stationaryInterval: 300)
        let last = TrackPoint(fix(0, north: 0))
        XCTAssertTrue(filter.accepts(fix(0, north: 0), after: nil))
        XCTAssertFalse(filter.accepts(fix(2, north: 20), after: last), "too soon")
        XCTAssertFalse(filter.accepts(fix(10, north: 5), after: last), "too close")
        XCTAssertTrue(filter.accepts(fix(10, north: 20), after: last))
        XCTAssertFalse(filter.accepts(fix(10, north: 20, accuracy: 80), after: last), "inaccurate")
        XCTAssertTrue(filter.accepts(fix(400, north: 1), after: last), "stationary heartbeat")
        XCTAssertFalse(filter.accepts(fix(-1, north: 50), after: last), "time going backwards")
    }

    func testBatchesPausesResumesAndStops() async throws {
        let store = FakeTrackStore()
        let recorder = TrackRecorder(store: store, filter: TrackPointFilter(minimumInterval: 1, minimumDistance: 1),
                                     batchSize: 3, maximumBatchAge: 1000)
        let track = try await recorder.start(name: "Test")
        for i in 0..<5 {
            await recorder.record(fix(Double(i * 10), north: Double(i * 100)))
        }
        var calls = await store.appendCalls
        XCTAssertEqual(calls.map(\.count), [3], "one full batch written, two pending")
        var snap = await recorder.snapshot
        XCTAssertEqual(snap.pointCount, 5)
        XCTAssertEqual(snap.distance, 200, accuracy: 1, "the fake stores no distance: the two unsaved steps")
        XCTAssertEqual(snap.segments.map(\.count), [5])

        await recorder.pause()
        calls = await store.appendCalls
        XCTAssertEqual(calls.map(\.count), [3, 2])
        let ignored = await recorder.record(fix(100, north: 2000))
        XCTAssertFalse(ignored, "paused: fixes ignored")

        await recorder.resume()
        await recorder.record(fix(200, north: 3000))
        await recorder.flush()
        calls = await store.appendCalls
        XCTAssertEqual(calls.last?.newSegment, true, "resume starts a new segment")
        snap = await recorder.snapshot
        XCTAssertEqual(snap.segments.map(\.count), [5, 1])

        let finished = try await recorder.stop()
        XCTAssertEqual(finished?.id, track.id)
        XCTAssertEqual(finished?.state, .finished)
        let idle = await recorder.snapshot
        XCTAssertEqual(idle.state, .idle)
        do {
            _ = try await recorder.start(name: "Again")
            _ = try await recorder.start(name: "Twice")
            XCTFail("second start should throw")
        } catch let error as TrackRecorderError {
            XCTAssertEqual(error, .alreadyRecording)
        }
    }

    func testFailedWriteKeepsPointsAndRetries() async throws {
        let store = FakeTrackStore()
        let recorder = TrackRecorder(store: store, filter: TrackPointFilter(minimumInterval: 1, minimumDistance: 1),
                                     batchSize: 2, maximumBatchAge: 1000)
        _ = try await recorder.start(name: "Flaky")
        await store.setFailNextAppend()
        await recorder.record(fix(0, north: 0))
        await recorder.record(fix(10, north: 50))
        var snap = await recorder.snapshot
        XCTAssertNotNil(snap.lastError)
        XCTAssertEqual(snap.pointCount, 2)
        await recorder.record(fix(20, north: 100))
        snap = await recorder.snapshot
        XCTAssertNil(snap.lastError)
        let calls = await store.appendCalls
        XCTAssertEqual(calls.map(\.count), [3])
    }

    func testBatchAgeFlushes() async throws {
        let store = FakeTrackStore()
        let recorder = TrackRecorder(store: store, filter: TrackPointFilter(minimumInterval: 1, minimumDistance: 1),
                                     batchSize: 100, maximumBatchAge: 30)
        _ = try await recorder.start(name: "Slow")
        await recorder.record(fix(0, north: 0))
        await recorder.record(fix(10, north: 50))
        var calls = await store.appendCalls
        XCTAssertTrue(calls.isEmpty)
        await recorder.record(fix(31, north: 100))
        calls = await store.appendCalls
        XCTAssertEqual(calls.map(\.count), [3])
    }

    func testRecoveredRecordingContinuesInPersistenceWithANewSegment() async throws {
        let store = try PersistenceStore(inMemoryWith: .init())
        let first = TrackRecorder(store: PersistenceTrackRecordingStore(store: store),
                                  filter: TrackPointFilter(minimumInterval: 1, minimumDistance: 1), batchSize: 2)
        let track = try await first.start(name: "Passage")
        await first.record(fix(0, north: 0))
        await first.record(fix(10, north: 100))
        // The app is killed here: the recorder is gone, the track is still "recording".
        let outcome = await RecordingRecovery.recover(store: store, now: t0.addingTimeInterval(600))
        XCTAssertEqual(outcome.resumed?.id, track.id)

        let second = TrackRecorder(store: PersistenceTrackRecordingStore(store: store),
                                   filter: TrackPointFilter(minimumInterval: 1, minimumDistance: 1), batchSize: 2)
        await second.adopt(outcome.resumed!)
        var snap = await second.snapshot
        XCTAssertEqual(snap.segments.map(\.count), [2, 0])
        await second.record(fix(700, north: 5000))
        await second.record(fix(710, north: 5100))
        let finished = try await second.stop()
        XCTAssertEqual(finished?.statistics.segmentCount, 2)
        XCTAssertEqual(finished?.statistics.pointCount, 4)
        XCTAssertEqual(finished!.statistics.distance.meters, 200, accuracy: 2, "the gap is not counted")
        snap = await second.snapshot
        XCTAssertEqual(snap.state, .idle)
    }
}

final class MapFeaturesTests: XCTestCase {
    func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func features(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(try json(data)["features"] as? [[String: Any]])
    }

    func testWaypointsGeoJSONUsesLonLatAndFlags() throws {
        let a = Waypoint(name: "A \"quoted\"\nname", coordinate: Coordinate(latitude: 27.5, longitude: -82.25), symbol: "Anchor")
        let b = Waypoint(name: "B", coordinate: Coordinate(latitude: 27.75, longitude: -82.5))
        let list = try features(MapFeatures.waypoints([a, b], selected: b.id, target: a.id))
        XCTAssertEqual(list.count, 2)
        let geometry = try XCTUnwrap(list[0]["geometry"] as? [String: Any])
        XCTAssertEqual(geometry["type"] as? String, "Point")
        let coordinates = try XCTUnwrap(geometry["coordinates"] as? [Double])
        XCTAssertEqual(coordinates, [-82.25, 27.5])
        let props = try XCTUnwrap(list[0]["properties"] as? [String: Any])
        XCTAssertEqual(props["name"] as? String, "A \"quoted\"\nname")
        XCTAssertEqual(props["target"] as? Bool, true)
        XCTAssertEqual(props["selected"] as? Bool, false)
        XCTAssertEqual(props["symbol"] as? String, "Anchor")
    }

    func testRouteLegsCarryGradesAndState() throws {
        var route = Route(name: "R", points: [
            RoutePoint(coordinate: Coordinate(latitude: 27.6, longitude: -82.7)),
            RoutePoint(coordinate: Coordinate(latitude: 27.7, longitude: -82.7), name: "Mid"),
            RoutePoint(coordinate: Coordinate(latitude: 27.7, longitude: -82.6)),
        ])
        let manual = RouteDisplay(route: route)
        XCTAssertEqual(manual.legs.map(\.grade), [nil, nil])
        XCTAssertEqual(manual.pointName(0), "WP 1")
        XCTAssertEqual(manual.pointName(1), "Mid")
        XCTAssertGreaterThan(manual.length, 20_000)

        let info = AutoRouteInfo(boat: .init(name: "Boat", draftMeters: 1, safetyMarginMeters: 0.3,
                                             useMaintainedChannels: true, acceptUnknownClearance: false),
                                 legs: [.init(index: 0, grade: .green), .init(index: 1, grade: .yellow, reasonCodes: ["maintained-channel-depth"])],
                                 summary: .init(distanceMeters: 21_000, worstGrade: .yellow))
        route.metadata = try RouteMetadata(info)
        let auto = RouteDisplay(route: route)
        XCTAssertEqual(auto.legs.map(\.grade), ["green", "yellow"])
        XCTAssertEqual(auto.legs[1].reasonCodes, ["maintained-channel-depth"])
        XCTAssertEqual(auto.summary?.worstGrade, .yellow)

        let legs = try features(MapFeatures.routeLegs([auto], activeRouteID: auto.id, activeLeg: 1))
        let props = legs.map { $0["properties"] as! [String: Any] }
        XCTAssertEqual(props.map { $0["state"] as! String }, ["done", "active"])
        XCTAssertEqual(props.map { $0["grade"] as! String }, ["green", "yellow"])
        XCTAssertEqual(props.map { $0["leg"] as! Double }, [0, 1])
        let manualLegs = try features(MapFeatures.routeLegs([manual], activeRouteID: nil, activeLeg: nil))
        XCTAssertEqual(manualLegs.map { ($0["properties"] as! [String: Any])["state"] as! String }, ["plan", "plan"])
        XCTAssertEqual(manualLegs.map { ($0["properties"] as! [String: Any])["grade"] as! String }, ["none", "none"])

        let points = try features(MapFeatures.routePoints([auto], activeRouteID: auto.id, nextPointIndex: 2))
        let kinds = points.map { ($0["properties"] as! [String: Any])["kind"] as! String }
        XCTAssertEqual(kinds, ["start", "turn", "end"])
        XCTAssertEqual(points.map { ($0["properties"] as! [String: Any])["next"] as! Bool }, [false, false, true])
    }

    func testTracksSkipShortSegmentsAndDirectTo() throws {
        let line = [Coordinate(latitude: 27.6, longitude: -82.7), Coordinate(latitude: 27.61, longitude: -82.69)]
        let id = UUID()
        let list = try features(MapFeatures.tracks([
            TrackLine(id: id, segments: [line, [line[0]]], isLive: true),
            TrackLine(id: UUID(), segments: [[line[0]]], isLive: false),
        ]))
        XCTAssertEqual(list.count, 1)
        let geometry = list[0]["geometry"] as! [String: Any]
        XCTAssertEqual(geometry["type"] as? String, "MultiLineString")
        XCTAssertEqual((geometry["coordinates"] as! [[[Double]]]).count, 1)
        let props = list[0]["properties"] as! [String: Any]
        XCTAssertEqual(props["color"] as? String, "#D02090")
        XCTAssertEqual(props["live"] as? Bool, true)
        XCTAssertEqual(try features(MapFeatures.directTo(nil)).count, 0)
        XCTAssertEqual(try features(MapFeatures.directTo(line)).count, 1)
        XCTAssertEqual(GeoJSON.number(-0.0000000001, digits: 7), "0")
        XCTAssertEqual(GeoJSON.number(12.5, digits: 7), "12.5")
    }

    func testTrackDetailPolicy() {
        XCTAssertEqual(TrackDetailPolicy.detail(forZoom: 18, latitude: 27), .full)
        XCTAssertEqual(TrackDetailPolicy.detail(forZoom: 12.7, latitude: 27), .zoom(12, latitude: 27, pixels: 1))
        XCTAssertEqual(TrackDetailPolicy.bucket(forZoom: .nan), 10)
    }

    func testTrackGeometryQueryAtZoomSimplifies() async throws {
        let store = try PersistenceStore(inMemoryWith: .init())
        var points: [TrackPoint] = []
        let base = Coordinate(latitude: 27.6, longitude: -82.7)
        for i in 0..<200 {
            // A nearly straight line with sub-metre wiggle: simplifies to a few points at low zoom.
            let c = Geodesy.destination(from: base, bearing: i % 2 == 0 ? 0 : 0.01, distance: Double(i) * 20)
            points.append(TrackPoint(timestamp: Date(timeIntervalSince1970: Double(i)), coordinate: c))
        }
        let track = try await store.saveTrack(name: "Line", segments: [points])
        let coarse = try await store.trackGeometry(track.id, detail: TrackDetailPolicy.detail(forZoom: 10, latitude: 27.6))
        let fine = try await store.trackGeometry(track.id, detail: TrackDetailPolicy.detail(forZoom: 18, latitude: 27.6))
        XCTAssertEqual(fine[0].count, 200)
        XCTAssertLessThan(coarse[0].count, 10)
    }
}

final class GPXPresentationTests: XCTestCase {
    func testSampleParsesAndPlansWithDuplicatesOnSecondImport() async throws {
        let document = try GPXFiles.parse(Data(GPXSamples.tampaBay.utf8))
        XCTAssertEqual(document.waypoints.count, 2)
        XCTAssertEqual(document.routes.count, 1)
        XCTAssertEqual(document.tracks.count, 1)

        let store = try PersistenceStore(inMemoryWith: .init())
        let plan = try await store.planGPXImport(document)
        XCTAssertEqual(plan.duplicateCount, 0)
        XCTAssertEqual(GPXImportPresentation.summary(plan), "2 waypoints, 1 route and 1 track.")
        let rows = GPXImportPresentation.rows(plan, units: UnitPreferences())
        XCTAssertEqual(rows.map(\.id), ["w0", "w1", "r0", "t0"])
        XCTAssertEqual(rows[2].detail.hasPrefix("3 points, "), true, rows[2].detail)
        XCTAssertTrue(rows[3].detail.hasPrefix("3 points, 1 Nov 2026"), rows[3].detail)
        XCTAssertTrue(rows.allSatisfy { $0.duplicateText == nil && $0.decision == .importNew })
        let result = try await store.applyGPXImport(plan)
        XCTAssertEqual(GPXImportPresentation.resultText(result), "Imported 4.")

        var again = try await store.planGPXImport(document)
        XCTAssertEqual(again.duplicateCount, 4)
        let dupRows = GPXImportPresentation.rows(again, units: UnitPreferences())
        XCTAssertEqual(dupRows[0].duplicateText, "Already saved as “Sample Egmont Channel”")
        XCTAssertTrue(dupRows.allSatisfy { $0.decision == .skip && $0.canReplace })
        XCTAssertTrue(GPXImportPresentation.summary(again).contains("4 already saved or repeated. 4 will be skipped."))
        GPXImportPresentation.setDecision(.replaceExisting, rowID: "w0", in: &again)
        GPXImportPresentation.setDecision(.importNew, rowID: "t0", in: &again)
        GPXImportPresentation.setDecision(.importNew, rowID: "x9", in: &again)
        let second = try await store.applyGPXImport(again)
        XCTAssertEqual(GPXImportPresentation.resultText(second), "Imported 1, replaced 1, skipped 2.")
        let count = try await store.waypointCount()
        XCTAssertEqual(count, 2)
    }

    func testReplaceIsOnlyAllowedForStoredDuplicates() async throws {
        let doc = GPXDocument(creator: "t", waypoints: [GPXWaypoint(latitude: 27, longitude: -82, name: "A"),
                                                        GPXWaypoint(latitude: 27, longitude: -82, name: "A")])
        let store = try PersistenceStore(inMemoryWith: .init())
        var plan = try await store.planGPXImport(doc)
        let rows = GPXImportPresentation.rows(plan, units: UnitPreferences())
        XCTAssertEqual(rows[1].duplicateText, "Same as waypoint 1 in this file")
        XCTAssertFalse(rows[1].canReplace)
        GPXImportPresentation.setDecision(.replaceExisting, rowID: "w1", in: &plan)
        XCTAssertEqual(plan.waypoints[1].decision, GPXImportDecision.importNew)
    }

    func testFileNamesAndExportRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15
        XCTAssertEqual(GPXFiles.fileName(title: "Egmont/Key: run?", date: date), "Gulf Nav - Egmont Key  run 2027-01-15.gpx")
        XCTAssertEqual(GPXFiles.fileName(title: "  ", date: date), "Gulf Nav 2027-01-15.gpx")
        let dir = try TempDir()
        defer { dir.cleanup() }
        let doc = try GPXFiles.parse(Data(GPXSamples.tampaBay.utf8))
        let url = try GPXFiles.writeTemporary(doc, title: "All", date: date, directory: dir.url)
        XCTAssertEqual(url.pathExtension, "gpx")
        let back = try GPXFiles.parse(try Data(contentsOf: url))
        XCTAssertEqual(back.waypoints.map(\.name), doc.waypoints.map(\.name))
        XCTAssertEqual(back.tracks.first?.segments.first?.points.count, 3)
    }
}

final class ListRowsAndSettingsTests: XCTestCase {
    func testWaypointRowsSortByDistanceFromTheBoat() {
        let boat = Coordinate(latitude: 27.6, longitude: -82.7)
        let near = Waypoint(name: "Near", coordinate: Coordinate(latitude: 27.61, longitude: -82.7))
        let far = Waypoint(name: "Far", coordinate: Coordinate(latitude: 27.0, longitude: -82.7))
        let rows = WaypointRow.rows([far, near], from: boat, units: UnitPreferences())
        XCTAssertEqual(rows.map(\.name), ["Near", "Far"])
        XCTAssertEqual(rows[0].bearingText, "000°T")
        XCTAssertEqual(rows[1].bearingText, "180°T")
        XCTAssertEqual(rows[0].distanceText, "0.60 nm")
        let noFix = WaypointRow.rows([near, far], from: nil, units: UnitPreferences())
        XCTAssertEqual(noFix.map(\.name), ["Far", "Near"])
        XCTAssertEqual(noFix[0].distanceText, "—")
    }

    func testTrackRowsAndNames() {
        var t = Track(name: "T", startDate: Date(timeIntervalSince1970: 1_700_000_000))
        t.statistics = TrackStatistics(pointCount: 10, segmentCount: 1, distance: .nauticalMiles(6), duration: 3600)
        let row = TrackRow.rows([t], units: UnitPreferences(), timeZone: TimeZone(identifier: "UTC")!)[0]
        XCTAssertEqual(row.distance, "6.00 nm")
        XCTAssertEqual(row.duration, "1 h 00 min")
        XCTAssertEqual(row.averageSpeed, "6.0 kn")
        XCTAssertEqual(row.date, "14 Nov 2023 22:13")
        XCTAssertEqual(DefaultNames.nextWaypointName(existing: ["WP 001", "WP 017", "Other", "WP x"]), "WP 018")
        XCTAssertEqual(DefaultNames.nextWaypointName(existing: []), "WP 001")
        XCTAssertEqual(WaypointSymbols.systemImage(for: "anchor"), "sailboat")
        XCTAssertEqual(WaypointSymbols.systemImage(for: nil), "mappin")
    }

    func testSettingsRoundTripThroughPersistence() async throws {
        let store = try PersistenceStore(inMemoryWith: .init())
        let defaults = await AppSettings.load(from: store)
        XCTAssertEqual(defaults, AppSettings())
        var changed = defaults
        changed.speedUnit = .kilometersPerHour
        changed.distanceUnit = .kilometers
        changed.mapOrientation = .headingUp
        changed.trackInterval = 10
        changed.keepScreenOn = false
        try await changed.save(to: store, previous: defaults)
        let names = try await store.storedSettingNames()
        XCTAssertEqual(Set(names), ["units.speed", "units.distance", "map.orientation", "track.recordingInterval",
                                    "display.keepScreenOn"])
        let loaded = await AppSettings.load(from: store)
        XCTAssertEqual(loaded, changed)
        XCTAssertEqual(loaded.orientationMode, .courseUp)
        XCTAssertEqual(loaded.trackFilter.minimumInterval, 10)
        XCTAssertEqual(loaded.units, UnitPreferences(distance: .kilometers, depth: .feet, speed: .kilometersPerHour))
    }
}

final class OverlayAndLaunchAdditionsTests: XCTestCase {
    func testBestStartIndexJoinsTheLegTheBoatIsOn() {
        let a = Coordinate(latitude: 27.60, longitude: -82.75)
        let b = Coordinate(latitude: 27.62, longitude: -82.75)
        let c = Coordinate(latitude: 27.62, longitude: -82.70)
        XCTAssertEqual(NavigationSession.bestStartIndex(points: [a, b, c], position: nil), 0)
        XCTAssertEqual(NavigationSession.bestStartIndex(points: [a, b, c], position: Coordinate(latitude: 27.59, longitude: -82.75)), 0,
                       "before the start: go to the start")
        XCTAssertEqual(NavigationSession.bestStartIndex(points: [a, b, c], position: Coordinate(latitude: 27.61, longitude: -82.7501)), 1,
                       "on the first leg: steer to its end")
        XCTAssertEqual(NavigationSession.bestStartIndex(points: [a, b, c], position: Coordinate(latitude: 27.6201, longitude: -82.72)), 2)
        XCTAssertEqual(NavigationSession.bestStartIndex(points: [a], position: a), 0)
    }

    func testMapOverlaysCountsAndActiveLeg() throws {
        let route = Route(name: "R", points: [
            RoutePoint(coordinate: Coordinate(latitude: 27.6, longitude: -82.7)),
            RoutePoint(coordinate: Coordinate(latitude: 27.7, longitude: -82.7)),
            RoutePoint(coordinate: Coordinate(latitude: 27.7, longitude: -82.6)),
        ])
        let display = RouteDisplay(route: route)
        let w = Waypoint(name: "W", coordinate: Coordinate(latitude: 27.5, longitude: -82.5))
        let line = [Coordinate(latitude: 27.6, longitude: -82.7), Coordinate(latitude: 27.61, longitude: -82.7)]
        let overlays = MapOverlays.make(waypoints: [w], selectedWaypoint: nil, targetWaypoint: w.id, routes: [display],
                                        activeRouteID: display.id, nextPointIndex: 2, editingRouteID: nil,
                                        tracks: [TrackLine(id: UUID(), segments: [line], isLive: true)], directLine: line)
        XCTAssertEqual(overlays.summary, "waypoints:1,routeLegs:2,routePoints:3,tracks:1,direct:1,plannedLegs:0,blocked:0")
        let legs = try XCTUnwrap(try JSONSerialization.jsonObject(with: overlays.routeLegs) as? [String: Any])
        let states = (legs["features"] as! [[String: Any]]).map { ($0["properties"] as! [String: Any])["state"] as! String }
        XCTAssertEqual(states, ["done", "active"])
        XCTAssertEqual(MapOverlays.empty.summary, "waypoints:0,routeLegs:0,routePoints:0,tracks:0,direct:0,plannedLegs:0,blocked:0")
        XCTAssertNotEqual(overlays, MapOverlays.empty)

        var d = MapDiagnostics()
        d.overlayFeatures = overlays.summary
        XCTAssertEqual(MapDiagnostics.overlayCount("routePoints", in: d.statusValue), 3)
        XCTAssertEqual(MapDiagnostics.overlayCount("waypoints", in: d.statusValue), 1)
        XCTAssertEqual(MapDiagnostics.overlayCount("tracks", in: d.statusValue), 1)
    }

    func testLaunchSpeedAndBatch() {
        let launch = LaunchConfiguration(environment: ["GULFNAV_SIM_SPEED_KNOTS": "240", "GULFNAV_TRACK_BATCH_SIZE": "2"])
        XCTAssertEqual(launch.simulatedSpeedKnots, 240)
        XCTAssertEqual(launch.trackBatchSize, 2)
        let bad = LaunchConfiguration(environment: ["GULFNAV_SIM_SPEED_KNOTS": "-3", "GULFNAV_TRACK_BATCH_SIZE": "0"])
        XCTAssertNil(bad.simulatedSpeedKnots)
        XCTAssertNil(bad.trackBatchSize)
    }

    func testSnapshotReportsStoredPoints() async throws {
        let store = FakeTrackStore()
        let recorder = TrackRecorder(store: store, filter: TrackPointFilter(minimumInterval: 1, minimumDistance: 1), batchSize: 2)
        _ = try await recorder.start(name: "S")
        let base = Coordinate(latitude: 27.6, longitude: -82.7)
        for i in 0..<3 {
            await recorder.record(Fix(coordinate: Geodesy.destination(from: base, bearing: 0, distance: Double(i) * 50),
                                      timestamp: Date(timeIntervalSince1970: Double(i) * 10), speed: 2, course: 0,
                                      horizontalAccuracy: 5))
        }
        let snap = await recorder.snapshot
        XCTAssertEqual(snap.pointCount, 3)
        XCTAssertEqual(snap.storedPointCount, 2)
    }
}

final class GPXFileFlowTests: XCTestCase {
    func testPlanFromFileAndExportAll() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let file = dir.url.appendingPathComponent("in.gpx")
        try Data(GPXSamples.tampaBay.utf8).write(to: file)
        let store = try PersistenceStore(inMemoryWith: .init())
        let plan = try await GPXFiles.plan(fileAt: file, store: store)
        _ = try await store.applyGPXImport(plan)
        let url = try await GPXFiles.export(store: store, waypoints: nil, routes: [], tracks: [], title: "Waypoints",
                                            date: Date(timeIntervalSince1970: 1_800_000_000), directory: dir.url)
        let back = try GPXFiles.parse(try Data(contentsOf: url))
        XCTAssertEqual(back.waypoints.count, 2)
        XCTAssertEqual(back.routes.count, 0)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Gulf Nav - Waypoints"))
        do {
            _ = try await GPXFiles.plan(data: Data("not xml".utf8), store: store)
            XCTFail("expected a parse error")
        } catch {}
    }
}

final class DirectToRearmTests: XCTestCase {
    func testGoToAMarkTheBoatIsAtArrivesThenRearmsWhenTheBoatLeaves() {
        let mark = Coordinate(latitude: 27.6, longitude: -82.7)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = NavigationSession()
        session.startDirectTo(NavigationTarget(name: "Mark", coordinate: mark), from: mark)
        XCTAssertEqual(session.update(position: mark, speedOverGround: 3, now: now), [.arrived(name: "Mark")],
                       "already there: arrival at once")
        XCTAssertNil(session.guidance?.eta, "no ETA while arrived")

        // 150 m away (inside twice the 92.6 m radius): still arrived, distance and bearing live.
        let near = Geodesy.destination(from: mark, bearing: 90, distance: 150)
        XCTAssertEqual(session.update(position: near, speedOverGround: 3, now: now), [])
        XCTAssertEqual(session.guidance?.arrived, true)
        XCTAssertEqual(session.guidance!.distanceToTarget, 150, accuracy: 1)
        XCTAssertEqual(session.guidance!.bearingToTarget, 270, accuracy: 1)

        // 300 m away: re-armed, ETA back, still direct-to.
        let away = Geodesy.destination(from: mark, bearing: 90, distance: 300)
        XCTAssertEqual(session.update(position: away, speedOverGround: 3, now: now), [])
        XCTAssertEqual(session.guidance?.arrived, false)
        XCTAssertNotNil(session.guidance?.eta)
        XCTAssertEqual(session.directToTarget?.name, "Mark")

        // Coming back in: a second arrival is announced.
        XCTAssertEqual(session.update(position: Geodesy.destination(from: mark, bearing: 90, distance: 20),
                                      speedOverGround: 3, now: now), [.arrived(name: "Mark")])
    }

    func testFinishedRouteDoesNotRearm() {
        let a = Coordinate(latitude: 27.6, longitude: -82.7)
        let b = Coordinate(latitude: 27.61, longitude: -82.7)
        var session = NavigationSession()
        session.startRoute(id: UUID(), name: "R", points: [NavigationTarget(name: "A", coordinate: a),
                                                           NavigationTarget(name: "B", coordinate: b)], from: a)
        let now = Date()
        _ = session.update(position: a, speedOverGround: 3, now: now)
        XCTAssertEqual(session.update(position: b, speedOverGround: 3, now: now), [.arrived(name: "B")])
        let away = Geodesy.destination(from: b, bearing: 0, distance: 1000)
        XCTAssertEqual(session.update(position: away, speedOverGround: 3, now: now), [])
        XCTAssertEqual(session.guidance?.arrived, true)
    }
}

final class WaypointNumberingTests: XCTestCase {
    func testNumbersNeverRepeatAfterRenameOrDelete() async throws {
        let store = try PersistenceStore(inMemoryWith: .init())
        let first = await WaypointNumbering.takeNextName(store: store, existing: [])
        XCTAssertEqual(first, "WP 001")
        // WP 001 renamed to "Egmont": the next one is still WP 002, not WP 001 again.
        let second = await WaypointNumbering.takeNextName(store: store, existing: ["Egmont"])
        XCTAssertEqual(second, "WP 002")
        // Everything deleted: still counting on.
        let third = await WaypointNumbering.takeNextName(store: store, existing: [])
        XCTAssertEqual(third, "WP 003")
        // An imported "WP 041" moves the counter past it.
        let fourth = await WaypointNumbering.takeNextName(store: store, existing: ["WP 041", "Other"])
        XCTAssertEqual(fourth, "WP 042")
        let stored = try await store.setting(WaypointNumbering.nextNumberKey)
        XCTAssertEqual(stored, 43)
        XCTAssertEqual(WaypointNumbering.name(for: 1234), "WP 1234")
    }
}

final class RetainedIDsTests: XCTestCase {
    func testAStaleReloadDoesNotDropANewChoiceButAFreshOneDoes() {
        let a = UUID()
        var selection = RetainedIDs()
        // Reload 1 starts (a settings write) ...
        let staleReloadStart = 1
        // ... meanwhile the waypoint is saved and selected (revision is still 1).
        selection.set(a, revision: 1)
        // Reload 1 finishes without the new waypoint: the selection stays.
        XCTAssertFalse(selection.reconcile(present: [], reloadStartedAt: staleReloadStart))
        XCTAssertEqual(selection.single, a)
        // Reload 2 (started after the selection) has it: stays.
        XCTAssertFalse(selection.reconcile(present: [a], reloadStartedAt: 2))
        XCTAssertEqual(selection.single, a)
        // Reload 3, after a delete, does not have it: dropped.
        XCTAssertTrue(selection.reconcile(present: [], reloadStartedAt: 3))
        XCTAssertNil(selection.single)
        XCTAssertTrue(selection.isEmpty)
    }

    func testSetsOfShownItems() {
        let a = UUID(), b = UUID()
        var shown = RetainedIDs()
        shown.insert(a, revision: 1)
        shown.insert(b, revision: 4)
        XCTAssertEqual(shown.count, 2)
        XCTAssertNil(shown.single)
        shown.reconcile(present: [], reloadStartedAt: 3)
        XCTAssertEqual(shown.ids, [b], "a dropped (added before reload 3), b kept (added after)")
        shown.set(nil, revision: 5)
        XCTAssertTrue(shown.isEmpty)
    }
}
