import Foundation
import NavCore

/// Byte counts in decimal units, as iOS Settings shows storage ("621 MB", "2.67 GB").
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let value: Double = Double(max(0, bytes))
        if value < 1_000 { return "\(Int64(value)) bytes" }
        let units: [String] = ["KB", "MB", "GB", "TB"]
        var scaled: Double = value / 1_000
        var index = 0
        while scaled >= 1_000 && index < units.count - 1 {
            scaled /= 1_000
            index += 1
        }
        let digits: Int
        if scaled >= 100 { digits = 0 } else if scaled >= 10 { digits = 1 } else { digits = 2 }
        // Formatted with a fixed POSIX format so output does not depend on the device locale in tests.
        let text: String = String(format: "%.\(digits)f", scaled)
        return "\(text) \(units[index])"
    }
}

/// Dates as shown next to chart data: "28 May 2024" (UTC, so a date-only manifest value never shifts a day).
public enum DataDateFormat {
    private static let monthNames: [String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static func string(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        let parts: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let month: Int = min(max((parts.month ?? 1) - 1, 0), 11)
        return "\(parts.day ?? 1) \(monthNames[month]) \(parts.year ?? 1970)"
    }
}

/// Text for the instrument strip.
public enum InstrumentFormat {
    public static let placeholder = "—"

    /// Speed over ground from m/s, in knots with one decimal: "6.0 kn".
    public static func sog(metersPerSecond: Double?) -> String {
        guard let mps = metersPerSecond, mps.isFinite, mps >= 0 else { return placeholder }
        let knots: Double = Speed(metersPerSecond: mps).knots
        return String(format: "%.1f kn", knots)
    }

    /// Course over ground, whole degrees true with three digits: "074°T".
    public static func cog(degrees: Double?) -> String {
        guard let d = degrees, d.isFinite else { return placeholder }
        var whole: Int = Int(Angle.normalizeBearing(d).rounded())
        if whole >= 360 { whole -= 360 }
        let text: String = String(whole)
        let padded: String = String(repeating: "0", count: max(0, 3 - text.count)) + text
        return padded + "°T"
    }

    /// Position in degrees and decimal minutes, latitude and longitude on separate lines.
    public static func position(_ coordinate: Coordinate?) -> (latitude: String, longitude: String) {
        guard let c = coordinate, c.isValid else { return (placeholder, placeholder) }
        return (CoordinateFormat.latitudeDDM(c.latitude, fractionDigits: 3),
                CoordinateFormat.longitudeDDM(c.longitude, fractionDigits: 3))
    }
}
