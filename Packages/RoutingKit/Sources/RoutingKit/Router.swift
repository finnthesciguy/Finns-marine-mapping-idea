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
        // One class only: building a whole Classifier would classify every attribute class.
        let r = Classifier.reason(classes, Int(attrClass[t]), req: profile.requiredDepthDm, air: profile.requiredAirDm,
                                  useMaintained: profile.useMaintainedChannels, avoidOpenGulf: profile.avoidOpenGulf)
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

/// A* state per triangle (cost so far, entry edge, closed), in pages of 4096 triangles allocated on first touch.
/// Triangles are stored in a space-filling order, so a search touches compact runs of pages; a search that reaches
/// the whole region costs 13 bytes per triangle, as a flat layout would.
struct SearchState {
    static let shift = 12
    static let pageSize = 1 << shift
    var costs: [ContiguousArray<Double>] = []
    var entries: [ContiguousArray<Int32>] = []
    var closedFlags: [ContiguousArray<Bool>] = []
    var pageOf: ContiguousArray<Int32>

    init(triangleCount: Int) {
        pageOf = ContiguousArray(repeating: -1, count: (triangleCount + Self.pageSize - 1) >> Self.shift)
    }

    @inline(__always) mutating func page(_ t: Int) -> Int {
        let p = t >> Self.shift
        let q = Int(pageOf[p])
        if q >= 0 { return q }
        let n = costs.count
        costs.append(ContiguousArray(repeating: .infinity, count: Self.pageSize))
        entries.append(ContiguousArray(repeating: -1, count: Self.pageSize))
        closedFlags.append(ContiguousArray(repeating: false, count: Self.pageSize))
        pageOf[p] = Int32(n)
        return n
    }

    @inline(__always) func cost(_ t: Int) -> Double {
        let q = Int(pageOf[t >> Self.shift])
        return q < 0 ? .infinity : costs[q][t & (Self.pageSize - 1)]
    }

    @inline(__always) func entry(_ t: Int) -> Int32 {
        let q = Int(pageOf[t >> Self.shift])
        return q < 0 ? -1 : entries[q][t & (Self.pageSize - 1)]
    }

    @inline(__always) func isClosed(_ t: Int) -> Bool {
        let q = Int(pageOf[t >> Self.shift])
        return q < 0 ? false : closedFlags[q][t & (Self.pageSize - 1)]
    }

    @inline(__always) mutating func setCost(_ t: Int, _ c: Double) {
        let q = page(t)
        costs[q][t & (Self.pageSize - 1)] = c
    }

    @inline(__always) mutating func reach(_ t: Int, cost c: Double, entry e: Int32) {
        let q = page(t)
        costs[q][t & (Self.pageSize - 1)] = c
        entries[q][t & (Self.pageSize - 1)] = e
    }

    @inline(__always) mutating func close(_ t: Int) {
        let q = page(t)
        closedFlags[q][t & (Self.pageSize - 1)] = true
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
        var points: [Waypoint]
        var legTriangles: [[Int]]
        var route = corridor
        if start.point == goal.point {
            points = [Waypoint(point: start.point, index: corridor.count)]
            legTriangles = []
        } else {
            (points, legTriangles) = planLegs(corridor: corridor, S: start.point, G: goal.point, cls: cls)
            route = [corridor[0]]
            for lt in legTriangles { route.append(contentsOf: lt.dropFirst()) }
        }
        let (legs, violations) = grade(points: points, legTriangles: legTriangles, cls: cls)
        if !violations.isEmpty {
            throw .legValidation(LegValidationReport(violations: violations, corridor: route))
        }
        let summary = summarize(corridor: route, legs: legs, cls: cls)
        return RouteResult(profile: profile, requiredDepthDm: cls.req, requiredAirDm: cls.air, start: start, goal: goal,
                           corridor: route, waypointsUnits: points.map(\.point), legs: legs, summary: summary,
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
        // Per-triangle search state, allocated in pages on first touch (a search rarely reaches most of a region).
        var state = SearchState(triangleCount: T)
        var heap = MinHeap()
        var seq = 0
        state.setCost(s, 0)
        heap.push(HeapEntry(priority: fMin * distMeters(S.0, S.1, gx, gy), seq: 0, t: Int32(s)))
        var expanded = 0
        var found = false
        let relaxed = mode == .relaxed
        while let top = heap.pop() {
            let t = Int(top.t)
            if state.isClosed(t) { continue }
            state.close(t)
            expanded += 1
            if expanded & 4095 == 0 {
                try checkInterrupt(expanded: expanded)
                if let progress { progress(RoutingProgress(phase: phase, expanded: expanded, elapsed: clock.now - started)) }
            }
            if t == g {
                found = true
                break
            }
            let (px, py) = t == s ? S : edgeMid(Int(state.entry(t)))
            let gt = state.cost(t)
            let bt = cls.bits(t)
            let blockedT = relaxed && !cls.ok(t)
            let ft = blockedT ? 50.0 : cls.factor(t)
            for k in 0..<3 {
                let u = Int(nbr[3 * t + k])
                if u < 0 || state.isClosed(u) { continue }
                let okU = cls.ok(u)
                if !relaxed && !okU { continue }
                let bu = cls.bits(u)
                let blockedU = relaxed && !okU
                let fu = blockedU ? 50.0 : cls.factor(u)
                let e = 3 * t + k
                let (mx, my) = edgeMid(e)
                var step = distMeters(px, py, mx, my) * ((ft + fu) * 0.5)
                if bu.contains(.needsOpening) && !bt.contains(.needsOpening) { step += 1500.0 }
                if bu.contains(.unknownUsed) && !bt.contains(.unknownUsed) { step += 3000.0 }
                if bu.contains(.restricted) && !bt.contains(.restricted) { step += 1000.0 }
                if bu.contains(.lock) && !bt.contains(.lock) { step += 2000.0 }
                if bu.contains(.prohibited) && !bt.contains(.prohibited) { step += 5000.0 }
                if bu.contains(.uncharted) && !bt.contains(.uncharted) { step += 3000.0 }
                if blockedU && !blockedT { step += 100_000.0 }
                let ng = gt + step
                if ng < state.cost(u) {
                    state.reach(u, cost: ng, entry: Int32(e))
                    seq += 1
                    heap.push(HeapEntry(priority: ng + fMin * distMeters(mx, my, gx, gy), seq: seq, t: Int32(u)))
                }
            }
        }
        guard found else { return (nil, expanded) }
        var path = [g]
        var cur = g
        while cur != s {
            cur = Int(state.entry(cur)) / 3
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

    /// Portals of a corridor (spec B.8): `(left, right) = (v[k+1], v[k])` of the edge of t shared with the next triangle,
    /// framed by `(S, S)` and `(G, G)`.
    func portals(corridor: [Int], S: GridPoint, G: GridPoint) -> [(GridPoint, GridPoint)] {
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
        return portals
    }

    /// The B.8 funnel over `portals` (`portals[0] = (S, S)`, the last `(G, G)`).
    func funnel(portals: [(GridPoint, GridPoint)]) -> [Waypoint] {
        let S = portals[0].0, G = portals[portals.count - 1].0
        let n = portals.count - 1

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

    // MARK: B.8 leg planning

    @inline(__always) func vertexPoint(_ v: Int) -> GridPoint { GridPoint(x: lon[v], y: lat[v]) }

    @inline(__always) func tri2(_ a: GridPoint, _ b: GridPoint, _ c: GridPoint) -> Int64 {
        orient(Int64(a.x), Int64(a.y), Int64(b.x), Int64(b.y), Int64(c.x), Int64(c.y))
    }

    func strictlyInside(_ t: Int, _ p: GridPoint) -> Bool {
        let a = vertexPoint(Int(tris[3 * t])), b = vertexPoint(Int(tris[3 * t + 1])), c = vertexPoint(Int(tris[3 * t + 2]))
        return tri2(a, b, p) > 0 && tri2(b, c, p) > 0 && tri2(c, a, p) > 0
    }

    /// Spec B.8 straight walk from A (in triangle tA) to B, which must end in triangle tB. Every triangle entered
    /// must satisfy `admissible`. Nil if the segment meets a vertex, leaves the mesh or enters a forbidden triangle.
    func walk(from A: GridPoint, in tA: Int, to B: GridPoint, endingIn tB: Int, admissible: (Int) -> Bool) -> [Int]? {
        var t = tA
        var out = [t]
        for _ in 0..<pack.triangleCount {
            if t == tB { return out }
            if pack.triangle(t, contains: B) { return nil }
            let o0 = tri2(A, B, vertexPoint(Int(tris[3 * t])))
            let o1 = tri2(A, B, vertexPoint(Int(tris[3 * t + 1])))
            let o2 = tri2(A, B, vertexPoint(Int(tris[3 * t + 2])))
            var k = -1
            if o0 < 0 && o1 > 0 {
                k = 0
            } else if o1 < 0 && o2 > 0 {
                k = 1
            } else if o2 < 0 && o0 > 0 {
                k = 2
            }
            if k < 0 { return nil }
            let u = Int(nbr[3 * t + k])
            if u < 0 || !admissible(u) { return nil }
            out.append(u)
            t = u
        }
        return nil
    }

    /// Spec B.8: legs by greedy visibility over targets next to the corridor's portal midpoints, with the funnel
    /// as fallback. Returns the waypoints and, per leg, the triangles it crosses.
    func planLegs(corridor: [Int], S: GridPoint, G: GridPoint, cls: Classifier) -> ([Waypoint], [[Int]]) {
        let n = corridor.count
        let P = portals(corridor: corridor, S: S, G: G)
        func target(_ j: Int) -> GridPoint? {
            if j == n { return G }
            let (l, r) = P[j]
            let t = corridor[j]
            var o = vertexPoint(Int(tris[3 * t]))
            for k in 0..<3 {
                let q = vertexPoint(Int(tris[3 * t + k]))
                if q != l && q != r { o = q }
            }
            let mx = floorDiv(2 * Int64(l.x) + 2 * Int64(r.x) + Int64(o.x), 5)
            let my = floorDiv(2 * Int64(l.y) + 2 * Int64(r.y) + Int64(o.y), 5)
            let m = GridPoint(x: Int32(mx), y: Int32(my))
            return strictlyInside(t, m) ? m : nil
        }
        var A = S, ia = 0, tA = corridor[0]
        var points = [Waypoint(point: S, index: 0)]
        var legs: [[Int]] = []
        while true {
            func visible(_ j: Int) -> [Int]? {
                guard let T = target(j), T != A else { return nil }
                var Y: UInt16 = 0
                for pos in ia...min(j, n - 1) { Y |= cls.yellowMask(corridor[pos]) }
                let mask = Y
                return walk(from: A, in: tA, to: T, endingIn: corridor[min(j, n - 1)]) { u in
                    cls.ok(u) && cls.yellowMask(u) & ~mask == 0
                }
            }
            var B: GridPoint
            var jb: Int
            var seq: [Int]
            if var best = visible(ia + 1) {
                var lo = ia + 1, step = 1
                while lo + step <= n {
                    guard let w = visible(lo + step) else { break }
                    lo += step
                    best = w
                    step *= 2
                }
                var hi = min(lo + step, n + 1)
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if let w = visible(mid) {
                        lo = mid
                        best = w
                    } else {
                        hi = mid
                    }
                }
                B = target(lo)!
                jb = lo
                seq = best
            } else {
                var sub: [(GridPoint, GridPoint)] = [(A, A)]
                if ia + 1 <= n - 1 { sub.append(contentsOf: P[(ia + 1)...(n - 1)]) }
                sub.append((G, G))
                let f = funnel(portals: sub)
                B = f[1].point
                jb = ia + f[1].index
                seq = Array(corridor[ia...min(jb, n - 1)])
            }
            points.append(Waypoint(point: B, index: jb))
            legs.append(seq)
            if jb == n { return (points, legs) }
            A = B
            ia = jb
            tA = corridor[jb]
        }
    }

    // MARK: B.9 grading and B.10 validation

    func grade(points: [Waypoint], legTriangles: [[Int]], cls: Classifier) -> ([RouteLeg], [LegViolation]) {
        var legs: [RouteLeg] = []
        var violations: [LegViolation] = []
        var lo = 0
        for (j, tl) in legTriangles.enumerated() {
            let A = points[j].point
            let B = points[j + 1].point
            let hi = lo + tl.count - 1
            var mask: UInt16 = 0
            var minDepth = Int.max
            var minSpare: Int?
            for t in tl {
                mask |= cls.yellowMask(t)
                let d = Int(pack.depth(t))
                minDepth = min(minDepth, d)
                if !cls.bits(t).contains(.viaMaint) {
                    let spare = d - cls.req
                    minSpare = min(minSpare ?? spare, spare)
                }
            }
            var reasons: [CautionReason] = []
            for (k, r) in CautionReason.allCases.enumerated() where mask & (1 << UInt16(k)) != 0 { reasons.append(r) }
            let (v, crossings) = validateLeg(A, B, cls: cls, leg: j)
            violations += v
            let length = distMeters(Double(A.x) / 1e7, Double(A.y) / 1e7, Double(B.x) / 1e7, Double(B.y) / 1e7)
            legs.append(RouteLeg(from: A, to: B, corridorRange: lo...hi, lengthMeters: length,
                                 grade: reasons.isEmpty ? .green : .yellow, reasons: reasons, minDepthDm: minDepth,
                                 minSpareDm: minSpare, crossings: crossings))
            lo = hi
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
            var uncharted: Bool?
            if opening {
                needs = c == 0xFFFE || c < cls.air
            } else if c == 0xFFFE {
                // No charted clearance (a fixed bridge part, a cable or a pipe): passed with a caution,
                // recorded on the crossing, never a violation (round 4).
                uncharted = true
            } else if c < cls.air {
                violations.append(LegViolation(kind: .clearance, leg: leg, record: o, distanceMeters: nil, valsouDm: nil,
                                               clearanceDm: c))
            }
            crossings.append(OverheadCrossing(record: o, clearanceDm: c, isOpeningSpan: opening, needsOpening: needs,
                                              uncharted: uncharted, name: pack.string(r.name)))
        }
        return (violations, crossings)
    }

    // MARK: B.12 summary

    func overheadName(_ index: UInt16) -> String {
        index == PackSentinel.noIndex ? "" : pack.string(pack.overheadObjects[Int(index)].name)
    }

    func summarize(corridor: [Int], legs: [RouteLeg], cls: Classifier) -> RouteSummary {
        var k = 0
        for i in 1..<corridor.count where pack.depth(corridor[i]) < pack.depth(corridor[k]) { k = i }
        let st = corridor[k]
        let shallowest = ShallowestPoint(depthDm: Int(pack.depth(st)), triangle: st, centroid: pack.centroid(of: st),
                                         maintained: cls.bits(st).contains(.viaMaint))
        var low: LowestClearance?
        var lowIndex = -1
        for i in 0..<corridor.count {
            let c = pack.clearance(corridor[i])
            if c < 0xFFFE && (lowIndex < 0 || c < pack.clearance(corridor[lowIndex])) { lowIndex = i }
        }
        if lowIndex >= 0 {
            let t = corridor[lowIndex]
            let ov = pack.overheadIndex(t)
            low = LowestClearance(clearanceDm: Int(pack.clearance(t)), overhead: ov == PackSentinel.noIndex ? nil : Int(ov),
                                  name: overheadName(ov), opening: pack.flags(t) & TriangleFlags.openingBridge.rawValue != 0)
        }
        func runs(_ bit: TriBits) -> [OverheadRun] {
            var out: [OverheadRun] = []
            var prev = false
            for (i, t) in corridor.enumerated() {
                let on = cls.bits(t).contains(bit)
                if on && !prev {
                    let ov = pack.overheadIndex(t)
                    let kind: Int = ov == PackSentinel.noIndex ? 0 : Int(pack.overheadObjects[Int(ov)].kind)
                    out.append(OverheadRun(corridorIndex: i, overhead: ov == PackSentinel.noIndex ? nil : Int(ov),
                                           clearanceDm: Int(pack.clearance(t)), name: overheadName(ov),
                                           kind: kind, centroid: pack.centroid(of: t)))
                }
                prev = on
            }
            return out
        }
        func areaRuns(_ bit: TriBits) -> [LockRun] {
            var out: [LockRun] = []
            var prev = false
            for (i, t) in corridor.enumerated() {
                let on = cls.bits(t).contains(bit)
                if on && !prev {
                    let ar = pack.areaIndex(t)
                    out.append(LockRun(corridorIndex: i, area: ar == PackSentinel.noIndex ? nil : Int(ar),
                                       name: ar == PackSentinel.noIndex ? "" : pack.string(pack.areas[Int(ar)].name),
                                       centroid: pack.centroid(of: t)))
                }
                prev = on
            }
            return out
        }
        let locks: [LockRun] = areaRuns(.lock)
        var advisoryIDs = Set<Int>()
        for t in corridor {
            for a in pack.advisorySets[pack.advisorySet(t)] { advisoryIDs.insert(a) }
        }
        let advisories: [AreaAdvisory] = advisoryIDs.sorted().map { a in
            let r = pack.areas[a]
            return AreaAdvisory(area: a, kind: Int(r.kind), source: Int(r.source), name: pack.string(r.name),
                                text: pack.string(r.text))
        }
        var total = 0.0
        for l in legs { total += l.lengthMeters }
        var maintained = 0
        for t in corridor where cls.bits(t).contains(.viaMaint) { maintained += 1 }
        return RouteSummary(distanceMeters: total, legCount: legs.count,
                            greenLegs: legs.filter { $0.grade == .green }.count,
                            yellowLegs: legs.filter { $0.grade == .yellow }.count,
                            shallowest: shallowest, lowestClearance: low, openings: runs(.needsOpening),
                            unknownClearances: runs(.unknownUsed), locks: locks, unchartedBridges: runs(.uncharted),
                            prohibitedAreas: areaRuns(.prohibited), advisories: advisories,
                            maintainedTriangles: maintained, dataDate: pack.dataDate)
    }

    // MARK: B.11 no route

    func noRouteReport(start: SnappedEndpoint, goal: SnappedEndpoint, cls: Classifier) throws(RoutingError) -> NoRouteReport {
        let profile = request.profile
        let relaxed = try astar(start: start, goal: goal, cls: cls, mode: .relaxed, phase: .noRouteReport)
        // Round 4: "accept unknown clearance" can no longer open a route, so it is never offered (always nil).
        var hints = RouteHints(useMaintainedChannels: profile.useMaintainedChannels ? nil : false,
                               acceptUnknownClearance: nil)
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
                let ar = pack.areaIndex(t)
                blocked.append(BlockedPlace(corridorIndex: i, triangle: t, reason: BlockReason.allCases[r],
                                            centroid: pack.centroid(of: t), depthDm: Int(pack.depth(t)),
                                            maintDm: Int(pack.maint(t)), clearanceDm: Int(pack.clearance(t)),
                                            overheadName: overheadName(pack.overheadIndex(t)),
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
        let reason: NoRouteReason = blocked.first.map { .blocked($0.reason) } ?? .notConnected
        return NoRouteReport(requiredDepthDm: cls.req, requiredAirDm: cls.air, start: start, goal: goal, reason: reason,
                             blocked: blocked, hints: hints, dataDate: pack.dataDate)
    }
}
