import Foundation

// Spec B.1 constants and the floating-point helpers of B.6 and B.10. Operation order follows the spec
// (and the reference router where the spec is silent) so results match the vectors bit for bit.

/// Mean Earth radius, metres.
let earthRadius: Double = 6371008.8
/// π/180 as a double.
let degToRad: Double = 0.017453292519943295
/// Metres per degree of latitude: R · DEG.
let metersPerDegree: Double = earthRadius * degToRad
/// Heuristic multiplier (B.5).
let fMin: Double = 0.8
/// B.10: a leg within this distance of an overhead point object passes under it.
let overheadPointMeters: Double = 1.0

/// Spec B.1: equirectangular distance about the mean latitude. Degrees in, metres out.
@inline(__always) func distMeters(_ lon1: Double, _ lat1: Double, _ lon2: Double, _ lat2: Double) -> Double {
    let phi = (lat1 + lat2) * 0.5 * degToRad
    let dx = (lon2 - lon1) * degToRad * cos(phi)
    let dy = (lat2 - lat1) * degToRad
    return earthRadius * (dx * dx + dy * dy).squareRoot()
}

/// `floor(deg · 1e7 + 0.5)` (B.6 step 1), or nil when the result is not a finite Int32.
func toUnits(_ deg: Double) -> Int32? {
    let v = (deg * 1e7 + 0.5).rounded(.down)
    guard v.isFinite, v >= -2_147_483_648, v <= 2_147_483_647 else { return nil }
    return Int32(v)
}

/// Closest point of segment AB to P in a planar frame.
@inline(__always) func closestOnSegment(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                                        _ px: Double, _ py: Double) -> (Double, Double) {
    let dx = bx - ax, dy = by - ay
    let l2 = dx * dx + dy * dy
    if l2 == 0 { return (ax, ay) }
    var s = ((px - ax) * dx + (py - ay) * dy) / l2
    s = s < 0 ? 0.0 : (s > 1 ? 1.0 : s)
    return (ax + s * dx, ay + s * dy)
}

/// B.6: closest point of a triangle (local frame, vertices in edge order) to the origin.
/// Returns (distance, qx, qy).
func closestOnTriangle(_ X: (Double, Double, Double), _ Y: (Double, Double, Double)) -> (Double, Double, Double) {
    let xs = [X.0, X.1, X.2], ys = [Y.0, Y.1, Y.2]
    var inside = true
    for k in 0..<3 {
        let ax = xs[k], ay = ys[k], bx = xs[(k + 1) % 3], by = ys[(k + 1) % 3]
        if (bx - ax) * (0 - ay) - (by - ay) * (0 - ax) < 0 { inside = false }
    }
    if inside { return (0, 0, 0) }
    var best = (Double.infinity, 0.0, 0.0)
    for k in 0..<3 {
        let ax = xs[k], ay = ys[k], bx = xs[(k + 1) % 3], by = ys[(k + 1) % 3]
        let (qx, qy) = closestOnSegment(ax, ay, bx, by, 0.0, 0.0)
        let d = hypot(qx, qy)
        if d < best.0 { best = (d, qx, qy) }
    }
    return best
}

/// B.10 item 4: segment–segment distance (0 on a proper intersection).
func segmentSegmentDistance(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                            _ cx: Double, _ cy: Double, _ dx: Double, _ dy: Double) -> Double {
    @inline(__always) func o(_ px: Double, _ py: Double, _ qx: Double, _ qy: Double, _ rx: Double, _ ry: Double) -> Double {
        (qx - px) * (ry - py) - (qy - py) * (rx - px)
    }
    let d1 = o(ax, ay, bx, by, cx, cy), d2 = o(ax, ay, bx, by, dx, dy)
    let d3 = o(cx, cy, dx, dy, ax, ay), d4 = o(cx, cy, dx, dy, bx, by)
    if (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0) && d1 != 0 && d2 != 0 && d3 != 0 && d4 != 0 {
        return 0
    }
    var best = Double.infinity
    var (qx, qy) = closestOnSegment(ax, ay, bx, by, cx, cy)
    best = min(best, hypot(cx - qx, cy - qy))
    (qx, qy) = closestOnSegment(ax, ay, bx, by, dx, dy)
    best = min(best, hypot(dx - qx, dy - qy))
    (qx, qy) = closestOnSegment(cx, cy, dx, dy, ax, ay)
    best = min(best, hypot(ax - qx, ay - qy))
    (qx, qy) = closestOnSegment(cx, cy, dx, dy, bx, by)
    best = min(best, hypot(bx - qx, by - qy))
    return best
}

/// Even–odd point-in-ring test (the ring is not closed: the last point is not repeated).
func pointInRing(_ px: Double, _ py: Double, _ hx: [Double], _ hy: [Double]) -> Bool {
    var inside = false
    let n = hx.count
    var j = n - 1
    for i in 0..<n {
        if (hy[i] > py) != (hy[j] > py) {
            let xin = hx[i] + (py - hy[i]) * (hx[j] - hx[i]) / (hy[j] - hy[i])
            if px < xin { inside.toggle() }
        }
        j = i
    }
    return inside
}

/// Distance from P to the ring's boundary (closing edge included).
func ringBoundaryDistance(_ px: Double, _ py: Double, _ hx: [Double], _ hy: [Double]) -> Double {
    let n = hx.count
    var best = Double.infinity
    for i in 0..<n {
        let j = (i + 1) % n
        let (qx, qy) = closestOnSegment(hx[i], hy[i], hx[j], hy[j], px, py)
        best = min(best, hypot(px - qx, py - qy))
    }
    return best
}

/// B.10 item 4: distance between segment AB and a geometry (point, polyline, or ring with 0 inside).
func segmentGeometryDistance(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                             _ hx: [Double], _ hy: [Double], _ type: PackGeometryType) -> Double {
    let n = hx.count
    if type == .point || n == 1 {
        let (qx, qy) = closestOnSegment(ax, ay, bx, by, hx[0], hy[0])
        return hypot(qx - hx[0], qy - hy[0])
    }
    var best = Double.infinity
    let m = type == .ring ? n : n - 1
    for i in 0..<m {
        let j = (i + 1) % n
        let d = segmentSegmentDistance(ax, ay, bx, by, hx[i], hy[i], hx[j], hy[j])
        if d < best {
            best = d
            if d == 0 { return 0 }
        }
    }
    if type == .ring && pointInRing(ax, ay, hx, hy) { return 0 }
    return best
}

/// B.10 item 3 for point objects and rings, in the leg's local metric frame (polylines use the exact rule of
/// ``polylineCrossings(_:_:_:)``): does the leg AB pass under the geometry?
func segmentCrosses(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                    _ hx: [Double], _ hy: [Double], _ type: PackGeometryType) -> Bool {
    if type != .ring || hx.count == 1 {
        return segmentGeometryDistance(ax, ay, bx, by, hx, hy, .point) <= overheadPointMeters
    }
    let n = hx.count
    let dx = bx - ax, dy = by - ay
    var params: [Double] = [0.0, 1.0]
    let l2 = dx * dx + dy * dy
    for i in 0..<n {
        let j = (i + 1) % n
        let cx = hx[i], cy = hy[i], ex = hx[j], ey = hy[j]
        let fx = ex - cx, fy = ey - cy
        let den = dx * fy - dy * fx
        if den != 0 {
            let s = ((cx - ax) * fy - (cy - ay) * fx) / den
            let u = ((cx - ax) * dy - (cy - ay) * dx) / den
            if s >= 0 && s <= 1 && u >= 0 && u <= 1 { params.append(s) }
        }
        if l2 > 0 {
            for (px, py) in [(cx, cy), (ex, ey)] {
                let s = ((px - ax) * dx + (py - ay) * dy) / l2
                if s >= 0 && s <= 1 {
                    let qx = ax + s * dx, qy = ay + s * dy
                    if hypot(px - qx, py - qy) <= 1e-6 { params.append(s) }
                }
            }
        }
    }
    params = Array(Set(params)).sorted()
    for k in 0..<(params.count - 1) {
        let s0 = params[k], s1 = params[k + 1]
        if s1 - s0 <= 1e-12 { continue }
        let sm = 0.5 * (s0 + s1)
        let mx = ax + sm * dx, my = ay + sm * dy
        if pointInRing(mx, my, hx, hy) && ringBoundaryDistance(mx, my, hx, hy) > 1e-6 { return true }
    }
    return false
}

/// One overhead polyline for ``polylineCrossings(_:_:_:)``: consecutive duplicate points removed, at least two points.
struct PolylineGeometry {
    var record: Int
    var points: [GridPoint]
}

/// Polyline points with consecutive duplicates removed.
func dedupeConsecutive(_ points: [GridPoint]) -> [GridPoint] {
    var out: [GridPoint] = []
    out.reserveCapacity(points.count)
    for p in points where out.last != p { out.append(p) }
    return out
}

/// B.10 polyline rule, exact on integer units (all points lie in the header bbox, so every product fits in Int64).
/// Returns the records the leg AB passes under:
/// 1. AB properly crosses one of its segments (all four orientations non-zero, pairwise opposite);
/// 2. AB overlaps one of its segments collinearly over a positive length;
/// 3. A or B lies on the polyline (closed segments);
/// 4. AB passes through a point V strictly between A and B where polyline vertices lie, and the arms leaving V
///    (neighbouring vertices, over every polyline record with a vertex at V) lie strictly on both sides of AB:
///    every record with an arm at V is crossed.
/// A leg that only touches a polyline (all arms at the touching vertex on one side) does not pass under it.
func polylineCrossings(_ A: GridPoint, _ B: GridPoint, _ lines: [PolylineGeometry]) -> Set<Int> {
    let ax = Int64(A.x), ay = Int64(A.y), bx = Int64(B.x), by = Int64(B.y)
    let dx = bx - ax, dy = by - ay
    let l2 = dx * dx + dy * dy
    var crossed = Set<Int>()
    var positive: [GridPoint: Bool] = [:]
    var negative: [GridPoint: Bool] = [:]
    var armRecords: [GridPoint: [Int]] = [:]

    func onSegment(_ px: Int64, _ py: Int64, _ c: GridPoint, _ d: GridPoint) -> Bool {
        let cx = Int64(c.x), cy = Int64(c.y), ex = Int64(d.x), ey = Int64(d.y)
        return orient(cx, cy, ex, ey, px, py) == 0 && px >= min(cx, ex) && px <= max(cx, ex)
            && py >= min(cy, ey) && py <= max(cy, ey)
    }

    for line in lines {
        let pts = line.points
        let m = pts.count
        var hit = false
        for i in 0..<(m - 1) {
            let c = pts[i], d = pts[i + 1]
            let cx = Int64(c.x), cy = Int64(c.y), ex = Int64(d.x), ey = Int64(d.y)
            let o1: Int64 = orient(ax, ay, bx, by, cx, cy)
            let o2: Int64 = orient(ax, ay, bx, by, ex, ey)
            let o3: Int64 = orient(cx, cy, ex, ey, ax, ay)
            let o4: Int64 = orient(cx, cy, ex, ey, bx, by)
            if o1 != 0 && o2 != 0 && o3 != 0 && o4 != 0 && (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0) {
                hit = true
            } else if o1 == 0 && o2 == 0 {
                let tc: Int64 = (cx - ax) * dx + (cy - ay) * dy
                let td: Int64 = (ex - ax) * dx + (ey - ay) * dy
                if max(min(tc, td), 0) < min(max(tc, td), l2) { hit = true }
            }
            if onSegment(ax, ay, c, d) || onSegment(bx, by, c, d) { hit = true }
        }
        for i in 0..<m {
            let v = pts[i]
            let vx = Int64(v.x), vy = Int64(v.y)
            guard orient(ax, ay, bx, by, vx, vy) == 0 else { continue }
            let t: Int64 = (vx - ax) * dx + (vy - ay) * dy
            guard t > 0 && t < l2 else { continue }
            for k in [i - 1, i + 1] where k >= 0 && k < m {
                let side: Int64 = orient(ax, ay, bx, by, Int64(pts[k].x), Int64(pts[k].y))
                if side == 0 { continue }
                if side > 0 { positive[v] = true } else { negative[v] = true }
                armRecords[v, default: []].append(line.record)
            }
        }
        if hit { crossed.insert(line.record) }
    }
    for (v, records) in armRecords where positive[v] == true && negative[v] == true {
        crossed.formUnion(records)
    }
    return crossed
}
