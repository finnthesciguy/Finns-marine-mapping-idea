import Foundation
import NavCore
@testable import RoutingKit

/// Locations of the shared fixtures in `testdata/routing`, found relative to this file so the tests work
/// wherever the repository is checked out.
enum Fixtures {
    static let routingDir: URL = {
        let here = URL(fileURLWithPath: #filePath)
        // .../Packages/RoutingKit/Tests/RoutingKitTests/TestSupport.swift → repository root is 5 levels up.
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("testdata").appendingPathComponent("routing")
    }()

    static func url(_ name: String) -> URL { routingDir.appendingPathComponent(name) }

    static func bytes(_ name: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: url(name))) }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(type, from: Data(contentsOf: url(name)))
    }

    /// Loaded once per process.
    static let synthetic: RoutingPack = try! RoutingPack(contentsOf: url("synthetic.pack"))
    static let sarasota: RoutingPack = try! RoutingPack(contentsOf: url("sarasota.pack"))

    static func pack(named name: String) -> RoutingPack { name == "synthetic" ? synthetic : sarasota }
}

// MARK: - *.vectors.json

struct VectorFile: Decodable {
    var schema: String
    var pack: String
    var queries: [VectorQuery]
}

struct VectorProfile: Decodable {
    var draftFt: Double
    var marginFt: Double
    var airDraftFt: Double
    var useMaintained: Bool?
    var acceptUnknownClearance: Bool?
    var avoidOpenGulf: Bool?

    var boatProfile: BoatProfile {
        BoatProfile(draftFeet: draftFt, safetyMarginFeet: marginFt, airDraftFeet: airDraftFt,
                    useMaintainedChannels: useMaintained ?? false, acceptUnknownClearance: acceptUnknownClearance ?? false,
                    avoidOpenGulf: avoidOpenGulf ?? false)
    }
}

struct VectorQuery: Decodable {
    var id: String
    var start: [Double]
    var goal: [Double]
    var profile: VectorProfile
    var maxSnapM: Double
    var expected: VectorExpected

    var request: RouteRequest {
        RouteRequest(start: Coordinate(latitude: start[1], longitude: start[0]),
                     goal: Coordinate(latitude: goal[1], longitude: goal[0]),
                     profile: profile.boatProfile, maxSnapMeters: maxSnapM)
    }
}

struct VectorEndpoint: Decodable {
    var x: Int?
    var y: Int?
    var triangle: Int?
    var snapM: Double?
    var inMesh: Bool?
    var error: String?
    var located: Int?
    var nearestM: Double?
}

struct VectorViolation: Decodable {
    var kind: String
    var record: Int
    var leg: Int
    var distanceM: Double?
    var valsouDm: Int?
    var clearanceDm: Int?
}

struct VectorCrossing: Decodable {
    var record: Int
    var clearanceDm: Int
    var opening: Bool
    var needsOpening: Bool?
}

struct VectorLeg: Decodable {
    var triangles: [Int]
    var lengthM: Double
    var grade: String
    var reasons: [String]
    var minDepthDm: Int
    var minSpareDm: Int?
    var crossings: [VectorCrossing]
}

struct VectorShallowest: Decodable {
    var depthDm: Int
    var triangle: Int
    var lon: Double
    var lat: Double
    var maintained: Bool
}

struct VectorLowest: Decodable {
    var clearanceDm: Int
    var overhead: Int
    var name: String
    var opening: Bool
}

struct VectorRun: Decodable {
    var corridorIndex: Int
    var overhead: Int
    var clearanceDm: Int
    var name: String
    var lon: Double
    var lat: Double
}

struct VectorSummary: Decodable {
    var distanceM: Double
    var distanceNm: Double
    var legs: Int
    var greenLegs: Int
    var yellowLegs: Int
    var shallowest: VectorShallowest
    var lowestClearance: VectorLowest?
    var openings: [VectorRun]
    var unknownClearances: [VectorRun]
    var maintainedTriangles: Int
    var dataDate: Int
}

struct VectorBlocked: Decodable {
    var corridorIndex: Int
    var triangle: Int
    var reason: String
    var lon: Double
    var lat: Double
    var depthDm: Int
    var maintDm: Int
    var clearanceDm: Int
    var overhead: String
    var area: String
}

struct VectorExpected: Decodable {
    var ok: Bool
    var error: String?
    /// Absent for INVALID_REQUEST.
    var reqDm: Int?
    var airDm: Int?
    var start: VectorEndpoint?
    var goal: VectorEndpoint?
    var corridor: [Int]?
    var waypointsUnits: [[Int]]?
    var legs: [VectorLeg]?
    var summary: VectorSummary?
    var dataDate: Int
    var distanceM: Double?
    var reason: String?
    var blocked: [VectorBlocked]?
    var hints: [String: Bool]?
    var violations: [VectorViolation]?
}

// MARK: - Comparison (spec part D rules)

/// Collects human-readable mismatches between a RoutingKit outcome and an expected B.13 object.
struct VectorComparator {
    var mismatches: [String] = []
    let distanceTolerance = 1e-6
    let snapTolerance = 1e-3

    mutating func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { mismatches.append(what()) }
    }

    mutating func int(_ got: Int, _ want: Int, _ field: String) {
        check(got == want, "\(field): got \(got), want \(want)")
    }

    mutating func intOpt(_ got: Int?, _ want: Int?, _ field: String) {
        check(got == want, "\(field): got \(String(describing: got)), want \(String(describing: want))")
    }

    mutating func double(_ got: Double, _ want: Double, _ tol: Double, _ field: String) {
        check(abs(got - want) <= tol, "\(field): got \(got), want \(want)")
    }

    mutating func degrees(_ p: GridPoint, _ lon: Double, _ lat: Double, _ field: String) {
        let c = p.coordinate
        check(c.longitude == lon && c.latitude == lat, "\(field): got \(c.longitude),\(c.latitude), want \(lon),\(lat)")
    }

    mutating func endpoint(_ got: SnappedEndpoint, _ want: VectorEndpoint?, _ field: String) {
        guard let want else { return check(false, "\(field): expected object missing") }
        intOpt(Int(got.point.x), want.x, "\(field).x")
        intOpt(Int(got.point.y), want.y, "\(field).y")
        intOpt(got.triangle, want.triangle, "\(field).triangle")
        check(got.inMesh == want.inMesh, "\(field).in_mesh: got \(got.inMesh)")
        double(got.snapMeters, want.snapM ?? .nan, snapTolerance, "\(field).snap_m")
    }

    mutating func route(_ r: RouteResult, _ e: VectorExpected) {
        check(e.ok, "got a route, expected error \(e.error ?? "?")")
        guard e.ok else { return }
        intOpt(r.requiredDepthDm, e.reqDm, "req_dm")
        intOpt(r.requiredAirDm, e.airDm, "air_dm")
        int(Int(r.dataDate.rawValue), e.dataDate, "data_date")
        endpoint(r.start, e.start, "start")
        endpoint(r.goal, e.goal, "goal")
        check(r.corridor == (e.corridor ?? []), "corridor differs (got \(r.corridor.count), want \(e.corridor?.count ?? 0))")
        let wpts: [[Int]] = r.waypointsUnits.map { [Int($0.x), Int($0.y)] }
        check(wpts == (e.waypointsUnits ?? []), "waypoints_units differ: got \(wpts.count) points, want \(e.waypointsUnits?.count ?? 0)")
        let legs = e.legs ?? []
        int(r.legs.count, legs.count, "legs.count")
        for (i, pair) in zip(r.legs, legs).enumerated() {
            leg(pair.0, pair.1, "legs[\(i)]")
        }
        if let s = e.summary { summary(r.summary, s) } else { check(false, "summary missing") }
        double(r.summary.distanceMeters, e.distanceM ?? .nan, distanceTolerance, "distance_m")
    }

    mutating func leg(_ g: RouteLeg, _ w: VectorLeg, _ f: String) {
        int(g.corridorRange.lowerBound, w.triangles[0], "\(f).triangles[0]")
        int(g.corridorRange.upperBound, w.triangles[1], "\(f).triangles[1]")
        double(g.lengthMeters, w.lengthM, distanceTolerance, "\(f).length_m")
        check(g.grade.rawValue == w.grade, "\(f).grade: got \(g.grade.rawValue), want \(w.grade)")
        let reasons: [String] = g.reasons.map(\.rawValue)
        check(reasons == w.reasons, "\(f).reasons: got \(reasons), want \(w.reasons)")
        int(g.minDepthDm, w.minDepthDm, "\(f).min_depth_dm")
        intOpt(g.minSpareDm, w.minSpareDm, "\(f).min_spare_dm")
        int(g.crossings.count, w.crossings.count, "\(f).crossings.count")
        for (c, x) in zip(g.crossings, w.crossings) {
            int(c.record, x.record, "\(f).crossing.record")
            int(c.clearanceDm, x.clearanceDm, "\(f).crossing.clearance_dm")
            check(c.isOpeningSpan == x.opening, "\(f).crossing.opening")
            check(c.needsOpening == x.needsOpening, "\(f).crossing.needs_opening")
        }
    }

    mutating func run(_ g: OverheadRun, _ w: VectorRun, _ f: String) {
        int(g.corridorIndex, w.corridorIndex, "\(f).corridor_index")
        int(g.overhead ?? 0xFFFF, w.overhead, "\(f).overhead")
        int(g.clearanceDm, w.clearanceDm, "\(f).clearance_dm")
        check(g.name == w.name, "\(f).name: got \(g.name)")
        degrees(g.centroid, w.lon, w.lat, "\(f).lon/lat")
    }

    mutating func summary(_ g: RouteSummary, _ w: VectorSummary) {
        double(g.distanceMeters, w.distanceM, distanceTolerance, "summary.distance_m")
        double(g.distanceNauticalMiles, w.distanceNm, distanceTolerance / 1852, "summary.distance_nm")
        int(g.legCount, w.legs, "summary.legs")
        int(g.greenLegs, w.greenLegs, "summary.green_legs")
        int(g.yellowLegs, w.yellowLegs, "summary.yellow_legs")
        int(g.shallowest.depthDm, w.shallowest.depthDm, "shallowest.depth_dm")
        int(g.shallowest.triangle, w.shallowest.triangle, "shallowest.triangle")
        degrees(g.shallowest.centroid, w.shallowest.lon, w.shallowest.lat, "shallowest.lon/lat")
        check(g.shallowest.maintained == w.shallowest.maintained, "shallowest.maintained")
        if let wl = w.lowestClearance, let gl = g.lowestClearance {
            int(gl.clearanceDm, wl.clearanceDm, "lowest_clearance.clearance_dm")
            int(gl.overhead ?? 0xFFFF, wl.overhead, "lowest_clearance.overhead")
            check(gl.name == wl.name, "lowest_clearance.name")
            check(gl.opening == wl.opening, "lowest_clearance.opening")
        } else {
            check(w.lowestClearance == nil && g.lowestClearance == nil, "lowest_clearance presence differs")
        }
        int(g.openings.count, w.openings.count, "openings.count")
        for (i, p) in zip(g.openings, w.openings).enumerated() { run(p.0, p.1, "openings[\(i)]") }
        int(g.unknownClearances.count, w.unknownClearances.count, "unknown_clearances.count")
        for (i, p) in zip(g.unknownClearances, w.unknownClearances).enumerated() { run(p.0, p.1, "unknown_clearances[\(i)]") }
        int(g.maintainedTriangles, w.maintainedTriangles, "maintained_triangles")
        int(Int(g.dataDate.rawValue), w.dataDate, "summary.data_date")
    }

    mutating func optionalDouble(_ got: Double?, _ want: Double?, _ tol: Double, _ field: String) {
        if let got, let want {
            double(got, want, tol, field)
        } else {
            check(got == nil && want == nil, "\(field): got \(String(describing: got)), want \(String(describing: want))")
        }
    }

    mutating func failure(_ err: RoutingError, _ e: VectorExpected, profile: BoatProfile) {
        check(!e.ok, "got error \(err.code), expected a route")
        guard !e.ok else { return }
        check(err.code == e.error, "error: got \(err.code), want \(e.error ?? "?")")
        switch err {
        case .invalidRequest:
            check(e.reqDm == nil && e.airDm == nil && e.start == nil, "INVALID_REQUEST carries no req_dm, air_dm or start")
        case .snapFailed(let f):
            intOpt(profile.requiredDepthDm, e.reqDm, "req_dm")
            intOpt(profile.requiredAirDm, e.airDm, "air_dm")
            let want = f.endpoint == .start ? e.start : e.goal
            check(want?.error == f.kind.code, "snap error kind: got \(f.kind.code)")
            if case .noWaterNearby(let located, let nearest) = f.kind {
                intOpt(located, want?.located, "located")
                optionalDouble(nearest, want?.nearestM, distanceTolerance, "nearest_m")
            }
            if f.endpoint == .goal, let s = f.start { endpoint(s, e.start, "start") }
            if f.endpoint == .start { check(e.goal == nil, "a START_ error has no goal object") }
        case .legValidation(let r):
            check(r.corridor == (e.corridor ?? []), "corridor differs")
            let want = e.violations ?? []
            int(r.violations.count, want.count, "violations.count")
            for (i, p) in zip(r.violations, want).enumerated() {
                let (g, w) = p
                let f = "violations[\(i)]"
                check(g.kind.rawValue == w.kind, "\(f).kind: got \(g.kind.rawValue), want \(w.kind)")
                int(g.record, w.record, "\(f).record")
                int(g.leg, w.leg, "\(f).leg")
                optionalDouble(g.distanceMeters, w.distanceM, distanceTolerance, "\(f).distance_m")
                intOpt(g.valsouDm, w.valsouDm, "\(f).valsou_dm")
                intOpt(g.clearanceDm, w.clearanceDm, "\(f).clearance_dm")
            }
        case .noRoute(let r):
            intOpt(r.requiredDepthDm, e.reqDm, "req_dm")
            intOpt(r.requiredAirDm, e.airDm, "air_dm")
            int(Int(r.dataDate.rawValue), e.dataDate, "data_date")
            endpoint(r.start, e.start, "start")
            endpoint(r.goal, e.goal, "goal")
            check(r.reason.code == e.reason, "reason: got \(r.reason.code), want \(e.reason ?? "?")")
            let blocked = e.blocked ?? []
            int(r.blocked.count, blocked.count, "blocked.count")
            for (i, p) in zip(r.blocked, blocked).enumerated() {
                let (g, w) = p
                let f = "blocked[\(i)]"
                int(g.corridorIndex, w.corridorIndex, "\(f).corridor_index")
                int(g.triangle, w.triangle, "\(f).triangle")
                check(g.reason.rawValue == w.reason, "\(f).reason")
                degrees(g.centroid, w.lon, w.lat, "\(f).lon/lat")
                int(g.depthDm, w.depthDm, "\(f).depth_dm")
                int(g.maintDm, w.maintDm, "\(f).maint_dm")
                int(g.clearanceDm, w.clearanceDm, "\(f).clearance_dm")
                check(g.overheadName == w.overhead, "\(f).overhead: got \(g.overheadName)")
                check(g.areaName == w.area, "\(f).area: got \(g.areaName)")
            }
            let hints = e.hints ?? [:]
            check(r.hints.useMaintainedChannels == hints["use_maintained"], "hints.use_maintained")
            check(r.hints.acceptUnknownClearance == hints["accept_unknown_clearance"], "hints.accept_unknown_clearance")
        default:
            break
        }
    }
}

/// Runs one vector query and returns the mismatches (empty = exact match).
func compareVector(_ q: VectorQuery, on pack: RoutingPack) -> [String] {
    var cmp = VectorComparator()
    do {
        let r = try pack.routeSynchronously(q.request)
        cmp.route(r, q.expected)
    } catch {
        cmp.failure(error, q.expected, profile: q.request.profile)
    }
    return cmp.mismatches
}
