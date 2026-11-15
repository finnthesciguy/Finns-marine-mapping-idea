import Foundation
import NavCore

/// Whether the instrument strip has a usable position, and what to say when it has not.
///
/// A Mac has no GPS: CoreLocation positions it from Wi-Fi (when allowed and available), often not at all,
/// and a fix that stops updating must not be shown as if it were current. The Mac build shows this state in
/// the instrument strip; planning (charts, waypoints, routes, GPX, auto-routes from waypoints or chart points)
/// works without a position.
public enum PositionState: Sendable, Equatable {
    /// A fix newer than `PositionStatus.staleAfter`.
    case current
    /// The last fix is this many whole seconds old.
    case stale(seconds: Int)
    /// Location is allowed (or not decided yet) but no fix has arrived.
    case waiting
    /// Location access is denied or restricted.
    case off
}

public enum PositionStatus {
    /// A fix older than this is not shown as the boat's position.
    public static let staleAfter: TimeInterval = 30

    public static func state(lastFix: Fix?, authorization: LocationAuthorization, now: Date) -> PositionState {
        if authorization == .denied || authorization == .restricted {
            return .off
        }
        guard let fix = lastFix else { return .waiting }
        let age: TimeInterval = now.timeIntervalSince(fix.timestamp)
        if age > staleAfter {
            return .stale(seconds: Int(age))
        }
        return .current
    }

    /// Whether speed, course and position values should be shown.
    public static func showsValues(_ state: PositionState) -> Bool {
        state == .current
    }

    /// The line shown in the instrument strip instead of values; nil when there is a current position.
    public static func message(_ state: PositionState) -> String? {
        switch state {
        case .current:
            return nil
        case .off:
            return "No position: location access is off. Charts, waypoints and routes work without it."
        case .waiting:
            return "No position yet. Charts, waypoints and routes work without it."
        case .stale(let seconds):
            return "No position for " + age(seconds) + "."
        }
    }

    /// "45 s", "3 min", "2 h 05 min".
    static func age(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 0)) s" }
        let minutes: Int = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours: Int = minutes / 60
        let rest: Int = minutes % 60
        return "\(hours) h " + (rest < 10 ? "0" : "") + "\(rest) min"
    }
}
