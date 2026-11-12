import Foundation
import NavCore
import Testing
@testable import RoutingKit

// Port of pipeline/routing/tests/test_regression.py: no route touches land, structures or blocking hazards of
// the RAW source data (which the router never sees), and every leg keeps the safety clearance: 12 m outside the
// bridge zones and 4 m inside them, each less 0.5 m for rounding and the metric.
//
// Fixtures (spec part D): testdata/routing/sarasota.obstacles.wkb.gz and sarasota.bridge_zone.wkb.gz, gzip-compressed
// WKB in EPSG:4326 degrees. Both are read here directly (gzip by RoutingKit's INFLATE, WKB below).

/// A point in the test's metric frame (metres).
struct MetricPoint: Hashable {
    var x: Double
    var y: Double
}

/// Raw-source geometry flattened into its parts, in degrees (x = lon, y = lat).
struct SourceGeometry {
    var points: [MetricPoint] = []
    var lines: [[MetricPoint]] = []
    /// Each polygon is a list of rings (exterior first), as stored in WKB (closed: last point == first point).
    var polygons: [[[MetricPoint]]] = []
}

struct WKBError: Error, CustomStringConvertible {
    var description: String
}

/// Minimal WKB reader (2-D Point, LineString, Polygon and their Multi*/GeometryCollection containers).
struct WKBReader {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw WKBError(description: "WKB truncated") }
        pos += 1
        return bytes[pos - 1]
    }

    mutating func u32(_ little: Bool) throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw WKBError(description: "WKB truncated") }
        var v: UInt32 = 0
        for k in 0..<4 {
            let b = UInt32(bytes[pos + k])
            v |= little ? b << UInt32(8 * k) : b << UInt32(8 * (3 - k))
        }
        pos += 4
        return v
    }

    mutating func f64(_ little: Bool) throws -> Double {
        guard pos + 8 <= bytes.count else { throw WKBError(description: "WKB truncated") }
        var v: UInt64 = 0
        for k in 0..<8 {
            let b = UInt64(bytes[pos + k])
            v |= little ? b << UInt64(8 * k) : b << UInt64(8 * (7 - k))
        }
        pos += 8
        return Double(bitPattern: v)
    }

    mutating func point(_ little: Bool) throws -> MetricPoint {
        let x: Double = try f64(little)
        let y: Double = try f64(little)
        return MetricPoint(x: x, y: y)
    }

    mutating func pointList(_ little: Bool) throws -> [MetricPoint] {
        let n = Int(try u32(little))
        var out: [MetricPoint] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try point(little)) }
        return out
    }

    mutating func geometry(into g: inout SourceGeometry) throws {
        let little: Bool = try u8() == 1
        let type: UInt32 = try u32(little)
        switch type {
        case 1:
            g.points.append(try point(little))
        case 2:
            g.lines.append(try pointList(little))
        case 3:
            let rings = Int(try u32(little))
            var polygon: [[MetricPoint]] = []
            for _ in 0..<rings { polygon.append(try pointList(little)) }
            g.polygons.append(polygon)
        case 4, 5, 6, 7:
            let n = Int(try u32(little))
            for _ in 0..<n { try geometry(into: &g) }
        default:
            throw WKBError(description: "unsupported WKB geometry type \(type)")
        }
    }

    static func read(_ bytes: [UInt8]) throws -> SourceGeometry {
        var r = WKBReader(bytes)
        var g = SourceGeometry()
        try r.geometry(into: &g)
        guard r.pos == bytes.count else { throw WKBError(description: "trailing bytes after WKB") }
        return g
    }
}

/// An edge (or point, when a == b) with its bounding box.
struct ObstacleEdge {
    var a: MetricPoint
    var b: MetricPoint
    var minX: Double, minY: Double, maxX: Double, maxY: Double

    init(_ a: MetricPoint, _ b: MetricPoint) {
        self.a = a
        self.b = b
        minX = min(a.x, b.x)
        minY = min(a.y, b.y)
        maxX = max(a.x, b.x)
        maxY = max(a.y, b.y)
    }
}

/// A polygon for point-in-polygon tests: rings as coordinate arrays, plus a bounding box.
struct ObstaclePolygon {
    var ringsX: [[Double]]
    var ringsY: [[Double]]
    var minX: Double, minY: Double, maxX: Double, maxY: Double

    /// Even-odd over all rings (exterior and holes).
    func contains(_ p: MetricPoint) -> Bool {
        guard p.x >= minX, p.x <= maxX, p.y >= minY, p.y <= maxY else { return false }
        var inside = false
        for k in 0..<ringsX.count where pointInRing(p.x, p.y, ringsX[k], ringsY[k]) { inside.toggle() }
        return inside
    }
}

/// The geometry in the test's metric frame: equirectangular about lat0 (as the Python test).
struct MetricGeometry {
    var edges: [ObstacleEdge] = []
    var polygons: [ObstaclePolygon] = []

    static let lat0: Double = 27.35

    static func metric(_ p: MetricPoint) -> MetricPoint {
        MetricPoint(x: p.x * metersPerDegree * cos(lat0 * degToRad), y: p.y * metersPerDegree)
    }

    init(_ g: SourceGeometry) {
        for p in g.points {
            let m = Self.metric(p)
            edges.append(ObstacleEdge(m, m))
        }
        for line in g.lines {
            let m: [MetricPoint] = line.map { Self.metric($0) }
            if m.count == 1 { edges.append(ObstacleEdge(m[0], m[0])) }
            for i in 0..<max(m.count - 1, 0) { edges.append(ObstacleEdge(m[i], m[i + 1])) }
        }
        for polygon in g.polygons {
            var xs: [[Double]] = [], ys: [[Double]] = []
            var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
            for ring in polygon {
                let m: [MetricPoint] = ring.map { Self.metric($0) }
                for i in 0..<max(m.count - 1, 0) { edges.append(ObstacleEdge(m[i], m[i + 1])) }
                xs.append(m.map(\.x))
                ys.append(m.map(\.y))
                for p in m {
                    x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
                }
            }
            polygons.append(ObstaclePolygon(ringsX: xs, ringsY: ys, minX: x0, minY: y0, maxX: x1, maxY: y1))
        }
    }

    /// Distance from segment pq to the geometry, exact up to `cutoff` (larger values are reported as found or as
    /// infinity): 0 when the segment touches an edge or point or an endpoint lies inside a polygon.
    func distance(_ p: MetricPoint, _ q: MetricPoint, cutoff: Double) -> Double {
        for poly in polygons where poly.contains(p) || poly.contains(q) { return 0 }
        let sx0 = min(p.x, q.x) - cutoff, sx1 = max(p.x, q.x) + cutoff
        let sy0 = min(p.y, q.y) - cutoff, sy1 = max(p.y, q.y) + cutoff
        var best = Double.infinity
        for e in edges where e.maxX >= sx0 && e.minX <= sx1 && e.maxY >= sy0 && e.minY <= sy1 {
            let d: Double = segmentSegmentDistance(p.x, p.y, q.x, q.y, e.a.x, e.a.y, e.b.x, e.b.y)
            if d < best { best = d }
            if best == 0 { return 0 }
        }
        return best
    }

    /// The parts of segment pq outside every polygon (the zones), as (from, to) pairs.
    func partsOutside(_ p: MetricPoint, _ q: MetricPoint) -> [(MetricPoint, MetricPoint)] {
        let dx = q.x - p.x, dy = q.y - p.y
        var params: [Double] = [0, 1]
        for e in edges where e.a != e.b {
            let fx = e.b.x - e.a.x, fy = e.b.y - e.a.y
            let den = dx * fy - dy * fx
            if den == 0 { continue }
            let s = ((e.a.x - p.x) * fy - (e.a.y - p.y) * fx) / den
            let u = ((e.a.x - p.x) * dy - (e.a.y - p.y) * dx) / den
            if s >= 0 && s <= 1 && u >= 0 && u <= 1 { params.append(s) }
        }
        params.sort()
        var out: [(MetricPoint, MetricPoint)] = []
        for k in 0..<(params.count - 1) {
            let s0 = params[k], s1 = params[k + 1]
            if s1 - s0 <= 1e-12 { continue }
            let sm = 0.5 * (s0 + s1)
            let mid = MetricPoint(x: p.x + sm * dx, y: p.y + sm * dy)
            var inZone = false
            for poly in polygons where poly.contains(mid) { inZone = true }
            if !inZone {
                out.append((MetricPoint(x: p.x + s0 * dx, y: p.y + s0 * dy), MetricPoint(x: p.x + s1 * dx, y: p.y + s1 * dy)))
            }
        }
        return out
    }
}

enum SourceFixtures {
    static func load(_ name: String) throws -> MetricGeometry {
        let gz: [UInt8] = try Fixtures.bytes(name)
        let wkb: [UInt8] = try Gzip.decompress(gz)
        return MetricGeometry(try WKBReader.read(wkb))
    }
}

@Suite struct ObstacleRegressionTests {
    @Test func gzipAndWKBFixturesDecode() throws {
        let obstacles: MetricGeometry = try SourceFixtures.load("sarasota.obstacles.wkb.gz")
        let zones: MetricGeometry = try SourceFixtures.load("sarasota.bridge_zone.wkb.gz")
        // 794 parts (52 polygons, 441 lines, 301 points) and 23 bridge-zone polygons.
        #expect(obstacles.polygons.count == 52)
        #expect(zones.polygons.count == 23)
        #expect(obstacles.edges.count > 9000)
        #expect(throws: InflateError.self) { try Gzip.decompress([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]) }
    }

    /// Clearances of one route; returns the problems found.
    func check(_ r: RouteResult, _ id: String, obstacles: MetricGeometry, zones: MetricGeometry) -> [String] {
        var problems: [String] = []
        let pts: [MetricPoint] = r.waypoints.map { MetricGeometry.metric(MetricPoint(x: $0.longitude, y: $0.latitude)) }
        var minAll = Double.infinity, minOutside = Double.infinity
        for i in 0..<max(pts.count - 1, 0) {
            let d: Double = obstacles.distance(pts[i], pts[i + 1], cutoff: 20)
            minAll = min(minAll, d)
            for (a, b) in zones.partsOutside(pts[i], pts[i + 1]) {
                minOutside = min(minOutside, obstacles.distance(a, b, cutoff: 20))
            }
        }
        if minAll == 0 { problems.append("\(id): route touches a source obstacle") }
        if minAll < 3.5 { problems.append("\(id): \(minAll) m from an obstacle inside a bridge zone (< 3.5 m)") }
        if minOutside < 11.5 { problems.append("\(id): \(minOutside) m from an obstacle outside the bridge zones (< 11.5 m)") }
        return problems
    }

    @Test func sarasotaRoutesClearOfSourceObstacles() throws {
        let obstacles: MetricGeometry = try SourceFixtures.load("sarasota.obstacles.wkb.gz")
        let zones: MetricGeometry = try SourceFixtures.load("sarasota.bridge_zone.wkb.gz")
        let pack = Fixtures.sarasota
        let file = try Fixtures.decode(VectorFile.self, "sarasota.vectors.json")
        var problems: [String] = []
        var forward = 0, backward = 0
        for q in file.queries {
            guard let r = try? pack.routeSynchronously(q.request) else { continue }
            forward += 1
            problems += check(r, q.id, obstacles: obstacles, zones: zones)
            let rev = RouteRequest(start: q.request.goal, goal: q.request.start, profile: q.request.profile)
            if let back = try? pack.routeSynchronously(rev) {
                backward += 1
                problems += check(back, "\(q.id) reversed", obstacles: obstacles, zones: zones)
            }
        }
        print("[regression] sarasota: \(forward) routes and \(backward) reversed routes checked against the raw source obstacles")
        #expect(forward >= 3)
        #expect(backward == forward)
        #expect(problems.isEmpty, "\(problems.prefix(10))")
    }
}
