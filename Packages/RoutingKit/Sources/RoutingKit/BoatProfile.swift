import Foundation
import NavCore

/// The boat and the skipper's routing options (spec B.2).
///
/// Dimensions are in feet because charts are compiled in feet and the spec's threshold rule rounds the
/// requirement up to whole feet (``requiredDepthDm``). Use ``init(draft:safetyMargin:airDraft:...)`` to
/// build one from NavCore ``Distance`` values.
public struct BoatProfile: Hashable, Sendable, Codable {
    /// Draft, feet.
    public var draftFeet: Double
    /// Safety margin under the keel, feet.
    public var safetyMarginFeet: Double
    /// Height above the waterline, feet.
    public var airDraftFeet: Double
    /// Allow USACE maintained (project) depth where the chart is shallower ("use maintained channels").
    /// Such legs are always yellow (`MAINTAINED_DEPTH`).
    public var useMaintainedChannels: Bool
    /// Allow passing under overhead objects of unknown clearance (yellow `UNKNOWN_CLEARANCE`).
    public var acceptUnknownClearance: Bool
    /// Inside route only: open-Gulf triangles are impassable.
    public var avoidOpenGulf: Bool

    public init(draftFeet: Double, safetyMarginFeet: Double, airDraftFeet: Double,
                useMaintainedChannels: Bool = false, acceptUnknownClearance: Bool = false, avoidOpenGulf: Bool = false) {
        self.draftFeet = draftFeet
        self.safetyMarginFeet = safetyMarginFeet
        self.airDraftFeet = airDraftFeet
        self.useMaintainedChannels = useMaintainedChannels
        self.acceptUnknownClearance = acceptUnknownClearance
        self.avoidOpenGulf = avoidOpenGulf
    }

    /// Creates a profile from NavCore distances (converted to feet).
    public init(draft: Distance, safetyMargin: Distance, airDraft: Distance,
                useMaintainedChannels: Bool = false, acceptUnknownClearance: Bool = false, avoidOpenGulf: Bool = false) {
        self.init(draftFeet: draft.feet, safetyMarginFeet: safetyMargin.feet, airDraftFeet: airDraft.feet,
                  useMaintainedChannels: useMaintainedChannels, acceptUnknownClearance: acceptUnknownClearance,
                  avoidOpenGulf: avoidOpenGulf)
    }

    /// True when every dimension is finite, non-negative and below 1000 ft.
    public var isValid: Bool {
        [draftFeet, safetyMarginFeet, airDraftFeet].allSatisfy { $0.isFinite && $0 >= 0 && $0 < 1000 }
            && (draftFeet + safetyMarginFeet) < 1000
    }

    /// Required charted depth in dm: `req_dm(draft + margin)` (spec B.2).
    public var requiredDepthDm: Int { Self.requirementDm(feet: draftFeet + safetyMarginFeet) }

    /// Required vertical clearance in dm: `req_dm(air_draft)` (spec B.2).
    public var requiredAirDm: Int { Self.requirementDm(feet: airDraftFeet) }

    /// Spec B.2: `floor(ceil(f − 1e-9) · 3048 / 1000)`. Rounds up to whole feet, then converts as NOAA does.
    /// Callers must pass a finite value below 1000 ft (see ``isValid``); others are clamped.
    public static func requirementDm(feet: Double) -> Int {
        let f = feet - 1e-9
        guard f.isFinite else { return 0 }
        let whole = Int(min(max(f.rounded(.up), -1e6), 1e6))
        return Int(floorDiv(Int64(whole) * 3048, 1000))
    }

    /// The same profile with one option changed.
    func with(useMaintained: Bool? = nil, acceptUnknown: Bool? = nil) -> BoatProfile {
        var p = self
        if let useMaintained { p.useMaintainedChannels = useMaintained }
        if let acceptUnknown { p.acceptUnknownClearance = acceptUnknown }
        return p
    }
}

/// One routing query.
public struct RouteRequest: Hashable, Sendable {
    public var start: Coordinate
    public var goal: Coordinate
    public var profile: BoatProfile
    /// Largest distance an endpoint may be moved onto passable water (spec B.6, default 750 m).
    public var maxSnapMeters: Double
    /// Optional limit on wall-clock time for the whole query; exceeded → ``RoutingError/timedOut(expanded:)``.
    public var timeLimit: Duration?

    public init(start: Coordinate, goal: Coordinate, profile: BoatProfile, maxSnapMeters: Double = 750,
                timeLimit: Duration? = nil) {
        self.start = start
        self.goal = goal
        self.profile = profile
        self.maxSnapMeters = maxSnapMeters
        self.timeLimit = timeLimit
    }
}

/// Progress reported while a query runs (from the routing thread; keep the handler cheap).
public struct RoutingProgress: Hashable, Sendable {
    public enum Phase: String, Hashable, Sendable {
        /// The main A* search (B.7).
        case search
        /// The relaxed search that explains a failure (B.11).
        case noRouteReport
        /// The option-hint searches (B.11 hints).
        case hints
    }

    public var phase: Phase
    /// Triangles closed so far in this phase.
    public var expanded: Int
    /// Wall-clock time since the query started.
    public var elapsed: Duration
}
