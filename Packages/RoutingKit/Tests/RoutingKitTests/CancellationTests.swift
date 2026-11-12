import Foundation
import NavCore
import Testing
@testable import RoutingKit

/// A small lock-protected box for sharing state with `@Sendable` progress handlers.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&value) }
}

/// Sarasota q4: a strict Roberts Bay query with no route, so the main, relaxed and hint searches all run
/// (well over 8192 expansions in total).
func sarasotaNoRouteRequest() throws -> RouteRequest {
    let file = try Fixtures.decode(VectorFile.self, "sarasota.vectors.json")
    let q = file.queries.first { $0.id == "q4_same_strict" }!
    return q.request
}

@Suite struct CancellationTests {
    @Test func preCancelledAsyncRouteIsCancelled() async throws {
        let pack = Fixtures.sarasota
        let req = try sarasotaNoRouteRequest()
        let task = Task { () async -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(RoutingError) {
                _ = try await pack.route(req)
                return "finished"
            } catch {
                return error.code
            }
        }
        let code: String = await task.value
        #expect(code == "CANCELLED")
    }

    @Test func preCancelledSynchronousRouteIsCancelled() async throws {
        let pack = Fixtures.sarasota
        let req = try sarasotaNoRouteRequest()
        let task = Task.detached { () async -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(RoutingError) {
                _ = try pack.routeSynchronously(req)
                return "finished"
            } catch {
                return error.code
            }
        }
        let code: String = await task.value
        #expect(code == "CANCELLED")
    }

    /// Cancels from inside the search (on the first progress report): the next check stops the search.
    @Test func cancellationDuringSearch() async throws {
        let pack = Fixtures.sarasota
        let req = try sarasotaNoRouteRequest()
        let handle = LockedBox<Task<String, Never>?>(nil)
        let reports = LockedBox(0)
        let task = Task { () async -> String in
            do throws(RoutingError) {
                _ = try await pack.route(req, progress: { _ in
                    reports.update { $0 += 1 }
                    handle.get()?.cancel()
                })
                return "finished"
            } catch {
                return error.code
            }
        }
        handle.update { $0 = task }
        let code: String = await task.value
        // If the handle was stored after the first report, a later report cancels; either way it must stop.
        #expect(code == "CANCELLED")
        #expect(reports.get() >= 1)
    }

    @Test func timeLimitStopsTheQuery() throws {
        let pack = Fixtures.sarasota
        var req = try sarasotaNoRouteRequest()
        req.timeLimit = .zero
        do {
            _ = try pack.routeSynchronously(req)
            Issue.record("expected a timeout")
        } catch {
            #expect(error.code == "TIMED_OUT")
        }
    }

    @Test func progressIsReported() throws {
        let pack = Fixtures.sarasota
        let req = try sarasotaNoRouteRequest()
        let phases = LockedBox<Set<String>>([])
        do {
            _ = try pack.routeSynchronously(req, progress: { p in phases.update { $0.insert(p.phase.rawValue) } })
            Issue.record("expected NO_ROUTE")
        } catch {
            #expect(error.code == "NO_ROUTE")
        }
        #expect(!phases.get().isEmpty)
    }

    /// The async API returns the same result as the synchronous one and can run many queries concurrently on
    /// one shared pack.
    @Test func concurrentQueriesAgree() async throws {
        let pack = Fixtures.sarasota
        let file = try Fixtures.decode(VectorFile.self, "sarasota.vectors.json")
        let requests: [RouteRequest] = file.queries.map(\.request)
        let results = await withTaskGroup(of: (Int, String).self) { group -> [Int: String] in
            for (i, r) in requests.enumerated() {
                group.addTask { () async -> (Int, String) in
                    do throws(RoutingError) {
                        let res = try await pack.route(r)
                        return (i, "ok \(res.corridor.count) \(res.waypointsUnits.count)")
                    } catch {
                        return (i, error.code)
                    }
                }
            }
            var out: [Int: String] = [:]
            for await (i, s) in group { out[i] = s }
            return out
        }
        for (i, r) in requests.enumerated() {
            let expected: String
            do {
                let res = try pack.routeSynchronously(r)
                expected = "ok \(res.corridor.count) \(res.waypointsUnits.count)"
            } catch {
                expected = error.code
            }
            #expect(results[i] == expected)
        }
    }
}
