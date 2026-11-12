import Foundation

/// Exact unit conversion factors used throughout NavCore.
///
/// NavCore computes internally in SI units: metres, seconds, metres per second, degrees.
public enum UnitConversion {
    /// Metres in one international nautical mile (exact).
    public static let metersPerNauticalMile = 1852.0
    /// Metres in one international foot (exact).
    public static let metersPerFoot = 0.3048
    /// Metres in one fathom (6 ft, exact).
    public static let metersPerFathom = 1.8288
    /// Metres in one statute mile (exact).
    public static let metersPerStatuteMile = 1609.344
    /// Metres per second in one knot (1852 m / 3600 s).
    public static let metersPerSecondPerKnot = 1852.0 / 3600.0
}

/// A length, stored in metres.
public struct Distance: Hashable, Comparable, Sendable, Codable {
    /// Length in metres.
    public var meters: Double

    /// Creates a distance from metres.
    public init(meters: Double) { self.meters = meters }
    /// Creates a distance from metres.
    public static func meters(_ value: Double) -> Distance { Distance(meters: value) }
    /// Creates a distance from nautical miles.
    public static func nauticalMiles(_ value: Double) -> Distance {
        Distance(meters: value * UnitConversion.metersPerNauticalMile)
    }
    /// Creates a distance from feet.
    public static func feet(_ value: Double) -> Distance { Distance(meters: value * UnitConversion.metersPerFoot) }
    /// Creates a distance from fathoms.
    public static func fathoms(_ value: Double) -> Distance { Distance(meters: value * UnitConversion.metersPerFathom) }
    /// Creates a distance from statute miles.
    public static func statuteMiles(_ value: Double) -> Distance {
        Distance(meters: value * UnitConversion.metersPerStatuteMile)
    }

    /// Length in nautical miles.
    public var nauticalMiles: Double { meters / UnitConversion.metersPerNauticalMile }
    /// Length in feet.
    public var feet: Double { meters / UnitConversion.metersPerFoot }
    /// Length in fathoms.
    public var fathoms: Double { meters / UnitConversion.metersPerFathom }
    /// Length in statute miles.
    public var statuteMiles: Double { meters / UnitConversion.metersPerStatuteMile }

    /// Orders by length.
    public static func < (lhs: Distance, rhs: Distance) -> Bool { lhs.meters < rhs.meters }
    /// Sum of two distances.
    public static func + (lhs: Distance, rhs: Distance) -> Distance { Distance(meters: lhs.meters + rhs.meters) }
    /// Difference of two distances.
    public static func - (lhs: Distance, rhs: Distance) -> Distance { Distance(meters: lhs.meters - rhs.meters) }
}

/// A speed, stored in metres per second.
public struct Speed: Hashable, Comparable, Sendable, Codable {
    /// Speed in metres per second.
    public var metersPerSecond: Double

    /// Creates a speed from metres per second.
    public init(metersPerSecond: Double) { self.metersPerSecond = metersPerSecond }
    /// Creates a speed from metres per second.
    public static func metersPerSecond(_ value: Double) -> Speed { Speed(metersPerSecond: value) }
    /// Creates a speed from knots.
    public static func knots(_ value: Double) -> Speed {
        Speed(metersPerSecond: value * UnitConversion.metersPerSecondPerKnot)
    }
    /// Creates a speed from kilometres per hour.
    public static func kilometersPerHour(_ value: Double) -> Speed { Speed(metersPerSecond: value / 3.6) }

    /// Speed in knots.
    public var knots: Double { metersPerSecond / UnitConversion.metersPerSecondPerKnot }
    /// Speed in kilometres per hour.
    public var kilometersPerHour: Double { metersPerSecond * 3.6 }

    /// Time to cover `distance` at this speed, or nil if the speed is not positive.
    public func timeToCover(_ distance: Distance) -> TimeInterval? {
        guard metersPerSecond > 0, metersPerSecond.isFinite else { return nil }
        return distance.meters / metersPerSecond
    }

    /// Orders by magnitude.
    public static func < (lhs: Speed, rhs: Speed) -> Bool { lhs.metersPerSecond < rhs.metersPerSecond }
}
