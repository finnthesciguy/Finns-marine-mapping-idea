import Foundation
import NavCore
import Persistence
import RoutingKit

/// The safety rules of PLAN.md D5 for auto-routes, applied before a route may be saved or followed.
///
/// - Only green and yellow legs: a route with any other grade (red, or one this version does not know) is
///   never offered for saving or following. (RoutingKit never returns one; the check guards the stored form.)
/// - Every yellow leg states at least one reason.
/// - A route with yellow legs is saved or followed only after an explicit confirmation listing the reasons.
public enum AutoRouteSafety {
    public enum Decision: Sendable, Equatable {
        /// All legs green: may be saved and followed.
        case allowed
        /// Yellow legs: may be saved or followed only after this confirmation.
        case needsConfirmation(AutoRouteCautionConfirmation)
        /// Must not be saved or followed.
        case refused(String)

        public var canSave: Bool {
            if case .refused = self { return false }
            return true
        }

        public var confirmation: AutoRouteCautionConfirmation? {
            if case .needsConfirmation(let c) = self { return c }
            return nil
        }
    }

    public static func decide(legs: [AutoRouteInfo.Leg], reasonTitles: [String: String] = [:]) -> Decision {
        if legs.isEmpty {
            return .refused("The route has no legs (the start and destination are the same place).")
        }
        var yellow: [AutoRouteInfo.Leg] = []
        for leg in legs {
            if leg.grade == .green { continue }
            if leg.grade == .yellow {
                if leg.reasonCodes.isEmpty {
                    return .refused("Leg \(leg.index + 1) is marked for caution without a stated reason, so the route cannot be used.")
                }
                yellow.append(leg)
                continue
            }
            return .refused("Leg \(leg.index + 1) is graded \(leg.grade.rawValue). Only green and yellow legs can be saved or followed.")
        }
        if yellow.isEmpty { return .allowed }
        // Distinct reasons in first-seen order, with how many legs carry each.
        var order: [String] = []
        var counts: [String: Int] = [:]
        for leg in yellow {
            for code in leg.reasonCodes {
                if counts[code] == nil { order.append(code) }
                counts[code, default: 0] += 1
            }
        }
        var lines: [String] = []
        for code in order {
            let title: String = reasonTitles[code] ?? AutoRouteReason.caution(code).title
            let n: Int = counts[code] ?? 0
            lines.append("\(title) (\(n) \(n == 1 ? "leg" : "legs"))")
        }
        let legWord: String = yellow.count == 1 ? "leg needs" : "legs need"
        return .needsConfirmation(AutoRouteCautionConfirmation(
            title: "\(yellow.count) \(legWord) caution",
            message: "This route has \(yellow.count) yellow \(yellow.count == 1 ? "leg" : "legs"). Check each one yourself before you use the route:",
            reasons: lines,
            confirmLabel: "I have reviewed the yellow legs"))
    }
}

/// What the skipper must confirm before a route with yellow legs is saved or followed.
public struct AutoRouteCautionConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    /// One line per distinct reason: "Maintained channel depth (14 legs)".
    public var reasons: [String]
    public var confirmLabel: String

    /// Message and reasons as one text (for an alert).
    public var fullText: String {
        ([message] + reasons.map { "• " + $0 }).joined(separator: "\n")
    }
}

public enum AutoRouteSaveError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The safety rules refuse this route.
    case refused(String)
    /// The route has yellow legs and the caution confirmation was not given.
    case confirmationRequired(AutoRouteCautionConfirmation)
    case emptyName
    case store(String)

    public var description: String {
        switch self {
        case .refused(let reason): return reason
        case .confirmationRequired(let c): return c.title
        case .emptyName: return "Enter a name for the route."
        case .store(let message): return "The route could not be saved: \(message)"
        }
    }
}

/// Extra details stored under the `planner` key of the route's `AutoRouteInfo` JSON. `AutoRouteInfo` ignores
/// unknown keys, so older readers still load the route.
public struct AutoRoutePlannerRecord: Sendable, Equatable, Codable {
    public var packRegionID: String
    public var packTitle: String
    public var startName: String
    public var goalName: String
    public var startSnapMeters: Double
    public var goalSnapMeters: Double
    public var avoidOpenGulf: Bool
    public var greenLegs: Int
    public var yellowLegs: Int
    /// Names of bridges that must open ("" for unnamed ones).
    public var bridgeOpenings: [String]
    public var unknownClearances: [String]
    public var shallowestLatitude: Double
    public var shallowestLongitude: Double
    public var cruisingSpeedMetersPerSecond: Double?
    public var noticeVersion: Int
}

/// `AutoRouteInfo` plus the planner record, encoded into one JSON object.
struct StoredAutoRoute: Encodable {
    var info: AutoRouteInfo
    var planner: AutoRoutePlannerRecord

    enum Keys: String, CodingKey { case planner }

    func encode(to encoder: any Encoder) throws {
        try info.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(planner, forKey: .planner)
    }
}

private struct PlannerRecordBox: Decodable {
    var planner: AutoRoutePlannerRecord?
}

/// Converting a proposal into Persistence's `Route` with `AutoRouteInfo`, and saving it.
public enum AutoRouteSaving {
    /// "Marina Jack to Roberts Bay".
    public static func suggestedName(start: AutoRouteEndpoint, goal: AutoRouteEndpoint) -> String {
        func short(_ e: AutoRouteEndpoint) -> String {
            switch e.kind {
            case .boat: return "Boat position"
            case .waypoint: return e.name
            case .chartPoint: return CoordinateFormat.ddm(e.coordinate, fractionDigits: 2)
            }
        }
        return "\(short(start)) to \(short(goal))"
    }

    /// The `AutoRouteInfo` for a proposal (per-leg grades and reasons, summary, boat snapshot, pack date/version).
    public static func autoRouteInfo(_ proposal: AutoRouteProposal) -> AutoRouteInfo {
        let s: RouteSummary = proposal.result.summary
        let summary = AutoRouteInfo.Summary(
            distanceMeters: s.distanceMeters, shallowestDepthMeters: Double(s.shallowest.depthDm) / 10,
            lowestClearanceMeters: s.lowestClearance.map { Double($0.clearanceDm) / 10 },
            worstGrade: LegGrade(rawValue: proposal.result.worstGrade.rawValue))
        return AutoRouteInfo(boat: proposal.boat.snapshot, legs: proposal.storedLegs, summary: summary,
                             routingPackDataDate: proposal.result.dataDate.date ?? proposal.pack.dataDate,
                             routingPackVersion: proposal.pack.version, generatedAt: proposal.generatedAt)
    }

    public static func plannerRecord(_ proposal: AutoRouteProposal) -> AutoRoutePlannerRecord {
        let s: RouteSummary = proposal.result.summary
        let shallow: Coordinate = s.shallowest.centroid.coordinate
        return AutoRoutePlannerRecord(
            packRegionID: proposal.pack.packRegionID, packTitle: proposal.pack.title,
            startName: proposal.request.start.name, goalName: proposal.request.goal.name,
            startSnapMeters: proposal.result.start.snapMeters, goalSnapMeters: proposal.result.goal.snapMeters,
            avoidOpenGulf: proposal.boat.avoidOpenGulf, greenLegs: s.greenLegs, yellowLegs: s.yellowLegs,
            bridgeOpenings: s.openings.map(\.name), unknownClearances: s.unknownClearances.map(\.name),
            shallowestLatitude: shallow.latitude, shallowestLongitude: shallow.longitude,
            cruisingSpeedMetersPerSecond: proposal.boat.cruisingSpeed?.metersPerSecond,
            noticeVersion: AutoRouteNotice.version)
    }

    /// The planner record of a saved auto-route, if it has one.
    public static func plannerRecord(of route: Route) -> AutoRoutePlannerRecord? {
        guard let metadata = route.metadata, metadata.version == AutoRouteInfo.formatVersion else { return nil }
        return (try? metadata.decode(PlannerRecordBox.self))?.planner
    }

    /// Route notes: what the route is and what to check.
    public static func notes(_ proposal: AutoRouteProposal, units: UnitPreferences) -> String {
        var lines: [String] = ["Auto-route suggestion from Gulf Nav. Review every leg before use; depths are charted at chart datum with no tide allowance."]
        for line in proposal.summary where ["distance", "legs", "shallowest", "clearance", "openings", "unknownClearance", "data", "boat"].contains(line.id) {
            lines.append("\(line.label): \(line.value)")
        }
        return lines.joined(separator: "\n")
    }

    /// The route to store: one point per RoutingKit waypoint (start and end named), leg `i` from point `i`.
    public static func route(_ proposal: AutoRouteProposal, name: String, units: UnitPreferences = UnitPreferences(),
                             id: UUID = UUID(), now: Date = Date()) throws -> Route {
        let waypoints: [Coordinate] = proposal.result.waypoints
        var points: [RoutePoint] = []
        for (i, c) in waypoints.enumerated() {
            var pointName: String? = nil
            if i == 0 { pointName = proposal.request.start.name }
            if i == waypoints.count - 1 && i > 0 { pointName = proposal.request.goal.name }
            points.append(RoutePoint(coordinate: c, name: pointName))
        }
        let stored = StoredAutoRoute(info: autoRouteInfo(proposal), planner: plannerRecord(proposal))
        let metadata = try RouteMetadata(version: AutoRouteInfo.formatVersion, encoding: stored)
        return Route(id: id, name: name, notes: notes(proposal, units: units), points: points, metadata: metadata,
                     createdAt: now)
    }

    /// Applies the safety rules: throws unless the route may be saved/followed with the given confirmation.
    public static func checkAllowed(_ proposal: AutoRouteProposal, cautionConfirmed: Bool) throws(AutoRouteSaveError) {
        // Re-evaluated from the stored legs, so a proposal edited after it was built cannot slip through.
        let decision: AutoRouteSafety.Decision = AutoRouteSafety.decide(legs: proposal.storedLegs)
        switch decision {
        case .allowed:
            return
        case .refused(let reason):
            throw .refused(reason)
        case .needsConfirmation(let c):
            if !cautionConfirmed { throw .confirmationRequired(c) }
        }
    }

    /// Saves the proposal as a route in `store`, after the safety rules. `cautionConfirmed` must be true when the
    /// route has yellow legs (the user accepted ``AutoRouteSafety/Decision/needsConfirmation(_:)``).
    @discardableResult
    public static func save(_ proposal: AutoRouteProposal, name: String, cautionConfirmed: Bool, store: PersistenceStore,
                            units: UnitPreferences = UnitPreferences(), now: Date = Date()) async throws(AutoRouteSaveError) -> Route {
        try checkAllowed(proposal, cautionConfirmed: cautionConfirmed)
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw .emptyName }
        let route: Route
        do {
            route = try AutoRouteSaving.route(proposal, name: trimmed, units: units, now: now)
        } catch {
            throw .store("could not encode the route details (\(error))")
        }
        do {
            return try await store.save(route)
        } catch {
            throw .store(String(describing: error))
        }
    }
}
