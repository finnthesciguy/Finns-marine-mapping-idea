import Foundation

/// A latitude/longitude rectangle.
///
/// Designed for the Gulf of Mexico, so it does not try to be clever about the antimeridian:
/// a box whose `west` is greater than `east` is treated as wrapping across 180° by ``contains(_:)``,
/// and every operation is total (never traps), but ``init(coordinates:)`` and ``union(_:)`` simply take
/// minimum and maximum longitudes.
public struct BoundingBox: Hashable, Sendable, Codable {
    /// Southern edge latitude, degrees.
    public var south: Double
    /// Western edge longitude, degrees.
    public var west: Double
    /// Northern edge latitude, degrees.
    public var north: Double
    /// Eastern edge longitude, degrees.
    public var east: Double

    /// Creates a box from its edges.
    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    /// The smallest box containing every coordinate, or nil for an empty sequence.
    /// Non-finite coordinates are ignored.
    public init?<S: Sequence>(coordinates: S) where S.Element == Coordinate {
        var s = Double.infinity, w = Double.infinity, n = -Double.infinity, e = -Double.infinity
        for c in coordinates where c.latitude.isFinite && c.longitude.isFinite {
            s = min(s, c.latitude); n = max(n, c.latitude)
            w = min(w, c.longitude); e = max(e, c.longitude)
        }
        guard s.isFinite else { return nil }
        self.init(south: s, west: w, north: n, east: e)
    }

    /// South-west corner.
    public var southWest: Coordinate { Coordinate(latitude: south, longitude: west) }
    /// North-east corner.
    public var northEast: Coordinate { Coordinate(latitude: north, longitude: east) }

    /// True when `west > east`, i.e. the box is read as spanning the antimeridian.
    public var crossesAntimeridian: Bool { west > east }

    /// Centre of the box (simple average of edges; wraps correctly for antimeridian boxes).
    public var center: Coordinate {
        let lat = (south + north) / 2
        if crossesAntimeridian {
            return Coordinate(latitude: lat, longitude: Angle.normalizeLongitude((west + east + 360) / 2))
        }
        return Coordinate(latitude: lat, longitude: (west + east) / 2)
    }

    /// Whether the coordinate lies inside or on the edge of the box.
    public func contains(_ c: Coordinate) -> Bool {
        guard c.latitude >= south, c.latitude <= north else { return false }
        if crossesAntimeridian { return c.longitude >= west || c.longitude <= east }
        return c.longitude >= west && c.longitude <= east
    }

    /// Whether two boxes overlap (edges touching counts). Non-wrapping boxes only;
    /// wrapping boxes are compared conservatively (always overlapping in longitude).
    public func intersects(_ other: BoundingBox) -> Bool {
        guard south <= other.north, other.south <= north else { return false }
        if crossesAntimeridian || other.crossesAntimeridian { return true }
        return west <= other.east && other.west <= east
    }

    /// The smallest box containing both boxes (min/max of edges).
    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(south: min(south, other.south), west: min(west, other.west),
                    north: max(north, other.north), east: max(east, other.east))
    }

    /// Box grown on every side by approximately `meters` (spherical), clamped to valid latitudes.
    public func expanded(byMeters meters: Double) -> BoundingBox {
        let dLat = Angle.degrees(meters / Geodesy.earthMeanRadius)
        let maxAbsLat = min(max(abs(south), abs(north)), 89.999)
        let dLon = dLat / max(cos(Angle.radians(maxAbsLat)), 1e-6)
        return BoundingBox(south: max(south - dLat, -90), west: max(west - dLon, -180),
                           north: min(north + dLat, 90), east: min(east + dLon, 180))
    }
}
