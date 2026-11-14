import Foundation
import Testing
@testable import RoutingKit

// `*.records.json`: decoded records of each section, used to check the reader independently of routing.

struct RecHeader: Decodable {
    var major: Int, minor: Int, headerSize: Int, fileSize: Int, sectionCount: Int, sectionTableOffset: Int
    var flags: UInt32
    var regionId: String
    var minLon: Int32, minLat: Int32, maxLon: Int32, maxLat: Int32
    var dataDate: UInt32, buildDate: UInt32, buildTime: UInt32
    var vertexCount: Int, triangleCount: Int
    var clearanceDm: Int, checkDm: Int, shoreRing0M: Int, shoreRing1M: Int
    var tableCrc32: UInt32
    var headerCrc32: UInt32
}

struct RecSection: Decodable {
    var name: String, count: Int, encoding: Int, offset: UInt64, storedLength: Int, rawLength: Int, crc32: UInt32
}

struct RecStrings: Decodable {
    var count: Int
    var first: [String: String]
}

struct RecVertex: Decodable { var index: Int, lon: Int32, lat: Int32 }

struct RecTriangle: Decodable {
    var index: Int, v: [Int], nbr: [Int]
    var depthDm: Int16, bandDepthDm: Int16, maintDm: Int16
    var clearanceDm: UInt16, flags: UInt16, channel: UInt16, overhead: UInt16, area: UInt16, quality: UInt8
}

struct RecGridCell: Decodable { var cell: Int, ids: [Int] }

struct RecGrid: Decodable {
    var originLon: Int32, originLat: Int32, cell: Int32, nx: Int, ny: Int, totalIds: Int
    var cells: [RecGridCell]
}

struct RecSource: Decodable {
    var index: Int, name: UInt32, edition: UInt16, update: UInt16, issueDate: UInt32, cscale: UInt32, band: UInt8, used: Int
}

struct RecOverhead: Decodable {
    var index: Int, kind: UInt8, flags: UInt8, catbrg: UInt16, clearanceDm: UInt16, openClearanceDm: UInt16
    var horClearanceDm: UInt16, name: UInt32, lon: Int32, lat: Int32, geomFirst: UInt32, geomCount: UInt32, geomType: UInt8
    var geom: [[Int32]]
}

struct RecHazard: Decodable {
    var index: Int, cls: UInt8, watlev: UInt8, category: UInt8, geomType: UInt8, valsouDm: Int16, lon: Int32, lat: Int32
    var geomFirst: UInt32, geomCount: UInt32, name: UInt32
    var geom: [[Int32]]
}

struct RecChannel: Decodable {
    var index: Int, source: UInt8, flags: UInt8, maintDm: Int16, authDm: Int16, name: UInt32, ident: UInt32, desc: UInt32
    var date: UInt32, lon: Int32, lat: Int32
}

struct RecArea: Decodable {
    var index: Int, kind: UInt8, source: UInt8, name: UInt32, text: UInt32, lon: Int32, lat: Int32
}

struct RecordsFile: Decodable {
    var file: String
    var header: RecHeader
    var sections: [RecSection]
    var info: [String: String]
    var strings: RecStrings
    var vertices: [RecVertex]
    var triangles: [RecTriangle]
    var grid: RecGrid
    var sources: [RecSource]
    var overhead: [RecOverhead]
    var hazards: [RecHazard]
    var channels: [RecChannel]
    var areas: [RecArea]
}

/// Field lists for comparing records one statement at a time (keeps every expression cheap to type-check).
struct Fields {
    var values: [Int64] = []
    mutating func add<T: BinaryInteger>(_ v: T) { values.append(Int64(v)) }
}

func headerFields(_ h: PackHeader) -> [Int64] {
    var f = Fields()
    f.add(h.formatMajor); f.add(h.formatMinor); f.add(h.headerSize); f.add(h.fileSize); f.add(h.sectionCount)
    f.add(h.sectionTableOffset); f.add(h.flags); f.add(h.minLon); f.add(h.minLat); f.add(h.maxLon); f.add(h.maxLat)
    f.add(h.dataDate.rawValue); f.add(h.buildDate.rawValue); f.add(h.buildTime); f.add(h.vertexCount)
    f.add(h.triangleCount); f.add(h.clearanceDm); f.add(h.checkDm); f.add(h.shoreRing0M); f.add(h.shoreRing1M)
    f.add(h.tableCRC32); f.add(h.headerCRC32)
    return f.values
}

func headerFields(_ w: RecHeader) -> [Int64] {
    var f = Fields()
    f.add(w.major); f.add(w.minor); f.add(w.headerSize); f.add(w.fileSize); f.add(w.sectionCount)
    f.add(w.sectionTableOffset); f.add(w.flags); f.add(w.minLon); f.add(w.minLat); f.add(w.maxLon); f.add(w.maxLat)
    f.add(w.dataDate); f.add(w.buildDate); f.add(w.buildTime); f.add(w.vertexCount)
    f.add(w.triangleCount); f.add(w.clearanceDm); f.add(w.checkDm); f.add(w.shoreRing0M); f.add(w.shoreRing1M)
    f.add(w.tableCrc32); f.add(w.headerCrc32)
    return f.values
}

func sectionFields(_ s: PackSection) -> [Int64] {
    var f = Fields()
    f.add(s.count); f.add(s.encoding); f.add(s.offset); f.add(s.storedLength); f.add(s.rawLength); f.add(s.crc32)
    return f.values
}

func sectionFields(_ s: RecSection) -> [Int64] {
    var f = Fields()
    f.add(s.count); f.add(s.encoding); f.add(s.offset); f.add(s.storedLength); f.add(s.rawLength); f.add(s.crc32)
    return f.values
}

func triangleFields(_ pack: RoutingPack, _ t: Int) -> [Int64] {
    var f = Fields()
    let (a, b, c) = pack.triangleVertices(t)
    f.add(a); f.add(b); f.add(c)
    let (n0, n1, n2) = pack.neighbors(t)
    f.add(n0); f.add(n1); f.add(n2)
    let at: TriangleAttributes = pack.attributes(t)
    f.add(at.depthDm); f.add(at.bandDepthDm); f.add(at.maintDm); f.add(at.clearanceDm); f.add(at.flags)
    f.add(at.channel); f.add(at.overhead); f.add(at.area); f.add(at.quality)
    return f.values
}

func triangleFields(_ t: RecTriangle) -> [Int64] {
    var f = Fields()
    for v in t.v { f.add(v) }
    for n in t.nbr { f.add(n) }
    f.add(t.depthDm); f.add(t.bandDepthDm); f.add(t.maintDm); f.add(t.clearanceDm); f.add(t.flags)
    f.add(t.channel); f.add(t.overhead); f.add(t.area); f.add(t.quality)
    return f.values
}

func gridFields(_ g: GridIndexInfo) -> [Int64] {
    var f = Fields()
    f.add(g.originLon); f.add(g.originLat); f.add(g.cell); f.add(g.nx); f.add(g.ny); f.add(g.totalIDs)
    return f.values
}

func gridFields(_ g: RecGrid) -> [Int64] {
    var f = Fields()
    f.add(g.originLon); f.add(g.originLat); f.add(g.cell); f.add(g.nx); f.add(g.ny); f.add(g.totalIds)
    return f.values
}

func sourceFields(_ r: SourceCell) -> [Int64] {
    var f = Fields()
    f.add(r.name); f.add(r.edition); f.add(r.update); f.add(r.issueDate.rawValue); f.add(r.compilationScale)
    f.add(r.usageBand); f.add(r.used ? 1 : 0)
    return f.values
}

func sourceFields(_ s: RecSource) -> [Int64] {
    var f = Fields()
    f.add(s.name); f.add(s.edition); f.add(s.update); f.add(s.issueDate); f.add(s.cscale); f.add(s.band); f.add(s.used)
    return f.values
}

func overheadFields(_ r: OverheadObject) -> [Int64] {
    var f = Fields()
    f.add(r.kind); f.add(r.flags); f.add(r.catbrg); f.add(r.clearanceDm); f.add(r.openClearanceDm)
    f.add(r.horizontalClearanceDm); f.add(r.name); f.add(r.lon); f.add(r.lat); f.add(r.geomFirst); f.add(r.geomCount)
    f.add(r.geomType.rawValue)
    return f.values
}

func overheadFields(_ o: RecOverhead) -> [Int64] {
    var f = Fields()
    f.add(o.kind); f.add(o.flags); f.add(o.catbrg); f.add(o.clearanceDm); f.add(o.openClearanceDm)
    f.add(o.horClearanceDm); f.add(o.name); f.add(o.lon); f.add(o.lat); f.add(o.geomFirst); f.add(o.geomCount)
    f.add(o.geomType)
    return f.values
}

func hazardFields(_ r: Hazard) -> [Int64] {
    var f = Fields()
    f.add(r.cls); f.add(r.watlev); f.add(r.category); f.add(r.geomType.rawValue); f.add(r.valsouDm); f.add(r.lon)
    f.add(r.lat); f.add(r.geomFirst); f.add(r.geomCount); f.add(r.name)
    return f.values
}

func hazardFields(_ z: RecHazard) -> [Int64] {
    var f = Fields()
    f.add(z.cls); f.add(z.watlev); f.add(z.category); f.add(z.geomType); f.add(z.valsouDm); f.add(z.lon)
    f.add(z.lat); f.add(z.geomFirst); f.add(z.geomCount); f.add(z.name)
    return f.values
}

func channelFields(_ r: Channel) -> [Int64] {
    var f = Fields()
    f.add(r.source); f.add(r.flags); f.add(r.maintDm); f.add(r.authDm); f.add(r.name); f.add(r.ident); f.add(r.desc)
    f.add(r.date.rawValue); f.add(r.lon); f.add(r.lat)
    return f.values
}

func channelFields(_ c: RecChannel) -> [Int64] {
    var f = Fields()
    f.add(c.source); f.add(c.flags); f.add(c.maintDm); f.add(c.authDm); f.add(c.name); f.add(c.ident); f.add(c.desc)
    f.add(c.date); f.add(c.lon); f.add(c.lat)
    return f.values
}

func areaFields(_ r: RegulatedArea) -> [Int64] {
    var f = Fields()
    f.add(r.kind); f.add(r.source); f.add(r.name); f.add(r.text); f.add(r.lon); f.add(r.lat)
    return f.values
}

func areaFields(_ a: RecArea) -> [Int64] {
    var f = Fields()
    f.add(a.kind); f.add(a.source); f.add(a.name); f.add(a.text); f.add(a.lon); f.add(a.lat)
    return f.values
}

func geomFields(_ pts: [GridPoint]) -> [[Int32]] { pts.map { [$0.x, $0.y] } }

@Suite struct RecordsTests {
    func checkHeaderAndTable(_ pack: RoutingPack, _ rec: RecordsFile) {
        #expect(headerFields(pack.header) == headerFields(rec.header))
        #expect(pack.header.regionID == rec.header.regionId)
        #expect(pack.sections.count == rec.sections.count)
        for (s, e) in zip(pack.sections, rec.sections) {
            #expect(s.tag == e.name)
            #expect(sectionFields(s) == sectionFields(e), "section \(e.name)")
        }
        for (k, v) in rec.info { #expect(pack.info[k] == v, "info[\(k)]") }
        #expect(pack.stringCount == rec.strings.count)
        for (k, v) in rec.strings.first {
            let id: UInt32 = UInt32(k) ?? 0
            #expect(pack.string(id) == v)
        }
    }

    func checkMesh(_ pack: RoutingPack, _ rec: RecordsFile) {
        for v in rec.vertices {
            let p: GridPoint = pack.vertex(v.index)
            #expect(p == GridPoint(x: v.lon, y: v.lat), "vertex \(v.index)")
        }
        for t in rec.triangles {
            #expect(triangleFields(pack, t.index) == triangleFields(t), "triangle \(t.index)")
        }
        #expect(gridFields(pack.gridInfo) == gridFields(rec.grid))
        for cell in rec.grid.cells {
            #expect(pack.gridCellTriangles(cell.cell) == cell.ids, "grid cell \(cell.cell)")
        }
    }

    func checkSideTables(_ pack: RoutingPack, _ rec: RecordsFile) {
        for s in rec.sources { #expect(sourceFields(pack.sources[s.index]) == sourceFields(s), "source \(s.index)") }
        for o in rec.overhead {
            let r: OverheadObject = pack.overheadObjects[o.index]
            #expect(overheadFields(r) == overheadFields(o), "overhead \(o.index)")
            #expect(geomFields(pack.geometry(of: r)) == o.geom)
        }
        for z in rec.hazards {
            let r: Hazard = pack.hazards[z.index]
            #expect(hazardFields(r) == hazardFields(z), "hazard \(z.index)")
            #expect(geomFields(pack.geometry(of: r)) == z.geom)
        }
        for c in rec.channels { #expect(channelFields(pack.channels[c.index]) == channelFields(c), "channel \(c.index)") }
        for a in rec.areas { #expect(areaFields(pack.areas[a.index]) == areaFields(a), "area \(a.index)") }
    }

    func check(_ name: String) throws {
        let rec = try Fixtures.decode(RecordsFile.self, "\(name).records.json")
        let pack = try RoutingPack(contentsOf: Fixtures.url(rec.file))
        checkHeaderAndTable(pack, rec)
        checkMesh(pack, rec)
        checkSideTables(pack, rec)
    }

    @Test func syntheticRecords() throws { try check("synthetic") }

    @Test func sarasotaRecords() throws { try check("sarasota") }

    @Test func storedAndDerivedAdjacencyAgree() throws {
        let pack = Fixtures.synthetic
        #expect(!pack.adjacencyWasDerived)
        let derived = try PackParser.deriveAdjacency(tris: pack.tris, vertexCount: pack.vertexCount)
        #expect(derived == pack.nbr)
        #expect(Fixtures.sarasota.adjacencyWasDerived)
    }

    @Test(arguments: ["synthetic", "sarasota"])
    func adjacencyIsSymmetric(_ name: String) {
        let pack = Fixtures.pack(named: name)
        var bad = 0
        for t in 0..<pack.triangleCount {
            for k in 0..<3 {
                let u = Int(pack.nbr[3 * t + k])
                if u < 0 { continue }
                let back: [Int32] = [pack.nbr[3 * u], pack.nbr[3 * u + 1], pack.nbr[3 * u + 2]]
                if !back.contains(Int32(t)) { bad += 1 }
            }
        }
        #expect(bad == 0)
    }

    /// Every sampled triangle's centroid locates to a triangle containing it, and the located triangle really contains the point.
    @Test(arguments: ["synthetic", "sarasota"])
    func gridLocatesEveryCentroid(_ name: String) {
        let pack = Fixtures.pack(named: name)
        var failures = 0
        for t in stride(from: 0, to: pack.triangleCount, by: max(1, pack.triangleCount / 2000)) {
            let c: GridPoint = pack.centroid(of: t)
            guard let found = pack.locate(c) else {
                failures += 1
                continue
            }
            // When t contains its (floored) centroid, the lowest containing id is at most t. For a sliver the
            // floored centroid can fall just outside t, and then only containment is required.
            let tContains = pack.triangle(t, contains: c)
            if !pack.triangle(found, contains: c) || (tContains && found > t) { failures += 1 }
        }
        #expect(failures == 0)
    }

    @Test func spec_A10_workedExamples() throws {
        let pack = Fixtures.synthetic
        #expect(pack.header.formatMajor == 1 && pack.header.formatMinor == 1 && pack.header.fileSize == 1824)
        #expect(pack.header.tableCRC32 == 0x0387_020D)
        #expect(pack.header.headerCRC32 == 0x34A0_171D)
        #expect(pack.sections[3].tag == "VERT" && pack.sections[3].encoding == 1 && pack.sections[3].rawLength == 182)
        #expect(pack.vertex(1) == GridPoint(x: -819_990_000, y: 270_000_000))
        #expect(pack.vertex(2) == GridPoint(x: -819_990_000, y: 270_010_000))
        let n = pack.neighbors(0)
        #expect(n.0 == -1 && n.1 == 2 && n.2 == 1)
        #expect(pack.string(1) == "Test Opening Bridge")
        #expect(pack.attributes(0).quality == 0x55 && pack.attributes(0).catzoc == 5 && pack.attributes(0).surveyDecade == 1950)
        #expect(pack.geometry(first: 0, count: 1) == [GridPoint(x: -819_945_000, y: 270_010_000)])
        #expect(pack.hazards[0].geomFirst == 7 && pack.overheadObjects[3].geomType == .point)
        #expect(pack.dataDate.description == "2026-11-01")
    }
}

@Suite struct PrimitiveTests {
    @Test func crc32CheckValue() {
        let v: UInt32 = CRC32.checksum(Array("123456789".utf8))
        #expect(v == 0xCBF4_3926)
    }

    @Test func varintExamples() {
        let bytes: [UInt8] = [0x00, 0x7F, 0x80, 0x01, 0xAC, 0x02, 0x80, 0x80, 0x01]
        let values: [UInt64] = bytes.withUnsafeBufferPointer { p in
            var c = VarintCursor(p)
            var out: [UInt64] = []
            while let v = c.next() { out.append(v) }
            return out
        }
        #expect(values == [0, 127, 128, 300, 16384])
    }

    @Test func zigzag() {
        let got: [Int64] = [0, 1, 2, 3, 20000].map { unzigzag($0) }
        #expect(got == [0, -1, 1, -2, 10000])
    }

    @Test func floorDivision() {
        #expect(floorDiv(-7, 2) == -4)
        #expect(floorDiv(7, 2) == 3)
        #expect(floorDiv(-6, 3) == -2)
        #expect(floorDiv(-819_966_667 * 3 - 1, 3) == -819_966_668)
    }

    @Test func requirementRule() {
        // Spec B.2 examples.
        #expect(BoatProfile.requirementDm(feet: 6.0) == 18)
        #expect(BoatProfile.requirementDm(feet: 5.5) == 18)
        #expect(BoatProfile.requirementDm(feet: 6.1) == 21)
        #expect(BoatProfile.requirementDm(feet: 20) == 60)
        #expect(BoatProfile.requirementDm(feet: 65) == 198)
        let metric = BoatProfile(draft: .meters(1.8288), safetyMargin: .meters(0), airDraft: .feet(20))
        #expect(metric.requiredDepthDm == 18)
        #expect(metric.requiredAirDm == 60)
    }

    @Test func inflateRejectsGarbage() {
        let junk: [UInt8] = [0x78, 0xDA, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00]
        #expect(throws: InflateError.self) { try Zlib.decompress(junk, expectedLength: 10) }
    }

    /// Stored (type 0), fixed (type 1) and dynamic (type 2) blocks: hand-made stored stream plus the packs'
    /// own zlib sections (dynamic/fixed, verified by Adler-32 and the section CRCs).
    @Test func inflateStoredBlock() throws {
        let payload: [UInt8] = Array("hello, routing".utf8)
        var s: [UInt8] = [0x78, 0x01, 0x01]
        let n = UInt16(payload.count)
        s += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8)]
        s += payload
        let adler = payload.withUnsafeBufferPointer { Adler32.checksum($0) }
        s += [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
        let out: [UInt8] = try Zlib.decompress(s, expectedLength: payload.count)
        #expect(out == payload)
        #expect(throws: InflateError.self) { try Zlib.decompress(s, expectedLength: payload.count + 1) }
    }

    @Test func fixedHuffmanBlock() throws {
        // zlib.compress(b"aaaaaaaaaa", 9) uses a fixed-Huffman block.
        let s: [UInt8] = [0x78, 0xDA, 0x4B, 0x4C, 0x84, 0x01, 0x00, 0x14, 0xE1, 0x03, 0xCB]
        let out: [UInt8] = try Zlib.decompress(s, expectedLength: 10)
        #expect(out == Array("aaaaaaaaaa".utf8))
    }
}
