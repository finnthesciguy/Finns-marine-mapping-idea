import Foundation
import NavCore

/// Why a triangle is impassable for the profile (spec B.3, codes 0..4 in precedence order).
public enum BlockReason: String, Hashable, Sendable, Codable, CaseIterable {
    case prohibited = "PROHIBITED"
    case openGulf = "OPEN_GULF"
    case depth = "DEPTH"
    case clearance = "CLEARANCE"
    case unknownClearance = "UNKNOWN_CLEARANCE"

    /// The spec's numeric code (0..4).
    public var code: Int {
        switch self {
        case .prohibited: return 0
        case .openGulf: return 1
        case .depth: return 2
        case .clearance: return 3
        case .unknownClearance: return 4
        }
    }
}

/// Why a leg is yellow (spec B.9), in report order.
public enum CautionReason: String, Hashable, Sendable, Codable, CaseIterable {
    /// Passable only thanks to USACE maintained depth.
    case maintainedDepth = "MAINTAINED_DEPTH"
    /// Passable only thanks to the sounding refinement.
    case soundingDepth = "SOUNDING_DEPTH"
    /// A bridge must open for the boat's air draft.
    case bridgeOpening = "BRIDGE_OPENING"
    /// Passes under an object of unknown clearance.
    case unknownClearance = "UNKNOWN_CLEARANCE"
    case restrictedArea = "RESTRICTED_AREA"
    case cautionArea = "CAUTION_AREA"
    /// Within the clearance zone of a hazard of known depth.
    case hazardProximity = "HAZARD_PROXIMITY"
    /// CATZOC unknown, D or U.
    case lowDataQuality = "LOW_DATA_QUALITY"
    /// Less than 3 dm spare depth on poor survey data.
    case thinMargin = "THIN_MARGIN"
}

/// Leg grade. A returned route never has a red leg (spec B.9): anything that would be red fails the query.
public enum RouteGrade: String, Hashable, Sendable, Codable {
    case green, yellow
}

/// A snapped route endpoint (spec B.6 / B.13 `start`, `goal`).
public struct SnappedEndpoint: Hashable, Sendable {
    /// The position the caller asked for.
    public var requested: Coordinate
    /// The point used for routing, in units.
    public var point: GridPoint
    /// The triangle the point lies in.
    public var triangle: Int
    /// Distance moved onto passable water, metres (unrounded; 0 when not moved).
    public var snapMeters: Double
    /// False when the requested point was not inside any mesh triangle (land, the clearance zone, tiny water).
    public var inMesh: Bool

    /// The point used for routing, degrees.
    public var coordinate: Coordinate { point.coordinate }
    /// `snap_m` as reported by the spec: rounded to 0.001 m, half-even.
    public var roundedSnapMeters: Double { (snapMeters * 1000).rounded(.toNearestOrEven) / 1000 }
}

/// An overhead object the leg passes under (spec B.10 `crossings`).
public struct OverheadCrossing: Hashable, Sendable {
    /// `OVHD` record index.
    public var record: Int
    public var clearanceDm: Int
    public var isOpeningSpan: Bool
    /// For an opening span: true when it must open for the boat (closed clearance unknown or below air draft).
    /// Nil for fixed objects.
    public var needsOpening: Bool?
    /// The object's name ("" if unnamed).
    public var name: String
}

/// One straight leg of a route.
public struct RouteLeg: Hashable, Sendable {
    public var from: GridPoint
    public var to: GridPoint
    /// Corridor positions `lo...hi` that the leg covers (spec B.8).
    public var corridorRange: ClosedRange<Int>
    /// `dist(A, B)` (spec B.1), metres.
    public var lengthMeters: Double
    public var grade: RouteGrade
    public var reasons: [CautionReason]
    /// Least charted depth over the leg's triangles, dm.
    public var minDepthDm: Int
    /// Least `depth − req` over triangles not relying on maintained depth, dm; nil if there are none.
    public var minSpareDm: Int?
    public var crossings: [OverheadCrossing]

    public var fromCoordinate: Coordinate { from.coordinate }
    public var toCoordinate: Coordinate { to.coordinate }
    /// Leg geometry as NavCore coordinates.
    public var geometry: [Coordinate] { [from.coordinate, to.coordinate] }
    public var length: Distance { Distance(meters: lengthMeters) }
}

/// The shallowest corridor triangle (spec B.12).
public struct ShallowestPoint: Hashable, Sendable {
    /// Charted depth (even where maintained depth was used), dm.
    public var depthDm: Int
    public var triangle: Int
    public var centroid: GridPoint
    /// Passable only thanks to maintained depth.
    public var maintained: Bool
}

/// The lowest known clearance along the corridor (spec B.12).
public struct LowestClearance: Hashable, Sendable {
    public var clearanceDm: Int
    /// `OVHD` record, or nil if the triangle names none.
    public var overhead: Int?
    public var name: String
    /// The triangle is under opening spans only (ATTR flag OPENING_BRIDGE).
    public var opening: Bool
}

/// A bridge that must open, or a run under unknown clearance (spec B.12 `openings`, `unknown_clearances`).
public struct OverheadRun: Hashable, Sendable {
    public var corridorIndex: Int
    public var overhead: Int?
    /// The triangle's `clearance_dm`.
    public var clearanceDm: Int
    public var name: String
    public var centroid: GridPoint
}

/// Whole-route summary (spec B.12).
public struct RouteSummary: Hashable, Sendable {
    public var distanceMeters: Double
    public var distanceNauticalMiles: Double { distanceMeters / 1852.0 }
    public var distance: Distance { Distance(meters: distanceMeters) }
    public var legCount: Int
    public var greenLegs: Int
    public var yellowLegs: Int
    public var shallowest: ShallowestPoint
    public var lowestClearance: LowestClearance?
    public var openings: [OverheadRun]
    public var unknownClearances: [OverheadRun]
    public var maintainedTriangles: Int
    public var dataDate: PackDate
}

/// A computed route (spec B.13 success object).
public struct RouteResult: Hashable, Sendable {
    public var profile: BoatProfile
    /// `req` (spec B.2), dm.
    public var requiredDepthDm: Int
    /// `air` (spec B.2), dm.
    public var requiredAirDm: Int
    public var start: SnappedEndpoint
    public var goal: SnappedEndpoint
    /// Triangles from start to goal (spec B.7).
    public var corridor: [Int]
    /// Waypoints in units: these are the exact, comparable result (spec D: `waypoints_units`).
    public var waypointsUnits: [GridPoint]
    public var legs: [RouteLeg]
    public var summary: RouteSummary
    /// Chart data date of the pack.
    public var dataDate: PackDate
    /// Region the route was computed on.
    public var regionID: String
    /// Triangles closed by the main search.
    public var expanded: Int

    /// Waypoints in degrees.
    public var waypoints: [Coordinate] { waypointsUnits.map(\.coordinate) }
    /// Overall grade: yellow if any leg is yellow.
    public var worstGrade: RouteGrade { legs.contains { $0.grade == .yellow } ? .yellow : .green }
    /// Every distinct caution reason over all legs, in spec order.
    public var allReasons: [CautionReason] {
        CautionReason.allCases.filter { r in legs.contains { $0.reasons.contains(r) } }
    }
}

// MARK: - Failures

/// Which endpoint a snap failure is about.
public enum RouteEndpoint: String, Hashable, Sendable {
    case start = "START"
    case goal = "GOAL"
}

/// Why an endpoint could not be placed on passable water (spec B.6).
public enum SnapFailureKind: Error, Hashable, Sendable {
    /// The point is outside the pack's bounding box (or not a valid coordinate).
    case outsidePack
    /// No passable triangle within `maxSnapMeters`. `locatedTriangle` is the (impassable) triangle containing
    /// the point, if any; `nearestMeters` the distance to the nearest passable triangle found, if any.
    case noWaterNearby(locatedTriangle: Int?, nearestMeters: Double?)

    public var code: String {
        switch self {
        case .outsidePack: return "OUTSIDE_PACK"
        case .noWaterNearby: return "NO_WATER_NEARBY"
        }
    }
}

/// A snap error, plus the start when it was the goal that failed.
public struct SnapFailure: Hashable, Sendable {
    public var endpoint: RouteEndpoint
    public var kind: SnapFailureKind
    /// The snapped start when the goal failed.
    public var start: SnappedEndpoint?
    /// `START_OUTSIDE_PACK`, `GOAL_NO_WATER_NEARBY`, ...
    public var code: String { "\(endpoint.rawValue)_\(kind.code)" }
}

/// A place where the cheapest almost-route is blocked (spec B.11 `blocked`).
public struct BlockedPlace: Hashable, Sendable {
    /// Position in the relaxed corridor.
    public var corridorIndex: Int
    /// First triangle of the blocked run.
    public var triangle: Int
    public var reason: BlockReason
    public var centroid: GridPoint
    public var depthDm: Int
    public var maintDm: Int
    public var clearanceDm: Int
    /// Name of the triangle's overhead object ("" if none).
    public var overheadName: String
    /// Name of the triangle's regulated area ("" if none).
    public var areaName: String

    public var coordinate: Coordinate { centroid.coordinate }
}

/// Why no route exists (spec B.11 `reason`).
public enum NoRouteReason: Hashable, Sendable {
    /// `blocked[0].reason`.
    case blocked(BlockReason)
    /// Start and goal are in disconnected water.
    case notConnected

    public var code: String {
        switch self {
        case .blocked(let r): return r.rawValue
        case .notConnected: return "NOT_CONNECTED"
        }
    }
}

/// Options that would make the route exist (spec B.11 `hints`). Nil = the option was already on.
public struct RouteHints: Hashable, Sendable {
    /// True if switching on "use maintained channels" alone would give a route.
    public var useMaintainedChannels: Bool?
    /// True if switching on "accept unknown clearance" alone would give a route.
    public var acceptUnknownClearance: Bool?
}

/// The no-route report (spec B.11).
public struct NoRouteReport: Hashable, Sendable {
    public var requiredDepthDm: Int
    public var requiredAirDm: Int
    public var start: SnappedEndpoint
    public var goal: SnappedEndpoint
    public var reason: NoRouteReason
    /// Blocked runs along the relaxed corridor, in order. `blocked.first` is the place to show the user.
    public var blocked: [BlockedPlace]
    public var hints: RouteHints
    public var dataDate: PackDate
}

/// A leg-validation violation (spec B.10). Indicates a builder or reader bug; never shown as a red leg.
public struct LegViolation: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case hazard = "HAZARD"
        case clearance = "CLEARANCE"
        case unknownClearance = "UNKNOWN_CLEARANCE"
    }

    public var kind: Kind
    public var leg: Int
    /// `HAZD` record for `.hazard`, else `OVHD` record.
    public var record: Int
    /// `.hazard`: distance from the leg, metres.
    public var distanceMeters: Double?
    /// `.hazard`: the hazard's VALSOU, dm.
    public var valsouDm: Int?
    /// `.clearance`: the object's clearance, dm.
    public var clearanceDm: Int?
}

/// The leg-validation failure report.
public struct LegValidationReport: Hashable, Sendable {
    public var violations: [LegViolation]
    public var corridor: [Int]
}

/// Every way a routing query can fail. `code` is the spec's B.13 error string where one exists.
public enum RoutingError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The request is unusable: non-finite, negative or absurd boat dimensions, or a bad snap radius.
    case invalidRequest(String)
    /// An endpoint could not be snapped (`START_OUTSIDE_PACK`, `GOAL_NO_WATER_NEARBY`, ...).
    case snapFailed(SnapFailure)
    /// No route for this boat (`NO_ROUTE`), with the blocking place and option hints.
    case noRoute(NoRouteReport)
    /// A leg failed validation against the hazard and overhead tables (`LEG_VALIDATION`).
    case legValidation(LegValidationReport)
    /// The calling task was cancelled.
    case cancelled
    /// ``RouteRequest/timeLimit`` was exceeded.
    case timedOut(expanded: Int)

    /// The spec's error string (`NO_ROUTE`, `START_OUTSIDE_PACK`, ...), or a RoutingKit one.
    public var code: String {
        switch self {
        case .invalidRequest: return "INVALID_REQUEST"
        case .snapFailed(let f): return f.code
        case .noRoute: return "NO_ROUTE"
        case .legValidation: return "LEG_VALIDATION"
        case .cancelled: return "CANCELLED"
        case .timedOut: return "TIMED_OUT"
        }
    }

    public var description: String {
        switch self {
        case .noRoute(let r): return "NO_ROUTE (\(r.reason.code))"
        default: return code
        }
    }
}
