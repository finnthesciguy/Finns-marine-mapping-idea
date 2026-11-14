import Foundation
import NavCore
@testable import Persistence

/// A unique temporary directory, removed by `cleanup()`.
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func cleanup() { try? FileManager.default.removeItem(at: url) }

    var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

/// A clock that advances one second per reading, so modified stamps are distinct and predictable.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(1)
        return current
    }

    var options: PersistenceStore.Options {
        PersistenceStore.Options(clock: { [self] in now() })
    }
}

/// Points along a line heading east from Tampa Bay at `speed` m/s, one per `interval` seconds.
func syntheticTrack(count: Int, start: Date = Date(timeIntervalSince1970: 1_800_000_000),
                    origin: Coordinate = Coordinate(latitude: 27.6, longitude: -82.7),
                    interval: TimeInterval = 1, speed: Double = 3, wiggle: Bool = true) -> [TrackPoint] {
    let metersPerDegLon = 111_320 * cos(origin.latitude * .pi / 180)
    return (0..<count).map { i in
        let along = Double(i) * speed * interval
        let lat = origin.latitude + (wiggle ? sin(Double(i) / 50) * 0.002 : 0)
        return TrackPoint(timestamp: start.addingTimeInterval(Double(i) * interval),
                          coordinate: Coordinate(latitude: lat, longitude: origin.longitude + along / metersPerDegLon),
                          speed: speed, course: 90, horizontalAccuracy: 5)
    }
}

/// Collects up to `count` changes from a stream, or whatever arrived within `timeout`.
func collect(_ stream: AsyncStream<StoreChange>, count: Int, timeout: Duration = .seconds(5)) async -> [StoreChange] {
    await withTaskGroup(of: [StoreChange]?.self) { group in
        group.addTask {
            var out: [StoreChange] = []
            for await c in stream {
                out.append(c)
                if out.count >= count { break }
            }
            return out
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

func elapsedMilliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
