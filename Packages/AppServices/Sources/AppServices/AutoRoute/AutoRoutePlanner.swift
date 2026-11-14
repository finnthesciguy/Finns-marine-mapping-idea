import Foundation
import NavCore
import Persistence
import RoutingKit

/// Progress of a plan, for the planner screen.
public struct AutoRouteProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case openingPack, searching, explaining, checkingOptions
    }

    public var phase: Phase
    /// "Opening routing pack…", "Searching for a route…", ...
    public var text: String
    /// Triangles searched so far in this phase.
    public var expanded: Int
    public var elapsedSeconds: Double

    public init(phase: Phase, expanded: Int = 0, elapsedSeconds: Double = 0) {
        self.phase = phase
        self.expanded = expanded
        self.elapsedSeconds = elapsedSeconds
        switch phase {
        case .openingPack: text = "Opening routing pack…"
        case .searching: text = "Searching for a route…"
        case .explaining: text = "No route yet: finding where it is blocked…"
        case .checkingOptions: text = "Checking which settings would help…"
        }
    }

    init(_ progress: RoutingProgress) {
        let phase: Phase
        switch progress.phase {
        case .search: phase = .searching
        case .noRouteReport: phase = .explaining
        case .hints: phase = .checkingOptions
        }
        let parts = progress.elapsed.components
        self.init(phase: phase, expanded: progress.expanded,
                  elapsedSeconds: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}

/// Plans auto-routes: picks and opens the routing pack, runs RoutingKit off the main actor with progress,
/// cancellation and a time limit, and maps every outcome to ``AutoRoutePlanOutcome``.
///
/// Refuses to plan until ``AutoRouteNotice`` has been acknowledged (when a gate is given).
public final class AutoRoutePlanner: Sendable {
    public let library: RoutingPackLibrary
    public let noticeGate: AutoRouteNoticeGate?

    public init(library: RoutingPackLibrary, noticeGate: AutoRouteNoticeGate?) {
        self.library = library
        self.noticeGate = noticeGate
    }

    /// Runs one plan. Cancelling the calling task stops it promptly (outcome `.failed(.cancelled)`).
    public func plan(_ request: AutoRoutePlanRequest, units: UnitPreferences = UnitPreferences(), now: Date = Date(),
                     progress: (@Sendable (AutoRouteProgress) -> Void)? = nil) async -> AutoRoutePlanOutcome {
        if let noticeGate, await noticeGate.needsAcknowledgement() {
            return .failed(AutoRoutePresenter.noticeNotAcknowledged())
        }
        let profileProblems: [String] = AutoRouteProfileCheck.problems(request.profile)
        guard profileProblems.isEmpty, let boat = EffectiveBoat(profile: request.profile, options: request.options) else {
            return .failed(AutoRoutePresenter.invalidProfile(profileProblems, name: request.profile.name))
        }
        if Task.isCancelled { return .failed(AutoRoutePresenter.cancelled()) }

        let selection: RoutingPackSelection = await library.select(start: request.start.coordinate, goal: request.goal.coordinate)
        if let failure = AutoRoutePresenter.selectionFailure(selection, request: request) { return .failed(failure) }
        guard case .pack(let entry) = selection else { return .failed(AutoRoutePresenter.cancelled()) }

        progress?(AutoRouteProgress(phase: .openingPack))
        let library: RoutingPackLibrary = self.library
        let opened: Result<RoutingPack, PackError> = await Task.detached(priority: .userInitiated) { () -> Result<RoutingPack, PackError> in
            do throws(PackError) {
                return .success(try library.open(entry))
            } catch {
                return .failure(error)
            }
        }.value
        let pack: RoutingPack
        switch opened {
        case .success(let p): pack = p
        case .failure(let error): return .failed(AutoRoutePresenter.packUnreadable(entry, reason: error.description))
        }
        if Task.isCancelled { return .failed(AutoRoutePresenter.cancelled()) }

        let context = AutoRoutePresenter.Context(request: request, boat: boat, pack: entry, units: units, now: now)
        let limit: Double = max(1, min(request.options.timeLimitSeconds, 600))
        let routingRequest = RouteRequest(start: request.start.coordinate, goal: request.goal.coordinate,
                                          profile: boat.routingProfile, maxSnapMeters: request.options.maxSnapMeters,
                                          timeLimit: .milliseconds(Int64(limit * 1000)))
        var forward: (@Sendable (RoutingProgress) -> Void)? = nil
        if let handler = progress {
            forward = { @Sendable (p: RoutingProgress) -> Void in handler(AutoRouteProgress(p)) }
        }
        progress?(AutoRouteProgress(phase: .searching))
        let routed: Result<RouteResult, RoutingError> = await AutoRoutePlanner.route(pack, routingRequest, progress: forward)
        switch routed {
        case .success(let result):
            if Task.isCancelled { return .failed(AutoRoutePresenter.cancelled()) }
            return .proposal(AutoRoutePresenter.proposal(result, context: context))
        case .failure(let error):
            return AutoRoutePresenter.outcome(for: error, context: context)
        }
    }

    static func route(_ pack: RoutingPack, _ request: RouteRequest,
                      progress: (@Sendable (RoutingProgress) -> Void)?) async -> Result<RouteResult, RoutingError> {
        do throws(RoutingError) {
            let result: RouteResult = try await pack.route(request, progress: progress)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }
}
