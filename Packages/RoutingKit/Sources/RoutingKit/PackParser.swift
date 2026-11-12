import Foundation

/// Everything decoded from a pack file, before it is frozen into a ``RoutingPack``.
struct PackContents {
    var header: PackHeader
    var sections: [PackSection]
    var info: [String: String] = [:]
    var adjacencyWasDerived = false
    var sources: [SourceCell] = []
    var overheads: [OverheadObject] = []
    var hazards: [Hazard] = []
    var channels: [Channel] = []
    var areas: [RegulatedArea] = []
    var gridInfo = GridIndexInfo(originLon: 0, originLat: 0, cell: 1, nx: 1, ny: 1, totalIDs: 0)
    var lon = ContiguousArray<Int32>()
    var lat = ContiguousArray<Int32>()
    var tris = ContiguousArray<Int32>()
    var nbr = ContiguousArray<Int32>()
    var depth = ContiguousArray<Int16>()
    var band = ContiguousArray<Int16>()
    var maint = ContiguousArray<Int16>()
    var clr = ContiguousArray<UInt16>()
    var flags = ContiguousArray<UInt16>()
    var chan = ContiguousArray<UInt16>()
    var ovhd = ContiguousArray<UInt16>()
    var area = ContiguousArray<UInt16>()
    var quality = ContiguousArray<UInt8>()
    var gridOffsets = ContiguousArray<UInt32>()
    var gridIDs = ContiguousArray<Int32>()
    var geom = ContiguousArray<Int32>()
    var stringOffsets = ContiguousArray<UInt32>()
    var stringBlob = ContiguousArray<UInt8>()
    var hazardBoxes = ContiguousArray<Int32>()
    var overheadBoxes = ContiguousArray<Int32>()
}

/// Section tags (spec A.2).
enum Tag {
    static let info = "INFO", strs = "STRS", srcs = "SRCS", vert = "VERT", tris = "TRIS", adjc = "ADJC"
    static let attr = "ATTR", grid = "GRID", ovhd = "OVHD", hazd = "HAZD", chan = "CHAN", area = "AREA"
    static let geom = "GEOM"
    static let required = [info, strs, srcs, vert, tris, attr, grid, ovhd, hazd, chan, area, geom]
}

/// Largest bounding-box span (units) accepted, so that every orientation test of A.8 is exact in Int64
/// (differences < 2^30, products < 2^60). About 107 degrees: far larger than any region.
let maxSpanUnits: Int64 = 1 << 30

/// Validating decoder for spec part A. Reads only through bounds-checked accessors.
struct PackParser {
    let file: UnsafeBufferPointer<UInt8>

    init(file: UnsafeBufferPointer<UInt8>) { self.file = file }

    func parse() throws(PackError) -> PackContents {
        let v = ByteView(file)
        guard file.count >= 256 else { throw .truncated("file is \(file.count) bytes, shorter than the 256-byte header") }
        // 1. magic
        let magic: [UInt8] = Array("GCRTPACK".utf8)
        for i in 0..<8 where file[i] != magic[i] { throw .badMagic }
        // 2. major version
        let major = Int(v.u16(8)!), minor = Int(v.u16(10)!)
        guard major == 1 else { throw .unsupportedVersion(major: major, minor: minor) }
        // 3. header CRC
        let headerCRC = v.u32(252)!
        guard CRC32.checksum(UnsafeBufferPointer(rebasing: file[0..<252])) == headerCRC else { throw .headerChecksumMismatch }
        // 4. file size
        let fileSize = Int(v.u32(16)!)
        guard fileSize == file.count else { throw .fileSizeMismatch(header: fileSize, actual: file.count) }

        // 5. header fields (header_size, section_table_offset, section_count, bounding box, counts).
        let header = try parseHeader(v, major: major, minor: minor, crc: headerCRC)
        // 6. section-table CRC (format 1.1 and later), then the entries.
        let sections = try parseSectionTable(v, header: header)
        // 7. layout: back to back in table order at 8-byte boundaries, zero padding, nothing after the end.
        try checkLayout(sections, tableEnd: header.sectionTableOffset + 32 * header.sectionCount)
        var c = PackContents(header: header, sections: sections)

        // 8. CRC of every section (unknown tags included), 9. unique tags, before anything is decoded.
        var byTag: [String: PackSection] = [:]
        for s in sections {
            let stored = UnsafeBufferPointer(rebasing: file[Int(s.offset)..<(Int(s.offset) + s.storedLength)])
            guard CRC32.checksum(stored) == s.crc32 else { throw .sectionChecksumMismatch(tag: s.tag) }
            guard byTag[s.tag] == nil else { throw .duplicateSection(tag: s.tag) }
            byTag[s.tag] = s
        }
        for t in Tag.required where byTag[t] == nil { throw .missingSection(tag: t) }
        guard (byTag[Tag.adjc] != nil) == header.hasStoredAdjacency else {
            throw .invalidHeader("flag bit 0 (ADJC present) disagrees with the section table")
        }

        // 10. encodings and inflated lengths, 11. section contents (decoded in place or inflated).
        let T = header.triangleCount, V = header.vertexCount
        c.info = try withSection(byTag[Tag.info]!) { p throws(PackError) in Self.decodeInfo(p) }
        let strs = try withSection(byTag[Tag.strs]!) { p throws(PackError) in try Self.decodeStrings(p, section: byTag[Tag.strs]!) }
        c.stringOffsets = strs.0
        c.stringBlob = strs.1
        let nStrings = UInt32(c.stringOffsets.count - 1)
        func checkString(_ id: UInt32, _ tag: String) throws(PackError) {
            guard id < nStrings else { throw .malformedSection(tag: tag, reason: "string id \(id) out of range") }
        }

        let geomSection = byTag[Tag.geom]!
        c.geom = try withSection(geomSection) { p throws(PackError) in
            guard p.count % 8 == 0, p.count / 8 == geomSection.count else {
                throw .malformedSection(tag: Tag.geom, reason: "length \(p.count) does not hold \(geomSection.count) points")
            }
            var g = ContiguousArray<Int32>(repeating: 0, count: p.count / 4)
            let bv = ByteView(p)
            for i in 0..<g.count { g[i] = bv.i32(4 * i)! }
            // Every GEOM point lies inside the header bounding box (spec A.3), which keeps A.8 exact.
            for i in 0..<(g.count / 2) {
                let x = g[2 * i], y = g[2 * i + 1]
                guard x >= header.minLon, x <= header.maxLon, y >= header.minLat, y <= header.maxLat else {
                    throw .malformedSection(tag: Tag.geom, reason: "point \(i) outside the header bounding box")
                }
            }
            return g
        }
        let geomPoints = UInt64(c.geom.count / 2)
        func checkGeom(_ first: UInt32, _ count: UInt32, _ type: UInt8, _ tag: String, _ i: Int) throws(PackError) -> PackGeometryType {
            guard let gt = PackGeometryType(rawValue: type) else {
                throw .malformedSection(tag: tag, reason: "record \(i): geometry type \(type)")
            }
            guard UInt64(first) + UInt64(count) <= geomPoints else {
                throw .malformedSection(tag: tag, reason: "record \(i): geometry range outside GEOM")
            }
            let minimum: UInt32 = gt == .point ? 1 : (gt == .polyline ? 2 : 3)
            guard count >= minimum, gt != .point || count == 1 else {
                throw .malformedSection(tag: tag, reason: "record \(i): \(count) points for geometry type \(type)")
            }
            return gt
        }

        c.sources = try records(byTag[Tag.srcs]!, size: 24) { (r: ByteView, o: Int, i: Int) throws(PackError) -> SourceCell in
            let s = SourceCell(name: r.u32(o)!, edition: r.u16(o + 4)!, update: r.u16(o + 6)!,
                               issueDate: PackDate(rawValue: r.u32(o + 8)!), compilationScale: r.u32(o + 12)!,
                               usageBand: r.u8(o + 16)!, used: r.u8(o + 17)! != 0)
            try checkString(s.name, Tag.srcs)
            return s
        }
        c.overheads = try records(byTag[Tag.ovhd]!, size: 40) { (r: ByteView, o: Int, i: Int) throws(PackError) -> OverheadObject in
            let first = r.u32(o + 24)!, count = r.u32(o + 28)!
            let gt = try checkGeom(first, count, r.u8(o + 32)!, Tag.ovhd, i)
            let rec = OverheadObject(kind: r.u8(o)!, flags: r.u8(o + 1)!, catbrg: r.u16(o + 2)!, clearanceDm: r.u16(o + 4)!,
                                     openClearanceDm: r.u16(o + 6)!, horizontalClearanceDm: r.u16(o + 8)!, name: r.u32(o + 12)!,
                                     lon: r.i32(o + 16)!, lat: r.i32(o + 20)!, geomFirst: first, geomCount: count, geomType: gt)
            try checkString(rec.name, Tag.ovhd)
            return rec
        }
        c.hazards = try records(byTag[Tag.hazd]!, size: 32) { (r: ByteView, o: Int, i: Int) throws(PackError) -> Hazard in
            let first = r.u32(o + 16)!, count = r.u32(o + 20)!
            let gt = try checkGeom(first, count, r.u8(o + 3)!, Tag.hazd, i)
            let rec = Hazard(cls: r.u8(o)!, watlev: r.u8(o + 1)!, category: r.u8(o + 2)!, geomType: gt, valsouDm: r.i16(o + 4)!,
                             lon: r.i32(o + 8)!, lat: r.i32(o + 12)!, geomFirst: first, geomCount: count, name: r.u32(o + 24)!)
            try checkString(rec.name, Tag.hazd)
            return rec
        }
        c.channels = try records(byTag[Tag.chan]!, size: 32) { (r: ByteView, o: Int, i: Int) throws(PackError) -> Channel in
            let rec = Channel(source: r.u8(o)!, flags: r.u8(o + 1)!, maintDm: r.i16(o + 2)!, authDm: r.i16(o + 4)!,
                              name: r.u32(o + 8)!, ident: r.u32(o + 12)!, desc: r.u32(o + 16)!,
                              date: PackDate(rawValue: r.u32(o + 20)!), lon: r.i32(o + 24)!, lat: r.i32(o + 28)!)
            try checkString(rec.name, Tag.chan)
            try checkString(rec.ident, Tag.chan)
            try checkString(rec.desc, Tag.chan)
            return rec
        }
        c.areas = try records(byTag[Tag.area]!, size: 32) { (r: ByteView, o: Int, i: Int) throws(PackError) -> RegulatedArea in
            let rec = RegulatedArea(kind: r.u8(o)!, source: r.u8(o + 1)!, name: r.u32(o + 4)!, text: r.u32(o + 8)!,
                                    lon: r.i32(o + 12)!, lat: r.i32(o + 16)!)
            try checkString(rec.name, Tag.area)
            try checkString(rec.text, Tag.area)
            return rec
        }
        c.hazardBoxes = boxes(c.hazards.map { ($0.geomFirst, $0.geomCount) }, geom: c.geom)
        c.overheadBoxes = boxes(c.overheads.map { ($0.geomFirst, $0.geomCount) }, geom: c.geom)

        // Vertices.
        let vs = byTag[Tag.vert]!
        guard vs.count == V else { throw .malformedSection(tag: Tag.vert, reason: "count \(vs.count) != vertex_count \(V)") }
        let verts = try withSection(vs) { p throws(PackError) in try Self.decodeVertices(p, header: header) }
        c.lon = verts.0
        c.lat = verts.1

        // Triangles.
        let ts = byTag[Tag.tris]!
        guard ts.count == T else { throw .malformedSection(tag: Tag.tris, reason: "count \(ts.count) != triangle_count \(T)") }
        c.tris = try withSection(ts) { p throws(PackError) in try Self.decodeTriangles(p, T: T, V: V) }
        try Self.checkOrientation(c.tris, lon: c.lon, lat: c.lat)

        // Adjacency: stored, or derived (spec A.5 ADJC).
        if let adj = byTag[Tag.adjc] {
            guard adj.count == T else { throw .malformedSection(tag: Tag.adjc, reason: "count \(adj.count) != triangle_count \(T)") }
            c.nbr = try withSection(adj) { p throws(PackError) in try Self.decodeAdjacency(p, T: T) }
            try Self.checkAdjacency(tris: c.tris, nbr: c.nbr)
        } else {
            c.nbr = try Self.deriveAdjacency(tris: c.tris, vertexCount: V)
            c.adjacencyWasDerived = true
        }

        // Attributes.
        let at = byTag[Tag.attr]!
        guard at.count == T else { throw .malformedSection(tag: Tag.attr, reason: "count \(at.count) != triangle_count \(T)") }
        try withSection(at) { p throws(PackError) in try Self.decodeAttributes(p, T: T, into: &c) }

        // Point-location grid.
        try withSection(byTag[Tag.grid]!) { p throws(PackError) in
            try Self.decodeGrid(p, section: byTag[Tag.grid]!, header: header, into: &c)
        }
        return c
    }

    // MARK: Header and table

    private func parseHeader(_ v: ByteView, major: Int, minor: Int, crc: UInt32) throws(PackError) -> PackHeader {
        var idBytes: [UInt8] = []
        for i in 32..<64 {
            let b = file[i]
            if b == 0 { break }
            idBytes.append(b)
        }
        let h = PackHeader(
            formatMajor: major, formatMinor: minor, headerSize: Int(v.u32(12)!), fileSize: Int(v.u32(16)!),
            sectionCount: Int(v.u32(20)!), sectionTableOffset: Int(v.u32(24)!), flags: v.u32(28)!,
            regionID: String(decoding: idBytes, as: UTF8.self),
            minLon: v.i32(64)!, minLat: v.i32(68)!, maxLon: v.i32(72)!, maxLat: v.i32(76)!,
            dataDate: PackDate(rawValue: v.u32(80)!), buildDate: PackDate(rawValue: v.u32(84)!), buildTime: v.u32(88)!,
            vertexCount: Int(v.u32(92)!), triangleCount: Int(v.u32(96)!),
            clearanceDm: Int(v.u16(100)!), checkDm: Int(v.u16(102)!), shoreRing0M: Int(v.u16(104)!),
            shoreRing1M: Int(v.u16(106)!), tableCRC32: minor >= 1 ? v.u32(108)! : 0, headerCRC32: crc)
        guard h.headerSize == 256 else { throw .invalidHeader("header_size \(h.headerSize)") }
        guard h.sectionTableOffset == 256 else { throw .invalidHeader("section_table_offset \(h.sectionTableOffset)") }
        guard h.sectionCount >= 1, h.sectionCount <= 4096, 256 + 32 * h.sectionCount <= file.count else {
            throw .invalidHeader("section_count \(h.sectionCount)")
        }
        guard h.minLon <= h.maxLon, h.minLat <= h.maxLat,
              Int64(h.maxLon) - Int64(h.minLon) <= maxSpanUnits, Int64(h.maxLat) - Int64(h.minLat) <= maxSpanUnits,
              h.minLon >= -1_800_000_000, h.maxLon <= 1_800_000_000, h.minLat >= -900_000_000, h.maxLat <= 900_000_000
        else { throw .invalidHeader("bounding box") }
        guard h.vertexCount >= 3, h.triangleCount >= 1, h.vertexCount <= Int(Int32.max), 3 * h.triangleCount <= Int(Int32.max) else {
            throw .invalidHeader("vertex/triangle counts")
        }
        return h
    }

    private func parseSectionTable(_ v: ByteView, header: PackHeader) throws(PackError) -> [PackSection] {
        let n = header.sectionCount, off = header.sectionTableOffset
        guard v.has(off, n * 32) else { throw .truncated("section table runs past the end of the file") }
        if header.formatMinor >= 1 {
            let table = UnsafeBufferPointer(rebasing: file[off..<(off + 32 * n)])
            guard CRC32.checksum(table) == header.tableCRC32 else { throw .sectionTableChecksumMismatch }
        }
        var out: [PackSection] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let o = off + 32 * i
            let tag = String(decoding: file[o..<(o + 4)], as: UTF8.self)
            out.append(PackSection(tag: tag, encoding: Int(v.u32(o + 4)!), offset: v.u64(o + 8)!,
                                   storedLength: Int(v.u32(o + 16)!), rawLength: Int(v.u32(o + 20)!),
                                   crc32: v.u32(o + 24)!, count: Int(v.u32(o + 28)!)))
        }
        return out
    }

    /// Spec A.4 check 7: section i starts at the first multiple of 8 at or after the end of section i-1 (the
    /// first one after the table), every padding byte is zero and the file ends at the padded end of the last
    /// section. Together with the CRCs this covers every byte of the file.
    private func checkLayout(_ sections: [PackSection], tableEnd: Int) throws(PackError) {
        @inline(__always) func align8(_ n: Int) -> Int { (n + 7) & ~7 }
        var prevEnd = tableEnd
        var expected = align8(tableEnd)
        for s in sections {
            guard s.offset == UInt64(expected) else {
                throw .invalidLayout("section \(s.tag) at offset \(s.offset), expected \(expected)")
            }
            guard expected <= file.count, s.storedLength <= file.count - expected else { throw .sectionOutOfBounds(tag: s.tag) }
            for i in prevEnd..<expected where file[i] != 0 { throw .invalidLayout("non-zero padding at byte \(i)") }
            prevEnd = expected + s.storedLength
            expected = align8(prevEnd)
        }
        guard file.count == expected else {
            throw .invalidLayout("file is \(file.count) bytes, the padded end of the last section is \(expected)")
        }
        for i in prevEnd..<expected where file[i] != 0 { throw .invalidLayout("non-zero padding at byte \(i)") }
    }

    // MARK: Section access

    /// Runs `body` on the raw (inflated) bytes of a section. Raw sections are used in place.
    private func withSection<R>(_ s: PackSection, _ body: (UnsafeBufferPointer<UInt8>) throws(PackError) -> R) throws(PackError) -> R {
        let stored = UnsafeBufferPointer(rebasing: file[Int(s.offset)..<(Int(s.offset) + s.storedLength)])
        switch s.encoding {
        case 0:
            guard s.rawLength == s.storedLength else {
                throw .rawLengthMismatch(tag: s.tag, expected: s.rawLength, actual: s.storedLength)
            }
            return try body(stored)
        case 1:
            // A zlib stream cannot expand more than about 1032:1; refuse absurd raw lengths before allocating.
            guard s.rawLength <= s.storedLength &* 1032 &+ 1024 else {
                throw .inflateFailed(tag: s.tag, reason: "raw_length \(s.rawLength) impossible for \(s.storedLength) stored bytes")
            }
            let raw: [UInt8]
            do {
                raw = try Zlib.decompress(stored, expectedLength: s.rawLength)
            } catch {
                throw .inflateFailed(tag: s.tag, reason: error.reason)
            }
            let r: Result<R, PackError> = raw.withUnsafeBufferPointer { p in
                Result { () throws(PackError) -> R in try body(p) }
            }
            return try r.get()
        default:
            throw .unsupportedEncoding(tag: s.tag, encoding: s.encoding)
        }
    }

    private func records<R>(_ s: PackSection, size: Int,
                            _ make: (ByteView, Int, Int) throws(PackError) -> R) throws(PackError) -> [R] {
        try withSection(s) { (p: UnsafeBufferPointer<UInt8>) throws(PackError) -> [R] in
            guard p.count % size == 0, p.count / size == s.count else {
                throw .malformedSection(tag: s.tag, reason: "length \(p.count) does not hold \(s.count) records of \(size) bytes")
            }
            let v = ByteView(p)
            var out: [R] = []
            out.reserveCapacity(s.count)
            for i in 0..<s.count { out.append(try make(v, i * size, i)) }
            return out
        }
    }

    private func boxes(_ ranges: [(UInt32, UInt32)], geom: ContiguousArray<Int32>) -> ContiguousArray<Int32> {
        var out = ContiguousArray<Int32>()
        out.reserveCapacity(ranges.count * 4)
        for (first, count) in ranges {
            var x0 = Int32.max, y0 = Int32.max, x1 = Int32.min, y1 = Int32.min
            for k in Int(first)..<(Int(first) + Int(count)) {
                let x = geom[2 * k], y = geom[2 * k + 1]
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
            }
            out.append(x0); out.append(y0); out.append(x1); out.append(y1)
        }
        return out
    }

    // MARK: Section decoders

    static func decodeInfo(_ p: UnsafeBufferPointer<UInt8>) -> [String: String] {
        var out: [String: String] = [:]
        let text = String(decoding: p, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    static func decodeStrings(_ p: UnsafeBufferPointer<UInt8>, section: PackSection) throws(PackError)
        -> (ContiguousArray<UInt32>, ContiguousArray<UInt8>) {
        let v = ByteView(p)
        guard let n32 = v.u32(0) else { throw .malformedSection(tag: Tag.strs, reason: "too short") }
        let n = Int(n32)
        guard n >= 1, n == section.count, v.has(4, 4 * (n + 1)) else {
            throw .malformedSection(tag: Tag.strs, reason: "string count \(n)")
        }
        let blobStart = 4 + 4 * (n + 1)
        let blobLength = p.count - blobStart
        var offsets = ContiguousArray<UInt32>(repeating: 0, count: n + 1)
        var prev: UInt32 = 0
        for i in 0...n {
            let o = v.u32(4 + 4 * i)!
            guard o >= prev, Int(o) <= blobLength, i > 0 || o == 0 else {
                throw .malformedSection(tag: Tag.strs, reason: "string offsets not ascending within the blob")
            }
            offsets[i] = o
            prev = o
        }
        guard offsets[1] == 0 else { throw .malformedSection(tag: Tag.strs, reason: "string 0 is not empty") }
        guard Int(offsets[n]) == blobLength else {
            throw .malformedSection(tag: Tag.strs, reason: "offsets end at \(offsets[n]), the blob has \(blobLength) bytes")
        }
        let blob = ContiguousArray(UnsafeBufferPointer(rebasing: p[blobStart...]))
        for i in 0..<n {
            let bytes = blob[Int(offsets[i])..<Int(offsets[i + 1])]
            // Decoding replaces every invalid sequence, so a valid string re-encodes to the same bytes.
            guard String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(bytes) else {
                throw .malformedSection(tag: Tag.strs, reason: "string \(i) is not valid UTF-8")
            }
        }
        return (offsets, blob)
    }

    static func decodeVertices(_ p: UnsafeBufferPointer<UInt8>, header h: PackHeader) throws(PackError)
        -> (ContiguousArray<Int32>, ContiguousArray<Int32>) {
        let V = h.vertexCount
        guard p.count >= 2 * V else { throw .malformedSection(tag: Tag.vert, reason: "too short for \(V) vertices") }
        var lon = ContiguousArray<Int32>(repeating: 0, count: V)
        var lat = ContiguousArray<Int32>(repeating: 0, count: V)
        var cur = VarintCursor(p)
        var x = Int64(h.minLon), y = Int64(h.minLat)
        let x0 = Int64(h.minLon), x1 = Int64(h.maxLon), y0 = Int64(h.minLat), y1 = Int64(h.maxLat)
        for i in 0..<V {
            guard let ux = cur.next(), let uy = cur.next() else {
                throw .malformedSection(tag: Tag.vert, reason: "varint data ends at vertex \(i)")
            }
            let dx = unzigzag(ux), dy = unzigzag(uy)
            guard abs(dx) <= maxSpanUnits, abs(dy) <= maxSpanUnits else {
                throw .malformedSection(tag: Tag.vert, reason: "vertex \(i) delta out of range")
            }
            x += dx
            y += dy
            guard x >= x0, x <= x1, y >= y0, y <= y1 else {
                throw .malformedSection(tag: Tag.vert, reason: "vertex \(i) outside the header bounding box")
            }
            lon[i] = Int32(x)
            lat[i] = Int32(y)
        }
        guard cur.atEnd else { throw .malformedSection(tag: Tag.vert, reason: "trailing bytes") }
        return (lon, lat)
    }

    static func decodeTriangles(_ p: UnsafeBufferPointer<UInt8>, T: Int, V: Int) throws(PackError) -> ContiguousArray<Int32> {
        guard p.count >= 3 * T else { throw .malformedSection(tag: Tag.tris, reason: "too short for \(T) triangles") }
        var tris = ContiguousArray<Int32>(repeating: 0, count: 3 * T)
        var cur = VarintCursor(p)
        var a: UInt64 = 0
        let vmax = UInt64(V)
        for t in 0..<T {
            guard let da = cur.next(), let db = cur.next(), let dc = cur.next() else {
                throw .malformedSection(tag: Tag.tris, reason: "varint data ends at triangle \(t)")
            }
            guard da < vmax, db < vmax, dc < vmax else {
                throw .malformedSection(tag: Tag.tris, reason: "triangle \(t) vertex index out of range")
            }
            a += da
            let b = a + db, c = a + dc
            guard a < vmax, b < vmax, c < vmax, db > 0, dc > 0, db != dc else {
                throw .malformedSection(tag: Tag.tris, reason: "triangle \(t) vertex indices invalid")
            }
            tris[3 * t] = Int32(a)
            tris[3 * t + 1] = Int32(b)
            tris[3 * t + 2] = Int32(c)
        }
        guard cur.atEnd else { throw .malformedSection(tag: Tag.tris, reason: "trailing bytes") }
        return tris
    }

    /// A.9 guarantee 1: every triangle is strictly counter-clockwise. Point location and the funnel rely on it.
    static func checkOrientation(_ tris: ContiguousArray<Int32>, lon: ContiguousArray<Int32>, lat: ContiguousArray<Int32>) throws(PackError) {
        for t in 0..<(tris.count / 3) {
            let a = Int(tris[3 * t]), b = Int(tris[3 * t + 1]), c = Int(tris[3 * t + 2])
            let o = orient(Int64(lon[a]), Int64(lat[a]), Int64(lon[b]), Int64(lat[b]), Int64(lon[c]), Int64(lat[c]))
            guard o > 0 else { throw .malformedSection(tag: Tag.tris, reason: "triangle \(t) is not counter-clockwise") }
        }
    }

    static func decodeAdjacency(_ p: UnsafeBufferPointer<UInt8>, T: Int) throws(PackError) -> ContiguousArray<Int32> {
        guard p.count >= 3 * T else { throw .malformedSection(tag: Tag.adjc, reason: "too short for \(T) triangles") }
        var nbr = ContiguousArray<Int32>(repeating: -1, count: 3 * T)
        var cur = VarintCursor(p)
        for t in 0..<T {
            for k in 0..<3 {
                guard let u = cur.next() else { throw .malformedSection(tag: Tag.adjc, reason: "varint data ends at triangle \(t)") }
                let d = unzigzag(u)
                if d == 0 { continue }  // boundary
                let n = Int64(t) + d
                guard n >= 0, n < Int64(T) else {
                    throw .malformedSection(tag: Tag.adjc, reason: "triangle \(t) neighbour out of range")
                }
                nbr[3 * t + k] = Int32(n)
            }
        }
        guard cur.atEnd else { throw .malformedSection(tag: Tag.adjc, reason: "trailing bytes") }
        return nbr
    }

    /// Spec A.4: a stored neighbour n of (t, k) is another triangle that owns the reversed edge and lists t across it.
    static func checkAdjacency(tris: ContiguousArray<Int32>, nbr: ContiguousArray<Int32>) throws(PackError) {
        let T = tris.count / 3
        for t in 0..<T {
            for k in 0..<3 {
                let n = Int(nbr[3 * t + k])
                if n < 0 { continue }
                guard n != t else { throw .malformedSection(tag: Tag.adjc, reason: "triangle \(t) is its own neighbour") }
                let p = tris[3 * t + k], q = tris[3 * t + (k + 1) % 3]
                var found = false
                for j in 0..<3 where tris[3 * n + j] == q && tris[3 * n + (j + 1) % 3] == p && nbr[3 * n + j] == Int32(t) {
                    found = true
                }
                guard found else { throw .malformedSection(tag: Tag.adjc, reason: "adjacency of triangle \(t) is not consistent") }
            }
        }
    }

    /// Derived adjacency (spec A.5): the neighbour across directed edge p→q is the triangle owning q→p.
    /// Uses a per-vertex bucket of outgoing edges (compressed rows) instead of a hash map: 8 bytes per edge.
    static func deriveAdjacency(tris: ContiguousArray<Int32>, vertexCount V: Int) throws(PackError) -> ContiguousArray<Int32> {
        let E = tris.count
        var start = ContiguousArray<Int32>(repeating: 0, count: V + 1)
        for e in 0..<E { start[Int(tris[e]) + 1] += 1 }
        for i in 0..<V { start[i + 1] += start[i] }
        var fill = start
        var target = ContiguousArray<Int32>(repeating: 0, count: E)
        var edge = ContiguousArray<Int32>(repeating: 0, count: E)
        for e in 0..<E {
            let t = e / 3, k = e % 3
            let p = Int(tris[e]), q = tris[3 * t + (k + 1) % 3]
            let slot = Int(fill[p])
            fill[p] += 1
            target[slot] = q
            edge[slot] = Int32(e)
        }
        var nbr = ContiguousArray<Int32>(repeating: -1, count: E)
        for e in 0..<E {
            let t = e / 3, k = e % 3
            let p = tris[e], q = Int(tris[3 * t + (k + 1) % 3])
            // Directed edge p→q must be unique (A.9 guarantee 2).
            var same = 0
            for s in Int(start[Int(p)])..<Int(start[Int(p) + 1]) where target[s] == Int32(q) { same += 1 }
            guard same == 1 else { throw .malformedSection(tag: Tag.tris, reason: "directed edge occurs twice (triangle \(t))") }
            for s in Int(start[q])..<Int(start[q + 1]) where target[s] == p {
                let u = Int(edge[s]) / 3
                guard u != t else { throw .malformedSection(tag: Tag.tris, reason: "triangle \(t) is its own neighbour") }
                nbr[e] = Int32(u)
                break
            }
        }
        return nbr
    }

    static func decodeAttributes(_ p: UnsafeBufferPointer<UInt8>, T: Int, into c: inout PackContents) throws(PackError) {
        guard p.count == 17 * T else { throw .malformedSection(tag: Tag.attr, reason: "length \(p.count) != 17 * \(T)") }
        let v = ByteView(p)
        func i16col(_ j: Int) -> ContiguousArray<Int16> {
            var a = ContiguousArray<Int16>(repeating: 0, count: T)
            let base = 2 * j * T
            for t in 0..<T { a[t] = v.i16(base + 2 * t)! }
            return a
        }
        func u16col(_ j: Int) -> ContiguousArray<UInt16> {
            var a = ContiguousArray<UInt16>(repeating: 0, count: T)
            let base = 2 * j * T
            for t in 0..<T { a[t] = v.u16(base + 2 * t)! }
            return a
        }
        c.depth = i16col(0)
        c.band = i16col(1)
        c.maint = i16col(2)
        c.clr = u16col(3)
        c.flags = u16col(4)
        c.chan = u16col(5)
        c.ovhd = u16col(6)
        c.area = u16col(7)
        c.quality = ContiguousArray(UnsafeBufferPointer(rebasing: p[(16 * T)..<(17 * T)]))
        let nc = c.channels.count, no = c.overheads.count, na = c.areas.count
        for t in 0..<T {
            guard c.chan[t] == PackSentinel.noIndex || Int(c.chan[t]) < nc,
                  c.ovhd[t] == PackSentinel.noIndex || Int(c.ovhd[t]) < no,
                  c.area[t] == PackSentinel.noIndex || Int(c.area[t]) < na else {
                throw .malformedSection(tag: Tag.attr, reason: "triangle \(t) refers to a missing CHAN/OVHD/AREA record")
            }
        }
    }

    static func decodeGrid(_ p: UnsafeBufferPointer<UInt8>, section: PackSection, header h: PackHeader,
                           into c: inout PackContents) throws(PackError) {
        let T = h.triangleCount
        let v = ByteView(p)
        guard p.count >= 20 else { throw .malformedSection(tag: Tag.grid, reason: "too short") }
        let ox = v.i32(0)!, oy = v.i32(4)!, cell = v.i32(8)!
        let nx = Int(v.u32(12)!), ny = Int(v.u32(16)!)
        guard ox == h.minLon, oy == h.minLat, cell > 0 else {
            throw .malformedSection(tag: Tag.grid, reason: "origin or cell size")
        }
        // nx = max(1, ceil((max_lon - min_lon) / cell)), ny likewise (spec A.5).
        let cellSize = Int64(cell)
        let nxExpected = max(1, Int(floorDiv(Int64(h.maxLon) - Int64(h.minLon) + cellSize - 1, cellSize)))
        let nyExpected = max(1, Int(floorDiv(Int64(h.maxLat) - Int64(h.minLat) + cellSize - 1, cellSize)))
        guard nx == nxExpected, ny == nyExpected, nx * ny <= p.count - 20, nx * ny == section.count else {
            throw .malformedSection(tag: Tag.grid, reason: "grid dimensions")
        }
        let cells = nx * ny
        var offsets = ContiguousArray<UInt32>(repeating: 0, count: cells + 1)
        var ids = ContiguousArray<Int32>()
        ids.reserveCapacity(max(T, (p.count - 20) / 2))
        var cur = VarintCursor(p, position: 20)
        let tmax = UInt64(T)
        for ci in 0..<cells {
            guard let n = cur.next(), n <= tmax else { throw .malformedSection(tag: Tag.grid, reason: "cell \(ci) count") }
            var id: UInt64 = 0
            for k in 0..<Int(n) {
                guard let d = cur.next(), d < tmax else { throw .malformedSection(tag: Tag.grid, reason: "cell \(ci) ids") }
                guard k == 0 || d > 0 else { throw .malformedSection(tag: Tag.grid, reason: "cell \(ci) ids not ascending") }
                id = k == 0 ? d : id + d
                guard id < tmax else { throw .malformedSection(tag: Tag.grid, reason: "cell \(ci) id out of range") }
                ids.append(Int32(id))
            }
            guard ids.count <= Int(UInt32.max) else { throw .malformedSection(tag: Tag.grid, reason: "too many ids") }
            offsets[ci + 1] = UInt32(ids.count)
        }
        guard cur.atEnd else { throw .malformedSection(tag: Tag.grid, reason: "trailing bytes") }
        c.gridOffsets = offsets
        c.gridIDs = ids
        c.gridInfo = GridIndexInfo(originLon: ox, originLat: oy, cell: cell, nx: nx, ny: ny, totalIDs: ids.count)
    }
}
