import Foundation
import NavCore

/// Spatial point-location grid (spec A.5 GRID).
public struct GridIndexInfo: Hashable, Sendable {
    public var originLon: Int32
    public var originLat: Int32
    /// Cell size in units.
    public var cell: Int32
    public var nx: Int
    public var ny: Int
    /// Total number of triangle ids over all cells.
    public var totalIDs: Int
}

/// A routing pack loaded into memory: one region, decoded once into compact fixed-width arrays.
///
/// Immutable after loading and therefore `Sendable`: share one instance between concurrent queries.
/// Open with ``init(contentsOf:)`` (or ``init(data:)``); every structural problem is a ``PackError``.
public final class RoutingPack: Sendable {
    /// The decoded header.
    public let header: PackHeader
    /// The section table, in file order.
    public let sections: [PackSection]
    /// `INFO` key/value pairs (informative only; routing never reads them).
    public let info: [String: String]
    /// True when the file had no `ADJC` section and adjacency was derived (spec A.5).
    public let adjacencyWasDerived: Bool
    /// `SRCS` records.
    public let sources: [SourceCell]
    /// `OVHD` records.
    public let overheadObjects: [OverheadObject]
    /// `HAZD` records.
    public let hazards: [Hazard]
    /// `CHAN` records.
    public let channels: [Channel]
    /// `AREA` records.
    public let areas: [RegulatedArea]
    /// GRID parameters.
    public let gridInfo: GridIndexInfo

    // Mesh, as flat fixed-width arrays (no per-triangle objects).
    let lon: ContiguousArray<Int32>
    let lat: ContiguousArray<Int32>
    /// 3 vertex indices per triangle.
    let tris: ContiguousArray<Int32>
    /// 3 neighbour triangles per triangle, -1 = boundary.
    let nbr: ContiguousArray<Int32>
    // ATTR columns.
    let depth: ContiguousArray<Int16>
    let band: ContiguousArray<Int16>
    let maint: ContiguousArray<Int16>
    let clr: ContiguousArray<UInt16>
    let flags: ContiguousArray<UInt16>
    let chan: ContiguousArray<UInt16>
    let ovhd: ContiguousArray<UInt16>
    let area: ContiguousArray<UInt16>
    let quality: ContiguousArray<UInt8>
    // GRID: ids of cell c are gridIDs[gridOffsets[c] ..< gridOffsets[c+1]].
    let gridOffsets: ContiguousArray<UInt32>
    let gridIDs: ContiguousArray<Int32>
    // GEOM pool: lon, lat interleaved.
    let geom: ContiguousArray<Int32>
    // STRS.
    let stringOffsets: ContiguousArray<UInt32>
    let stringBlob: ContiguousArray<UInt8>
    // Bounding boxes (minx, miny, maxx, maxy) of HAZD and OVHD geometry, for leg validation.
    let hazardBoxes: ContiguousArray<Int32>
    let overheadBoxes: ContiguousArray<Int32>

    /// Opens and fully validates a pack file. The file is memory-mapped while it is decoded and is
    /// not retained afterwards.
    public convenience init(contentsOf url: URL) throws(PackError) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw .unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        try self.init(data: data)
    }

    /// Decodes and validates a pack held in memory.
    public convenience init(data: Data) throws(PackError) {
        let result: Result<PackContents, PackError> = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return Result { () throws(PackError) -> PackContents in try PackParser(file: bytes).parse() }
        }
        self.init(contents: try result.get())
    }

    /// Decodes and validates a pack held in memory.
    public convenience init(bytes: [UInt8]) throws(PackError) {
        let result: Result<PackContents, PackError> = bytes.withUnsafeBufferPointer { p in
            Result { () throws(PackError) -> PackContents in try PackParser(file: p).parse() }
        }
        self.init(contents: try result.get())
    }

    init(contents c: PackContents) {
        header = c.header
        sections = c.sections
        info = c.info
        adjacencyWasDerived = c.adjacencyWasDerived
        sources = c.sources
        overheadObjects = c.overheads
        hazards = c.hazards
        channels = c.channels
        areas = c.areas
        gridInfo = c.gridInfo
        lon = c.lon
        lat = c.lat
        tris = c.tris
        nbr = c.nbr
        depth = c.depth
        band = c.band
        maint = c.maint
        clr = c.clr
        flags = c.flags
        chan = c.chan
        ovhd = c.ovhd
        area = c.area
        quality = c.quality
        gridOffsets = c.gridOffsets
        gridIDs = c.gridIDs
        geom = c.geom
        stringOffsets = c.stringOffsets
        stringBlob = c.stringBlob
        hazardBoxes = c.hazardBoxes
        overheadBoxes = c.overheadBoxes
    }

    // MARK: - Public accessors

    /// Region identifier from the header, e.g. `pilot`.
    public var regionID: String { header.regionID }
    /// The chart data date shown to the user.
    public var dataDate: PackDate { header.dataDate }
    public var vertexCount: Int { lon.count }
    public var triangleCount: Int { depth.count }
    /// Number of strings in `STRS`.
    public var stringCount: Int { stringOffsets.count - 1 }

    /// Vertex `i` in units.
    public func vertex(_ i: Int) -> GridPoint { GridPoint(x: lon[i], y: lat[i]) }

    /// The vertex indices `(a, b, c)` of triangle `t`, counter-clockwise, `a` smallest.
    public func triangleVertices(_ t: Int) -> (a: Int, b: Int, c: Int) {
        (Int(tris[3 * t]), Int(tris[3 * t + 1]), Int(tris[3 * t + 2]))
    }

    /// The triangles across edges 0, 1, 2 of `t` (-1 = boundary).
    public func neighbors(_ t: Int) -> (Int, Int, Int) {
        (Int(nbr[3 * t]), Int(nbr[3 * t + 1]), Int(nbr[3 * t + 2]))
    }

    /// The `ATTR` columns of triangle `t`.
    public func attributes(_ t: Int) -> TriangleAttributes {
        TriangleAttributes(depthDm: depth[t], bandDepthDm: band[t], maintDm: maint[t], clearanceDm: clr[t],
                           flags: flags[t], channel: chan[t], overhead: ovhd[t], area: area[t], quality: quality[t])
    }

    /// String `id` of `STRS` (empty for an out-of-range id).
    public func string(_ id: UInt32) -> String {
        let i = Int(id)
        guard i >= 0, i + 1 < stringOffsets.count else { return "" }
        let a = Int(stringOffsets[i]), b = Int(stringOffsets[i + 1])
        return String(decoding: stringBlob[a..<b], as: UTF8.self)
    }

    /// GEOM points `first ..< first + count`.
    public func geometry(first: UInt32, count: UInt32) -> [GridPoint] {
        let a = Int(first), n = Int(count)
        guard a >= 0, n >= 0, a + n <= geom.count / 2 else { return [] }
        return (a..<(a + n)).map { GridPoint(x: geom[2 * $0], y: geom[2 * $0 + 1]) }
    }

    /// Geometry of an `OVHD` record.
    public func geometry(of o: OverheadObject) -> [GridPoint] { geometry(first: o.geomFirst, count: o.geomCount) }
    /// Geometry of a `HAZD` record.
    public func geometry(of h: Hazard) -> [GridPoint] { geometry(first: h.geomFirst, count: h.geomCount) }

    /// The triangle ids listed in GRID cell `c` (`c = row * nx + column`).
    public func gridCellTriangles(_ c: Int) -> [Int] {
        guard c >= 0, c + 1 < gridOffsets.count else { return [] }
        return gridIDs[Int(gridOffsets[c])..<Int(gridOffsets[c + 1])].map { Int($0) }
    }

    /// True when `p` lies inside the header bounding box (inclusive).
    public func contains(_ p: GridPoint) -> Bool {
        p.x >= header.minLon && p.x <= header.maxLon && p.y >= header.minLat && p.y <= header.maxLat
    }

    /// True when triangle `t` contains `p` (edges and vertices count as inside, spec A.8).
    public func triangle(_ t: Int, contains p: GridPoint) -> Bool {
        let a = Int(tris[3 * t]), b = Int(tris[3 * t + 1]), c = Int(tris[3 * t + 2])
        let ax = Int64(lon[a]), ay = Int64(lat[a]), bx = Int64(lon[b]), by = Int64(lat[b])
        let cx = Int64(lon[c]), cy = Int64(lat[c]), px = Int64(p.x), py = Int64(p.y)
        return orient(ax, ay, bx, by, px, py) >= 0 && orient(bx, by, cx, cy, px, py) >= 0
            && orient(cx, cy, ax, ay, px, py) >= 0
    }

    /// GRID cell (row, column) for a point, clamped into the grid (spec A.5 lookup).
    func cellOf(x: Int64, y: Int64) -> (i: Int, j: Int) {
        let cell = Int64(gridInfo.cell)
        let j = min(max(floorDiv(x - Int64(gridInfo.originLon), cell), 0), Int64(gridInfo.nx - 1))
        let i = min(max(floorDiv(y - Int64(gridInfo.originLat), cell), 0), Int64(gridInfo.ny - 1))
        return (Int(i), Int(j))
    }

    /// The located triangle of B.6 step 3: the lowest id in the point's GRID cell that contains it.
    /// Nil outside the bounding box or when no triangle contains the point.
    public func locate(_ p: GridPoint) -> Int? {
        guard contains(p) else { return nil }
        let (i, j) = cellOf(x: Int64(p.x), y: Int64(p.y))
        let c = i * gridInfo.nx + j
        for k in Int(gridOffsets[c])..<Int(gridOffsets[c + 1]) {
            let t = Int(gridIDs[k])
            if triangle(t, contains: p) { return t }
        }
        return nil
    }

    /// Approximate bytes held by the decoded arrays (excluding small side tables' Swift overhead).
    public var memoryFootprintBytes: Int {
        lon.count * 4 + lat.count * 4 + tris.count * 4 + nbr.count * 4
            + depth.count * 17 + gridOffsets.count * 4 + gridIDs.count * 4 + geom.count * 4
            + stringOffsets.count * 4 + stringBlob.count + hazardBoxes.count * 4 + overheadBoxes.count * 4
            + overheadObjects.count * MemoryLayout<OverheadObject>.stride + hazards.count * MemoryLayout<Hazard>.stride
            + channels.count * MemoryLayout<Channel>.stride + areas.count * MemoryLayout<RegulatedArea>.stride
            + sources.count * MemoryLayout<SourceCell>.stride
    }
}

/// Exact orientation (spec A.8): twice the signed area of (p, q, r); positive when counter-clockwise.
@inline(__always) func orient(_ px: Int64, _ py: Int64, _ qx: Int64, _ qy: Int64, _ rx: Int64, _ ry: Int64) -> Int64 {
    (qx - px) * (ry - py) - (qy - py) * (rx - px)
}
