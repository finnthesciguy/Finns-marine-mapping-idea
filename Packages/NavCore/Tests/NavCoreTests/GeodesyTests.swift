import Foundation
import Testing
@testable import NavCore

func dms(_ d: Double, _ m: Double, _ s: Double) -> Double { d + m / 60 + s / 3600 }

func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

/// Smallest angular difference between two bearings, degrees.
func bearingClose(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
    abs(Angle.difference(from: a, to: b)) <= tolerance
}

@Suite("Ellipsoidal geodesy (Vincenty)")
struct VincentyTests {
    // Vincenty (1975) / Geoscience Australia worked example: Flinders Peak to Buninyong.
    // Published: s = 54 972.271 m, α1 = 306°52'05.37", α2(reverse) = 127°10'25.07".
    let flinders = Coordinate(latitude: -dms(37, 57, 3.72030), longitude: dms(144, 25, 29.52440))
    let buninyong = Coordinate(latitude: -dms(37, 39, 10.15610), longitude: dms(143, 55, 35.38390))

    @Test func flindersPeakToBuninyongInverse() {
        let r = Geodesy.inverse(from: flinders, to: buninyong)
        #expect(r.method == .vincenty)
        #expect(close(r.distance, 54_972.271, 0.001))
        #expect(bearingClose(r.initialBearing, dms(306, 52, 5.37), 0.5 / 3600))
        // Final (forward) azimuth = reverse azimuth - 180°.
        #expect(bearingClose(r.finalBearing, dms(127, 10, 25.07) + 180, 0.5 / 3600))
    }

    @Test func flindersPeakToBuninyongDirect() {
        let r = Geodesy.direct(from: flinders, bearing: dms(306, 52, 5.37), distance: 54_972.271)
        #expect(close(r.coordinate.latitude, buninyong.latitude, 1e-7))
        #expect(close(r.coordinate.longitude, buninyong.longitude, 1e-7))
        #expect(bearingClose(r.finalBearing, dms(127, 10, 25.07) + 180, 1.0 / 3600))
    }

    // One degree of arc on the equator and along a meridian from the equator — textbook WGS84 values.
    @Test func oneDegreeArcs() {
        let o = Coordinate(latitude: 0, longitude: 0)
        #expect(close(Geodesy.distance(from: o, to: Coordinate(latitude: 0, longitude: 1)), 111_319.491, 0.001))
        #expect(close(Geodesy.distance(from: o, to: Coordinate(latitude: 1, longitude: 0)), 110_574.389, 0.001))
        #expect(bearingClose(Geodesy.initialBearing(from: o, to: Coordinate(latitude: 0, longitude: 1)), 90, 1e-9))
    }

    // Reference values from GeographicLib (Karney 2013), WGS84.
    @Test(arguments: [
        // (lat1, lon1, lat2, lon2, s12 m, azi1, azi2)
        (27.9506, -82.4572, 24.5551, -81.7800, 382_226.4165, 169.653_645_6, 169.953_328_6),   // Tampa – Key West
        (30.4213, -87.2169, 29.3013, -94.7977, 742_751.9947, 262.283_162_0, 258.504_318_1),   // Pensacola – Galveston
        (40.6413, -73.7781, 51.4700, -0.4543, 5_554_908.7905, 51.381_647_9, 107.982_829_1),   // JFK – Heathrow
    ])
    func geographicLibCityPairs(_ c: (Double, Double, Double, Double, Double, Double, Double)) {
        let r = Geodesy.inverse(from: Coordinate(latitude: c.0, longitude: c.1), to: Coordinate(latitude: c.2, longitude: c.3))
        #expect(r.method == .vincenty)
        #expect(close(r.distance, c.4, 0.01))
        #expect(bearingClose(r.initialBearing, c.5, 1e-6))
        #expect(bearingClose(r.finalBearing, c.6, 1e-6))
    }

    @Test func directInverseRoundTripGulf() {
        // GeographicLib: Direct(27.6, -82.8, azi 225, 50 km) -> (27.280479682, -83.157096408), azi2 -135.164559
        let start = Coordinate(latitude: 27.6, longitude: -82.8)
        let r = Geodesy.direct(from: start, bearing: 225, distance: 50_000)
        #expect(close(r.coordinate.latitude, 27.280_479_682, 1e-8))
        #expect(close(r.coordinate.longitude, -83.157_096_408, 1e-8))
        #expect(bearingClose(r.finalBearing, 360 - 135.164_559_37, 1e-6))
    }

    @Test func identicalPoints() {
        let p = Coordinate(latitude: 27.5, longitude: -82.5)
        let r = Geodesy.inverse(from: p, to: p)
        #expect(r.distance == 0)
        #expect(r.initialBearing == 0)
        #expect(Geodesy.destination(from: p, bearing: 123, distance: 0) == p)
    }

    @Test func poles() {
        let north = Coordinate(latitude: 90, longitude: 0)
        let northOtherMeridian = Coordinate(latitude: 90, longitude: 120)
        #expect(close(Geodesy.distance(from: north, to: northOtherMeridian), 0, 1e-6))
        // Pole to equator: quarter meridian, 10 001 965.729 m on WGS84.
        let q = Geodesy.distance(from: north, to: Coordinate(latitude: 0, longitude: 45))
        #expect(close(q, 10_001_965.729, 0.01))
        // Across the pole (GeographicLib: 22 338.7957 m).
        let a = Coordinate(latitude: 89.9, longitude: 0), b = Coordinate(latitude: 89.9, longitude: 180)
        #expect(close(Geodesy.distance(from: a, to: b), 22_338.7957, 0.01))
    }

    // Nearly antipodal pairs where Vincenty does not converge. Reference values from
    // GeographicLib (Karney 2013); (-30, 0)→(29.9, 179.8) is Karney's published example.
    @Test(arguments: [
        (0.0, 0.0, 0.5, 179.7, 19_944_127.4208, 15.556_882_8),
        (-30.0, 0.0, 29.9, 179.8, 19_989_832.8276, 161.890_524_7),
        (0.0, 0.0, 0.0, 179.5, 19_980_861.9089, 55.966_495_1),
        (0.0, 0.0, 0.0, 180.0, 20_003_931.4586, 0.0),   // exactly antipodal on the equator: over the pole
    ])
    func nearlyAntipodalFallback(_ c: (Double, Double, Double, Double, Double, Double)) {
        let a = Coordinate(latitude: c.0, longitude: c.1), b = Coordinate(latitude: c.2, longitude: c.3)
        #expect(Geodesy.vincentyInverse(a, b) == nil)
        let r = Geodesy.inverse(from: a, to: b)
        #expect(r.method == .vincentySplit)
        #expect(close(r.distance, c.4, 0.01))
        if c.5 != 0 { #expect(bearingClose(r.initialBearing, c.5, 1e-4)) }   // exact antipode: any meridian is valid
    }

    @Test func invalidInputYieldsNaNNotCrash() {
        let r = Geodesy.inverse(from: Coordinate(latitude: .nan, longitude: 0), to: Coordinate(latitude: 0, longitude: 0))
        #expect(r.distance.isNaN)
        let d = Geodesy.destination(from: Coordinate(latitude: 0, longitude: 0), bearing: .infinity, distance: 10)
        #expect(d.latitude.isNaN)
    }
}

@Suite("Spherical geodesy")
struct SphericalTests {
    // Movable Type Scripts worked example (R = 6371 km): Land's End to John o' Groats
    // 968.9 km, initial bearing 009°07'11", final bearing 011°16'31".
    let landsEnd = Coordinate(latitude: dms(50, 3, 59), longitude: -dms(5, 42, 53))
    let johnOGroats = Coordinate(latitude: dms(58, 38, 38), longitude: -dms(3, 4, 12))

    @Test func haversineLandsEndJohnOGroats() {
        #expect(close(Geodesy.haversineDistance(from: landsEnd, to: johnOGroats, radius: 6_371_000), 968_900, 60))
        #expect(bearingClose(Geodesy.sphericalInitialBearing(from: landsEnd, to: johnOGroats), dms(9, 7, 11), 1.0 / 3600))
        #expect(bearingClose(Geodesy.sphericalFinalBearing(from: landsEnd, to: johnOGroats), dms(11, 16, 31), 1.0 / 3600))
        // Ellipsoidal value (GeographicLib) differs from spherical by ~0.1%: 969 932.99 m.
        #expect(close(Geodesy.distance(from: landsEnd, to: johnOGroats), 969_932.988, 0.01))
    }

    @Test func midpointLandsEndJohnOGroats() {
        // Movable Type: midpoint 54°21'44"N 004°31'50"W.
        let m = Geodesy.midpoint(between: landsEnd, and: johnOGroats)
        #expect(close(m.latitude, dms(54, 21, 44), 1.0 / 3600))
        #expect(close(m.longitude, -dms(4, 31, 50), 1.0 / 3600))
        let i = Geodesy.interpolate(from: landsEnd, to: johnOGroats, fraction: 0.5)
        #expect(close(i.latitude, m.latitude, 1e-9) && close(i.longitude, m.longitude, 1e-9))
    }

    @Test func interpolationEndpointsAndDegenerate() {
        let a = Coordinate(latitude: 27, longitude: -82), b = Coordinate(latitude: 28, longitude: -83)
        let s = Geodesy.interpolate(from: a, to: b, fraction: 0), e = Geodesy.interpolate(from: a, to: b, fraction: 1)
        #expect(close(s.latitude, a.latitude, 1e-12) && close(s.longitude, a.longitude, 1e-12))
        #expect(close(e.latitude, b.latitude, 1e-12) && close(e.longitude, b.longitude, 1e-12))
        #expect(Geodesy.interpolate(from: a, to: a, fraction: 0.3) == a)
        // On the equator interpolation is linear in longitude.
        let q = Geodesy.interpolate(from: Coordinate(latitude: 0, longitude: 0), to: Coordinate(latitude: 0, longitude: 10), fraction: 0.25)
        #expect(close(q.latitude, 0, 1e-12) && close(q.longitude, 2.5, 1e-12))
    }

    @Test func sphericalDestinationInvertsHaversine() {
        let s = Geodesy.haversineDistance(from: landsEnd, to: johnOGroats, radius: 6_371_000)
        let theta = Geodesy.sphericalInitialBearing(from: landsEnd, to: johnOGroats)
        let d = Geodesy.sphericalDestination(from: landsEnd, bearing: theta, distance: s, radius: 6_371_000)
        #expect(Geodesy.haversineDistance(from: d, to: johnOGroats, radius: 6_371_000) < 1e-3)
        // Due north 1/4 circumference from the equator reaches the pole.
        let pole = Geodesy.sphericalDestination(from: Coordinate(latitude: 0, longitude: 10), bearing: 0,
                                                distance: .pi / 2 * Geodesy.earthMeanRadius)
        #expect(close(pole.latitude, 90, 1e-9))
    }
}

@Suite("Rhumb lines")
struct RhumbTests {
    @Test func alongParallelIsExact() {
        // Rhumb along a parallel: distance = R cos(φ) Δλ, bearing 090.
        let a = Coordinate(latitude: 27, longitude: -84), b = Coordinate(latitude: 27, longitude: -82)
        let expected = Geodesy.earthMeanRadius * cos(27 * .pi / 180) * (2 * .pi / 180)
        #expect(close(Geodesy.rhumbDistance(from: a, to: b), expected, 1e-6))
        #expect(close(Geodesy.rhumbBearing(from: a, to: b), 90, 1e-9))
        #expect(close(Geodesy.rhumbBearing(from: b, to: a), 270, 1e-9))
        // The rhumb line along a parallel is longer than the great circle.
        #expect(Geodesy.rhumbDistance(from: a, to: b) > Geodesy.haversineDistance(from: a, to: b))
    }

    @Test func alongMeridianIsExact() {
        let a = Coordinate(latitude: 25, longitude: -82), b = Coordinate(latitude: 30, longitude: -82)
        #expect(close(Geodesy.rhumbDistance(from: a, to: b), Geodesy.earthMeanRadius * 5 * .pi / 180, 1e-6))
        #expect(close(Geodesy.rhumbBearing(from: a, to: b), 0, 1e-9))
        #expect(close(Geodesy.rhumbBearing(from: b, to: a), 180, 1e-9))
    }

    @Test func doverCalais() {
        // Dover 51°07'32"N 001°20'17"E to Calais 50°57'48"N 001°51'08"E, R = 6371 km.
        // Independently computed with the Mercator-projected-latitude formula: 40 217.59 m, 116.6486°.
        let dover = Coordinate(latitude: dms(51, 7, 32), longitude: dms(1, 20, 17))
        let calais = Coordinate(latitude: dms(50, 57, 48), longitude: dms(1, 51, 8))
        #expect(close(Geodesy.rhumbDistance(from: dover, to: calais, radius: 6_371_000), 40_217.59, 0.05))
        #expect(close(Geodesy.rhumbBearing(from: dover, to: calais), 116.6486, 1e-4))
        let back = Geodesy.rhumbDestination(from: dover, bearing: 116.648_603, distance: 40_217.586, radius: 6_371_000)
        #expect(close(back.latitude, calais.latitude, 1e-6) && close(back.longitude, calais.longitude, 1e-6))
    }

    @Test func degenerateAndPolarDoNotCrash() {
        let p = Coordinate(latitude: 27, longitude: -82)
        #expect(Geodesy.rhumbDistance(from: p, to: p) == 0)
        #expect(Geodesy.rhumbBearing(from: p, to: p) == 0)
        let d = Geodesy.rhumbDistance(from: Coordinate(latitude: 89, longitude: 0), to: Coordinate(latitude: 90, longitude: 0))
        #expect(d.isFinite && close(d, Geodesy.earthMeanRadius * .pi / 180, 1))
        let e = Geodesy.rhumbDestination(from: Coordinate(latitude: 0, longitude: 0), bearing: 90, distance: 111_195)
        #expect(close(e.latitude, 0, 1e-12) && close(e.longitude, 1, 1e-4))
    }
}

@Suite("Legs: cross-track, along-track, closest point")
struct LegTests {
    // Equatorial leg from (0,0) to (0,10): a point at (1, 5) lies exactly 1° of arc left of track,
    // with its perpendicular foot at (0, 5) — 5° of arc along track.
    let start = Coordinate(latitude: 0, longitude: 0)
    let end = Coordinate(latitude: 0, longitude: 10)
    let degree = Geodesy.earthMeanRadius * .pi / 180

    @Test func analyticEquatorialLeg() {
        let p = Geodesy.project(Coordinate(latitude: 1, longitude: 5), legStart: start, legEnd: end)
        #expect(close(p.crossTrack, -degree, 1e-6))   // north of an eastbound track is to port
        #expect(close(p.alongTrack, 5 * degree, 1e-6))
        #expect(close(p.fraction, 0.5, 1e-12))
        #expect(close(p.closestPoint.latitude, 0, 1e-12) && close(p.closestPoint.longitude, 5, 1e-9))
        #expect(close(p.distanceToClosestPoint, degree, 1e-6))
        let s = Geodesy.crossTrackDistance(of: Coordinate(latitude: -0.5, longitude: 3), legStart: start, legEnd: end)
        #expect(close(s, 0.5 * degree, 1e-6))          // south is to starboard
    }

    @Test func beyondEndsClampsClosestPoint() {
        let before = Geodesy.project(Coordinate(latitude: 0.1, longitude: -2), legStart: start, legEnd: end)
        #expect(close(before.alongTrack, -2 * degree, 100))
        #expect(before.fraction == 0 && before.closestPoint == start)
        let after = Geodesy.project(Coordinate(latitude: 0, longitude: 12), legStart: start, legEnd: end)
        #expect(close(after.alongTrack, 12 * degree, 1e-6))
        #expect(after.fraction == 1 && after.closestPoint == end)
        #expect(close(after.distanceToClosestPoint, 2 * degree, 1e-6))
    }

    @Test func zeroLengthLeg() {
        let p = Geodesy.project(Coordinate(latitude: 1, longitude: 1), legStart: start, legEnd: start)
        #expect(p.crossTrack == 0 && p.alongTrack == 0 && p.legLength == 0)
        #expect(p.closestPoint == start)
        #expect(close(p.distanceToClosestPoint, Geodesy.haversineDistance(from: start, to: Coordinate(latitude: 1, longitude: 1)), 1e-9))
    }

    @Test func pointOnStart() {
        let p = Geodesy.project(start, legStart: start, legEnd: end)
        #expect(p.crossTrack == 0 && close(p.alongTrack, 0, 1e-9))
    }

    @Test func meridianLegInTampaBay() {
        // Northbound leg along 82.5°W; a point 0.01° of longitude east is to starboard by
        // approximately R·cos(27.5°)·0.01° (small-angle spherical geometry).
        let a = Coordinate(latitude: 27.4, longitude: -82.5), b = Coordinate(latitude: 27.6, longitude: -82.5)
        let x = Geodesy.crossTrackDistance(of: Coordinate(latitude: 27.5, longitude: -82.49), legStart: a, legEnd: b)
        #expect(close(x, Geodesy.earthMeanRadius * cos(27.5 * .pi / 180) * 0.01 * .pi / 180, 0.01))
    }
}

@Suite("Units and angles")
struct UnitTests {
    @Test func conversions() {
        #expect(Distance.nauticalMiles(1).meters == 1852)
        #expect(close(Distance.meters(1852).nauticalMiles, 1, 1e-15))
        #expect(close(Distance.feet(1).meters, 0.3048, 1e-15))
        #expect(close(Distance.meters(100).feet, 328.083_989_501_312_3, 1e-9))
        #expect(close(Distance.fathoms(1).feet, 6, 1e-12))
        #expect(close(Speed.knots(1).metersPerSecond, 0.514_444_444_444, 1e-12))
        #expect(close(Speed.metersPerSecond(10).knots, 19.438_444_924_406, 1e-9))
        #expect(close(Speed.knots(10).kilometersPerHour, 18.52, 1e-12))
        #expect(close(Speed.knots(6).timeToCover(.nauticalMiles(12)) ?? 0, 7200, 1e-9))
        #expect(Speed.knots(0).timeToCover(.nauticalMiles(1)) == nil)
    }

    @Test func angleNormalisation() {
        #expect(Angle.normalizeBearing(-10) == 350)
        #expect(Angle.normalizeBearing(720) == 0)
        #expect(Angle.normalizeLongitude(190) == -170)
        #expect(Angle.normalizeLongitude(-180) == -180)
        #expect(Angle.difference(from: 350, to: 10) == 20)
        #expect(Angle.difference(from: 10, to: 350) == -20)
        #expect(Angle.normalizeBearing(.nan).isNaN)
    }

    @Test func coordinateValidation() throws {
        #expect(throws: CoordinateError.latitudeOutOfRange(91)) { try Coordinate(validatingLatitude: 91, longitude: 0) }
        #expect(throws: CoordinateError.longitudeOutOfRange(-181)) { try Coordinate(validatingLatitude: 0, longitude: -181) }
        #expect(throws: CoordinateError.notFinite) { try Coordinate(validatingLatitude: .nan, longitude: 0) }
        let c = try Coordinate(validatingLatitude: 27.75, longitude: -82.62)
        #expect(c.isValid)
        #expect(!Coordinate(latitude: 0, longitude: .infinity).isValid)
        #expect(Coordinate(latitude: 95, longitude: 200).normalized == Coordinate(latitude: 90, longitude: -160))
    }

    @Test func boundingBox() {
        let box = BoundingBox(coordinates: [
            Coordinate(latitude: 27.0, longitude: -83.0), Coordinate(latitude: 28.0, longitude: -82.0),
            Coordinate(latitude: 27.5, longitude: .nan),
        ])!
        #expect(box == BoundingBox(south: 27, west: -83, north: 28, east: -82))
        #expect(box.contains(Coordinate(latitude: 27.5, longitude: -82.5)))
        #expect(!box.contains(Coordinate(latitude: 28.1, longitude: -82.5)))
        #expect(box.center == Coordinate(latitude: 27.5, longitude: -82.5))
        #expect(BoundingBox(coordinates: [Coordinate]()) == nil)
        let wrap = BoundingBox(south: -10, west: 170, north: 10, east: -170)
        #expect(wrap.crossesAntimeridian)
        #expect(wrap.contains(Coordinate(latitude: 0, longitude: 179)) && wrap.contains(Coordinate(latitude: 0, longitude: -175)))
        #expect(!wrap.contains(Coordinate(latitude: 0, longitude: 0)))
        #expect(close(wrap.center.longitude, -180, 1e-12))
        let grown = box.expanded(byMeters: 1852 * 60)  // 60 NM ≈ 1° of latitude
        #expect(close(grown.north, 29, 0.01) && close(grown.south, 26, 0.01))
        #expect(box.intersects(BoundingBox(south: 27.9, west: -82.1, north: 29, east: -81)))
        #expect(!box.intersects(BoundingBox(south: 29, west: -83, north: 30, east: -82)))
        #expect(BoundingBox(south: 89.5, west: 0, north: 90, east: 1).expanded(byMeters: 1e6).north == 90)
    }
}
