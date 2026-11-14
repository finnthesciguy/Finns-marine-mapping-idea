import Foundation
import NavCore

/// Packs track points into compact little-endian blobs, 36 bytes per point:
/// time (Float64, seconds since 1970, NaN = none), latitude and longitude (Float64),
/// speed, course and accuracy (Float32, NaN = none).
enum TrackPointCodec {
    static let bytesPerPoint = 36
    /// Points per stored chunk. Small appends are coalesced into the last chunk up to this size.
    static let chunkCapacity = 512

    static func encode(_ points: some Collection<TrackPoint>) -> Data {
        var data = Data(count: points.count * bytesPerPoint)
        data.withUnsafeMutableBytes { raw in
            var o = 0
            func put64(_ v: Double) { raw.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: o, as: UInt64.self); o += 8 }
            func put32(_ v: Double?) {
                let f = v.map { Float($0) } ?? .nan
                raw.storeBytes(of: f.bitPattern.littleEndian, toByteOffset: o, as: UInt32.self); o += 4
            }
            for p in points {
                put64(p.timestamp?.timeIntervalSince1970 ?? .nan)
                put64(p.coordinate.latitude)
                put64(p.coordinate.longitude)
                put32(p.speed)
                put32(p.course)
                put32(p.horizontalAccuracy)
            }
        }
        return data
    }

    static func decode(_ data: Data, into out: inout [TrackPoint]) throws(PersistenceError) {
        guard data.count % bytesPerPoint == 0 else {
            throw .decoding("track chunk of \(data.count) bytes is not a multiple of \(bytesPerPoint)")
        }
        let n = data.count / bytesPerPoint
        out.reserveCapacity(out.count + n)
        data.withUnsafeBytes { raw in
            var o = 0
            func get64() -> Double {
                let v = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt64.self)))
                o += 8
                return v
            }
            func get32() -> Double? {
                let v = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
                o += 4
                return v.isNaN ? nil : Double(v)
            }
            for _ in 0..<n {
                let t = get64()
                let lat = get64(), lon = get64()
                let speed = get32(), course = get32(), acc = get32()
                out.append(TrackPoint(timestamp: t.isNaN ? nil : Date(timeIntervalSince1970: t),
                                      coordinate: Coordinate(latitude: lat, longitude: lon),
                                      speed: speed, course: course, horizontalAccuracy: acc))
            }
        }
    }

    static func decode(_ data: Data) throws(PersistenceError) -> [TrackPoint] {
        var out: [TrackPoint] = []
        try decode(data, into: &out)
        return out
    }
}

/// Incremental track statistics. Feed points in order with `segment` breaks; the running state can be
/// resumed from the last stored point, so appends never re-read the whole track.
struct TrackStatisticsAccumulator {
    var stats: TrackStatistics
    var startDate: Date?
    var endDate: Date?
    /// Last point and its segment index.
    var last: (point: TrackPoint, segment: Int)?

    init(stats: TrackStatistics = TrackStatistics(), startDate: Date? = nil, endDate: Date? = nil,
         last: (point: TrackPoint, segment: Int)? = nil) {
        self.stats = stats
        self.startDate = startDate
        self.endDate = endDate
        self.last = last
    }

    mutating func add(_ p: TrackPoint, segment: Int) {
        stats.pointCount += 1
        if last == nil || last!.segment != segment { stats.segmentCount += 1 }
        let c = p.coordinate
        if var b = stats.bounds {
            b.south = min(b.south, c.latitude); b.north = max(b.north, c.latitude)
            b.west = min(b.west, c.longitude); b.east = max(b.east, c.longitude)
            stats.bounds = b
        } else {
            stats.bounds = BoundingBox(south: c.latitude, west: c.longitude, north: c.latitude, east: c.longitude)
        }
        if let t = p.timestamp {
            if startDate == nil || t < startDate! { startDate = t }
            if endDate == nil || t > endDate! { endDate = t }
        }
        var speed = p.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let (prev, seg) = last, seg == segment {
            let d = Geodesy.distance(from: prev.coordinate, to: c)
            if d.isFinite { stats.distance = Distance(meters: stats.distance.meters + d) }
            if let t0 = prev.timestamp, let t1 = p.timestamp {
                let dt = t1.timeIntervalSince(t0)
                if dt > 0 { stats.duration += dt }
                if speed == nil, dt >= 1, d.isFinite { speed = d / dt }
            }
        }
        if let s = speed, s > (stats.maxSpeed?.metersPerSecond ?? -1) { stats.maxSpeed = Speed(metersPerSecond: s) }
        last = (p, segment)
    }
}

/// How much detail to return from ``PersistenceStore/trackGeometry(_:detail:)``.
public enum GeometryDetail: Sendable, Hashable {
    /// Every point.
    case full
    /// Douglas–Peucker with this tolerance in metres.
    case tolerance(meters: Double)
    /// Douglas–Peucker with a tolerance of `pixels` screen pixels at a web-map zoom level and latitude.
    case zoom(Double, latitude: Double, pixels: Double = 1)
    /// Keep every n-th point (plus each segment's first and last point).
    case everyNth(Int)

    var toleranceMeters: Double? {
        switch self {
        case .full, .everyNth: return nil
        case .tolerance(let m): return m
        case .zoom(let z, let lat, let px): return WebMercator.metersPerPixel(latitude: lat, zoom: z) * px
        }
    }
}

/// Polyline simplification.
public enum Simplify {
    /// Douglas–Peucker simplification. Distances are measured in a local equirectangular projection,
    /// which is accurate to well under 1% over the extent of a track. Iterative (no recursion depth limit).
    /// Always keeps the first and last point.
    public static func douglasPeucker(_ points: [Coordinate], toleranceMeters: Double) -> [Coordinate] {
        guard points.count > 2, toleranceMeters > 0 else { return points }
        let lat0 = points[points.count / 2].latitude * .pi / 180
        let ky = Geodesy.earthMeanRadius * .pi / 180
        let kx = ky * cos(lat0)
        let xs = points.map { $0.longitude * kx }
        let ys = points.map { $0.latitude * ky }
        let tol2 = toleranceMeters * toleranceMeters
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let ax = xs[a], ay = ys[a]
            let dx = xs[b] - ax, dy = ys[b] - ay
            let len2 = dx * dx + dy * dy
            var maxD2 = -1.0, idx = a
            for i in (a + 1)..<b {
                let px = xs[i] - ax, py = ys[i] - ay
                let d2: Double
                if len2 == 0 {
                    d2 = px * px + py * py
                } else {
                    let t = max(0, min(1, (px * dx + py * dy) / len2))
                    let ex = px - t * dx, ey = py - t * dy
                    d2 = ex * ex + ey * ey
                }
                if d2 > maxD2 { maxD2 = d2; idx = i }
            }
            if maxD2 > tol2 {
                keep[idx] = true
                stack.append((a, idx))
                stack.append((idx, b))
            }
        }
        var out: [Coordinate] = []
        for i in points.indices where keep[i] { out.append(points[i]) }
        return out
    }

    /// Every n-th point, always keeping the first and last.
    public static func everyNth(_ points: [Coordinate], _ n: Int) -> [Coordinate] {
        guard n > 1, points.count > 2 else { return points }
        var out: [Coordinate] = []
        out.reserveCapacity(points.count / n + 2)
        for i in stride(from: 0, to: points.count, by: n) { out.append(points[i]) }
        if (points.count - 1) % n != 0 { out.append(points[points.count - 1]) }
        return out
    }
}
