import Foundation
import NavCore
import Persistence

/// What the map shows of the auto-route planner: the planned (unsaved) route's legs in grade colours, or the
/// blocked places of a failed plan.
public struct PlannedRouteLayer: Sendable, Equatable {
    public struct Leg: Sendable, Equatable {
        public var index: Int
        public var from: Coordinate
        public var to: Coordinate
        /// `green` / `yellow` (any other grade string is drawn red).
        public var grade: String

        public init(index: Int, from: Coordinate, to: Coordinate, grade: String) {
            self.index = index
            self.from = from
            self.to = to
            self.grade = grade
        }
    }

    public struct Blocked: Sendable, Equatable {
        public var coordinate: Coordinate
        public var reasonCode: String

        public init(coordinate: Coordinate, reasonCode: String) {
            self.coordinate = coordinate
            self.reasonCode = reasonCode
        }
    }

    public var legs: [Leg]
    public var blocked: [Blocked]

    public init(legs: [Leg] = [], blocked: [Blocked] = []) {
        self.legs = legs
        self.blocked = blocked
    }

    public static let empty: PlannedRouteLayer = PlannedRouteLayer()

    /// The layer for a plan outcome: the legs of a proposal, the blocked places of a no-route answer, nothing
    /// otherwise.
    public init(outcome: AutoRoutePlanOutcome?) {
        switch outcome {
        case .proposal(let p):
            self.init(legs: p.legs.map { Leg(index: $0.index, from: $0.from, to: $0.to, grade: $0.grade.rawValue) })
        case .noRoute(let n):
            self.init(blocked: n.blocked.map { Blocked(coordinate: $0.coordinate, reasonCode: $0.reason.code) })
        default:
            self.init()
        }
    }

    /// Every coordinate worth framing on the map (route points, or blocked places plus both ends).
    public static func focusCoordinates(_ outcome: AutoRoutePlanOutcome?) -> [Coordinate] {
        switch outcome {
        case .proposal(let p):
            return p.points
        case .noRoute(let n):
            return [n.request.start.coordinate, n.request.goal.coordinate] + n.blocked.map(\.coordinate)
        case .snapFailed(let s):
            return [s.requested]
        default:
            return []
        }
    }
}

/// A camera position that frames some coordinates.
public struct MapFocus: Sendable, Equatable {
    public var center: Coordinate
    public var zoom: Double

    public init(center: Coordinate, zoom: Double) {
        self.center = center
        self.zoom = zoom
    }

    /// Centre of the bounding box and a Web Mercator zoom at which it fits about `viewportPoints` wide/high
    /// (256-point tiles), clamped to 4...15. Nil for no valid coordinate.
    public static func framing(_ coordinates: [Coordinate], viewportPoints: Double = 320) -> MapFocus? {
        let valid: [Coordinate] = coordinates.filter(\.isValid)
        guard let first = valid.first else { return nil }
        var south: Double = first.latitude, north: Double = first.latitude
        var west: Double = first.longitude, east: Double = first.longitude
        for c in valid {
            south = min(south, c.latitude)
            north = max(north, c.latitude)
            west = min(west, c.longitude)
            east = max(east, c.longitude)
        }
        let center = Coordinate(latitude: (south + north) / 2, longitude: (west + east) / 2)
        let lonSpan: Double = max(east - west, 1e-6)
        let latSpan: Double = max((north - south) / max(cos(center.latitude * Double.pi / 180), 0.1), 1e-6)
        let span: Double = max(lonSpan, latSpan) * 1.3
        // At zoom z the world (360°) is 256·2^z points wide.
        let zoom: Double = log2(360 * viewportPoints / (256 * span))
        return MapFocus(center: center, zoom: min(max(zoom, 4), 15))
    }
}

/// The "Route check" lines of a saved auto-route (Routes screen): from its `AutoRouteInfo`, plus the planner
/// record when the route was saved by this planner.
public enum RouteCheckPresentation {
    public static func lines(_ route: Route, units: UnitPreferences, now: Date = Date()) -> [AutoRouteSummaryLine] {
        guard let info = route.metadata?.autoRouteInfo else { return [] }
        let record: AutoRoutePlannerRecord? = AutoRouteSaving.plannerRecord(of: route)
        var out: [AutoRouteSummaryLine] = []
        if let distance = info.summary.distanceMeters {
            out.append(AutoRouteSummaryLine(id: "distance", label: "Distance", value: NavFormat.distance(distance, unit: units.distance)))
        }
        let green: Int = info.legs.filter { $0.grade == .green }.count
        let yellow: Int = info.legs.filter { $0.grade == .yellow }.count
        let other: Int = info.legs.count - green - yellow
        var legs: String = "\(info.legs.count) \(info.legs.count == 1 ? "leg" : "legs"): \(green) green, \(yellow) yellow"
        if other > 0 { legs += ", \(other) other" }
        out.append(AutoRouteSummaryLine(id: "legs", label: "Legs", value: legs, isWarning: yellow + other > 0))
        if let depth = info.summary.shallowestDepthMeters {
            var value: String = NavFormat.depth(depth, unit: units.depth)
            if let record {
                value += " at " + NavFormat.position(Coordinate(latitude: record.shallowestLatitude, longitude: record.shallowestLongitude))
            }
            out.append(AutoRouteSummaryLine(id: "shallowest", label: "Shallowest charted depth", value: value))
        }
        if let clearance = info.summary.lowestClearanceMeters {
            out.append(AutoRouteSummaryLine(id: "clearance", label: "Lowest clearance", value: NavFormat.depth(clearance, unit: units.depth)))
        }
        if let record, !record.bridgeOpenings.isEmpty {
            let names: [String] = record.bridgeOpenings.map { $0.isEmpty ? "unnamed bridge" : $0 }
            out.append(AutoRouteSummaryLine(id: "openings", label: "Bridges that must open",
                                            value: "\(names.count): " + names.joined(separator: "; "), isWarning: true))
        }
        if let worst = info.summary.worstGrade {
            out.append(AutoRouteSummaryLine(id: "worst", label: "Worst leg", value: worst.rawValue, isWarning: worst != .green))
        }
        if let date = info.routingPackDataDate {
            out.append(AutoRoutePresenter.dataLine(date, now: now))
        }
        let boat: AutoRouteInfo.BoatSnapshot = info.boat
        var boatText: String = boat.name + ": draft " + NavFormat.depth(boat.draftMeters, unit: units.depth) + " + "
            + NavFormat.depth(boat.safetyMarginMeters, unit: units.depth) + " margin"
        if let air = boat.airDraftMeters { boatText += ", air draft " + NavFormat.depth(air, unit: units.depth) }
        out.append(AutoRouteSummaryLine(id: "boat", label: "Planned for", value: boatText))
        return out
    }

    /// Reason titles of one stored leg ("Maintained channel depth, Bridge must open").
    public static func reasonText(_ codes: [String]) -> String {
        codes.map { AutoRouteReason.caution($0).title }.joined(separator: ", ")
    }
}

/// The routing test pack the UI tests install (`testdata/routing/sarasota.pack`, a 216 KB cut of the pilot
/// pack around Sarasota), bundled into debug builds only, plus waypoints at points taken from
/// `sarasota.vectors.json` and a simulated GPS run inside its area (`LaunchConfiguration.preinstallFixtureRouting`).
public enum FixtureRoutingPack {
    public static let resourceName: String = "sarasota"
    public static let resourceExtension: String = "pack"
    /// `region_id` in the pack header.
    public static let packRegionID: String = "pilot-sarasota"

    /// Waypoints for the UI tests: q1 (Longboat → Marina Jack, 28 green legs) and q4/q3 (Marina Jack → Roberts
    /// Bay: no route under charted depth, hint "use maintained channels"; with it, 55 legs, 16 yellow).
    public static let waypoints: [(name: String, coordinate: Coordinate)] = [
        ("RT Longboat", Coordinate(latitude: 27.403, longitude: -82.603)),
        ("RT Marina Jack", Coordinate(latitude: 27.333, longitude: -82.5465)),
        ("RT Roberts Bay", Coordinate(latitude: 27.262, longitude: -82.539)),
    ]

    /// A run down Sarasota Bay on the q1 route (navigable water inside the pack), for the simulated GPS.
    public static let simulatedTrack: [Coordinate] = [
        Coordinate(latitude: 27.3946806, longitude: -82.6),
        Coordinate(latitude: 27.3750791, longitude: -82.5844722),
        Coordinate(latitude: 27.3633235, longitude: -82.575),
        Coordinate(latitude: 27.3471792, longitude: -82.5613181),
    ]

    public static func bundledFile(in bundle: Bundle) -> URL? {
        bundle.url(forResource: resourceName, withExtension: resourceExtension)
    }

    /// Side-loads the pack (unless a pack with its region id is already there) and adds the waypoints that are
    /// missing by name. Returns problems for a banner (empty when all went well).
    public static func install(packFile: URL?, library: RoutingPackLibrary, store: PersistenceStore) async -> [String] {
        var problems: [String] = []
        let catalog: RoutingPackCatalog = await library.catalog()
        if !catalog.entries.contains(where: { $0.packRegionID == packRegionID }) {
            if let packFile {
                let result: Result<Void, any Error> = await Task.detached(priority: .userInitiated) { () -> Result<Void, any Error> in
                    do {
                        _ = try library.sideLoad(from: packFile)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }.value
                if case .failure(let error) = result {
                    problems.append("Test routing pack could not be installed: \(error)")
                }
            } else {
                problems.append("Test routing pack is not in this build.")
            }
        }
        do {
            let existing: Set<String> = Set(try await store.waypoints().map(\.name))
            for seed in waypoints where !existing.contains(seed.name) {
                _ = try await store.save(Waypoint(name: seed.name, coordinate: seed.coordinate))
            }
        } catch {
            problems.append("Test waypoints could not be added: \(error)")
        }
        return problems
    }
}
