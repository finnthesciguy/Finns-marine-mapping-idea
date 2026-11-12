import Foundation

/// A geographic position on the WGS84 datum, in decimal degrees.
///
/// The memberwise initialiser does not validate, so that hot paths stay cheap;
/// use ``init(validatingLatitude:longitude:)`` or ``isValid`` at input boundaries
/// (parsing files, user entry, GPS callbacks).
public struct Coordinate: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Latitude in degrees, positive north. Valid range -90...90.
    public var latitude: Double
    /// Longitude in degrees, positive east. Valid range -180...180.
    public var longitude: Double

    /// Creates a coordinate without validation.
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Creates a coordinate, throwing if either component is non-finite or out of range.
    public init(validatingLatitude latitude: Double, longitude: Double) throws(CoordinateError) {
        guard latitude.isFinite, longitude.isFinite else { throw .notFinite }
        guard (-90.0...90.0).contains(latitude) else { throw .latitudeOutOfRange(latitude) }
        guard (-180.0...180.0).contains(longitude) else { throw .longitudeOutOfRange(longitude) }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// True when both components are finite and within their valid ranges.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    /// The same position with longitude wrapped into -180..<180 and latitude clamped to -90...90.
    public var normalized: Coordinate {
        Coordinate(latitude: min(max(latitude, -90), 90), longitude: Angle.normalizeLongitude(longitude))
    }

    /// Latitude in radians.
    public var latitudeRadians: Double { latitude * .pi / 180 }
    /// Longitude in radians.
    public var longitudeRadians: Double { longitude * .pi / 180 }

    /// Decimal-degree description, e.g. `27.752050, -82.624267`.
    public var description: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}

/// Reasons a coordinate failed validation.
public enum CoordinateError: Error, Hashable, Sendable {
    /// Latitude or longitude was NaN or infinite.
    case notFinite
    /// Latitude outside -90...90.
    case latitudeOutOfRange(Double)
    /// Longitude outside -180...180.
    case longitudeOutOfRange(Double)
}

/// A single position report, typically from GPS.
public struct Fix: Hashable, Sendable, Codable {
    /// Reported position.
    public var coordinate: Coordinate
    /// Time the position was measured.
    public var timestamp: Date
    /// Speed over ground in metres per second, if the receiver supplied one.
    public var speed: Double?
    /// Course over ground in degrees true (0..<360), if the receiver supplied one.
    public var course: Double?
    /// Estimated horizontal accuracy (radius, metres), if known.
    public var horizontalAccuracy: Double?

    /// Creates a fix.
    public init(
        coordinate: Coordinate,
        timestamp: Date,
        speed: Double? = nil,
        course: Double? = nil,
        horizontalAccuracy: Double? = nil
    ) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Small angle helpers (degrees).
public enum Angle {
    /// Converts degrees to radians.
    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    /// Converts radians to degrees.
    @inlinable public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Wraps a bearing into 0..<360 degrees.
    public static func normalizeBearing(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return degrees }
        var r = degrees.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        if r >= 360 { r -= 360 }
        return r
    }

    /// Wraps a longitude into -180..<180 degrees.
    public static func normalizeLongitude(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return degrees }
        return normalizeBearing(degrees + 180) - 180
    }

    /// Signed smallest difference `to - from` in degrees, in -180..<180.
    /// Positive means `to` is clockwise (to starboard) of `from`.
    public static func difference(from: Double, to: Double) -> Double {
        normalizeBearing(to - from + 180) - 180
    }
}
