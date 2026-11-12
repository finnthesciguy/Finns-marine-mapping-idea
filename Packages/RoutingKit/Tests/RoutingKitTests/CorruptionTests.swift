import Foundation
import NavCore
import Testing
@testable import RoutingKit

/// Test-only writer: the same pack with every section stored raw (encoding 0), CRCs and layout recomputed.
/// Mutations of a raw section with its CRC fixed up reach the semantic validators instead of the checksum.
struct RawPack {
    var bytes: [UInt8]
    /// (offset, length) of each section's bytes in `bytes`, and the offset of its table entry.
    var sections: [(tag: String, offset: Int, length: Int, entry: Int)]

    static func reencode(_ original: [UInt8]) throws -> RawPack {
        let pack = try RoutingPack(bytes: original)
        var raws: [[UInt8]] = []
        for s in pack.sections {
            let stored = Array(original[Int(s.offset)..<(Int(s.offset) + s.storedLength)])
            raws.append(s.encoding == 1 ? try Zlib.decompress(stored, expectedLength: s.rawLength) : stored)
        }
        func pad8(_ n: Int) -> Int { (n + 7) / 8 * 8 }
        var out = Array(original[0..<256])
        out += [UInt8](repeating: 0, count: 32 * pack.sections.count)
        out += [UInt8](repeating: 0, count: pad8(out.count) - out.count)
        var layout: [(tag: String, offset: Int, length: Int, entry: Int)] = []
        for (i, s) in pack.sections.enumerated() {
            let off = out.count
            out += raws[i]
            out += [UInt8](repeating: 0, count: pad8(out.count) - out.count)
            let e = 256 + 32 * i
            layout.append((s.tag, off, raws[i].count, e))
            put32(&out, e + 4, 0)
            put32(&out, e + 8, UInt32(off))
            put32(&out, e + 12, 0)
            put32(&out, e + 16, UInt32(raws[i].count))
            put32(&out, e + 20, UInt32(raws[i].count))
            put32(&out, e + 28, UInt32(s.count))
            for k in 0..<4 { out[e + k] = Array(s.tag.utf8)[k] }
        }
        var raw = RawPack(bytes: out, sections: layout)
        for i in 0..<layout.count { raw.fixSectionCRC(i) }
        put32(&raw.bytes, 16, UInt32(raw.bytes.count))
        raw.fixHeaderCRC()
        return raw
    }

    mutating func fixSectionCRC(_ i: Int) {
        let s = sections[i]
        let crc: UInt32 = bytes.withUnsafeBufferPointer {
            CRC32.checksum(UnsafeBufferPointer(rebasing: $0[s.offset..<(s.offset + s.length)]))
        }
        put32(&bytes, s.entry + 24, crc)
    }

    mutating func fixHeaderCRC() {
        let crc: UInt32 = bytes.withUnsafeBufferPointer { CRC32.checksum(UnsafeBufferPointer(rebasing: $0[0..<252])) }
        put32(&bytes, 252, crc)
    }
}

func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v & 0xFF)
    b[o + 1] = UInt8((v >> 8) & 0xFF)
    b[o + 2] = UInt8((v >> 16) & 0xFF)
    b[o + 3] = UInt8(v >> 24)
}

/// Same decoded content (used when a flip lands in padding that no checksum covers).
func sameContent(_ a: RoutingPack, _ b: RoutingPack) -> Bool {
    a.lon == b.lon && a.lat == b.lat && a.tris == b.tris && a.nbr == b.nbr && a.depth == b.depth && a.band == b.band
        && a.maint == b.maint && a.clr == b.clr && a.flags == b.flags && a.chan == b.chan && a.ovhd == b.ovhd
        && a.area == b.area && a.quality == b.quality && a.gridOffsets == b.gridOffsets && a.gridIDs == b.gridIDs
        && a.geom == b.geom && a.stringBlob == b.stringBlob && a.stringOffsets == b.stringOffsets
        && a.overheadObjects == b.overheadObjects && a.hazards == b.hazards && a.channels == b.channels
        && a.areas == b.areas && a.sources == b.sources && a.header.dataDate == b.header.dataDate
}

/// Loads a (possibly corrupt) pack; on success, routes once to show routing cannot crash either.
func loadAndExercise(_ bytes: [UInt8]) -> RoutingPack? {
    let pack: RoutingPack
    do {
        pack = try RoutingPack(bytes: bytes)
    } catch {
        return nil
    }
    let h = pack.header
    let a = Coordinate(latitude: (Double(h.minLat) * 0.7 + Double(h.maxLat) * 0.3) / 1e7,
                       longitude: (Double(h.minLon) * 0.8 + Double(h.maxLon) * 0.2) / 1e7)
    let b = Coordinate(latitude: (Double(h.minLat) * 0.3 + Double(h.maxLat) * 0.7) / 1e7,
                       longitude: (Double(h.minLon) * 0.2 + Double(h.maxLon) * 0.8) / 1e7)
    let req = RouteRequest(start: a, goal: b, profile: BoatProfile(draftFeet: 3, safetyMarginFeet: 1, airDraftFeet: 10),
                           timeLimit: .seconds(5))
    _ = try? pack.routeSynchronously(req)
    return pack
}

@Suite struct CorruptionTests {
    @Test func rawReencodingRoundTrips() throws {
        for name in ["synthetic", "sarasota"] {
            let original = try Fixtures.bytes("\(name).pack")
            let raw = try RawPack.reencode(original)
            let a = try RoutingPack(bytes: original)
            let b = try RoutingPack(bytes: raw.bytes)
            #expect(sameContent(a, b), "\(name)")
        }
        // The re-encoded synthetic pack still reproduces the vectors.
        let raw = try RawPack.reencode(try Fixtures.bytes("synthetic.pack"))
        let pack = try RoutingPack(bytes: raw.bytes)
        let file = try Fixtures.decode(VectorFile.self, "synthetic.vectors.json")
        for q in file.queries {
            let m: [String] = compareVector(q, on: pack)
            #expect(m.isEmpty, "\(q.id)")
        }
    }

    @Test func specificFailuresAreTyped() throws {
        var b = try Fixtures.bytes("synthetic.pack")
        b[0] = UInt8(ascii: "X")
        #expect(throws: PackError.badMagic) { try RoutingPack(bytes: b) }

        b = try Fixtures.bytes("synthetic.pack")
        b[8] = 2
        #expect(throws: PackError.unsupportedVersion(major: 2, minor: 0)) { try RoutingPack(bytes: b) }

        b = try Fixtures.bytes("synthetic.pack")
        b[200] ^= 1
        #expect(throws: PackError.headerChecksumMismatch) { try RoutingPack(bytes: b) }

        b = try Fixtures.bytes("synthetic.pack")
        b.append(0)
        #expect(throws: PackError.fileSizeMismatch(header: 1784, actual: 1785)) { try RoutingPack(bytes: b) }

        b = try Fixtures.bytes("synthetic.pack")
        let vert = Fixtures.synthetic.sections[3]
        b[Int(vert.offset) + 10] ^= 0x40
        #expect(throws: PackError.sectionChecksumMismatch(tag: "VERT")) { try RoutingPack(bytes: b) }

        #expect(throws: PackError.self) { try RoutingPack(contentsOf: URL(fileURLWithPath: "/nonexistent/x.pack")) }
        #expect(throws: PackError.self) { try RoutingPack(bytes: []) }
    }

    @Test func truncationAlwaysThrows() throws {
        for name in ["synthetic", "sarasota"] {
            let original = try Fixtures.bytes("\(name).pack")
            let ref = try RoutingPack(bytes: original)
            // Cutting only the alignment padding after the last section (and patching file_size) leaves a valid file.
            let dataEnd = ref.sections.map { Int($0.offset) + $0.storedLength }.max() ?? 0
            let step = max(1, original.count / 1500)
            var thrown = 0, cases = 0
            for n in stride(from: 0, to: original.count, by: step) {
                cases += 2
                let cut = Array(original[0..<n])
                if (try? RoutingPack(bytes: cut)) == nil { thrown += 1 }
                // Same, with file_size and the header CRC patched so the reader reaches the section checks.
                if n >= 256 && n < dataEnd {
                    var fixed = cut
                    put32(&fixed, 16, UInt32(n))
                    let crc: UInt32 = fixed.withUnsafeBufferPointer { CRC32.checksum(UnsafeBufferPointer(rebasing: $0[0..<252])) }
                    put32(&fixed, 252, crc)
                    if (try? RoutingPack(bytes: fixed)) == nil { thrown += 1 }
                } else {
                    thrown += 1
                }
            }
            #expect(thrown == cases, "\(name): \(cases - thrown) truncations loaded")
        }
    }

    /// Every single-bit flip of the synthetic pack, and a sample of the Sarasota pack: a typed error, or (for
    /// bytes no checksum covers, i.e. alignment padding) a pack with identical content. Never a crash.
    @Test func bitFlips() throws {
        for name in ["synthetic", "sarasota"] {
            let original = try Fixtures.bytes("\(name).pack")
            let reference = try RoutingPack(bytes: original)
            var rng = SplitMix(seed: 42)
            let positions: [Int] = name == "synthetic"
                ? Array(0..<original.count)
                : (0..<600).map { _ in Int(rng.next() % UInt64(original.count)) }
            var loadedSame = 0, rejected = 0, loadedDifferent = 0
            for pos in positions {
                for bit in (name == "synthetic" ? Array(0..<8) : [Int(rng.next() % 8)]) {
                    var b = original
                    b[pos] ^= UInt8(1 << bit)
                    if let p = try? RoutingPack(bytes: b) {
                        if sameContent(p, reference) { loadedSame += 1 } else { loadedDifferent += 1 }
                    } else {
                        rejected += 1
                    }
                }
            }
            print("[fuzz] \(name) bit flips: \(rejected) rejected, \(loadedSame) harmless (padding), \(loadedDifferent) changed")
            #expect(loadedDifferent == 0)
        }
    }

    /// Mutations that keep every CRC valid: raw sections (re-encoded) and the section table, which no CRC covers.
    @Test func checksumValidMutations() throws {
        for name in ["synthetic", "sarasota"] {
            let raw = try RawPack.reencode(try Fixtures.bytes("\(name).pack"))
            var rng = SplitMix(seed: 1234)
            var rejected = 0, loaded = 0
            let rounds = name == "synthetic" ? 300 : 15
            for (i, s) in raw.sections.enumerated() where s.length > 0 {
                for _ in 0..<rounds {
                    var m = raw
                    let flips = 1 + Int(rng.next() % 4)
                    for _ in 0..<flips {
                        let pos = s.offset + Int(rng.next() % UInt64(s.length))
                        m.bytes[pos] = UInt8(truncatingIfNeeded: rng.next())
                    }
                    m.fixSectionCRC(i)
                    if loadAndExercise(m.bytes) == nil { rejected += 1 } else { loaded += 1 }
                }
            }
            // Section-table fields: encoding, offset, lengths, count.
            for s in raw.sections {
                for field in [4, 8, 12, 16, 20, 28] {
                    for _ in 0..<(name == "synthetic" ? 20 : 2) {
                        var m = raw
                        let v = UInt32(truncatingIfNeeded: rng.next() % 4 == 0 ? rng.next() : rng.next() % 64)
                        put32(&m.bytes, s.entry + field, v)
                        if loadAndExercise(m.bytes) == nil { rejected += 1 } else { loaded += 1 }
                    }
                }
            }
            print("[fuzz] \(name) checksum-valid mutations: \(rejected) rejected, \(loaded) loaded and routed without a crash")
            #expect(rejected > 0)
        }
    }

    /// Corrupt zlib data with a valid section CRC: the inflater must fail cleanly.
    @Test func corruptZlibStreams() throws {
        let original = try Fixtures.bytes("sarasota.pack")
        let pack = try RoutingPack(bytes: original)
        var rng = SplitMix(seed: 99)
        var rejected = 0, loaded = 0
        for (i, s) in pack.sections.enumerated() where s.encoding == 1 {
            for _ in 0..<25 {
                var b = original
                let pos = Int(s.offset) + Int(rng.next() % UInt64(s.storedLength))
                b[pos] ^= UInt8(1 + rng.next() % 255)
                let crc: UInt32 = b.withUnsafeBufferPointer {
                    CRC32.checksum(UnsafeBufferPointer(rebasing: $0[Int(s.offset)..<(Int(s.offset) + s.storedLength)]))
                }
                put32(&b, 256 + 32 * i + 24, crc)
                if loadAndExercise(b) == nil { rejected += 1 } else { loaded += 1 }
            }
        }
        print("[fuzz] sarasota corrupt zlib streams: \(rejected) rejected, \(loaded) loaded")
        #expect(rejected > 0)
    }
}
