import Foundation
import NavCore
import Testing
@testable import RoutingKit

/// Exact test: does the closed segment AB meet the open interior of triangle t? (Separating-axis theorem on
/// the triangle's three edge lines and the segment's line, all in Int64.)
func segmentEntersTriangleInterior(_ pack: RoutingPack, _ A: GridPoint, _ B: GridPoint, _ t: Int) -> Bool {
    let (a, b, c) = pack.triangleVertices(t)
    let vs: [GridPoint] = [pack.vertex(a), pack.vertex(b), pack.vertex(c)]
    let ax = Int64(A.x), ay = Int64(A.y), bx = Int64(B.x), by = Int64(B.y)
    for k in 0..<3 {
        let p = vs[k], q = vs[(k + 1) % 3]
        let px = Int64(p.x), py = Int64(p.y), qx = Int64(q.x), qy = Int64(q.y)
        let oa: Int64 = orient(px, py, qx, qy, ax, ay)
        let ob: Int64 = orient(px, py, qx, qy, bx, by)
        if oa <= 0 && ob <= 0 { return false }
    }
    var pos = 0, neg = 0
    for v in vs {
        let o: Int64 = orient(ax, ay, bx, by, Int64(v.x), Int64(v.y))
        if o > 0 { pos += 1 }
        if o < 0 { neg += 1 }
    }
    return pos > 0 && neg > 0
}

/// Synthetic pack: the centre of every grid square (8 × 4), as start/goal candidates.
let syntheticPoints: [Coordinate] = {
    var out: [Coordinate] = []
    for row in 0..<4 {
        for col in 0..<8 {
            out.append(Coordinate(latitude: 27.0 + 0.001 * Double(row) + 0.0005, longitude: -82.0 + 0.001 * Double(col) + 0.0005))
        }
    }
    return out
}()

let syntheticProfiles: [BoatProfile] = [
    BoatProfile(draftFeet: 1, safetyMarginFeet: 0.5, airDraftFeet: 5),
    BoatProfile(draftFeet: 4, safetyMarginFeet: 1, airDraftFeet: 20),
    BoatProfile(draftFeet: 4, safetyMarginFeet: 1, airDraftFeet: 20, useMaintainedChannels: true),
    BoatProfile(draftFeet: 4, safetyMarginFeet: 1, airDraftFeet: 8, acceptUnknownClearance: true),
    BoatProfile(draftFeet: 5, safetyMarginFeet: 1, airDraftFeet: 9, useMaintainedChannels: true, acceptUnknownClearance: true),
    BoatProfile(draftFeet: 12, safetyMarginFeet: 1, airDraftFeet: 20),
]

/// Distance in units from a point to triangle t (0 inside).
func unitsDistance(_ pack: RoutingPack, _ p: GridPoint, _ t: Int) -> Double {
    let (a, b, c) = pack.triangleVertices(t)
    let vs: [GridPoint] = [pack.vertex(a), pack.vertex(b), pack.vertex(c)]
    let X = (Double(vs[0].x - p.x), Double(vs[1].x - p.x), Double(vs[2].x - p.x))
    let Y = (Double(vs[0].y - p.y), Double(vs[1].y - p.y), Double(vs[2].y - p.y))
    return closestOnTriangle(X, Y).0
}

/// Counts of known, reported spec behaviours seen by the property tests.
nonisolated(unsafe) var endpointGrazes = 0

@Suite(.serialized) struct PropertyTests {
    /// Checks every invariant a returned route must satisfy; returns the violations.
    func invariants(_ r: RouteResult, pack: RoutingPack) -> [String] {
        var bad: [String] = []
        for t in r.corridor where pack.blockReason(triangle: t, profile: r.profile) != nil {
            bad.append("corridor triangle \(t) is impassable")
        }
        for (t, u) in zip(r.corridor, r.corridor.dropFirst()) {
            let (n0, n1, n2) = pack.neighbors(t)
            if n0 != u && n1 != u && n2 != u { bad.append("corridor \(t)->\(u) not adjacent") }
        }
        if r.corridor.first != r.start.triangle || r.corridor.last != r.goal.triangle { bad.append("corridor ends") }
        if r.waypointsUnits.first != r.start.point || r.waypointsUnits.last != r.goal.point { bad.append("waypoint ends") }
        if r.legs.count != max(r.waypointsUnits.count - 1, 0) { bad.append("leg count") }
        // Impassable triangles and their bounding boxes, computed once.
        var blocked: [(t: Int, x0: Int32, y0: Int32, x1: Int32, y1: Int32)] = []
        for t in 0..<pack.triangleCount where pack.blockReason(triangle: t, profile: r.profile) != nil {
            let (a, b, c) = pack.triangleVertices(t)
            let p = pack.vertex(a), q = pack.vertex(b), w = pack.vertex(c)
            blocked.append((t, min(p.x, q.x, w.x), min(p.y, q.y, w.y), max(p.x, q.x, w.x), max(p.y, q.y, w.y)))
        }
        var total = 0.0
        for leg in r.legs {
            total += leg.lengthMeters
            if leg.grade == .green && !leg.reasons.isEmpty { bad.append("green leg with reasons") }
            if leg.grade == .yellow && leg.reasons.isEmpty { bad.append("yellow leg without reasons") }
            // No leg passes through the interior of an impassable triangle.
            let lx0 = min(leg.from.x, leg.to.x), lx1 = max(leg.from.x, leg.to.x)
            let ly0 = min(leg.from.y, leg.to.y), ly1 = max(leg.from.y, leg.to.y)
            for bt in blocked where bt.x0 <= lx1 && bt.x1 >= lx0 && bt.y0 <= ly1 && bt.y1 >= ly0 {
                if segmentEntersTriangleInterior(pack, leg.from, leg.to, bt.t) {
                    // Known spec B.6 behaviour (reported): a snapped endpoint is rounded to whole units and can lie
                    // up to about one unit outside its snapped triangle, inside a neighbouring impassable one.
                    // Accept only that: the endpoint is outside its own triangle and within 2 units of bt.
                    let ends: [SnappedEndpoint] = [r.start, r.goal]
                    let graze = ends.contains { e in
                        (e.point == leg.from || e.point == leg.to) && !pack.triangle(e.triangle, contains: e.point)
                            && unitsDistance(pack, e.point, bt.t) <= 2.0
                    }
                    if graze {
                        endpointGrazes += 1
                    } else {
                        bad.append("leg \(leg.from)->\(leg.to) crosses impassable triangle \(bt.t)")
                    }
                }
            }
        }
        if abs(total - r.summary.distanceMeters) > 1e-9 { bad.append("summary distance") }
        if r.summary.greenLegs + r.summary.yellowLegs != r.legs.count { bad.append("grade counts") }
        return bad
    }

    @Test func syntheticAllPairs() {
        let pack = Fixtures.synthetic
        var routes = 0, failures = 0, legValidations = 0
        var problems: [String] = []
        for profile in syntheticProfiles {
            for (i, a) in syntheticPoints.enumerated() {
                for (j, b) in syntheticPoints.enumerated() where i != j {
                    let req = RouteRequest(start: a, goal: b, profile: profile)
                    let rev = RouteRequest(start: b, goal: a, profile: profile)
                    let forward = Result { () throws(RoutingError) -> RouteResult in try pack.routeSynchronously(req) }
                    let backward = Result { () throws(RoutingError) -> RouteResult in try pack.routeSynchronously(rev) }
                    // Determinism: the same query gives the same answer.
                    let again = Result { () throws(RoutingError) -> RouteResult in try pack.routeSynchronously(req) }
                    if again != forward { problems.append("non-deterministic \(i)->\(j)") }
                    // Symmetry: passability does not depend on direction, so a route exists both ways or neither.
                    // LEG_VALIDATION still means the search found a corridor. It occurs here only where a leg along
                    // a row boundary touches the end of an overhead polyline (known spec B.10 behaviour, reported;
                    // the Python reference fails the same queries identically).
                    if case .success(let f) = forward { routes += 1; problems += invariants(f, pack: pack) }
                    if case .success(let g) = backward { problems += invariants(g, pack: pack) }
                    for case .failure(let e) in [forward, backward] {
                        if e.code == "NO_ROUTE" { failures += 1 }
                        if case .legValidation(let v) = e {
                            legValidations += 1
                            for x in v.violations where x.kind == .hazard { problems.append("hazard violation \(i)->\(j)") }
                        }
                    }
                    let found1 = outcomeFoundCorridor(forward), found2 = outcomeFoundCorridor(backward)
                    if found1 != found2 { problems.append("asymmetric passability \(i)<->\(j)") }
                }
            }
        }
        print("[property] synthetic: \(routes) routes, \(failures) NO_ROUTE, \(legValidations) LEG_VALIDATION (polyline touch)")
        #expect(routes > 100)
        #expect(problems.isEmpty, "\(problems.prefix(10))")
    }

    @Test func sarasotaRoutesNeverCrossImpassableTriangles() throws {
        let pack = Fixtures.sarasota
        let file = try Fixtures.decode(VectorFile.self, "sarasota.vectors.json")
        var problems: [String] = []
        var checked = 0
        for q in file.queries {
            guard let r = try? pack.routeSynchronously(q.request) else { continue }
            checked += 1
            problems += invariants(r, pack: pack)
            let back = try? pack.routeSynchronously(RouteRequest(start: q.request.goal, goal: q.request.start,
                                                                 profile: q.request.profile))
            if let back { problems += invariants(back, pack: pack) } else { problems.append("\(q.id) has no reverse route") }
        }
        #expect(checked == 4)
        print("[property] sarasota: \(endpointGrazes) leg/triangle grazes by a rounded snapped endpoint")
        #expect(problems.isEmpty, "\(problems.prefix(10))")
    }

    /// Point location agrees with a brute-force search for the lowest containing triangle.
    @Test func locateMatchesBruteForce() {
        let pack = Fixtures.sarasota
        let h = pack.header
        var rng = SplitMix(seed: 7)
        var mismatches = 0
        for _ in 0..<150 {
            let x = Int32(Int64(h.minLon) + Int64(rng.next() % UInt64(Int64(h.maxLon) - Int64(h.minLon) + 1)))
            let y = Int32(Int64(h.minLat) + Int64(rng.next() % UInt64(Int64(h.maxLat) - Int64(h.minLat) + 1)))
            let p = GridPoint(x: x, y: y)
            var brute: Int?
            for t in 0..<pack.triangleCount where pack.triangle(t, contains: p) {
                brute = t
                break
            }
            if pack.locate(p) != brute { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    @Test func boatProfileValidation() {
        let pack = Fixtures.synthetic
        let bad = BoatProfile(draftFeet: .nan, safetyMarginFeet: 1, airDraftFeet: 5)
        let req = RouteRequest(start: syntheticPoints[8], goal: syntheticPoints[15], profile: bad)
        #expect(throws: RoutingError.self) { try pack.routeSynchronously(req) }
        let nanStart = RouteRequest(start: Coordinate(latitude: .nan, longitude: .infinity), goal: syntheticPoints[15],
                                    profile: syntheticProfiles[1])
        do {
            _ = try pack.routeSynchronously(nanStart)
            Issue.record("expected START_OUTSIDE_PACK")
        } catch {
            #expect(error.code == "START_OUTSIDE_PACK")
        }
    }

    @Test func goalErrorKeepsSnappedStart() {
        let pack = Fixtures.synthetic
        let req = RouteRequest(start: syntheticPoints[8], goal: Coordinate(latitude: 27.0015, longitude: -81.5),
                               profile: syntheticProfiles[1])
        do {
            _ = try pack.routeSynchronously(req)
            Issue.record("expected GOAL_OUTSIDE_PACK")
        } catch {
            #expect(error.code == "GOAL_OUTSIDE_PACK")
            if case .snapFailed(let f) = error { #expect(f.start != nil) }
        }
    }

    /// The comparator really detects differences (negative control for the vector tests).
    @Test func comparatorDetectsMismatch() throws {
        let file = try Fixtures.decode(VectorFile.self, "synthetic.vectors.json")
        var q = file.queries[1]
        q.expected.waypointsUnits?[0][0] += 1
        let m1: [String] = compareVector(q, on: Fixtures.synthetic)
        #expect(!m1.isEmpty)
        var q2 = file.queries[0]
        q2.expected.hints?["use_maintained"] = false
        let m2: [String] = compareVector(q2, on: Fixtures.synthetic)
        #expect(!m2.isEmpty)
    }
}

/// True for a route, or a failure that happened after the search found a corridor.
func outcomeFoundCorridor(_ r: Result<RouteResult, RoutingError>) -> Bool? {
    switch r {
    case .success: return true
    case .failure(.legValidation): return true
    case .failure(.noRoute): return false
    default: return nil  // snap errors: not about passability
    }
}

/// Small deterministic RNG for the fuzz and property tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
