import Foundation

/// The WGS84 reference ellipsoid.
public enum WGS84 {
    /// Semi-major axis (equatorial radius), metres.
    public static let semiMajorAxis = 6_378_137.0
    /// Flattening.
    public static let flattening = 1.0 / 298.257_223_563
    /// Semi-minor axis (polar radius), metres.
    public static let semiMinorAxis = semiMajorAxis * (1 - flattening)
}

/// Result of an inverse geodesic computation between two points.
public struct GeodesicInverse: Hashable, Sendable {
    /// How a result was obtained.
    public enum Method: Hashable, Sendable {
        /// Vincenty's ellipsoidal inverse formula converged (sub-millimetre accuracy).
        case vincenty
        /// Vincenty did not converge (nearly antipodal points); the path was split at an
        /// optimised intermediate point and each half solved with Vincenty. Typically within
        /// a few metres of the true geodesic, and never shorter than it.
        case vincentySplit
        /// Last resort: spherical haversine on the mean earth radius (about 0.5% accuracy).
        case spherical
    }

    /// Geodesic distance in metres.
    public var distance: Double
    /// Initial bearing at the start point, degrees true 0..<360.
    public var initialBearing: Double
    /// Final bearing on arrival at the end point, degrees true 0..<360.
    public var finalBearing: Double
    /// Which algorithm produced the result.
    public var method: Method
}

/// Projection of a point onto a leg (great-circle segment) from `start` to `end`.
public struct LegProjection: Hashable, Sendable {
    /// Signed cross-track distance in metres. Positive when the point is to the
    /// right (starboard) of the track direction, negative to the left (port).
    public var crossTrack: Double
    /// Signed along-track distance in metres from the leg start to the foot of the
    /// perpendicular. Negative before the start; larger than ``legLength`` past the end.
    public var alongTrack: Double
    /// Length of the leg in metres.
    public var legLength: Double
    /// Fraction along the leg (0...1) of the closest point on the segment.
    public var fraction: Double
    /// Closest point on the segment (clamped to the leg end points).
    public var closestPoint: Coordinate
    /// Distance in metres from the point to ``closestPoint``.
    public var distanceToClosestPoint: Double
}

/// Geodesic calculations on WGS84 and on a spherical earth.
///
/// Distances are in metres and bearings in degrees true (0..<360) throughout.
/// Ellipsoidal functions (``inverse(from:to:)``, ``distance(from:to:)``, ``destination(from:bearing:distance:)``)
/// are accurate to well under a metre; spherical ones are within about 0.5% and are used where that is
/// ample (cross-track, rhumb lines, interpolation over short legs).
public enum Geodesy {
    /// Mean earth radius (IUGG R1), metres, used by the spherical formulas.
    public static let earthMeanRadius = 6_371_008.8

    // MARK: - Ellipsoidal (Vincenty)

    /// Ellipsoidal distance in metres between two points (WGS84).
    public static func distance(from a: Coordinate, to b: Coordinate) -> Double {
        inverse(from: a, to: b).distance
    }

    /// Ellipsoidal initial bearing from `a` to `b`, degrees true. 0 for coincident points.
    public static func initialBearing(from a: Coordinate, to b: Coordinate) -> Double {
        inverse(from: a, to: b).initialBearing
    }

    /// Ellipsoidal final bearing arriving at `b` from `a`, degrees true. 0 for coincident points.
    public static func finalBearing(from a: Coordinate, to b: Coordinate) -> Double {
        inverse(from: a, to: b).finalBearing
    }

    /// Solves the inverse geodesic problem on WGS84 using Vincenty's formula, with a
    /// fallback for nearly antipodal points where Vincenty fails to converge.
    public static func inverse(from a: Coordinate, to b: Coordinate) -> GeodesicInverse {
        guard a.isValid, b.isValid else {
            return GeodesicInverse(distance: .nan, initialBearing: .nan, finalBearing: .nan, method: .spherical)
        }
        if let r = vincentyInverse(a, b) { return r }
        if let r = splitInverse(a, b) { return r }
        return GeodesicInverse(
            distance: haversineDistance(from: a, to: b),
            initialBearing: sphericalInitialBearing(from: a, to: b),
            finalBearing: sphericalFinalBearing(from: a, to: b),
            method: .spherical
        )
    }

    /// Fallback for nearly antipodal points: route through an intermediate point chosen to
    /// minimise the two-part Vincenty length. Any such path is at least as long as the true
    /// geodesic, so the minimum found is a tight upper bound on it.
    static func splitInverse(_ a: Coordinate, _ b: Coordinate) -> GeodesicInverse? {
        let mid = midpoint(between: a, and: b)
        let across = sphericalInitialBearing(from: mid, to: b) + 90
        func evaluate(_ offset: Double) -> GeodesicInverse? {
            let via = offset == 0 ? mid
                : sphericalDestination(from: mid, bearing: across, distance: offset * earthMeanRadius)
            guard let first = vincentyInverse(a, via), let second = vincentyInverse(via, b),
                  first.distance > 0, second.distance > 0 else { return nil }
            return GeodesicInverse(distance: first.distance + second.distance,
                                   initialBearing: first.initialBearing,
                                   finalBearing: second.finalBearing,
                                   method: .vincentySplit)
        }
        // Coarse scan of offsets (radians of arc) across the path, then golden-section refinement.
        let step = Double.pi / 36
        var best: (offset: Double, result: GeodesicInverse)?
        for k in -18...18 {
            let off = Double(k) * step
            if let r = evaluate(off), r.distance < (best?.result.distance ?? .infinity) { best = (off, r) }
        }
        guard var found = best else { return nil }
        var lo = found.offset - step, hi = found.offset + step
        let phi = (5.0.squareRoot() - 1) / 2
        for _ in 0..<40 {
            let x1 = hi - phi * (hi - lo), x2 = lo + phi * (hi - lo)
            let d1 = evaluate(x1)?.distance ?? .infinity, d2 = evaluate(x2)?.distance ?? .infinity
            if d1 < d2 { hi = x2 } else { lo = x1 }
        }
        if let r = evaluate((lo + hi) / 2), r.distance < found.result.distance { found = ((lo + hi) / 2, r) }
        return found.result
    }

    /// Vincenty inverse; nil if it fails to converge.
    static func vincentyInverse(_ p1: Coordinate, _ p2: Coordinate) -> GeodesicInverse? {
        let a = WGS84.semiMajorAxis, b = WGS84.semiMinorAxis, f = WGS84.flattening
        let phi1 = p1.latitudeRadians, phi2 = p2.latitudeRadians
        let L = Angle.radians(Angle.normalizeLongitude(p2.longitude - p1.longitude))
        let tanU1 = (1 - f) * tan(phi1), cosU1 = 1 / (1 + tanU1 * tanU1).squareRoot(), sinU1 = tanU1 * cosU1
        let tanU2 = (1 - f) * tan(phi2), cosU2 = 1 / (1 + tanU2 * tanU2).squareRoot(), sinU2 = tanU2 * cosU2

        var lambda = L
        var sinLambda = 0.0, cosLambda = 0.0
        var sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0
        var cosSqAlpha = 0.0, cos2SigmaM = 0.0
        var converged = false
        for _ in 0..<200 {
            sinLambda = sin(lambda)
            cosLambda = cos(lambda)
            let t1 = cosU2 * sinLambda
            let t2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
            let sinSqSigma = t1 * t1 + t2 * t2
            if sinSqSigma < 1e-30 {
                // Exactly antipodal: no unique solution, let the caller fall back.
                if sinU1 * sinU2 + cosU1 * cosU2 * cosLambda < 0 { return nil }
                // Coincident points (or both at the same pole).
                return GeodesicInverse(distance: 0, initialBearing: 0, finalBearing: 0, method: .vincenty)
            }
            sinSigma = sinSqSigma.squareRoot()
            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
            cosSqAlpha = 1 - sinAlpha * sinAlpha
            cos2SigmaM = cosSqAlpha != 0 ? cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha : 0
            let C = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha))
            let previous = lambda
            lambda = L + (1 - C) * f * sinAlpha
                * (sigma + C * sinSigma * (cos2SigmaM + C * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
            if abs(lambda) > .pi * 1.5 || !lambda.isFinite { return nil }
            if abs(lambda - previous) < 1e-12 {
                converged = true
                break
            }
        }
        guard converged else { return nil }

        let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
        let A = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let B = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        let deltaSigma = B * sinSigma * (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
            - B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
        let s = b * A * (sigma - deltaSigma)
        let alpha1 = atan2(cosU2 * sinLambda, cosU1 * sinU2 - sinU1 * cosU2 * cosLambda)
        let alpha2 = atan2(cosU1 * sinLambda, -sinU1 * cosU2 + cosU1 * sinU2 * cosLambda)
        return GeodesicInverse(
            distance: s,
            initialBearing: Angle.normalizeBearing(Angle.degrees(alpha1)),
            finalBearing: Angle.normalizeBearing(Angle.degrees(alpha2)),
            method: .vincenty
        )
    }

    /// Point reached travelling `distance` metres from `start` along the geodesic with initial
    /// `bearing` (degrees true), on WGS84 (Vincenty direct). Longitude is normalised to -180..<180.
    public static func destination(from start: Coordinate, bearing: Double, distance: Double) -> Coordinate {
        direct(from: start, bearing: bearing, distance: distance).coordinate
    }

    /// Vincenty direct: destination plus the final bearing (degrees true) on arrival.
    public static func direct(
        from start: Coordinate, bearing: Double, distance s: Double
    ) -> (coordinate: Coordinate, finalBearing: Double) {
        guard start.isValid, bearing.isFinite, s.isFinite else {
            return (Coordinate(latitude: .nan, longitude: .nan), .nan)
        }
        if s == 0 { return (start, Angle.normalizeBearing(bearing)) }
        let a = WGS84.semiMajorAxis, b = WGS84.semiMinorAxis, f = WGS84.flattening
        let alpha1 = Angle.radians(bearing)
        let sinAlpha1 = sin(alpha1), cosAlpha1 = cos(alpha1)
        let tanU1 = (1 - f) * tan(start.latitudeRadians)
        let cosU1 = 1 / (1 + tanU1 * tanU1).squareRoot(), sinU1 = tanU1 * cosU1
        let sigma1 = atan2(tanU1, cosAlpha1)
        let sinAlpha = cosU1 * sinAlpha1
        let cosSqAlpha = 1 - sinAlpha * sinAlpha
        let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
        let A = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let B = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))

        var sigma = s / (b * A)
        var sinSigma = 0.0, cosSigma = 0.0, cos2SigmaM = 0.0
        for _ in 0..<200 {
            cos2SigmaM = cos(2 * sigma1 + sigma)
            sinSigma = sin(sigma)
            cosSigma = cos(sigma)
            let deltaSigma = B * sinSigma * (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
                - B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
            let previous = sigma
            sigma = s / (b * A) + deltaSigma
            if abs(sigma - previous) < 1e-12 { break }
        }
        sinSigma = sin(sigma)
        cosSigma = cos(sigma)
        cos2SigmaM = cos(2 * sigma1 + sigma)
        let x = sinU1 * sinSigma - cosU1 * cosSigma * cosAlpha1
        let phi2 = atan2(sinU1 * cosSigma + cosU1 * sinSigma * cosAlpha1,
                         (1 - f) * (sinAlpha * sinAlpha + x * x).squareRoot())
        let lambda = atan2(sinSigma * sinAlpha1, cosU1 * cosSigma - sinU1 * sinSigma * cosAlpha1)
        let C = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha))
        let L = lambda - (1 - C) * f * sinAlpha
            * (sigma + C * sinSigma * (cos2SigmaM + C * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
        let alpha2 = atan2(sinAlpha, -x)
        let coordinate = Coordinate(
            latitude: Angle.degrees(phi2),
            longitude: Angle.normalizeLongitude(start.longitude + Angle.degrees(L))
        )
        return (coordinate, Angle.normalizeBearing(Angle.degrees(alpha2)))
    }

    // MARK: - Spherical great circle

    /// Great-circle distance in metres using the haversine formula on ``earthMeanRadius``.
    public static func haversineDistance(from a: Coordinate, to b: Coordinate, radius: Double = earthMeanRadius) -> Double {
        centralAngle(a, b) * radius
    }

    /// Central angle in radians between two points (haversine, numerically safe).
    static func centralAngle(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dPhi = b.latitudeRadians - a.latitudeRadians
        let dLambda = b.longitudeRadians - a.longitudeRadians
        let h = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(a.latitudeRadians) * cos(b.latitudeRadians) * sin(dLambda / 2) * sin(dLambda / 2)
        let hc = min(max(h, 0), 1)
        return 2 * atan2(hc.squareRoot(), (1 - hc).squareRoot())
    }

    /// Spherical initial great-circle bearing from `a` to `b`, degrees true. 0 for coincident points.
    public static func sphericalInitialBearing(from a: Coordinate, to b: Coordinate) -> Double {
        let phi1 = a.latitudeRadians, phi2 = b.latitudeRadians
        let dLambda = b.longitudeRadians - a.longitudeRadians
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        if abs(x) < 1e-15 && abs(y) < 1e-15 { return 0 }
        return Angle.normalizeBearing(Angle.degrees(atan2(y, x)))
    }

    /// Spherical final great-circle bearing arriving at `b`, degrees true.
    public static func sphericalFinalBearing(from a: Coordinate, to b: Coordinate) -> Double {
        if a == b { return 0 }
        return Angle.normalizeBearing(sphericalInitialBearing(from: b, to: a) + 180)
    }

    /// Spherical destination from `start` travelling `distance` metres on initial `bearing`.
    public static func sphericalDestination(
        from start: Coordinate, bearing: Double, distance: Double, radius: Double = earthMeanRadius
    ) -> Coordinate {
        let delta = distance / radius
        let theta = Angle.radians(bearing)
        let phi1 = start.latitudeRadians, lambda1 = start.longitudeRadians
        let sinPhi2 = sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta)
        let phi2 = asin(min(max(sinPhi2, -1), 1))
        let y = sin(theta) * sin(delta) * cos(phi1)
        let x = cos(delta) - sin(phi1) * sinPhi2
        let lambda2 = lambda1 + atan2(y, x)
        return Coordinate(latitude: Angle.degrees(phi2), longitude: Angle.normalizeLongitude(Angle.degrees(lambda2)))
    }

    /// Point at `fraction` (0 = `a`, 1 = `b`) along the great circle from `a` to `b`.
    /// Fractions outside 0...1 extrapolate along the same great circle.
    public static func interpolate(from a: Coordinate, to b: Coordinate, fraction: Double) -> Coordinate {
        let delta = centralAngle(a, b)
        if delta < 1e-12 { return a }
        let sinDelta = sin(delta)
        if abs(sinDelta) < 1e-12 {
            // Antipodal: the great circle is undefined; fall back to linear interpolation.
            return Coordinate(
                latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: Angle.normalizeLongitude(a.longitude + (b.longitude - a.longitude) * fraction)
            )
        }
        let wa = sin((1 - fraction) * delta) / sinDelta
        let wb = sin(fraction * delta) / sinDelta
        let phi1 = a.latitudeRadians, l1 = a.longitudeRadians, phi2 = b.latitudeRadians, l2 = b.longitudeRadians
        let x = wa * cos(phi1) * cos(l1) + wb * cos(phi2) * cos(l2)
        let y = wa * cos(phi1) * sin(l1) + wb * cos(phi2) * sin(l2)
        let z = wa * sin(phi1) + wb * sin(phi2)
        let phi = atan2(z, (x * x + y * y).squareRoot())
        let lambda = atan2(y, x)
        return Coordinate(latitude: Angle.degrees(phi), longitude: Angle.normalizeLongitude(Angle.degrees(lambda)))
    }

    /// Great-circle midpoint between two points.
    public static func midpoint(between a: Coordinate, and b: Coordinate) -> Coordinate {
        let phi1 = a.latitudeRadians, phi2 = b.latitudeRadians
        let dLambda = b.longitudeRadians - a.longitudeRadians
        let bx = cos(phi2) * cos(dLambda)
        let by = cos(phi2) * sin(dLambda)
        let phi3 = atan2(sin(phi1) + sin(phi2), ((cos(phi1) + bx) * (cos(phi1) + bx) + by * by).squareRoot())
        let lambda3 = a.longitudeRadians + atan2(by, cos(phi1) + bx)
        return Coordinate(latitude: Angle.degrees(phi3), longitude: Angle.normalizeLongitude(Angle.degrees(lambda3)))
    }

    // MARK: - Rhumb lines (loxodromes), spherical

    /// Clamp latitude away from the poles where the Mercator projection is singular.
    private static func rhumbSafeLatitude(_ phi: Double) -> Double {
        let limit = Double.pi / 2 - 1e-9
        return min(max(phi, -limit), limit)
    }

    private static func projectedLatitudeDifference(_ phi1: Double, _ phi2: Double) -> Double {
        let p1 = rhumbSafeLatitude(phi1), p2 = rhumbSafeLatitude(phi2)
        return log(tan(.pi / 4 + p2 / 2) / tan(.pi / 4 + p1 / 2))
    }

    /// Rhumb-line (constant bearing) distance in metres from `a` to `b` on a sphere.
    public static func rhumbDistance(from a: Coordinate, to b: Coordinate, radius: Double = earthMeanRadius) -> Double {
        let phi1 = a.latitudeRadians, phi2 = b.latitudeRadians
        let dPhi = phi2 - phi1
        let dLambda = Angle.radians(Angle.normalizeLongitude(b.longitude - a.longitude))
        let dPsi = projectedLatitudeDifference(phi1, phi2)
        let q = abs(dPsi) > 1e-12 ? dPhi / dPsi : cos(phi1)
        return (dPhi * dPhi + q * q * dLambda * dLambda).squareRoot() * radius
    }

    /// Constant rhumb-line bearing from `a` to `b`, degrees true. 0 for coincident points.
    public static func rhumbBearing(from a: Coordinate, to b: Coordinate) -> Double {
        let dLambda = Angle.radians(Angle.normalizeLongitude(b.longitude - a.longitude))
        let dPsi = projectedLatitudeDifference(a.latitudeRadians, b.latitudeRadians)
        if abs(dLambda) < 1e-15 && abs(dPsi) < 1e-15 { return 0 }
        return Angle.normalizeBearing(Angle.degrees(atan2(dLambda, dPsi)))
    }

    /// Point reached travelling `distance` metres from `start` on constant `bearing` (sphere).
    public static func rhumbDestination(
        from start: Coordinate, bearing: Double, distance: Double, radius: Double = earthMeanRadius
    ) -> Coordinate {
        let delta = distance / radius
        let theta = Angle.radians(bearing)
        let phi1 = start.latitudeRadians
        let dPhi = delta * cos(theta)
        var phi2 = phi1 + dPhi
        if abs(phi2) > .pi / 2 { phi2 = phi2 > 0 ? .pi - phi2 : -.pi - phi2 }
        let dPsi = projectedLatitudeDifference(phi1, phi2)
        let q = abs(dPsi) > 1e-12 ? dPhi / dPsi : cos(phi1)
        let dLambda = abs(q) > 1e-15 ? delta * sin(theta) / q : 0
        return Coordinate(
            latitude: Angle.degrees(phi2),
            longitude: Angle.normalizeLongitude(start.longitude + Angle.degrees(dLambda))
        )
    }

    // MARK: - Legs

    /// Signed cross-track distance in metres of `point` from the great circle through
    /// `start` and `end`. Positive to the right of the track, negative to the left.
    /// Returns 0 for a zero-length leg.
    public static func crossTrackDistance(of point: Coordinate, legStart start: Coordinate, legEnd end: Coordinate) -> Double {
        project(point, legStart: start, legEnd: end).crossTrack
    }

    /// Signed along-track distance in metres from `start` to the foot of the perpendicular
    /// from `point` onto the leg's great circle. Returns 0 for a zero-length leg.
    public static func alongTrackDistance(of point: Coordinate, legStart start: Coordinate, legEnd end: Coordinate) -> Double {
        project(point, legStart: start, legEnd: end).alongTrack
    }

    /// Closest point to `point` on the segment from `start` to `end`.
    public static func closestPoint(to point: Coordinate, legStart start: Coordinate, legEnd end: Coordinate) -> Coordinate {
        project(point, legStart: start, legEnd: end).closestPoint
    }

    /// Projects `point` onto the leg from `start` to `end` (spherical model).
    ///
    /// A zero-length leg yields cross- and along-track of 0 and the start as closest point.
    public static func project(_ point: Coordinate, legStart start: Coordinate, legEnd end: Coordinate) -> LegProjection {
        let R = earthMeanRadius
        let legAngle = centralAngle(start, end)
        let legLength = legAngle * R
        let d13 = centralAngle(start, point)
        guard legAngle > 1e-12 else {
            return LegProjection(crossTrack: 0, alongTrack: 0, legLength: 0, fraction: 0,
                                 closestPoint: start, distanceToClosestPoint: d13 * R)
        }
        let theta13 = Angle.radians(sphericalInitialBearing(from: start, to: point))
        let theta12 = Angle.radians(sphericalInitialBearing(from: start, to: end))
        let dTheta = theta13 - theta12
        let xt = asin(min(max(sin(d13) * sin(dTheta), -1), 1))
        let at = atan2(sin(d13) * cos(dTheta), cos(d13))
        let alongTrack = at * R
        let fraction = min(max(at / legAngle, 0), 1)
        let closest: Coordinate
        if fraction <= 0 {
            closest = start
        } else if fraction >= 1 {
            closest = end
        } else {
            closest = interpolate(from: start, to: end, fraction: fraction)
        }
        return LegProjection(
            crossTrack: xt * R,
            alongTrack: alongTrack,
            legLength: legLength,
            fraction: fraction,
            closestPoint: closest,
            distanceToClosestPoint: haversineDistance(from: point, to: closest)
        )
    }
}

extension Coordinate {
    /// Ellipsoidal (WGS84) distance in metres to `other`.
    public func distance(to other: Coordinate) -> Double { Geodesy.distance(from: self, to: other) }
    /// Ellipsoidal initial bearing to `other`, degrees true.
    public func initialBearing(to other: Coordinate) -> Double { Geodesy.initialBearing(from: self, to: other) }
    /// Ellipsoidal destination travelling `distance` metres on initial `bearing`.
    public func destination(bearing: Double, distance: Double) -> Coordinate {
        Geodesy.destination(from: self, bearing: bearing, distance: distance)
    }
}
