import Foundation
import Testing
@testable import RoutingKit

@Suite struct HeaderOnlyTests {
    @Test func headerMatchesTheFullyLoadedPack() throws {
        for name in ["synthetic.pack", "sarasota.pack"] {
            let header = try RoutingPack.header(contentsOf: Fixtures.url(name))
            let full = try RoutingPack(contentsOf: Fixtures.url(name))
            #expect(header == full.header)
        }
        let s = try RoutingPack.header(contentsOf: Fixtures.url("sarasota.pack"))
        #expect(s.regionID == "pilot-sarasota")
        #expect(s.dataDate.rawValue == 20261023)
    }

    @Test func headerReaderRejectsBadFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rk-header-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = try Fixtures.bytes("synthetic.pack")

        let truncated = dir.appendingPathComponent("t.pack")
        try Data(bytes.prefix(100)).write(to: truncated)
        #expect(throws: PackError.self) { try RoutingPack.header(contentsOf: truncated) }

        let short = dir.appendingPathComponent("s.pack")
        try Data(bytes.dropLast(8)).write(to: short)
        do {
            _ = try RoutingPack.header(contentsOf: short)
            Issue.record("a file shorter than file_size must be rejected")
        } catch {
            guard case .fileSizeMismatch = error else { Issue.record("unexpected \(error)"); return }
        }

        bytes[40] ^= 0x01 // inside region_id: header CRC no longer matches
        let flipped = dir.appendingPathComponent("f.pack")
        try Data(bytes).write(to: flipped)
        do {
            _ = try RoutingPack.header(contentsOf: flipped)
            Issue.record("a flipped header byte must be rejected")
        } catch {
            #expect(error == .headerChecksumMismatch)
        }

        #expect(throws: PackError.self) { try RoutingPack.header(contentsOf: dir.appendingPathComponent("missing.pack")) }
    }
}
