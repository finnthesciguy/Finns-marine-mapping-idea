import Foundation
import Testing
@testable import NavCore

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Navigation")
struct NavigationTests {
    @Test func courseAndSpeedFromTwoFixes() throws {
        // GeographicLib Direct: (27.5, -82.5) on 045° for 1852 m -> (27.511817288, -82.486745539).
        let a = Fix(coordinate: Coordinate(latitude: 27.5, longitude: -82.5), timestamp: t0)
        let b = Fix(coordinate: Coordinate(latitude: 27.511_817_288_340_794, longitude: -82.486_745_538_687_17),
                    timestamp: t0.addingTimeInterval(600))
        let cs = try #require(Navigation.courseAndSpeed(from: a, to: b))
        #expect(close(cs.speed, 1852.0 / 600, 1e-6))          // 1 NM in 10 min = 6 kn
        #expect(close(Speed(metersPerSecond: cs.speed).knots, 6, 1e-6))
        #expect(bearingClose(try #require(cs.course), 45, 1e-6))
    }

    @Test func courseAndSpeedEdgeCases() {
        let p = Coordinate(latitude: 27.5, longitude: -82.5)
        let a = Fix(coordinate: p, timestamp: t0)
        #expect(Navigation.courseAndSpeed(from: a, to: Fix(coordinate: p, timestamp: t0)) == nil)
        #expect(Navigation.courseAndSpeed(from: a, to: Fix(coordinate: p, timestamp: t0.addingTimeInterval(-1))) == nil)
        let still = Navigation.courseAndSpeed(from: a, to: Fix(coordinate: p, timestamp: t0.addingTimeInterval(5)))
        #expect(still == CourseAndSpeed(course: nil, speed: 0))
    }

    @Test func velocityMadeGood() {
        #expect(close(Navigation.velocityMadeGood(speed: 5, course: 90, bearingToMark: 30), 2.5, 1e-12))
        #expect(close(Navigation.velocityMadeGood(speed: 5, course: 10, bearingToMark: 350), 5 * cos(20 * .pi / 180), 1e-12))
        #expect(close(Navigation.velocityMadeGood(speed: 5, course: 180, bearingToMark: 0), -5, 1e-12))
        // Heading due east along the equator toward a mark due east: VMG equals SOG.
        let vmg = Navigation.velocityMadeGood(position: Coordinate(latitude: 0, longitude: 0),
                                              motion: CourseAndSpeed(course: 90, speed: 3),
                                              toward: Coordinate(latitude: 0, longitude: 1))
        #expect(close(vmg, 3, 1e-9))
        #expect(Navigation.velocityMadeGood(position: Coordinate(latitude: 0, longitude: 0),
                                            motion: CourseAndSpeed(course: nil, speed: 0),
                                            toward: Coordinate(latitude: 0, longitude: 1)) == 0)
    }

    // Equatorial route: WGS84 equatorial arc is a·Δλ exactly, 111 319.4908 m per degree.
    let equatorDegree = WGS84.semiMajorAxis * .pi / 180
    let route = [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 1), Coordinate(latitude: 0, longitude: 2)]

    @Test func etaAlongMultiLegRoute() throws {
        let sog = Speed.knots(10).metersPerSecond
        let p = try #require(Navigation.progress(position: Coordinate(latitude: 0, longitude: 0.5), waypoints: route,
                                                 activeLegIndex: 0, speedOverGround: sog))
        #expect(close(p.distanceToNextWaypoint, 0.5 * equatorDegree, 1e-6))
        #expect(close(p.remainingDistance, 1.5 * equatorDegree, 1e-6))
        #expect(p.distancesToGo.count == 2)
        #expect(close(try #require(p.timeToGo), 1.5 * equatorDegree / sog, 1e-6))   // ≈ 32 458 s ≈ 9 h 01 m
        #expect(close(try #require(p.timeToGo), 32_458.2, 0.1))
        #expect(close(try #require(p.timesToGo)[0], 0.5 * equatorDegree / sog, 1e-6))
        let eta = try #require(p.eta(from: t0))
        #expect(close(eta.timeIntervalSince(t0), 32_458.2, 0.1))
        #expect(bearingClose(p.bearingToNextWaypoint, 90, 1e-9))
        #expect(close(p.crossTrackError, 0, 1e-6))
    }

    @Test func progressWithoutSpeedOrBadInput() {
        let p = Navigation.progress(position: Coordinate(latitude: 0, longitude: 0.5), waypoints: route,
                                    activeLegIndex: 1, speedOverGround: 0)
        #expect(p?.timeToGo == nil && p?.eta(from: t0) == nil)
        #expect(p.map { close($0.remainingDistance, 1.5 * equatorDegree, 1e-6) } == true)
        #expect(Navigation.progress(position: route[0], waypoints: [route[0]], activeLegIndex: 0, speedOverGround: 1) == nil)
        #expect(Navigation.progress(position: route[0], waypoints: route, activeLegIndex: 2, speedOverGround: 1) == nil)
        #expect(Navigation.progress(position: route[0], waypoints: route, activeLegIndex: -1, speedOverGround: 1) == nil)
    }

    @Test func legCompletion() {
        let policy = LegAdvancePolicy()   // 0.05 NM = 92.6 m
        let a = route[0], b = route[1]
        // 0.0005° of longitude at the equator ≈ 55.7 m short of the waypoint: inside the circle.
        #expect(Navigation.legCompletion(position: Coordinate(latitude: 0, longitude: 0.9995), legStart: a, legEnd: b, policy: policy) == .arrivalCircle)
        // 1.1 km north of track but past the waypoint's perpendicular.
        #expect(Navigation.legCompletion(position: Coordinate(latitude: 0.01, longitude: 1.0005), legStart: a, legEnd: b, policy: policy) == .passedPerpendicular)
        #expect(Navigation.legCompletion(position: Coordinate(latitude: 0.01, longitude: 1.0005), legStart: a, legEnd: b,
                                         policy: LegAdvancePolicy(advanceOnPerpendicular: false)) == nil)
        // Short of the perpendicular and outside the circle.
        #expect(Navigation.legCompletion(position: Coordinate(latitude: 0.1, longitude: 0.99), legStart: a, legEnd: b, policy: policy) == nil)
        // Zero-length leg is always complete.
        #expect(Navigation.legCompletion(position: Coordinate(latitude: 1, longitude: 1), legStart: a, legEnd: a, policy: policy) != nil)
    }

    @Test func routeNavigatorAdvancesAndFinishes() {
        var nav = RouteNavigator(waypoints: route)
        #expect(nav.update(position: Coordinate(latitude: 0, longitude: 0.5)).isEmpty)
        #expect(nav.activeLegIndex == 0)
        let e1 = nav.update(position: Coordinate(latitude: 0.0005, longitude: 1.0001))
        #expect(e1 == [RouteNavigator.Event(completedLegIndex: 0, reason: .arrivalCircle)])
        #expect(nav.activeLegIndex == 1 && !nav.isFinished)
        let e2 = nav.update(position: Coordinate(latitude: 0.05, longitude: 2.01))
        #expect(e2 == [RouteNavigator.Event(completedLegIndex: 1, reason: .passedPerpendicular)])
        #expect(nav.isFinished && nav.progress(position: route[2], speedOverGround: 1) == nil)
        #expect(nav.update(position: route[0]).isEmpty)
    }

    @Test func routeNavigatorSkipsClusteredWaypoints() {
        // Two waypoints 20 m apart: arriving at the first also arrives at the second.
        let w = [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 0.5),
                 Coordinate(latitude: 0, longitude: 0.50018), Coordinate(latitude: 0, longitude: 1)]
        var nav = RouteNavigator(waypoints: w)
        let events = nav.update(position: Coordinate(latitude: 0, longitude: 0.5001))
        #expect(events.map(\.completedLegIndex) == [0, 1])
        #expect(nav.activeLegIndex == 2)
        #expect(RouteNavigator(waypoints: [w[0]]).isFinished)
        #expect(RouteNavigator(waypoints: []).isFinished)
    }
}

@Suite("SOG/COG filter")
struct FilterTests {
    @Test func stepResponseMatchesFirstOrderLag() throws {
        // First-order low-pass with τ = 4 s sampled at 1 Hz: after n samples of a step from
        // 0 to 10 m/s the output is 10·(1 − e^(−n/4)).
        var f = SOGCOGFilter(timeConstant: 4)
        let p = Coordinate(latitude: 27, longitude: -82)
        f.update(with: Fix(coordinate: p, timestamp: t0, speed: 0, course: 90))
        var out: CourseAndSpeed?
        for n in 1...4 {
            out = f.update(with: Fix(coordinate: p, timestamp: t0.addingTimeInterval(Double(n)), speed: 10, course: 90))
        }
        #expect(close(try #require(out).speed, 10 * (1 - exp(-1.0)), 1e-9))
        #expect(bearingClose(try #require(out?.course), 90, 1e-9))
    }

    @Test func courseAveragesAcrossNorth() throws {
        var f = SOGCOGFilter(timeConstant: 3)
        let p = Coordinate(latitude: 27, longitude: -82)
        var out: CourseAndSpeed?
        for i in 0..<20 {
            let c = i % 2 == 0 ? 358.0 : 2.0
            out = f.update(with: Fix(coordinate: p, timestamp: t0.addingTimeInterval(Double(i)), speed: 3, course: c))
        }
        let course = try #require(out?.course)
        #expect(bearingClose(course, 0, 1.5))
        #expect(close(try #require(out).speed, 3, 1e-9))
    }

    @Test func derivesFromPositionsWhenReceiverOmitsSpeed() throws {
        var f = SOGCOGFilter(timeConstant: 1)
        // Moving east along the equator, 0.0001° (11.13 m) per second.
        for i in 0..<30 {
            f.update(with: Fix(coordinate: Coordinate(latitude: 0, longitude: Double(i) * 0.0001), timestamp: t0.addingTimeInterval(Double(i))))
        }
        let c = try #require(f.current)
        #expect(close(c.speed, 0.0001 * WGS84.semiMajorAxis * .pi / 180, 1e-3))
        #expect(bearingClose(try #require(c.course), 90, 1e-6))
    }

    @Test func stationaryHasNoCourseAndBadFixesIgnored() throws {
        var f = SOGCOGFilter()
        let p = Coordinate(latitude: 27, longitude: -82)
        #expect(f.update(with: Fix(coordinate: p, timestamp: t0)) == nil)   // nothing to derive yet
        f.update(with: Fix(coordinate: p, timestamp: t0.addingTimeInterval(1), speed: 0.05, course: 123))
        #expect(f.current?.course == nil)
        let before = f.current
        f.update(with: Fix(coordinate: p, timestamp: t0.addingTimeInterval(1), speed: 9, course: 0))   // duplicate time
        f.update(with: Fix(coordinate: p, timestamp: t0, speed: 9, course: 0))                          // out of order
        #expect(f.current == before)
        f.reset()
        #expect(f.current == nil)
    }

    @Test func longGapRestartsFilter() throws {
        var f = SOGCOGFilter(timeConstant: 10, maximumGap: 30)
        let p = Coordinate(latitude: 27, longitude: -82)
        f.update(with: Fix(coordinate: p, timestamp: t0, speed: 1, course: 0))
        let out = f.update(with: Fix(coordinate: p, timestamp: t0.addingTimeInterval(120), speed: 6, course: 180))
        #expect(out == CourseAndSpeed(course: 180, speed: 6))
    }
}
