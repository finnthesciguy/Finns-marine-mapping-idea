import Foundation
import NavCore
import Testing
@testable import Persistence

@Suite("Corruption recovery")
struct CorruptionTests {
    @Test func garbageFileIsSetAsideAndAFreshStoreCreated() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("user.sqlite")
        let garbage = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: url)

        let store = try PersistenceStore(url: url)
        let moved = try #require(store.openReport.recoveredCorruptFile)
        #expect(store.openReport.corruptionReason != nil)
        #expect(try Data(contentsOf: moved) == garbage, "the damaged file is kept for support")
        #expect(moved.lastPathComponent.hasPrefix("user.sqlite.corrupt-"))
        #expect(store.openReport.schemaVersionAfter == Schema.currentVersion)
        // The fresh store works.
        try await store.save(Waypoint(name: "new", coordinate: Coordinate(latitude: 27, longitude: -82)))
        #expect(try await store.waypointCount() == 1)
    }

    @Test func damagedPagesAreDetectedOnOpen() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("user.sqlite")
        do {
            let store = try PersistenceStore(url: url)
            for i in 0..<2000 {
                try await store.save(Waypoint(name: "WP \(i)", coordinate: Coordinate(latitude: 27 + Double(i) * 1e-4, longitude: -82),
                                              notes: String(repeating: "x", count: 100)))
            }
            try await store.checkpoint()
            await store.close()
        }
        // Scribble over the middle of the file (b-tree pages), keeping the 100-byte header intact.
        var bytes = try Data(contentsOf: url)
        #expect(bytes.count > 100_000)
        for i in stride(from: 8192, to: bytes.count - 4096, by: 4096) {
            for j in 0..<64 { bytes[i + j] = 0xA5 }
        }
        try bytes.write(to: url)

        let store = try PersistenceStore(url: url)
        #expect(store.openReport.recoveredCorruptFile != nil)
        #expect(try await store.waypointCount() == 0)
        #expect(try await store.checkIntegrity() == ["ok"])
        #expect(dir.contents.contains { $0.contains(".corrupt-") })
    }

    @Test func truncatedFileIsRecovered() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("user.sqlite")
        do {
            let store = try PersistenceStore(url: url)
            try await store.saveTrack(name: "t", segments: [syntheticTrack(count: 20_000)])
            try await store.checkpoint()
            await store.close()
        }
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count / 3).write(to: url)
        let store = try PersistenceStore(url: url)
        #expect(store.openReport.recoveredCorruptFile != nil)
        #expect(try await store.tracks().isEmpty)
    }

    @Test func inMemoryStoreNeverNeedsRecovery() throws {
        let store = try PersistenceStore(inMemoryWith: .init())
        #expect(store.openReport.recoveredCorruptFile == nil)
        #expect(store.openReport.databaseURL == nil)
    }

    @Test func unwritableLocationThrowsInsteadOfDeleting() throws {
        #expect(throws: PersistenceError.self) {
            _ = try PersistenceStore(url: URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.sqlite"))
        }
    }
}
