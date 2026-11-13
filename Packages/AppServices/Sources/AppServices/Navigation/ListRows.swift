import Foundation
import NavCore
import Persistence

/// A waypoint list row: name, position, and distance and bearing from the boat.
public struct WaypointRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbol: String?
    public var position: String
    /// Metres from the boat, nil without a fix.
    public var distance: Double?
    public var distanceText: String
    public var bearingText: String

    /// Rows sorted by distance from `boat` (by name when there is no fix).
    public static func rows(_ waypoints: [Waypoint], from boat: Coordinate?, units: UnitPreferences) -> [WaypointRow] {
        var rows: [WaypointRow] = []
        for w in waypoints {
            var distance: Double? = nil
            var bearing: Double? = nil
            if let boat, boat.isValid, w.coordinate.isValid {
                distance = Geodesy.distance(from: boat, to: w.coordinate)
                bearing = Geodesy.initialBearing(from: boat, to: w.coordinate)
            }
            rows.append(WaypointRow(id: w.id, name: w.name, symbol: w.symbol, position: NavFormat.position(w.coordinate),
                                    distance: distance, distanceText: NavFormat.distance(distance, unit: units.distance),
                                    bearingText: NavFormat.bearing(bearing)))
        }
        if boat != nil {
            rows.sort { a, b in
                (a.distance ?? .infinity, a.name.lowercased()) < (b.distance ?? .infinity, b.name.lowercased())
            }
        } else {
            rows.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
        return rows
    }
}

/// A route list row.
public struct RouteRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var detail: String
    public var isAutoRoute: Bool

    public static func rows(_ routes: [Route], units: UnitPreferences) -> [RouteRow] {
        routes.map { r in
            RouteRow(id: r.id, name: r.name,
                     detail: "\(r.points.count) points, " + NavFormat.distance(r.length.meters, unit: units.distance),
                     isAutoRoute: r.metadata != nil)
        }
    }
}

/// A track list row: distance, duration and average speed.
public struct TrackRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var date: String
    public var distance: String
    public var duration: String
    public var averageSpeed: String
    public var isRecording: Bool

    public static func rows(_ tracks: [Track], units: UnitPreferences, timeZone: TimeZone = .current) -> [TrackRow] {
        tracks.map { t in
            TrackRow(id: t.id, name: t.name, date: NavFormat.dateTime(t.startDate ?? t.createdAt, timeZone: timeZone),
                     distance: NavFormat.distance(t.statistics.distance.meters, unit: units.distance),
                     duration: NavFormat.duration(t.statistics.duration),
                     averageSpeed: NavFormat.speed(t.statistics.averageSpeed?.metersPerSecond, unit: units.speed),
                     isRecording: t.state == .recording)
        }
    }
}

/// Default names for new items.
public enum DefaultNames {
    /// "WP 001", "WP 002", … : one more than the highest "WP n" already used.
    public static func nextWaypointName(existing: [String]) -> String {
        var highest: Int = 0
        for name in existing {
            let trimmed: String = name.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("WP ") else { continue }
            if let n = Int(trimmed.dropFirst(3)) { highest = max(highest, n) }
        }
        let next: Int = highest + 1
        let digits: String = String(next)
        return "WP " + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }

    public static func trackName(start: Date, timeZone: TimeZone = .current) -> String {
        "Track " + NavFormat.dateTime(start, timeZone: timeZone)
    }

    public static func routeName(existingCount: Int) -> String {
        "Route \(existingCount + 1)"
    }
}

/// Symbols offered for waypoints (GPX `<sym>` vocabulary), with an SF Symbol for display.
public enum WaypointSymbols {
    public struct Choice: Sendable, Equatable, Identifiable {
        public var id: String { gpxName }
        public var gpxName: String
        public var title: String
        public var systemImage: String
    }

    public static let choices: [Choice] = [
        Choice(gpxName: "Waypoint", title: "Waypoint", systemImage: "mappin"),
        Choice(gpxName: "Anchor", title: "Anchorage", systemImage: "sailboat"),
        Choice(gpxName: "Fishing Area", title: "Fishing", systemImage: "fish"),
        Choice(gpxName: "Marina", title: "Marina", systemImage: "building.2"),
        Choice(gpxName: "Fuel", title: "Fuel", systemImage: "fuelpump"),
        Choice(gpxName: "Danger Area", title: "Hazard", systemImage: "exclamationmark.triangle"),
        Choice(gpxName: "Diver Down Flag 1", title: "Dive site", systemImage: "figure.pool.swim"),
        Choice(gpxName: "Flag", title: "Flag", systemImage: "flag"),
    ]

    public static func systemImage(for gpxName: String?) -> String {
        guard let gpxName else { return "mappin" }
        let lower: String = gpxName.lowercased()
        for c in choices where c.gpxName.lowercased() == lower { return c.systemImage }
        return "mappin"
    }
}
