import Foundation
import NavCore
import Testing
@testable import Persistence

@Suite("Tracks")
struct TrackTests {
    @Test func codecRoundTrip() throws {
        let pts = [
            TrackPoint(timestamp: Date(timeIntervalSince1970: 1_800_000_000.25),
                       coordinate: Coordinate(latitude: 27.123456789, longitude: -82.987654321),
                       speed: 2.5, course: 271.5, horizontalAccuracy: 4),
            TrackPoint(timestamp: nil, coordinate: Coordinate(latitude: -0.5, longitude: 179.999)),
        ]
        let data = TrackPointCodec.encode(pts)
        #expect(data.count == 2 * TrackPointCodec.bytesPerPoint)
        #expect(try TrackPointCodec.decode(data) == pts)
        #expect(throws: PersistenceError.self) { try TrackPointCodec.decode(data.dropLast()) }
    }

    @Test func appendInBatchesWithSegmentsAndStatistics() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let t = try await store.startTrack(name: "Morning run", color: TrackColor(hex: "#1e90ff")!)
        #expect(t.state == .recording)
        #expect(t.statistics.pointCount == 0)

        // 60 points at 1 Hz, 3 m/s, straight east (no wiggle): 59 legs of 3 m.
        let all = syntheticTrack(count: 60, wiggle: false)
        for batch in stride(from: 0, to: 30, by: 7) {
            try await store.appendTrackPoints(Array(all[batch..<min(batch + 7, 30)]), to: t.id)
        }
        // GPS lost for 5 minutes; new segment.
        let later = all[30...].map { p -> TrackPoint in
            var q = p
            q.timestamp = p.timestamp!.addingTimeInterval(300)
            return q
        }
        let r = try await store.appendTrackPoints(Array(later), to: t.id, startNewSegment: true)
        #expect(r.appended == 30)
        #expect(r.rejected == 0)
        let s = r.track.statistics
        #expect(s.pointCount == 60)
        #expect(s.segmentCount == 2)
        // Distance within segments only: 29 + 29 legs of ~3 m (the gap leg is excluded).
        #expect(abs(s.distance.meters - 58 * 3) < 0.5)
        #expect(s.duration == 58)
        #expect(abs((s.maxSpeed?.metersPerSecond ?? 0) - 3) < 1e-6)
        #expect(abs((s.averageSpeed?.metersPerSecond ?? 0) - 3) < 0.01)
        #expect(r.track.startDate == all[0].timestamp)
        #expect(r.track.endDate == later.last!.timestamp)
        #expect(r.track.color.hex == "#1E90FF")

        let segments = try await store.trackPoints(t.id)
        #expect(segments.count == 2)
        #expect(segments[0] == Array(all[..<30]))
        #expect(segments[1] == later)

        // All small appends were coalesced into one chunk per segment.
        #expect(try await store.scalar("SELECT count(*) FROM track_chunk") == 2)

        let finished = try await store.finishRecording(t.id)
        #expect(finished.state == .finished)
        #expect(finished.statistics == s)
        #expect(try await store.recordingTracks().isEmpty)
    }

    @Test func invalidPointsAreDroppedAndCounted() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let t = try await store.startTrack(name: "noisy")
        var pts = syntheticTrack(count: 5)
        pts[2].coordinate = Coordinate(latitude: .nan, longitude: -82)
        let r = try await store.appendTrackPoints(pts, to: t.id)
        #expect(r.appended == 4)
        #expect(r.rejected == 1)
        #expect(try await store.trackPoints(t.id).flatMap { $0 }.count == 4)
        await #expect(throws: PersistenceError.notFound(.track, UUIDs.missing)) {
            try await store.appendTrackPoints(pts, to: UUIDs.missing)
        }
    }

    @Test func derivedMaxSpeedWhenGPSReportsNone() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let pts = syntheticTrack(count: 10, interval: 2, speed: 4, wiggle: false).map {
            TrackPoint(timestamp: $0.timestamp, coordinate: $0.coordinate)
        }
        let t = try await store.saveTrack(name: "no speed", segments: [pts])
        #expect(abs((t.statistics.maxSpeed?.metersPerSecond ?? 0) - 4) < 0.05)
    }

    @Test func detailsUpdateAndDelete() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        var t = try await store.saveTrack(name: "old", segments: [syntheticTrack(count: 1000)])
        t.name = "new"
        t.notes = "renamed"
        t.color = TrackColor(red: 1, green: 2, blue: 3)
        let u = try await store.updateTrackDetails(t)
        #expect(u.name == "new")
        #expect(u.color.hex == "#010203")
        #expect(u.statistics.pointCount == 1000)
        #expect(try await store.deleteTrack(t.id))
        #expect(try await store.scalar("SELECT count(*) FROM track_chunk") == 0)
        #expect(try await store.tracks().isEmpty)
    }

    @Test func simplification() throws {
        // A straight line collapses to its ends; a zig-zag above tolerance keeps its corners.
        let line = (0...100).map { Coordinate(latitude: 27, longitude: -82 + Double($0) * 0.0001) }
        #expect(Simplify.douglasPeucker(line, toleranceMeters: 1) == [line.first!, line.last!])
        let zig = (0...10).map { Coordinate(latitude: 27 + ($0 % 2 == 0 ? 0 : 0.001), longitude: -82 + Double($0) * 0.001) }
        #expect(Simplify.douglasPeucker(zig, toleranceMeters: 10).count == zig.count)
        #expect(Simplify.douglasPeucker(zig, toleranceMeters: 500).count == 2)
        #expect(Simplify.everyNth(Array(line[0..<10]), 4).count == 4)  // 0, 4, 8, 9
        #expect(Simplify.everyNth(Array(line[0..<9]), 4).count == 3)   // 0, 4, 8
    }

    @Test func geometryQueryLevels() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let t = try await store.saveTrack(name: "g", segments: [syntheticTrack(count: 2000), syntheticTrack(count: 500)])
        let full = try await store.trackGeometry(t.id, detail: .full)
        #expect(full.map(\.count) == [2000, 500])
        let fine = try await store.trackGeometry(t.id, detail: .tolerance(meters: 2))
        let coarse = try await store.trackGeometry(t.id, detail: .zoom(8, latitude: 27.6))
        let nth = try await store.trackGeometry(t.id, detail: .everyNth(10))
        #expect(fine[0].count < 2000)
        #expect(coarse[0].count < fine[0].count)
        #expect(nth[0].count == 201)  // 0, 10, …, 1990, plus the last point 1999
        // Endpoints always survive.
        #expect(coarse[0].first == full[0].first)
        #expect(coarse[0].last == full[0].last)
    }

    /// Performance sanity check: 100,000 points recorded in batches of 10 (1 Hz with a 10 s flush is
    /// a realistic recording pattern), then read back and simplified.
    @Test func hundredThousandPoints() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try PersistenceStore(url: dir.file("perf.sqlite"), options: TestClock().options)
        let pts = syntheticTrack(count: 100_000)
        let t = try await store.startTrack(name: "long passage")
        let clock = ContinuousClock()

        let appendTime = try await clock.measure {
            for i in stride(from: 0, to: pts.count, by: 10) {
                try await store.appendTrackPoints(Array(pts[i..<min(i + 10, pts.count)]), to: t.id)
            }
        }
        var readBack: [[TrackPoint]] = []
        let readTime = try await clock.measure { readBack = try await store.trackPoints(t.id) }
        var simplified: [[Coordinate]] = []
        let simplifyTime = try await clock.measure {
            simplified = try await store.trackGeometry(t.id, detail: .zoom(12, latitude: 27.6))
        }
        let finishTime = try await clock.measure { _ = try await store.finishRecording(t.id) }
        let bulk = try await clock.measure { _ = try await store.saveTrack(name: "bulk", segments: [pts]) }
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.file("perf.sqlite").path)[.size] as? Int) ?? 0
        let wal = (try? FileManager.default.attributesOfItem(atPath: dir.file("perf.sqlite-wal").path)[.size] as? Int) ?? 0

        print(String(format: "[perf] 100k points: append in 10,000 batches of 10 %.0f ms; read all %.0f ms; "
                     + "simplify z12 %.0f ms (%d pts); finish+recompute %.0f ms; one-shot import %.0f ms; db %d KB + wal %d KB",
                     elapsedMilliseconds(appendTime), elapsedMilliseconds(readTime), elapsedMilliseconds(simplifyTime),
                     simplified.reduce(0) { $0 + $1.count }, elapsedMilliseconds(finishTime), elapsedMilliseconds(bulk),
                     size / 1024, wal / 1024))

        #expect(readBack.count == 1)
        #expect(readBack[0].count == 100_000)
        #expect(readBack[0][99_999] == pts[99_999])
        #expect(simplified[0].count < 100_000 / 10)
        // Generous ceilings: this is a sanity check that catches pathological regressions (e.g. O(n^2) appends), not a benchmark.
        #expect(appendTime < .seconds(60))
        #expect(readTime < .seconds(10))
        #expect(simplifyTime < .seconds(10))
    }
}

enum UUIDs {
    static let missing = UUID(uuidString: "00000000-0000-0000-0000-00000000DEAD")!
}

@Suite("Recording crash safety")
struct CrashRecoveryTests {
    /// Copies the database and its WAL while the writer still has it open: exactly what is on disk if the
    /// process is killed at that moment (committed transactions live in the WAL until a checkpoint).
    static func snapshotAsIfKilled(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        for side in ["", "-wal"] {
            let s = URL(fileURLWithPath: src.path + side)
            if fm.fileExists(atPath: s.path) { try fm.copyItem(at: s, to: URL(fileURLWithPath: dest.path + side)) }
        }
    }

    @Test func interruptedRecordingIsDetectedAndCanBeClosed() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let live = dir.file("live.sqlite")
        let store = try PersistenceStore(url: live, options: TestClock().options)
        try await store.save(Waypoint(name: "keep me", coordinate: Coordinate(latitude: 27, longitude: -82)))
        let finished = try await store.saveTrack(name: "yesterday", segments: [syntheticTrack(count: 100)])
        let t = try await store.startTrack(name: "today")
        let pts = syntheticTrack(count: 1234, wiggle: false)
        for i in stride(from: 0, to: pts.count, by: 50) {
            try await store.appendTrackPoints(Array(pts[i..<min(i + 50, pts.count)]), to: t.id)
        }
        let expected = try #require(try await store.track(t.id))
        try Self.snapshotAsIfKilled(live, to: dir.file("relaunch.sqlite"))

        // "Relaunch".
        let relaunched = try PersistenceStore(url: dir.file("relaunch.sqlite"), options: TestClock().options)
        #expect(relaunched.openReport.interruptedRecordings == [t.id])
        #expect(relaunched.openReport.recoveredCorruptFile == nil)
        #expect(try await relaunched.recordingTracks().map(\.id) == [t.id])
        #expect(try await relaunched.waypointCount() == 1)
        #expect(try await relaunched.track(finished.id)?.state == .finished)

        let closed = try await relaunched.finishRecording(t.id)
        #expect(closed.state == .finished)
        #expect(closed.statistics.pointCount == 1234)
        #expect(closed.statistics == expected.statistics)
        #expect(closed.endDate == pts.last!.timestamp)
        // The synthetic track is laid out on a sphere; the store measures on the ellipsoid (agree to ~0.1%).
        #expect(abs(closed.statistics.distance.meters / (1233 * 3) - 1) < 0.002)
        #expect(try await relaunched.recordingTracks().isEmpty)
        _ = store
    }

    @Test func interruptedRecordingCanBeResumedInANewSegment() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let live = dir.file("live.sqlite")
        let store = try PersistenceStore(url: live, options: TestClock().options)
        let t = try await store.startTrack(name: "passage")
        let first = syntheticTrack(count: 100, wiggle: false)
        try await store.appendTrackPoints(first, to: t.id)
        try Self.snapshotAsIfKilled(live, to: dir.file("relaunch.sqlite"))

        let relaunched = try PersistenceStore(url: dir.file("relaunch.sqlite"), options: TestClock().options)
        #expect(relaunched.openReport.interruptedRecordings == [t.id])
        let resumed = try await relaunched.resumeRecording(t.id)
        #expect(resumed.state == .recording)
        // Ten minutes later and 2 km away: must not be counted as distance or time.
        let second = syntheticTrack(count: 100, start: first.last!.timestamp!.addingTimeInterval(600),
                                    origin: Coordinate(latitude: 27.62, longitude: -82.6), wiggle: false)
        try await relaunched.appendTrackPoints(Array(second[..<50]), to: t.id)
        try await relaunched.appendTrackPoints(Array(second[50...]), to: t.id)  // continues the resumed segment
        let done = try await relaunched.finishRecording(t.id)
        #expect(done.statistics.segmentCount == 2)
        #expect(done.statistics.pointCount == 200)
        #expect(abs(done.statistics.distance.meters - 2 * 99 * 3) < 1)
        #expect(done.statistics.duration == 2 * 99)
        let segs = try await relaunched.trackPoints(t.id)
        #expect(segs.map(\.count) == [100, 100])
        _ = store
    }

    @Test func incrementalStatisticsMatchFullRecompute() async throws {
        let store = try PersistenceStore(inMemoryWith: TestClock().options)
        let t = try await store.startTrack(name: "x")
        for batch in syntheticTrack(count: 700).chunked(37) { try await store.appendTrackPoints(batch, to: t.id) }
        let before = try #require(try await store.track(t.id))
        let recomputed = try await store.recomputeStatistics(t.id)
        #expect(recomputed.statistics == before.statistics)
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
