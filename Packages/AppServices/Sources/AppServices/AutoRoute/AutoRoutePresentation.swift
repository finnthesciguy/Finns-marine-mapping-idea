import Foundation
import NavCore
import Persistence
import RoutingKit

// MARK: - Request

/// One end of a plan, as the user chose it.
public struct AutoRouteEndpoint: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The boat's position when Plan was pressed.
        case boat
        case waypoint
        /// A point picked on the chart.
        case chartPoint
    }

    public var kind: Kind
    public var coordinate: Coordinate
    /// "Boat position", the waypoint's name, or "Chart point".
    public var name: String
    public var waypointID: UUID?

    public init(kind: Kind, coordinate: Coordinate, name: String, waypointID: UUID? = nil) {
        self.kind = kind
        self.coordinate = coordinate
        self.name = name
        self.waypointID = waypointID
    }

    public static func boat(_ coordinate: Coordinate) -> AutoRouteEndpoint {
        AutoRouteEndpoint(kind: .boat, coordinate: coordinate, name: "Boat position")
    }

    public static func waypoint(_ waypoint: Waypoint) -> AutoRouteEndpoint {
        AutoRouteEndpoint(kind: .waypoint, coordinate: waypoint.coordinate, name: waypoint.name, waypointID: waypoint.id)
    }

    public static func chartPoint(_ coordinate: Coordinate) -> AutoRouteEndpoint {
        AutoRouteEndpoint(kind: .chartPoint, coordinate: coordinate, name: "Chart point " + CoordinateFormat.ddm(coordinate, fractionDigits: 2))
    }
}

/// Everything one plan needs.
public struct AutoRoutePlanRequest: Sendable, Equatable {
    public var start: AutoRouteEndpoint
    public var goal: AutoRouteEndpoint
    public var profile: Persistence.BoatProfile
    public var options: AutoRouteOptions

    public init(start: AutoRouteEndpoint, goal: AutoRouteEndpoint, profile: Persistence.BoatProfile,
                options: AutoRouteOptions = AutoRouteOptions()) {
        self.start = start
        self.goal = goal
        self.profile = profile
        self.options = options
    }
}

// MARK: - Reasons

/// A reason code (RoutingKit's caution or block reason) in words.
public struct AutoRouteReason: Sendable, Equatable {
    /// The spec name, e.g. `MAINTAINED_DEPTH`.
    public var code: String
    public var title: String
    public var detail: String

    public init(code: String, title: String, detail: String) {
        self.code = code
        self.title = title
        self.detail = detail
    }

    /// Why a leg is yellow (RoutingKit `CautionReason`, stored in `AutoRouteInfo.Leg.reasonCodes`).
    public static func caution(_ code: String) -> AutoRouteReason {
        switch code {
        case CautionReason.maintainedDepth.rawValue:
            return AutoRouteReason(code: code, title: "Maintained channel depth",
                                   detail: "The chart shows less water than your boat needs here. This leg relies on the Army Corps maintained (project) depth of the channel. Channels shoal between dredgings: check recent surveys and local notices.")
        case CautionReason.soundingDepth.rawValue:
            return AutoRouteReason(code: code, title: "Relies on spot soundings",
                                   detail: "The charted depth area is too shallow for your boat; individual soundings show enough water. Stay on the line and watch the depth sounder.")
        case CautionReason.bridgeOpening.rawValue:
            return AutoRouteReason(code: code, title: "Bridge must open",
                                   detail: "A bridge on this leg is lower than your air draft when closed. Check its opening schedule and call the bridge tender before you arrive.")
        case CautionReason.unknownClearance.rawValue:
            return AutoRouteReason(code: code, title: "Clearance not charted",
                                   detail: "This leg passes under a bridge or cable whose clearance is not on the chart. Find out the clearance before you go under.")
        case CautionReason.restrictedArea.rawValue:
            return AutoRouteReason(code: code, title: "Restricted area",
                                   detail: "This leg crosses a regulated area (for example a speed, no-wake or protected zone). Check the rules that apply.")
        case CautionReason.cautionArea.rawValue:
            return AutoRouteReason(code: code, title: "Caution area",
                                   detail: "This leg crosses an area the chart marks for caution. Read the chart note.")
        case CautionReason.hazardProximity.rawValue:
            return AutoRouteReason(code: code, title: "Near a charted hazard",
                                   detail: "This leg passes close to a charted obstruction, wreck or rock. Keep a lookout and stay on the line.")
        case CautionReason.lowDataQuality.rawValue:
            return AutoRouteReason(code: code, title: "Poor survey data",
                                   detail: "The survey data here is old, of low quality or unassessed. Real depths may differ from the chart.")
        case CautionReason.thinMargin.rawValue:
            return AutoRouteReason(code: code, title: "Little water to spare",
                                   detail: "Less than 1 ft (0.3 m) of water beyond your required depth, on poorly surveyed data.")
        default:
            return AutoRouteReason(code: code, title: "Check this leg (\(code))",
                                   detail: "This leg was marked for caution for a reason this version of Gulf Nav does not describe (\(code)). Check it carefully.")
        }
    }

    /// Why a place blocks the route (RoutingKit `BlockReason`).
    public static func block(_ reason: BlockReason) -> AutoRouteReason {
        switch reason {
        case .depth:
            return AutoRouteReason(code: reason.rawValue, title: "Too shallow", detail: "The charted depth is less than your boat needs.")
        case .clearance:
            return AutoRouteReason(code: reason.rawValue, title: "Too low", detail: "A bridge or cable is lower than your air draft.")
        case .unknownClearance:
            return AutoRouteReason(code: reason.rawValue, title: "Clearance not charted",
                                   detail: "A bridge or cable here has no charted clearance.")
        case .prohibited:
            return AutoRouteReason(code: reason.rawValue, title: "Entry prohibited", detail: "The chart marks this area as entry prohibited.")
        case .openGulf:
            return AutoRouteReason(code: reason.rawValue, title: "Open Gulf",
                                   detail: "This is open-Gulf water, which \"Inside route only\" excludes.")
        }
    }
}

// MARK: - Success

/// One leg of a proposed route, ready to show.
public struct AutoRouteLegRow: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var from: Coordinate
    public var to: Coordinate
    public var grade: LegGrade
    public var reasons: [AutoRouteReason]
    public var lengthMeters: Double
    /// "Leg 3".
    public var title: String
    /// "0.52 nm · 214°T · least depth 7.2 ft".
    public var detail: String
    /// "Under Ringling Causeway Bridge A / SR 789 (65.0 ft)", one per overhead object.
    public var overheads: [String]
}

/// One line of the route summary card.
public struct AutoRouteSummaryLine: Sendable, Equatable, Identifiable {
    /// Stable key: `distance`, `time`, `legs`, `shallowest`, `clearance`, `openings`, `unknownClearance`,
    /// `startSnap`, `goalSnap`, `data`, `pack`, `boat`.
    public var id: String
    public var label: String
    public var value: String
    /// Shown highlighted (stale data, bridge openings, unknown clearances, large snaps).
    public var isWarning: Bool

    public init(id: String, label: String, value: String, isWarning: Bool = false) {
        self.id = id
        self.label = label
        self.value = value
        self.isWarning = isWarning
    }
}

/// A computed route waiting for the skipper's decision.
public struct AutoRouteProposal: Sendable, Equatable {
    public var request: AutoRoutePlanRequest
    public var boat: EffectiveBoat
    public var pack: RoutingPackEntry
    /// RoutingKit's result (the exact geometry, grades and summary).
    public var result: RouteResult
    public var legs: [AutoRouteLegRow]
    public var summary: [AutoRouteSummaryLine]
    /// The legs as they will be stored (`AutoRouteInfo.Leg`); the safety rules run over these.
    public var storedLegs: [AutoRouteInfo.Leg]
    public var greenLegs: Int
    public var yellowLegs: Int
    /// Whether the route may be saved or followed, and what must be confirmed first.
    public var safety: AutoRouteSafety.Decision
    public var generatedAt: Date

    public var points: [Coordinate] { result.waypoints }
    public var distanceMeters: Double { result.summary.distanceMeters }
    /// "Marina Jack to Roberts Bay".
    public var suggestedName: String { AutoRouteSaving.suggestedName(start: request.start, goal: request.goal) }
}

// MARK: - Failures

/// A place where the boat cannot go, for the map and the explanation.
public struct AutoRouteBlockedPlace: Sendable, Equatable, Identifiable {
    public var id: Int
    public var coordinate: Coordinate
    public var reason: AutoRouteReason
    /// "Too shallow: charted 0.0 ft, your boat needs 6.0 ft (maintained channel depth 8.9 ft)".
    public var description: String
}

/// An option change that would give a route, offered as a button. Never applied without the user's tap.
public struct AutoRouteHintAction: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case useMaintainedChannels
        case acceptUnknownClearance
    }

    public var id: String { kind.rawValue }
    public var kind: Kind
    /// Button title: "Allow maintained channels".
    public var title: String
    public var explanation: String

    public static func make(_ kind: Kind) -> AutoRouteHintAction {
        switch kind {
        case .useMaintainedChannels:
            return AutoRouteHintAction(kind: kind, title: "Allow maintained channels",
                                       explanation: "A route exists if legs may rely on the Army Corps maintained (project) depth where the chart shows less water. Those legs are yellow: maintained depth is not guaranteed and channels shoal between dredgings.")
        case .acceptUnknownClearance:
            return AutoRouteHintAction(kind: kind, title: "Accept unknown clearance",
                                       explanation: "A route exists if the boat may pass under bridges or cables whose clearance is not charted. Those legs are yellow: find out the clearance before you go under.")
        }
    }

    /// The options for a re-plan with this change (this plan only; the boat profile is not changed).
    public func apply(to options: AutoRouteOptions) -> AutoRouteOptions {
        var next: AutoRouteOptions = options
        switch kind {
        case .useMaintainedChannels: next.useMaintainedChannels = true
        case .acceptUnknownClearance: next.acceptUnknownClearance = true
        }
        return next
    }
}

/// No route exists for this boat.
public struct AutoRouteNoRoute: Sendable, Equatable {
    public var request: AutoRoutePlanRequest
    public var pack: RoutingPackEntry
    /// `DEPTH`, `CLEARANCE`, `UNKNOWN_CLEARANCE`, `PROHIBITED`, `OPEN_GULF` or `NOT_CONNECTED`.
    public var reasonCode: String
    public var title: String
    public var message: String
    public var blocked: [AutoRouteBlockedPlace]
    public var hints: [AutoRouteHintAction]
    /// Shown when no option change would help.
    public var noHintText: String?
}

/// An end point could not be placed on navigable water.
public struct AutoRouteSnapProblem: Sendable, Equatable {
    public enum End: String, Sendable, Equatable {
        case start, goal
    }

    public var end: End
    /// RoutingKit's code, e.g. `START_NO_WATER_NEARBY`.
    public var code: String
    public var title: String
    public var message: String
    /// Distance to the nearest water deep enough for the boat, when the router found one.
    public var nearestWaterMeters: Double?
    public var requested: Coordinate
}

/// Every other way a plan can end without a route.
public struct AutoRouteFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case noticeNotAcknowledged, invalidProfile, noPacksInstalled, notCovered, differentPacks, packUnreadable
        case invalidRequest, legValidation, cancelled, timedOut
    }

    public var kind: Kind
    public var title: String
    public var message: String
    public var details: [String]

    public init(kind: Kind, title: String, message: String, details: [String] = []) {
        self.kind = kind
        self.title = title
        self.message = message
        self.details = details
    }
}

/// What a plan produced.
public enum AutoRoutePlanOutcome: Sendable, Equatable {
    case proposal(AutoRouteProposal)
    case noRoute(AutoRouteNoRoute)
    case snapFailed(AutoRouteSnapProblem)
    case failed(AutoRouteFailure)

    /// `proposal`, `noRoute`, `snapFailed`, or the failure kind (for `app.status`).
    public var statusCode: String {
        switch self {
        case .proposal: return "proposal"
        case .noRoute: return "noRoute"
        case .snapFailed: return "snapFailed"
        case .failed(let f): return f.kind.rawValue
        }
    }

    public var proposal: AutoRouteProposal? {
        if case .proposal(let p) = self { return p }
        return nil
    }

    public var noRoute: AutoRouteNoRoute? {
        if case .noRoute(let n) = self { return n }
        return nil
    }
}

// MARK: - Building the presentation

/// Turns RoutingKit results and errors into the presentation types above. All wording lives here.
public enum AutoRoutePresenter {
    public struct Context: Sendable {
        public var request: AutoRoutePlanRequest
        public var boat: EffectiveBoat
        public var pack: RoutingPackEntry
        public var units: UnitPreferences
        public var now: Date

        public init(request: AutoRoutePlanRequest, boat: EffectiveBoat, pack: RoutingPackEntry, units: UnitPreferences, now: Date) {
            self.request = request
            self.boat = boat
            self.pack = pack
            self.units = units
            self.now = now
        }
    }

    /// Charts older than this are shown with a warning (same threshold as the chart-age badge).
    public static let staleDataDays: Int = 90
    /// End points moved further than this are highlighted.
    public static let largeSnapMeters: Double = 100

    // MARK: Success

    public static func proposal(_ result: RouteResult, context: Context) -> AutoRouteProposal {
        let units: UnitPreferences = context.units
        var rows: [AutoRouteLegRow] = []
        var stored: [AutoRouteInfo.Leg] = []
        for (i, leg) in result.legs.enumerated() {
            let grade: LegGrade = LegGrade(rawValue: leg.grade.rawValue)
            let codes: [String] = leg.reasons.map(\.rawValue)
            let leastDepth: Double = Double(leg.minDepthDm) / 10
            let fixedClearances: [Double] = leg.crossings
                .filter { !$0.isOpeningSpan && $0.clearanceDm < 0xFFFE }
                .map { Double($0.clearanceDm) / 10 }
            stored.append(AutoRouteInfo.Leg(index: i, grade: grade, reasonCodes: codes, leastDepthMeters: leastDepth,
                                            leastClearanceMeters: fixedClearances.min()))
            let bearing: Double = Geodesy.initialBearing(from: leg.fromCoordinate, to: leg.toCoordinate)
            let detail: String = NavFormat.distance(leg.lengthMeters, unit: units.distance) + " · "
                + NavFormat.bearing(bearing) + " · least depth " + NavFormat.depth(leastDepth, unit: units.depth)
            rows.append(AutoRouteLegRow(index: i, from: leg.fromCoordinate, to: leg.toCoordinate, grade: grade,
                                        reasons: codes.map(AutoRouteReason.caution), lengthMeters: leg.lengthMeters,
                                        title: "Leg \(i + 1)", detail: detail,
                                        overheads: leg.crossings.map { overheadText($0, units: units) }))
        }
        let summary: [AutoRouteSummaryLine] = summaryLines(result, context: context)
        let reasonsByCode: [String: String] = Dictionary(uniqueKeysWithValues: CautionReason.allCases.map {
            ($0.rawValue, AutoRouteReason.caution($0.rawValue).title)
        })
        let decision: AutoRouteSafety.Decision = AutoRouteSafety.decide(legs: stored, reasonTitles: reasonsByCode)
        return AutoRouteProposal(request: context.request, boat: context.boat, pack: context.pack, result: result,
                                 legs: rows, summary: summary, storedLegs: stored,
                                 greenLegs: result.summary.greenLegs, yellowLegs: result.summary.yellowLegs,
                                 safety: decision, generatedAt: context.now)
    }

    static func overheadText(_ crossing: OverheadCrossing, units: UnitPreferences) -> String {
        let name: String = crossing.name.isEmpty ? (crossing.isOpeningSpan ? "an opening bridge" : "a bridge or cable") : crossing.name
        let clearance: String = clearanceText(crossing.clearanceDm, units: units)
        if crossing.isOpeningSpan {
            let opens: String = (crossing.needsOpening ?? false) ? ", must open" : ", clears closed"
            return "Under \(name) (\(clearance) closed\(opens))"
        }
        return "Under \(name) (\(clearance))"
    }

    /// "65.0 ft", "not charted", "none".
    static func clearanceText(_ dm: Int, units: UnitPreferences) -> String {
        if dm == 0xFFFF { return "none" }
        if dm == 0xFFFE { return "clearance not charted" }
        return NavFormat.depth(Double(dm) / 10, unit: units.depth)
    }

    static func summaryLines(_ result: RouteResult, context: Context) -> [AutoRouteSummaryLine] {
        let units: UnitPreferences = context.units
        let s: RouteSummary = result.summary
        var lines: [AutoRouteSummaryLine] = []
        lines.append(AutoRouteSummaryLine(id: "distance", label: "Distance", value: NavFormat.distance(s.distanceMeters, unit: units.distance)))
        if let speed = context.boat.cruisingSpeed, let seconds = speed.timeToCover(s.distance) {
            lines.append(AutoRouteSummaryLine(id: "time", label: "Time at \(NavFormat.speed(speed.metersPerSecond, unit: units.speed))",
                                              value: NavFormat.duration(seconds)))
        } else {
            lines.append(AutoRouteSummaryLine(id: "time", label: "Time", value: "Set a cruising speed in the boat profile"))
        }
        let legWord: String = s.legCount == 1 ? "leg" : "legs"
        lines.append(AutoRouteSummaryLine(id: "legs", label: "Legs",
                                          value: "\(s.legCount) \(legWord): \(s.greenLegs) green, \(s.yellowLegs) yellow",
                                          isWarning: s.yellowLegs > 0))
        var shallow: String = NavFormat.depth(Double(s.shallowest.depthDm) / 10, unit: units.depth) + " at "
            + NavFormat.position(s.shallowest.centroid.coordinate)
        if s.shallowest.maintained { shallow += " (the route uses the maintained channel depth there)" }
        lines.append(AutoRouteSummaryLine(id: "shallowest", label: "Shallowest charted depth", value: shallow,
                                          isWarning: s.shallowest.maintained))
        if let low = s.lowestClearance {
            let name: String = low.name.isEmpty ? (low.opening ? "Unnamed opening bridge" : "Unnamed bridge or cable") : low.name
            var value: String = "\(name): \(clearanceText(low.clearanceDm, units: units))"
            if low.opening { value += " closed (opening bridge)" }
            lines.append(AutoRouteSummaryLine(id: "clearance", label: "Lowest overhead clearance", value: value))
        } else {
            lines.append(AutoRouteSummaryLine(id: "clearance", label: "Lowest overhead clearance", value: "No bridges or cables on the route"))
        }
        if s.openings.isEmpty {
            lines.append(AutoRouteSummaryLine(id: "openings", label: "Bridges that must open", value: "None"))
        } else {
            let names: [String] = s.openings.map { run in
                run.name.isEmpty ? "unnamed bridge at " + NavFormat.position(run.centroid.coordinate) : run.name
            }
            lines.append(AutoRouteSummaryLine(id: "openings", label: "Bridges that must open",
                                              value: "\(s.openings.count): " + names.joined(separator: "; "), isWarning: true))
        }
        if !s.unknownClearances.isEmpty {
            let names: [String] = s.unknownClearances.map { run in
                run.name.isEmpty ? "unnamed object at " + NavFormat.position(run.centroid.coordinate) : run.name
            }
            lines.append(AutoRouteSummaryLine(id: "unknownClearance", label: "Clearance not charted",
                                              value: "\(s.unknownClearances.count): " + names.joined(separator: "; "), isWarning: true))
        }
        lines.append(snapLine(id: "startSnap", label: "Start", meters: result.start.snapMeters, units: units))
        lines.append(snapLine(id: "goalSnap", label: "Destination", meters: result.goal.snapMeters, units: units))
        let date: Date? = result.dataDate.date ?? context.pack.dataDate
        lines.append(dataLine(date, now: context.now))
        lines.append(AutoRouteSummaryLine(id: "pack", label: "Routing pack", value: context.pack.descriptionLine))
        lines.append(AutoRouteSummaryLine(id: "boat", label: "Boat", value: boatText(context.boat, units: units)))
        return lines
    }

    static func snapLine(id: String, label: String, meters: Double, units: UnitPreferences) -> AutoRouteSummaryLine {
        if meters < 1 {
            return AutoRouteSummaryLine(id: id, label: label, value: "On the chosen point")
        }
        return AutoRouteSummaryLine(id: id, label: label,
                                    value: "Moved \(shortDistance(meters, unit: units.distance)) to navigable water",
                                    isWarning: meters > largeSnapMeters)
    }

    static func dataLine(_ date: Date?, now: Date) -> AutoRouteSummaryLine {
        guard let date else {
            return AutoRouteSummaryLine(id: "data", label: "Chart data", value: "Date unknown", isWarning: true)
        }
        let days: Int = ageInDays(of: date, now: now)
        return AutoRouteSummaryLine(id: "data", label: "Chart data",
                                    value: "\(DataDateFormat.string(date)) (\(ageText(days: days)))",
                                    isWarning: days > staleDataDays)
    }

    /// Whole days from `date` to `now` (0 when in the future).
    public static func ageInDays(of date: Date, now: Date) -> Int {
        let seconds: Double = now.timeIntervalSince(date)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds / 86_400).rounded(.down))
    }

    /// "today", "1 day old", "21 days old".
    public static func ageText(days: Int) -> String {
        if days <= 0 { return "today" }
        if days == 1 { return "1 day old" }
        return "\(days) days old"
    }

    /// Short distances: feet (or metres with kilometre units) below 1,000, else the distance unit.
    public static func shortDistance(_ meters: Double, unit: DistanceUnit) -> String {
        guard meters.isFinite, meters >= 0 else { return NavFormat.placeholder }
        switch unit {
        case .kilometers:
            if meters < 1000 { return "\(Int(meters.rounded())) m" }
        case .nauticalMiles, .statuteMiles:
            let feet: Double = meters / UnitConversion.metersPerFoot
            if feet < 1000 { return "\(Int(feet.rounded())) ft" }
        }
        return NavFormat.distance(meters, unit: unit)
    }

    /// "My boat: needs 6.0 ft (draft 4.5 ft + 1.5 ft margin), air draft 20.0 ft; maintained channels allowed".
    public static func boatText(_ boat: EffectiveBoat, units: UnitPreferences) -> String {
        var text: String = "\(boat.name): needs \(NavFormat.depth(boat.requiredDepth.meters, unit: units.depth)) (draft "
            + NavFormat.depth(boat.draft.meters, unit: units.depth) + " + "
            + NavFormat.depth(boat.safetyMargin.meters, unit: units.depth) + " margin), air draft "
            + NavFormat.depth(boat.airDraft.meters, unit: units.depth)
        var options: [String] = []
        if boat.useMaintainedChannels { options.append("maintained channels allowed") }
        if boat.acceptUnknownClearance { options.append("unknown clearance accepted") }
        if boat.avoidOpenGulf { options.append("inside route only") }
        if !options.isEmpty { text += "; " + options.joined(separator: ", ") }
        return text
    }

    // MARK: Failures

    public static func outcome(for error: RoutingError, context: Context) -> AutoRoutePlanOutcome {
        switch error {
        case .noRoute(let report):
            return .noRoute(noRoute(report, context: context))
        case .snapFailed(let failure):
            return .snapFailed(snapProblem(failure, context: context))
        case .legValidation(let report):
            let count: Int = report.violations.count
            let noun: String = count == 1 ? "problem" : "problems"
            return .failed(AutoRouteFailure(
                kind: .legValidation, title: "Route failed its safety check",
                message: "The route the router found failed its final check against the charted hazards and bridges (\(count) \(noun)), so it is not shown. This points to a fault in the routing data. Plan between other points and please report it.",
                details: report.violations.map { "Leg \($0.leg + 1): \($0.kind.rawValue.lowercased().replacingOccurrences(of: "_", with: " "))" }))
        case .cancelled:
            return .failed(cancelled())
        case .timedOut:
            return .failed(timedOut(seconds: context.request.options.timeLimitSeconds))
        case .invalidRequest(let message):
            return .failed(AutoRouteFailure(kind: .invalidRequest, title: "Cannot plan with this boat",
                                            message: "The boat's dimensions cannot be used for routing (\(message)). Check the boat profile."))
        }
    }

    public static func cancelled() -> AutoRouteFailure {
        AutoRouteFailure(kind: .cancelled, title: "Planning cancelled", message: "Planning was cancelled. Nothing was changed.")
    }

    public static func timedOut(seconds: Double) -> AutoRouteFailure {
        AutoRouteFailure(kind: .timedOut, title: "Planning took too long",
                         message: "Planning stopped after \(Int(seconds.rounded())) seconds without an answer. Try a shorter trip, or plan it in parts.")
    }

    static func noRoute(_ report: NoRouteReport, context: Context) -> AutoRouteNoRoute {
        let units: UnitPreferences = context.units
        let boat: EffectiveBoat = context.boat
        let title: String
        let message: String
        switch report.reason {
        case .notConnected:
            title = "No water connection"
            message = "No route: the start and the destination are in separate stretches of water on the chart, with no connection between them for any boat."
        case .blocked(let reason):
            title = "No route for this boat"
            switch reason {
            case .depth:
                message = "No route for \(boat.name): the water is too shallow at the place marked on the chart. Your boat needs \(NavFormat.depth(boat.requiredDepth.meters, unit: units.depth)) of charted depth (draft plus safety margin)."
            case .clearance:
                message = "No route for \(boat.name): a bridge or cable is lower than your air draft of \(NavFormat.depth(boat.airDraft.meters, unit: units.depth)) at the place marked on the chart."
            case .unknownClearance:
                message = "No route for \(boat.name): every way passes under a bridge or cable whose clearance is not charted, at the place marked on the chart."
            case .prohibited:
                message = "No route for \(boat.name): every way passes through an area where entry is prohibited, at the place marked on the chart."
            case .openGulf:
                message = "No route for \(boat.name) inside: every way goes out into the open Gulf, and \"Inside route only\" is on."
            }
        }
        var places: [AutoRouteBlockedPlace] = []
        for place in report.blocked {
            places.append(AutoRouteBlockedPlace(id: place.corridorIndex, coordinate: place.coordinate,
                                                reason: AutoRouteReason.block(place.reason),
                                                description: blockedText(place, boat: boat, units: units)))
        }
        var hints: [AutoRouteHintAction] = []
        if report.hints.useMaintainedChannels == true { hints.append(.make(.useMaintainedChannels)) }
        if report.hints.acceptUnknownClearance == true { hints.append(.make(.acceptUnknownClearance)) }
        var noHint: String? = nil
        if hints.isEmpty {
            var off: [String] = []
            if report.hints.useMaintainedChannels != nil { off.append("\"use maintained channels\"") }
            if report.hints.acceptUnknownClearance != nil { off.append("\"accept unknown clearance\"") }
            if off.isEmpty {
                noHint = "No other setting would give a route for this boat."
            } else {
                noHint = "Turning on " + off.joined(separator: " or ") + " would not give a route either."
            }
        }
        return AutoRouteNoRoute(request: context.request, pack: context.pack, reasonCode: report.reason.code, title: title,
                                message: message, blocked: places, hints: hints, noHintText: noHint)
    }

    static func blockedText(_ place: BlockedPlace, boat: EffectiveBoat, units: UnitPreferences) -> String {
        let reason: AutoRouteReason = AutoRouteReason.block(place.reason)
        let at: String = " at " + NavFormat.position(place.coordinate)
        switch place.reason {
        case .depth:
            var text: String = "\(reason.title): charted \(NavFormat.depth(Double(place.depthDm) / 10, unit: units.depth)), your boat needs \(NavFormat.depth(boat.requiredDepth.meters, unit: units.depth))"
            if place.maintDm != Int(Int16.min) && place.maintDm > place.depthDm {
                text += " (maintained channel depth \(NavFormat.depth(Double(place.maintDm) / 10, unit: units.depth)))"
            }
            return text + at
        case .clearance:
            let name: String = place.overheadName.isEmpty ? "bridge or cable" : place.overheadName
            return "\(reason.title): \(name), clearance \(clearanceText(place.clearanceDm, units: units)), your air draft \(NavFormat.depth(boat.airDraft.meters, unit: units.depth))" + at
        case .unknownClearance:
            let name: String = place.overheadName.isEmpty ? "a bridge or cable" : place.overheadName
            return "\(reason.title): \(name)" + at
        case .prohibited:
            let name: String = place.areaName.isEmpty ? "" : ": " + place.areaName
            return reason.title + name + at
        case .openGulf:
            return reason.title + at
        }
    }

    static func snapProblem(_ failure: SnapFailure, context: Context) -> AutoRouteSnapProblem {
        let units: UnitPreferences = context.units
        let end: AutoRouteSnapProblem.End = failure.endpoint == .start ? .start : .goal
        let endpoint: AutoRouteEndpoint = end == .start ? context.request.start : context.request.goal
        let which: String = end == .start ? "start" : "destination"
        let Which: String = end == .start ? "Start" : "Destination"
        switch failure.kind {
        case .outsidePack:
            return AutoRouteSnapProblem(end: end, code: failure.code, title: "\(Which) outside the routing pack",
                                        message: "The \(which) (\(endpoint.name)) is outside the area of the routing pack \(context.pack.title).",
                                        nearestWaterMeters: nil, requested: endpoint.coordinate)
        case .noWaterNearby(_, let nearest):
            let radius: String = shortDistance(context.request.options.maxSnapMeters, unit: units.distance)
            var message: String = "The \(which) (\(endpoint.name)) is not on water deep enough for \(context.boat.name) (\(NavFormat.depth(context.boat.requiredDepth.meters, unit: units.depth))), and there is none within \(radius)."
            if let nearest, nearest.isFinite {
                message += " The nearest such water is \(shortDistance(nearest, unit: units.distance)) away."
            }
            message += " Choose a \(which) on open water."
            return AutoRouteSnapProblem(end: end, code: failure.code, title: "\(Which) not on navigable water", message: message,
                                        nearestWaterMeters: nearest, requested: endpoint.coordinate)
        }
    }

    // MARK: Before routing

    static func noticeNotAcknowledged() -> AutoRouteFailure {
        AutoRouteFailure(kind: .noticeNotAcknowledged, title: AutoRouteNotice.title,
                         message: "Read and acknowledge the auto-route notice before planning.", details: AutoRouteNotice.points)
    }

    static func invalidProfile(_ problems: [String], name: String) -> AutoRouteFailure {
        AutoRouteFailure(kind: .invalidProfile, title: "Boat profile incomplete",
                         message: "\(name) cannot be used for routing yet.", details: problems)
    }

    static func selectionFailure(_ selection: RoutingPackSelection, request: AutoRoutePlanRequest) -> AutoRouteFailure? {
        switch selection {
        case .pack:
            return nil
        case .noPacksInstalled:
            return AutoRouteFailure(kind: .noPacksInstalled, title: "No routing pack installed",
                                    message: "Auto-routing needs the routing pack of the chart region. Routing packs will download with chart regions once they are published; none is installed on this device.")
        case .notCovered(let start, let goal):
            let what: String
            if start && goal {
                what = "Neither the start (\(request.start.name)) nor the destination (\(request.goal.name)) is"
            } else if start {
                what = "The start (\(request.start.name)) is not"
            } else {
                what = "The destination (\(request.goal.name)) is not"
            }
            return AutoRouteFailure(kind: .notCovered, title: "Outside the routing packs",
                                    message: "\(what) inside an installed routing pack. Install the chart region that covers it.")
        case .differentPacks(let a, let b):
            return AutoRouteFailure(kind: .differentPacks, title: "Start and destination in different regions",
                                    message: "The start is in \(a.title) and the destination in \(b.title). Routes across regions are not supported yet: plan to a point inside one region first.")
        }
    }

    static func packUnreadable(_ entry: RoutingPackEntry, reason: String) -> AutoRouteFailure {
        AutoRouteFailure(kind: .packUnreadable, title: "Routing pack damaged",
                         message: "The routing pack \(entry.title) could not be opened, so no route can be planned with it. Delete the chart region and install it again.",
                         details: [reason])
    }
}
