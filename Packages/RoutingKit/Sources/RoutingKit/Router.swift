import Foundation
import NavCore

// MARK: - Public entry points

extension RoutingPack {
    /// Computes a route (spec part B). Runs on a background executor, never on the caller's actor.
    ///
    /// Cancelling the calling task stops the search promptly (``RoutingError/cancelled``). `progress`
    /// is called from the routing thread every few thousand expanded triangles.
    public func route(_ request: RouteRequest,
                      progress: (@Sendable (RoutingProgress) -> Void)? = nil) async throws(RoutingError) -> RouteResult {
        let task = Task.detached(priority: Task.currentPriority) { () -> Result<RouteResult, RoutingError> in
            do throws(RoutingError) {
                return .success(try self.routeSynchronously(request, progress: progress))
            } catch {
                return .failure(error)
            }
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return try result.get()
    }

    /// Computes a route on the calling thread. Do not call from the main thread on a large pack.
    /// Cancellation of the current task (if any) is honoured.
    public func routeSynchronously(_ request: RouteRequest,
                                   progress: (@Sendable (RoutingProgress) -> Void)? = nil) throws(RoutingError) -> RouteResult {
        guard request.profile.isValid else { throw .invalidRequest("boat dimensions must be finite, non-negative and below 1000 ft") }
        guard request.maxSnapMeters.isFinite, request.maxSnapMeters >= 0, request.maxSnapMeters <= 100_000 else {
            throw .invalidRequest("maxSnapMeters must be between 0 and 100000")
        }
        var engine = RouteEngine(pack: self, request: request, progress: progress)
        return try engine.run()
    }

    /// Snaps one point onto passable water for a profile (spec B.6), without routing.
    public func snap(_ coordinate: Coordinate, profile: BoatProfile,
                     maxSnapMeters: Double = 750) -> Result<SnappedEndpoint, SnapFailureKind> {
        let cls = Classifier(pack: self, profile: profile)
        return snapPoint(coordinate, cls: cls, maxMeters: maxSnapMeters)
    }

    /// Why triangle `t` is impassable for `profile`, or nil when it is passable (spec B.3).
    public func blockReason(triangle t: Int, profile: BoatProfile) -> BlockReason? {
        let r = Classifier(pack: self, profile: profile).reason(t)
        return r < 0 ? nil : BlockReason.allCases[r]
    }

    /// The centroid of triangle `t`: `floor((xa+xb+xc)/3)`, same for y (spec B.11).
    public func centroid(of t: Int) -> GridPoint {
        let a = Int(tris[3 * t]), b = Int(tris[3 * t + 1]), c = Int(tris[3 * t + 2])
        let x = floorDiv(Int64(lon[a]) + Int64(lon[b]) + Int64(lon[c]), 3)
        let y = floorDiv(Int64(lat[a]) + Int64(lat[b]) + Int64(lat[c]), 3)
        return GridPoint(x: Int32(x), y: Int32(y))
    }

    // MARK: B.6 snapping

    func snapPoint(_ coordinate: Coordinate, cls: Classifier, maxMeters: Double) -> Result<SnappedEndpoint, SnapFailureKind> {
        guard let x = toUnits(coordinate.longitude), let y = toUnits(coordinate.latitude) else { return .failure(.outsidePack) }
        let p = GridPoint(x: x, y: y)
        guard contains(p) else { return .failure(.outsidePack) }
        let located = locate(p)
        if let t = located, cls.ok(t) {
            return .success(SnappedEndpoint(requested: coordinate, point: p, triangle: t, snapMeters: 0, inMesh: true))
        }
        let lat0 = Double(y) / 1e7
        let lon0 = Double(x) / 1e7
        let kx = metersPerDegree * cos(lat0 * degToRad)
        let ky = metersPerDegree
        let rxD = (maxMeters / kx * 1e7).rounded(.up)
        let ryD = (maxMeters / ky * 1e7).rounded(.up)
        let rx = Int64(min(rxD, 4e9)), ry = Int64(min(ryD, 4e9))
        let (i0, j0) = cellOf(x: Int64(x) - rx, y: Int64(y) - ry)
        let (i1, j1) = cellOf(x: Int64(x) + rx, y: Int64(y) + ry)
        var cand: [Int32] = []
        for i in i0...i1 {
            for j in j0...j1 {
                let c = i * gridInfo.nx + j
                for k in Int(gridOffsets[c])..<Int(gridOffsets[c + 1]) { cand.append(gridIDs[k]) }
            }
        }
        cand.sort()
        var bestD = Double.infinity, bestT = -1, bestQ = (0.0, 0.0)
        var previous: Int32 = -1
        for t32 in cand {
            if t32 == previous { continue }
            previous = t32
            let t = Int(t32)
            guard cls.ok(t) else { continue }
            let a = Int(tris[3 * t]), b = Int(tris[3 * t + 1]), c = Int(tris[3 * t + 2])
            let X = ((Double(lon[a]) / 1e7 - lon0) * kx, (Double(lon[b]) / 1e7 - lon0) * kx, (Double(lon[c]) / 1e7 - lon0) * kx)
            let Y = ((Double(lat[a]) / 1e7 - lat0) * ky, (Double(lat[b]) / 1e7 - lat0) * ky, (Double(lat[c]) / 1e7 - lat0) * ky)
            let (d, qx, qy) = closestOnTriangle(X, Y)
            if d < bestD {
                bestD = d
                bestT = t
                bestQ = (qx, qy)
            }
        }
        if bestT < 0 { return .failure(.noWaterNearby(locatedTriangle: located, nearestMeters: nil)) }
        if bestD > maxMeters { return .failure(.noWaterNearby(locatedTriangle: located, nearestMeters: bestD)) }
        guard let sx = toUnits(lon0 + bestQ.0 / kx), let sy = toUnits(lat0 + bestQ.1 / ky) else {
            return .failure(.outsidePack)
        }
        func localDistance(_ q: GridPoint) -> Double {
            hypot((Double(q.x) / 1e7 - lon0) * kx, (Double(q.y) / 1e7 - lat0) * ky)
        }
        var point = GridPoint(x: sx, y: sy)
        if !triangle(bestT, contains: point) {
            // The rounded point fell outside the snapped triangle (B.6): take the nearest of the eight surrounding
            // whole-unit points and the triangle's vertices that the triangle contains (a vertex always qualifies).
            var candidates: [GridPoint] = []
            for j: Int32 in -1...1 {
                for i: Int32 in -1...1 where i != 0 || j != 0 {
                    candidates.append(GridPoint(x: sx + i, y: sy + j))
                }
            }
            let (a, b, c) = triangleVertices(bestT)
            candidates.append(vertex(a))
            candidates.append(vertex(b))
            candidates.append(vertex(c))
            var nearest = Double.infinity
            for q in candidates where triangle(bestT, contains: q) {
                let d = localDistance(q)
                if d < nearest {
                    nearest = d
                    point = q
                }
            }
        }
        return .success(SnappedEndpoint(requested: coordinate, point: point, triangle: bestT,
                                        snapMeters: localDistance(point), inMesh: located != nil))
    }
}

// MARK: - Engine

/// A* heap entry: ordered by (priority, seq), spec B.7.
struct HeapEntry {
    var priority: Double
    var seq: Int
    var t: Int32

    @inline(__always) static func less(_ a: HeapEntry, _ b: HeapEntry) -> Bool {
        a.priority < b.priority || (a.priority == b.priority && a.seq < b.seq)
    }
}

/// Binary min-heap of ``HeapEntry``.
struct MinHeap {
    var items = ContiguousArray<HeapEntry>()

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ e: HeapEntry) {
        items.append(e)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if !HeapEntry.less(items[i], items[parent]) { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> HeapEntry? {
        guard let last = items.popLast() else { return nil }
        guard !items.isEmpty else { return last }
        let top = items[0]
        items[0] = last
        var i = 0
        let n = items.count
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < n && HeapEntry.less(items[l], items[m]) { m = l }
            if r < n && HeapEntry.less(items[r], items[m]) { m = r }
            if m == i { break }
            items.swapAt(i, m)
            i = m
        }
        return top
    }
}

/// How the search treats triangles.
enum SearchMode {
    /// B.7: only passable triangles.
    case normal
    /// B.11: every triangle; blocked ones cost f = 50 and +100000 m on entry from a passable one.
    case relaxed
}

struct RouteEngine {
    let pack: RoutingPack
    let request: RouteRequest
    let progress: (@Sendable (RoutingProgress) -> Void)?
    let clock = ContinuousClock()
    let started: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant?

    let lon: ContiguousArray<Int32>
    let lat: ContiguousArray<Int32>
    let tris: ContiguousArray<Int32>
    let nbr: ContiguousArray<Int32>

    init(pack: RoutingPack, request: RouteRequest, progress: (@Sendable (RoutingProgress) -> Void)?) {
        self.pack = pack
        self.request = request
        self.progress = progress
        let now = ContinuousClock.now
        started = now
        if let limit = request.timeLimit { deadline = now + limit } else { deadline = nil }
        lon = pack.lon
        lat = pack.lat
        tris = pack.tris
        nbr = pack.nbr
    }

    mutating func run() throws(RoutingError) -> RouteResult {
        let profile = request.profile
        let cls = Classifier(pack: pack, profile: profile)

        // B.6: snap start, then goal.
        let start: SnappedEndpoint
        switch pack.snapPoint(request.start, cls: cls, maxMeters: request.maxSnapMeters) {
        case .success(let s): start = s
        case .failure(let k): throw .snapFailed(SnapFailure(endpoint: .start, kind: k, start: nil))
        }
        let goal: SnappedEndpoint
        switch pack.snapPoint(request.goal, cls: cls, maxMeters: request.maxSnapMeters) {
        case .success(let g): goal = g
        case .failure(let k): throw .snapFailed(SnapFailure(endpoint: .goal, kind: k, start: start))
        }
        try checkInterrupt(expanded: 0)

        // B.7.
        let search = try astar(start: start, goal: goal, cls: cls, mode: .normal, phase: .search)
        guard let corridor = search.corridor else {
            throw .noRoute(try noRouteReport(start: start, goal: goal, cls: cls))
        }

        // B.8 – B.10.
        let points = funnel(corridor: corridor, S: start.point, G: goal.point)
        let (legs, violations) = grade(corridor: corridor, points: points, cls: cls)
        if !violations.isEmpty {
            throw .legValidation(LegValidationReport(violations: violations, corridor: corridor))
        }
        let summary = summarize(corridor: corridor, legs: legs, cls: cls)
        return RouteResult(profile: profile, requiredDepthDm: cls.req, requiredAirDm: cls.air, start: start, goal: goal,
                           corridor: corridor, waypointsUnits: points.map(\.point), legs: legs, summary: summary,
                           dataDate: pack.dataDate, regionID: pack.regionID, expanded: search.expanded)
    }

    // MARK: Interrupts

    func checkInterrupt(expanded: Int) throws(RoutingError) {
        if Task.isCancelled { throw .cancelled }
        if let deadline, clock.now >= deadline { throw .timedOut(expanded: expanded) }
    }

    // MARK: B.7 A*

    @inline(__always) func edgeMid(_ e: Int) -> (Double, Double) {
        let t = e / 3, k = e % 3
        let a = Int(tris[e]), b = Int(tris[3 * t + (k + 1) % 3])
        return (Double(Int64(lon[a]) + Int64(lon[b])) / 2e7, Double(Int64(lat[a]) + Int64(lat[b])) / 2e7)
    }

    func astar(start: SnappedEndpoint, goal: SnappedEndpoint, cls: Classifier, mode: SearchMode,
               phase: RoutingProgress.Phase) throws(RoutingError) -> (corridor: [Int]?, expanded: Int) {
        let T = pack.triangleCount
        let s = start.triangle, g = goal.triangle
        let S = (Double(start.point.x) / 1e7, Double(start.point.y) / 1e7)
        let gx = Double(goal.point.x) / 1e7, gy = Double(goal.point.y) / 1e7
        var gcost = ContiguousArray<Double>(repeating: .infinity, count: T)
        // The edge (3·t + k) through which each triangle was last reached; its midpoint is pos[u], t is came[u].
        var entry = ContiguousArray<Int32>(repeating: -1, count: T)
        var closed = ContiguousArray<Bool>(repeating: false, count: T)
        var heap = MinHeap()
        var seq = 0
        gcost[s] = 0
        heap.push(HeapEntry(priority: fMin * distMeters(S.0, S.1, gx, gy), seq: 0, t: Int32(s)))
        var expanded = 0
        var found = false
        let relaxed = mode == .relaxed
        while let top = heap.pop() {
            let t = Int(top.t)
            if closed[t] { continue }
            closed[t] = true
            expanded += 1
            if expanded & 4095 == 0 {
                try checkInterrupt(expanded: expanded)
                if let progress { progress(RoutingProgress(phase: phase, expanded: expanded, elapsed: clock.now - started)) }
            }
            if t == g {
                found = true
                break
            }
            let (px, py) = t == s ? S : edgeMid(Int(entry[t]))
            let gt = gcost[t]
            let bt = cls.bits(t)
            let blockedT = relaxed && !cls.ok(t)
            let ft = blockedT ? 50.0 : cls.factor(t, bt)
            for k in 0..<3 {
                let u = Int(nbr[3 * t + k])
                if u < 0 || closed[u] { continue }
                let okU = cls.ok(u)
                if !relaxed && !okU { continue }
                let bu = cls.bits(u)
                let blockedU = relaxed && !okU
                let fu = blockedU ? 50.0 : cls.factor(u, bu)
                let e = 3 * t + k
                let (mx, my) = edgeMid(e)
                var step = distMeters(px, py, mx, my) * ((ft + fu) * 0.5)
                if bu.contains(.needsOpening) && !bt.contains(.needsOpening) { step += 1500.0 }
                if bu.contains(.unknownUsed) && !bt.contains(.unknownUsed) { step += 3000.0 }
                if bu.contains(.restricted) && !bt.contains(.restricted) { step += 1000.0 }
                if blockedU && !blockedT { step += 100_000.0 }
                let ng = gt + step
                if ng < gcost[u] {
                    gcost[u] = ng
                    entry[u] = Int32(e)
                    seq += 1
                    heap.push(HeapEntry(priority: ng + fMin * distMeters(mx, my, gx, gy), seq: seq, t: Int32(u)))
                }
            }
        }
        guard found else { return (nil, expanded) }
        var path = [g]
        var cur = g
        while cur != s {
            cur = Int(entry[cur]) / 3
            path.append(cur)
        }
        path.reverse()
        return (path, expanded)
    }

    // MARK: B.8 funnel

    struct Waypoint {
        var point: GridPoint
        var index: Int
    }

    func funnel(corridor: [Int], S: GridPoint, G: GridPoint) -> [Waypoint] {
        // Portals: (left, right) = (v[k+1], v[k]) of the edge of t shared with the next triangle.
        var portals: [(GridPoint, GridPoint)] = [(S, S)]
        portals.reserveCapacity(corridor.count + 1)
        for i in 0..<(corridor.count - 1) {
            let t = corridor[i], u = corridor[i + 1]
            var k = 0
            while Int(nbr[3 * t + k]) != u { k += 1 }
            let a = Int(tris[3 * t + k]), b = Int(tris[3 * t + (k + 1) % 3])
            portals.append((GridPoint(x: lon[b], y: lat[b]), GridPoint(x: lon[a], y: lat[a])))
        }
        portals.append((G, G))
        let n = corridor.count

        @inline(__always) func tri2(_ a: GridPoint, _ b: GridPoint, _ c: GridPoint) -> Int64 {
            orient(Int64(a.x), Int64(a.y), Int64(b.x), Int64(b.y), Int64(c.x), Int64(c.y))
        }

        var path = [Waypoint(point: S, index: 0)]
        var apex = S, left = portals[0].0, right = portals[0].1
        var ai = 0, li = 0, ri = 0
        var i = 1
        while i <= n {
            let (pl, pr) = portals[i]
            if tri2(apex, right, pr) >= 0 {
                if apex == right || tri2(apex, left, pr) < 0 {
                    right = pr
                    ri = i
                } else {
                    path.append(Waypoint(point: left, index: li))
                    apex = left
                    ai = li
                    left = apex
                    right = apex
                    li = ai
                    ri = ai
                    i = ai + 1
                    continue
                }
            }
            if tri2(apex, left, pl) <= 0 {
                if apex == left || tri2(apex, right, pl) > 0 {
                    left = pl
                    li = i
                } else {
                    path.append(Waypoint(point: right, index: ri))
                    apex = right
                    ai = ri
                    left = apex
                    right = apex
                    li = ai
                    ri = ai
                    i = ai + 1
                    continue
                }
            }
            i += 1
        }
        if path[path.count - 1].point != G { path.append(Waypoint(point: G, index: n)) }
        var out = [path[0]]
        for q in path.dropFirst() where q.point != out[out.count - 1].point { out.append(q) }
        if out[out.count - 1].index != n { out[out.count - 1].index = n }
        return out
    }

    // MARK: B.9 grading and B.10 validation

    func grade(corridor: [Int], points: [Waypoint], cls: Classifier) -> ([RouteLeg], [LegViolation]) {
        var legs: [RouteLeg] = []
        var violations: [LegViolation] = []
        let n = corridor.count
        let depth = pack.depth, flags = pack.flags, quality = pack.quality
        for j in 0..<max(points.count - 1, 0) {
            let A = points[j].point, pa = points[j].index
            let B = points[j + 1].point, pb = points[j + 1].index
            let lo = min(pa, n - 1)  // pa <= n - 1 for every leg start; the clamp only guards odd corridors
            let hi = max(min(max(pa, pb - 1), n - 1), lo)
            var any = TriBits()
            var restricted = false, caution = false, hazard = false, lowQuality = false, thin = false
            var minDepth = Int.max
            var minSpare: Int?
            for pos in lo...hi {
                let t = corridor[pos]
                let b = cls.bits(t)
                any.formUnion(b)
                let fl = flags[t]
                if fl & TriangleFlags.restricted.rawValue != 0 { restricted = true }
                if fl & TriangleFlags.caution.rawValue != 0 { caution = true }
                if fl & TriangleFlags.hazardDepth.rawValue != 0 { hazard = true }
                let cz = Int(quality[t] & 7)
                if cz == 0 || cz == 5 || cz == 6 { lowQuality = true }
                let d = Int(depth[t])
                minDepth = min(minDepth, d)
                if !b.contains(.viaMaint) {
                    let spare = d - cls.req
                    minSpare = min(minSpare ?? spare, spare)
                    if spare < 3 && (cz == 0 || cz == 4 || cz == 5 || cz == 6) { thin = true }
                }
            }
            var reasons: [CautionReason] = []
            if any.contains(.viaMaint) { reasons.append(.maintainedDepth) }
            if any.contains(.viaSound) { reasons.append(.soundingDepth) }
            if any.contains(.needsOpening) { reasons.append(.bridgeOpening) }
            if any.contains(.unknownUsed) { reasons.append(.unknownClearance) }
            if restricted { reasons.append(.restrictedArea) }
            if caution { reasons.append(.cautionArea) }
            if hazard { reasons.append(.hazardProximity) }
            if lowQuality { reasons.append(.lowDataQuality) }
            if thin { reasons.append(.thinMargin) }
            let (v, crossings) = validateLeg(A, B, cls: cls, leg: j)
            violations += v
            let length = distMeters(Double(A.x) / 1e7, Double(A.y) / 1e7, Double(B.x) / 1e7, Double(B.y) / 1e7)
            legs.append(RouteLeg(from: A, to: B, corridorRange: lo...hi, lengthMeters: length,
                                 grade: reasons.isEmpty ? .green : .yellow, reasons: reasons, minDepthDm: minDepth,
                                 minSpareDm: minSpare, crossings: crossings))
        }
        return (legs, violations)
    }

    func validateLeg(_ A: GridPoint, _ B: GridPoint, cls: Classifier, leg: Int) -> ([LegViolation], [OverheadCrossing]) {
        let x0 = Int64(min(A.x, B.x)), x1 = Int64(max(A.x, B.x))
        let y0 = Int64(min(A.y, B.y)), y1 = Int64(max(A.y, B.y))
        let latm = Double(Int64(A.y) + Int64(B.y)) / 2e7
        let lonm = Double(Int64(A.x) + Int64(B.x)) / 2e7
        let kx = metersPerDegree * cos(latm * degToRad)
        let ky = metersPerDegree
        let ax = (Double(A.x) / 1e7 - lonm) * kx, ay = (Double(A.y) / 1e7 - latm) * ky
        let bx = (Double(B.x) / 1e7 - lonm) * kx, by = (Double(B.y) / 1e7 - latm) * ky
        let checkM = Double(pack.header.checkDm) / 10.0
        let mx = Int64(((checkM + 1) / kx * 1e7).rounded(.up))
        let my = Int64(((checkM + 1) / ky * 1e7).rounded(.up))
        let geom = pack.geom

        func local(_ first: UInt32, _ count: UInt32) -> ([Double], [Double]) {
            var hx: [Double] = [], hy: [Double] = []
            hx.reserveCapacity(Int(count))
            hy.reserveCapacity(Int(count))
            for k in Int(first)..<(Int(first) + Int(count)) {
                hx.append((Double(geom[2 * k]) / 1e7 - lonm) * kx)
                hy.append((Double(geom[2 * k + 1]) / 1e7 - latm) * ky)
            }
            return (hx, hy)
        }

        var violations: [LegViolation] = []
        var crossings: [OverheadCrossing] = []
        let hb = pack.hazardBoxes
        for h in 0..<pack.hazards.count {
            guard Int64(hb[4 * h]) <= x1 + mx, Int64(hb[4 * h + 2]) >= x0 - mx,
                  Int64(hb[4 * h + 1]) <= y1 + my, Int64(hb[4 * h + 3]) >= y0 - my else { continue }
            let r = pack.hazards[h]
            let v = Int(r.valsouDm)
            guard v == -32768 || v < cls.req else { continue }
            let (hx, hy) = local(r.geomFirst, r.geomCount)
            let d = segmentGeometryDistance(ax, ay, bx, by, hx, hy, r.geomType)
            if d < checkM {
                violations.append(LegViolation(kind: .hazard, leg: leg, record: h, distanceMeters: d, valsouDm: v,
                                               clearanceDm: nil))
            }
        }
        // Overhead candidates: geometry bbox within 2 m (the 1 m point radius plus 1 m) of the leg bbox.
        let ob = pack.overheadBoxes
        let px = Int64(((overheadPointMeters + 1) / kx * 1e7).rounded(.up))
        let py = Int64(((overheadPointMeters + 1) / ky * 1e7).rounded(.up))
        var candidates: [Int] = []
        var lines: [PolylineGeometry] = []
        var singlePoints: [Int: GridPoint] = [:]
        for o in 0..<pack.overheadObjects.count {
            guard Int64(ob[4 * o]) <= x1 + px, Int64(ob[4 * o + 2]) >= x0 - px,
                  Int64(ob[4 * o + 1]) <= y1 + py, Int64(ob[4 * o + 3]) >= y0 - py else { continue }
            candidates.append(o)
            let r = pack.overheadObjects[o]
            if r.geomType == .polyline {
                let pts = dedupeConsecutive(pack.geometry(of: r))
                if pts.count >= 2 {
                    lines.append(PolylineGeometry(record: o, points: pts))
                } else {
                    singlePoints[o] = pts[0]  // every point equal: a point object
                }
            }
        }
        let crossedLines = polylineCrossings(A, B, lines)
        for o in candidates {
            let r = pack.overheadObjects[o]
            if r.geomType == .polyline && singlePoints[o] == nil {
                guard crossedLines.contains(o) else { continue }
            } else if let q = singlePoints[o] {
                let hx = [(Double(q.x) / 1e7 - lonm) * kx], hy = [(Double(q.y) / 1e7 - latm) * ky]
                guard segmentCrosses(ax, ay, bx, by, hx, hy, .point) else { continue }
            } else {
                let (hx, hy) = local(r.geomFirst, r.geomCount)
                guard segmentCrosses(ax, ay, bx, by, hx, hy, r.geomType) else { continue }
            }
            let c = Int(r.clearanceDm)
            let opening = r.isOpeningSpan
            var needs: Bool?
            if opening {
                needs = c == 0xFFFE || c < cls.air
            } else if c == 0xFFFE {
                if !cls.acceptUnknown {
                    violations.append(LegViolation(kind: .unknownClearance, leg: leg, record: o, distanceMeters: nil,
                                                   valsouDm: nil, clearanceDm: nil))
                }
            } else if c < cls.air {
                violations.append(LegViolation(kind: .clearance, leg: leg, record: o, distanceMeters: nil, valsouDm: nil,
                                               clearanceDm: c))
            }
            crossings.append(OverheadCrossing(record: o, clearanceDm: c, isOpeningSpan: opening, needsOpening: needs,
                                              name: pack.string(r.name)))
        }
        return (violations, crossings)
    }

    // MARK: B.12 summary

    func overheadName(_ index: UInt16) -> String {
        index == PackSentinel.noIndex ? "" : pack.string(pack.overheadObjects[Int(index)].name)
    }

    func summarize(corridor: [Int], legs: [RouteLeg], cls: Classifier) -> RouteSummary {
        let depth = pack.depth, clr = pack.clr, ovhd = pack.ovhd, flags = pack.flags
        var k = 0
        for i in 1..<corridor.count where depth[corridor[i]] < depth[corridor[k]] { k = i }
        let st = corridor[k]
        let shallowest = ShallowestPoint(depthDm: Int(depth[st]), triangle: st, centroid: pack.centroid(of: st),
                                         maintained: cls.bits(st).contains(.viaMaint))
        var low: LowestClearance?
        var lowIndex = -1
        for i in 0..<corridor.count {
            let c = clr[corridor[i]]
            if c < 0xFFFE && (lowIndex < 0 || c < clr[corridor[lowIndex]]) { lowIndex = i }
        }
        if lowIndex >= 0 {
            let t = corridor[lowIndex]
            let ov = ovhd[t]
            low = LowestClearance(clearanceDm: Int(clr[t]), overhead: ov == PackSentinel.noIndex ? nil : Int(ov),
                                  name: overheadName(ov), opening: flags[t] & TriangleFlags.openingBridge.rawValue != 0)
        }
        func runs(_ bit: TriBits) -> [OverheadRun] {
            var out: [OverheadRun] = []
            var prev = false
            for (i, t) in corridor.enumerated() {
                let on = cls.bits(t).contains(bit)
                if on && !prev {
                    let ov = ovhd[t]
                    out.append(OverheadRun(corridorIndex: i, overhead: ov == PackSentinel.noIndex ? nil : Int(ov),
                                           clearanceDm: Int(clr[t]), name: overheadName(ov), centroid: pack.centroid(of: t)))
                }
                prev = on
            }
            return out
        }
        var total = 0.0
        for l in legs { total += l.lengthMeters }
        var maintained = 0
        for t in corridor where cls.bits(t).contains(.viaMaint) { maintained += 1 }
        return RouteSummary(distanceMeters: total, legCount: legs.count,
                            greenLegs: legs.filter { $0.grade == .green }.count,
                            yellowLegs: legs.filter { $0.grade == .yellow }.count,
                            shallowest: shallowest, lowestClearance: low, openings: runs(.needsOpening),
                            unknownClearances: runs(.unknownUsed), maintainedTriangles: maintained, dataDate: pack.dataDate)
    }

    // MARK: B.11 no route

    func noRouteReport(start: SnappedEndpoint, goal: SnappedEndpoint, cls: Classifier) throws(RoutingError) -> NoRouteReport {
        let profile = request.profile
        let relaxed = try astar(start: start, goal: goal, cls: cls, mode: .relaxed, phase: .noRouteReport)
        var hints = RouteHints(useMaintainedChannels: profile.useMaintainedChannels ? nil : false,
                               acceptUnknownClearance: profile.acceptUnknownClearance ? nil : false)
        guard let corridor = relaxed.corridor else {
            // Disconnected water: no option can connect it, so every hint is false without searching.
            return NoRouteReport(requiredDepthDm: cls.req, requiredAirDm: cls.air, start: start, goal: goal,
                                 reason: .notConnected, blocked: [], hints: hints, dataDate: pack.dataDate)
        }
        var blocked: [BlockedPlace] = []
        var prev = false
        for (i, t) in corridor.enumerated() {
            let r = cls.reason(t)
            let isBlocked = r >= 0
            if isBlocked && !prev {
                let ar = pack.area[t]
                blocked.append(BlockedPlace(corridorIndex: i, triangle: t, reason: BlockReason.allCases[r],
                                            centroid: pack.centroid(of: t), depthDm: Int(pack.depth[t]),
                                            maintDm: Int(pack.maint[t]), clearanceDm: Int(pack.clr[t]),
                                            overheadName: overheadName(pack.ovhd[t]),
                                            areaName: ar == PackSentinel.noIndex ? "" : pack.string(pack.areas[Int(ar)].name)))
            }
            prev = isBlocked
        }
        func hint(_ p: BoatProfile) throws(RoutingError) -> Bool {
            let c2 = Classifier(pack: pack, profile: p)
            guard c2.ok(start.triangle) && c2.ok(goal.triangle) else { return false }
            return try astar(start: start, goal: goal, cls: c2, mode: .normal, phase: .hints).corridor != nil
        }
        if !profile.useMaintainedChannels { hints.useMaintainedChannels = try hint(profile.with(useMaintained: true)) }
        if !profile.acceptUnknownClearance { hints.acceptUnknownClearance = try hint(profile.with(acceptUnknown: true)) }
        let reason: NoRouteReason = blocked.first.map { .blocked($0.reason) } ?? .notConnected
        return NoRouteReport(requiredDepthDm: cls.req, requiredAirDm: cls.air, start: start, goal: goal, reason: reason,
                             blocked: blocked, hints: hints, dataDate: pack.dataDate)
    }
}
