import Foundation
import NavCore
import Testing
@testable import RoutingKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Gated on environment variables, skipped cleanly when unset:
//   ROUTINGKIT_PILOT_PACK     path to the full pilot pack (routing-pilot-20261023.pack, 4.3 MB)
//   ROUTINGKIT_PILOT_VECTORS  optional: a routing-vectors/1 file of reference routes on that pack, compared exactly

let pilotPackPath: String? = ProcessInfo.processInfo.environment["ROUTINGKIT_PILOT_PACK"]
let pilotVectorsPath: String? = ProcessInfo.processInfo.environment["ROUTINGKIT_PILOT_VECTORS"]

enum MemoryProbe {
    /// (current RSS, peak RSS) in bytes. Linux: /proc/self/status; Apple: getrusage (peak only).
    static func rss() -> (current: Int?, peak: Int?) {
        #if os(Linux)
        guard let s = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return (nil, nil) }
        func field(_ name: String) -> Int? {
            guard let line = s.split(separator: "\n").first(where: { $0.hasPrefix(name) }) else { return nil }
            let digits = line.filter(\.isNumber)
            return Int(digits).map { $0 * 1024 }
        }
        return (field("VmRSS:"), field("VmHWM:"))
        #else
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return (nil, Int(u.ru_maxrss))
        #endif
    }

    /// Resets the peak-RSS counter where the OS allows it (Linux: clear_refs 5).
    static func resetPeak() {
        #if os(Linux)
        try? "5".write(toFile: "/proc/self/clear_refs", atomically: false, encoding: .utf8)
        #endif
    }

    static func mb(_ b: Int?) -> String { b.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "n/a" }
}

func seconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}

#if DEBUG
let buildKind = "debug"
#else
let buildKind = "release"
#endif

@Suite(.serialized, .enabled(if: pilotPackPath != nil, "set ROUTINGKIT_PILOT_PACK to run"))
struct PilotPerformanceTests {
    @Test func loadTimeAndMemory() throws {
        let url = URL(fileURLWithPath: pilotPackPath!)
        MemoryProbe.resetPeak()
        let before = MemoryProbe.rss()
        let clock = ContinuousClock()
        let t0 = clock.now
        let pack = try RoutingPack(contentsOf: url)
        let loadTime = clock.now - t0
        let after = MemoryProbe.rss()
        print("[pilot \(buildKind)] load \(String(format: "%.3f", seconds(loadTime))) s; T=\(pack.triangleCount) V=\(pack.vertexCount) "
              + "derivedAdjacency=\(pack.adjacencyWasDerived); arrays \(MemoryProbe.mb(pack.memoryFootprintBytes)); "
              + "RSS before \(MemoryProbe.mb(before.current)) after \(MemoryProbe.mb(after.current)); "
              + "peak \(MemoryProbe.mb(after.peak)) (peak before load \(MemoryProbe.mb(before.peak)))")
        #expect(pack.triangleCount == 860_420)
        // Repeat to get a steady-state load time.
        var best = loadTime
        for _ in 0..<2 {
            let t = clock.now
            _ = try RoutingPack(contentsOf: url)
            best = min(best, clock.now - t)
        }
        print("[pilot \(buildKind)] best load of 3: \(String(format: "%.3f", seconds(best))) s")
    }

    @Test func referenceRoutes() throws {
        let pack = try RoutingPack(contentsOf: URL(fileURLWithPath: pilotPackPath!))
        let queries: [VectorQuery]
        if let p = pilotVectorsPath {
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            queries = try d.decode(VectorFile.self, from: Data(contentsOf: URL(fileURLWithPath: p))).queries
        } else {
            queries = []
        }
        guard !queries.isEmpty else {
            print("[pilot] ROUTINGKIT_PILOT_VECTORS not set: no reference routes to time")
            return
        }
        let clock = ContinuousClock()
        var matched = 0
        var peakQuery = 0
        MemoryProbe.resetPeak()
        for q in queries {
            let t0 = clock.now
            var outcome: String
            var expanded = 0
            do {
                let r = try pack.routeSynchronously(q.request)
                outcome = String(format: "ok %.1f nm, %d legs (%d yellow)", r.summary.distanceNauticalMiles, r.legs.count,
                                 r.summary.yellowLegs)
                expanded = r.expanded
            } catch {
                outcome = error.code
            }
            let dt = seconds(clock.now - t0)
            let mismatches: [String] = compareVector(q, on: pack)
            if mismatches.isEmpty { matched += 1 }
            peakQuery = max(peakQuery, MemoryProbe.rss().peak ?? 0)
            let status = mismatches.isEmpty ? "exact" : "MISMATCH \(mismatches.prefix(3))"
            print("[pilot \(buildKind)] \(q.id.padding(toLength: 34, withPad: " ", startingAt: 0)) "
                  + "\(String(format: "%7.3f", dt)) s  expanded \(expanded)  \(outcome)  \(status)")
        }
        print("[pilot \(buildKind)] \(matched)/\(queries.count) reference routes match the Python reference exactly; "
              + "peak RSS during queries \(MemoryProbe.mb(peakQuery))")
        #expect(matched == queries.count)
    }

    /// Cancelling a long query mid-search returns promptly.
    @Test func cancellationLatency() async throws {
        let pack = try RoutingPack(contentsOf: URL(fileURLWithPath: pilotPackPath!))
        let req = RouteRequest(start: Coordinate(latitude: 27.4690, longitude: -82.6930),
                               goal: Coordinate(latitude: 26.7530, longitude: -82.2480),
                               profile: BoatProfile(draftFeet: 4.5, safetyMarginFeet: 1.5, airDraftFeet: 20, avoidOpenGulf: true))
        let clock = ContinuousClock()
        let task = Task { () async -> String in
            do throws(RoutingError) {
                _ = try await pack.route(req)
                return "finished"
            } catch {
                return error.code
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let t0 = clock.now
        task.cancel()
        let code: String = await task.value
        let latency = seconds(clock.now - t0)
        print("[pilot \(buildKind)] cancel after 30 ms: \(code), returned \(String(format: "%.4f", latency)) s after cancel()")
        #expect(code == "CANCELLED")
        #expect(latency < 0.5)
    }
}
