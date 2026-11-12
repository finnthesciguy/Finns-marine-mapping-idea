import NavCore
import XCTest
@testable import AppServices

final class BroadcasterTests: XCTestCase {
    func testDeliversToEverySubscriberAndReplaysLatest() async {
        let broadcaster = Broadcaster<Int>()
        let a = broadcaster.stream()
        broadcaster.yield(1)
        let b = broadcaster.stream() // replays 1
        broadcaster.yield(2)
        broadcaster.finish()

        var seenA: [Int] = []
        for await value in a { seenA.append(value) }
        var seenB: [Int] = []
        for await value in b { seenB.append(value) }
        XCTAssertEqual(seenA, [1, 2])
        XCTAssertEqual(seenB, [1, 2])
        XCTAssertEqual(broadcaster.latest, 2)
    }

    func testNoReplayWhenAsked() async {
        let broadcaster = Broadcaster<Int>()
        broadcaster.yield(1)
        let stream = broadcaster.stream(replayLatest: false)
        broadcaster.yield(2)
        broadcaster.finish()
        var seen: [Int] = []
        for await value in stream { seen.append(value) }
        XCTAssertEqual(seen, [2])
    }

    func testSubscriberAfterFinishGetsFinishedStream() async {
        let broadcaster = Broadcaster<Int>()
        broadcaster.finish()
        broadcaster.yield(5)
        var count = 0
        for await _ in broadcaster.stream() { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testCancelledConsumerUnsubscribes() async throws {
        let broadcaster = Broadcaster<Int>()
        let task = Task {
            for await _ in broadcaster.stream() {}
        }
        // Wait until the subscription is registered.
        for _ in 0..<200 where broadcaster.subscriberCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(broadcaster.subscriberCount, 1)
        task.cancel()
        for _ in 0..<200 where broadcaster.subscriberCount != 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(broadcaster.subscriberCount, 0)
    }
}

final class LocationPolicyTests: XCTestCase {
    func testBackgroundOnlyWhenRecordingDeclaredAndAuthorized() {
        let off = LocationPolicy.settings(recording: false, backgroundModeDeclared: true, authorization: .authorizedAlways)
        XCTAssertFalse(off.allowsBackgroundUpdates)
        XCTAssertFalse(off.showsBackgroundIndicator)
        XCTAssertFalse(off.usesNavigationActivityType)
        XCTAssertFalse(off.pausesAutomatically)

        let notDeclared = LocationPolicy.settings(recording: true, backgroundModeDeclared: false,
                                                  authorization: .authorizedWhenInUse)
        XCTAssertFalse(notDeclared.allowsBackgroundUpdates, "must never be set without UIBackgroundModes=location")
        XCTAssertTrue(notDeclared.usesNavigationActivityType)

        let denied = LocationPolicy.settings(recording: true, backgroundModeDeclared: true, authorization: .denied)
        XCTAssertFalse(denied.allowsBackgroundUpdates)

        let on = LocationPolicy.settings(recording: true, backgroundModeDeclared: true, authorization: .authorizedWhenInUse)
        XCTAssertTrue(on.allowsBackgroundUpdates)
        XCTAssertTrue(on.showsBackgroundIndicator)
        XCTAssertTrue(on.usesNavigationActivityType)
        XCTAssertFalse(on.pausesAutomatically)
    }

    func testDetectsBackgroundModeInInfoPlist() {
        XCTAssertFalse(LocationPolicy.declaresBackgroundLocation(nil))
        XCTAssertFalse(LocationPolicy.declaresBackgroundLocation(["CFBundleName": "x"]))
        XCTAssertFalse(LocationPolicy.declaresBackgroundLocation(["UIBackgroundModes": ["audio"]]))
        XCTAssertTrue(LocationPolicy.declaresBackgroundLocation(["UIBackgroundModes": ["fetch", "location"]]))
    }

    func testAuthorizationAllowsUpdates() {
        XCTAssertEqual(LocationAuthorization.allCases.filter(\.allowsUpdates),
                       [.authorizedWhenInUse, .authorizedAlways])
    }
}

final class FixConversionTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testValidValues() throws {
        let fix = try XCTUnwrap(FixConversion.fix(latitude: 27.6, longitude: -82.7, timestamp: date,
                                                  speed: 3, speedAccuracy: 0.5, course: 370, courseAccuracy: 5,
                                                  horizontalAccuracy: 4))
        XCTAssertEqual(fix.coordinate, Coordinate(latitude: 27.6, longitude: -82.7))
        XCTAssertEqual(fix.speed, 3)
        XCTAssertEqual(try XCTUnwrap(fix.course), 10, accuracy: 1e-9)
        XCTAssertEqual(fix.horizontalAccuracy, 4)
        XCTAssertEqual(fix.timestamp, date)
    }

    func testInvalidMarkersBecomeNil() {
        XCTAssertNil(FixConversion.fix(latitude: 27.6, longitude: -82.7, timestamp: date, speed: 1, speedAccuracy: 1,
                                       course: 1, courseAccuracy: 1, horizontalAccuracy: -1))
        XCTAssertNil(FixConversion.fix(latitude: 95, longitude: -82.7, timestamp: date, speed: 1, speedAccuracy: 1,
                                       course: 1, courseAccuracy: 1, horizontalAccuracy: 5))
        let fix = FixConversion.fix(latitude: 27.6, longitude: -82.7, timestamp: date, speed: -1, speedAccuracy: 1,
                                    course: 90, courseAccuracy: -1, horizontalAccuracy: 5)
        XCTAssertNotNil(fix)
        XCTAssertNil(fix?.speed)
        XCTAssertNil(fix?.course)
        let badSpeedAccuracy = FixConversion.fix(latitude: 27.6, longitude: -82.7, timestamp: date, speed: 2,
                                                 speedAccuracy: -1, course: -1, courseAccuracy: 3, horizontalAccuracy: 5)
        XCTAssertNil(badSpeedAccuracy?.speed)
        XCTAssertNil(badSpeedAccuracy?.course)
    }

    func testHeading() {
        XCTAssertNil(FixConversion.heading(trueHeading: -1, headingAccuracy: 5))
        XCTAssertNil(FixConversion.heading(trueHeading: 90, headingAccuracy: -1))
        XCTAssertEqual(FixConversion.heading(trueHeading: 360, headingAccuracy: 5), 0)
    }
}

final class SimulatedTrackTests: XCTestCase {
    func testTampaBayTrackIsEvenlyTimedAndSpaced() throws {
        let start = Date(timeIntervalSince1970: 0)
        let fixes = SimulatedTrack.tampaBay(start: start, speedKnots: 6, interval: 1)
        XCTAssertGreaterThan(fixes.count, 1_000, "a few nautical miles at 6 kn, one fix per second")
        XCTAssertEqual(fixes.first?.coordinate, SimulatedTrack.tampaBayWaypoints.first)
        XCTAssertEqual(fixes.last?.coordinate, SimulatedTrack.tampaBayWaypoints.last)
        let expectedStep = 6 * UnitConversion.metersPerSecondPerKnot
        for index in 1..<(fixes.count - 1) {
            XCTAssertEqual(fixes[index].timestamp.timeIntervalSince(fixes[index - 1].timestamp), 1, accuracy: 1e-9)
            let step = Geodesy.distance(from: fixes[index - 1].coordinate, to: fixes[index].coordinate)
            XCTAssertLessThanOrEqual(step, expectedStep + 0.01)
            let speed = try XCTUnwrap(fixes[index].speed)
            XCTAssertEqual(speed, expectedStep, accuracy: 1e-9)
            let course = try XCTUnwrap(fixes[index].course)
            XCTAssertTrue((0..<360).contains(course))
        }
        // Heads generally east-north-east up the bay.
        let firstCourse = try XCTUnwrap(fixes[1].course)
        XCTAssertGreaterThan(firstCourse, 45)
        XCTAssertLessThan(firstCourse, 90)
    }

    func testDegenerateInputs() {
        XCTAssertEqual(SimulatedTrack.make(waypoints: [], speedKnots: 6, interval: 1, start: Date()).count, 0)
        XCTAssertEqual(SimulatedTrack.make(waypoints: [Coordinate(latitude: 27, longitude: -82)], speedKnots: 6,
                                           interval: 1, start: Date()).count, 1)
    }
}

@MainActor
final class SimulatedLocationServiceTests: XCTestCase {
    func testReplaysEveryFixInOrderWithoutLooping() async {
        let track = SimulatedTrack.make(waypoints: [Coordinate(latitude: 27.60, longitude: -82.73),
                                                    Coordinate(latitude: 27.61, longitude: -82.70)],
                                        speedKnots: 20, interval: 10, start: Date(timeIntervalSince1970: 0))
        let service = SimulatedLocationService(track: track,
                                               options: .init(interval: .zero, loops: false, restampsToNow: false))
        let stream = service.fixes()
        service.startUpdates()
        XCTAssertTrue(service.isUpdating)
        var received: [Fix] = []
        for await fix in stream {
            received.append(fix)
            if received.count == track.count { break }
        }
        XCTAssertEqual(received, track)
        service.stopUpdates()
        XCTAssertFalse(service.isUpdating)
        XCTAssertEqual(service.deliveredCount, track.count)
    }

    func testRestampsAndLoops() async {
        let track = [Fix(coordinate: Coordinate(latitude: 27.6, longitude: -82.7), timestamp: Date(timeIntervalSince1970: 0),
                         speed: 1, course: 45),
                     Fix(coordinate: Coordinate(latitude: 27.61, longitude: -82.7), timestamp: Date(timeIntervalSince1970: 1),
                         speed: 1, course: 45)]
        let service = SimulatedLocationService(track: track, options: .init(interval: .zero, loops: true, restampsToNow: true))
        let stream = service.fixes()
        let before = Date()
        service.startUpdates()
        var count = 0
        for await fix in stream {
            XCTAssertGreaterThanOrEqual(fix.timestamp, before.addingTimeInterval(-1))
            count += 1
            if count == 5 { break }
        }
        service.stopUpdates()
        XCTAssertGreaterThanOrEqual(service.deliveredCount, 5, "looped past the two-fix track")
    }

    func testAuthorizationFlow() async {
        let service = SimulatedLocationService(track: SimulatedTrack.tampaBay(),
                                               options: .init(interval: .zero, initialAuthorization: .notDetermined))
        let updates = service.authorizationUpdates()
        service.startUpdates()
        XCTAssertEqual(service.deliveredCount, 0, "no fixes before permission")
        service.requestWhenInUseAuthorization()
        XCTAssertEqual(service.authorization, .authorizedWhenInUse)
        var seen: [LocationAuthorization] = []
        for await value in updates {
            seen.append(value)
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen, [.notDetermined, .authorizedWhenInUse])
        service.setRecording(true)
        XCTAssertTrue(service.isRecording)
        service.stopUpdates()
    }
}
