import Foundation
import NavCore
import Persistence

/// The display units chosen in Settings.
public struct UnitPreferences: Sendable, Equatable {
    public var distance: DistanceUnit
    public var depth: DepthUnit
    public var speed: SpeedUnit

    public init(distance: DistanceUnit = .nauticalMiles, depth: DepthUnit = .feet, speed: SpeedUnit = .knots) {
        self.distance = distance
        self.depth = depth
        self.speed = speed
    }
}

/// Text for navigation values in the user's units. Fixed POSIX number formatting (no locale dependence),
/// with `InstrumentFormat.placeholder` for missing values.
public enum NavFormat {
    public static let placeholder = InstrumentFormat.placeholder

    public static func distance(_ meters: Double?, unit: DistanceUnit) -> String {
        guard let m = meters, m.isFinite, m >= 0 else { return placeholder }
        switch unit {
        case .nauticalMiles:
            return scaled(m / UnitConversion.metersPerNauticalMile) + " nm"
        case .statuteMiles:
            return scaled(m / UnitConversion.metersPerStatuteMile) + " mi"
        case .kilometers:
            if m < 1000 { return String(format: "%.0f m", m) }
            return scaled(m / 1000) + " km"
        }
    }

    /// Two decimals below 10, one below 100, none above.
    static func scaled(_ value: Double) -> String {
        if value < 10 { return String(format: "%.2f", value) }
        if value < 100 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }

    public static func speed(_ metersPerSecond: Double?, unit: SpeedUnit) -> String {
        guard let mps = metersPerSecond, mps.isFinite, mps >= 0 else { return placeholder }
        switch unit {
        case .knots: return String(format: "%.1f kn", Speed(metersPerSecond: mps).knots)
        case .milesPerHour: return String(format: "%.1f mph", mps * 3600 / UnitConversion.metersPerStatuteMile)
        case .kilometersPerHour: return String(format: "%.1f km/h", mps * 3.6)
        }
    }

    public static func depth(_ meters: Double?, unit: DepthUnit) -> String {
        guard let m = meters, m.isFinite else { return placeholder }
        switch unit {
        case .feet: return String(format: "%.1f ft", m / UnitConversion.metersPerFoot)
        case .meters: return String(format: "%.1f m", m)
        case .fathoms: return String(format: "%.1f fm", m / UnitConversion.metersPerFathom)
        }
    }

    /// Bearing in whole degrees true: "074°T".
    public static func bearing(_ degrees: Double?) -> String {
        InstrumentFormat.cog(degrees: degrees)
    }

    /// Cross-track error with the side to steer back from: "0.05 nm R" means the boat is right of track.
    public static func crossTrack(_ meters: Double?, unit: DistanceUnit) -> String {
        guard let m = meters, m.isFinite else { return placeholder }
        let text: String = distance(abs(m), unit: unit)
        let magnitudeIsZero: Bool = abs(m) < 0.5
        if magnitudeIsZero { return text }
        return text + (m > 0 ? " R" : " L")
    }

    /// Duration: "45 s", "12 min", "1 h 05 min", "3 d 4 h".
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return placeholder }
        let total: Int = Int(s.rounded())
        if total < 60 { return "\(total) s" }
        let minutes: Int = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours: Int = minutes / 60
        if hours < 48 {
            let rest: Int = minutes % 60
            return "\(hours) h " + (rest < 10 ? "0" : "") + "\(rest) min"
        }
        return "\(hours / 24) d \(hours % 24) h"
    }

    /// Clock time "14:32" in `timeZone` (24-hour, as on a chart plotter).
    public static func clockTime(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return placeholder }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts: DateComponents = calendar.dateComponents([.hour, .minute], from: date)
        let h: Int = parts.hour ?? 0
        let m: Int = parts.minute ?? 0
        return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
    }

    /// Position on one line: "27°36.060'N 082°42.000'W".
    public static func position(_ coordinate: Coordinate?) -> String {
        guard let c = coordinate, c.isValid else { return placeholder }
        return CoordinateFormat.ddm(c)
    }

    /// Date and time for lists: "12 Nov 2026 14:32".
    public static func dateTime(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return placeholder }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let months: [String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let month: String = months[min(max((parts.month ?? 1) - 1, 0), 11)]
        return "\(parts.day ?? 1) \(month) \(parts.year ?? 1970) " + clockTime(date, timeZone: timeZone)
    }
}

extension InstrumentFormat {
    /// Speed over ground in the chosen unit.
    public static func sog(metersPerSecond: Double?, unit: SpeedUnit) -> String {
        NavFormat.speed(metersPerSecond, unit: unit)
    }
}
