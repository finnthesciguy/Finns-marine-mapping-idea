import Foundation
import NavCore

/// A point to steer to.
public struct NavigationTarget: Sendable, Equatable {
    /// The stored waypoint, when the target is one.
    public var waypointID: UUID?
    public var name: String
    public var coordinate: Coordinate

    public init(waypointID: UUID? = nil, name: String, coordinate: Coordinate) {
        self.waypointID = waypointID
        self.name = name
        self.coordinate = coordinate
    }
}

/// What the instrument strip shows while navigating.
public struct NavigationGuidance: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case directTo
        case route(id: UUID, name: String)
    }

    public var mode: Mode
    /// Name of the waypoint being steered to.
    public var targetName: String
    /// Index into the route's points of the waypoint being steered to (0 for direct-to).
    public var targetIndex: Int
    /// Number of points in the route (1 for direct-to).
    public var pointCount: Int
    /// Metres.
    public var distanceToTarget: Double
    /// Degrees true.
    public var bearingToTarget: Double
    /// Metres; positive means right of the intended track.
    public var crossTrackError: Double
    /// Metres to the final point.
    public var remainingDistance: Double
    public var timeToTarget: TimeInterval?
    public var timeToGo: TimeInterval?
    public var eta: Date?
    public var arrived: Bool
}

/// Things worth telling the skipper about.
public enum NavigationEvent: Sendable, Equatable {
    /// Reached a route point and moved on to the next one.
    case advanced(reachedName: String, nextName: String)
    /// Reached the final point (or the direct-to target).
    case arrived(name: String)
}

/// Direct-to and route following on top of NavCore's `RouteNavigator`, as a value type driven fix by fix.
///
/// The leg the boat is on when navigation starts runs from the boat's position to the first target (the
/// direct-to point, or the route's first point), so guidance is meaningful from wherever the boat is; the
/// route's own legs follow. Leg advance uses NavCore's arrival circle and perpendicular rule; the final
/// point uses the arrival circle only (passing abeam of the destination is not arriving).
public struct NavigationSession: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case directTo(NavigationTarget)
        case route(id: UUID, name: String)
    }

    public private(set) var state: State = .idle
    public private(set) var guidance: NavigationGuidance?
    /// Route points (or the single direct-to target), with names.
    public private(set) var targets: [NavigationTarget] = []
    public var policy: LegAdvancePolicy
    /// Index in the original route of `targets[0]` (non-zero after starting later or skipping).
    public private(set) var routeIndexOffset: Int = 0
    /// Number of points in the original route (1 for direct-to).
    public private(set) var routePointCount: Int = 0

    /// The navigator's waypoints are `[start] + targets`; nil until a position is known.
    private var navigator: RouteNavigator?
    private var arrivedAnnounced = false

    public init(policy: LegAdvancePolicy = LegAdvancePolicy()) {
        self.policy = policy
    }

    public var isActive: Bool { state != .idle }

    /// Index into `targets` of the point being steered to, or nil when idle / not started.
    public var activeTargetIndex: Int? {
        guard let navigator else { return isActive ? 0 : nil }
        return min(max(navigator.activeLegIndex, 0), max(targets.count - 1, 0))
    }

    /// Index in the original route of the point being steered to.
    public var activeRoutePointIndex: Int? {
        guard let index = activeTargetIndex else { return nil }
        return routeIndexOffset + index
    }

    public var activeRouteID: UUID? {
        if case .route(let id, _) = state { return id }
        return nil
    }

    public var directToTarget: NavigationTarget? {
        if case .directTo(let target) = state { return target }
        return nil
    }

    public mutating func startDirectTo(_ target: NavigationTarget, from position: Coordinate?) {
        state = .directTo(target)
        targets = [target]
        routeIndexOffset = 0
        routePointCount = 1
        begin(at: position)
    }

    /// Follows a route from its first point (or from `startingAt`, an index into `points`).
    public mutating func startRoute(id: UUID, name: String, points: [NavigationTarget], from position: Coordinate?,
                                    startingAt: Int = 0) {
        guard !points.isEmpty else {
            stop()
            return
        }
        state = .route(id: id, name: name)
        let first: Int = min(max(startingAt, 0), points.count - 1)
        targets = Array(points[first...])
        routeIndexOffset = first
        routePointCount = points.count
        begin(at: position)
    }

    /// Where to join a route from `position`: the index of the point to steer to first. 0 (the route's
    /// start) unless the boat is alongside a later leg, closer to it than to the start; then the end of
    /// that leg, so a boat already under way on the route is not sent back to the beginning.
    public static func bestStartIndex(points: [Coordinate], position: Coordinate?) -> Int {
        guard let position, position.isValid, points.count >= 2 else { return 0 }
        var bestIndex: Int = 0
        var bestDistance: Double = Geodesy.distance(from: position, to: points[0])
        for i in 0..<(points.count - 1) {
            let projection = Geodesy.project(position, legStart: points[i], legEnd: points[i + 1])
            guard projection.legLength > 0, projection.alongTrack > 0, projection.alongTrack < projection.legLength else {
                continue
            }
            let offTrack: Double = abs(projection.crossTrack)
            if offTrack < bestDistance {
                bestDistance = offTrack
                bestIndex = i + 1
            }
        }
        return bestIndex
    }

    public mutating func stop() {
        state = .idle
        targets = []
        navigator = nil
        guidance = nil
        arrivedAnnounced = false
        routeIndexOffset = 0
        routePointCount = 0
    }

    /// Skips the point being steered to (route only); the new leg starts at the current position.
    public mutating func skipToNext(position: Coordinate?) {
        guard case .route = state, let index = activeTargetIndex, index + 1 < targets.count else { return }
        targets = Array(targets[(index + 1)...])
        routeIndexOffset += index + 1
        begin(at: position)
    }

    private mutating func begin(at position: Coordinate?) {
        arrivedAnnounced = false
        guidance = nil
        navigator = nil
        if let position, position.isValid {
            navigator = RouteNavigator(waypoints: [position] + targets.map(\.coordinate), policy: policy)
        }
    }

    /// Feeds a fix. Returns leg-advance and arrival events.
    @discardableResult
    public mutating func update(position: Coordinate, speedOverGround: Double?, now: Date) -> [NavigationEvent] {
        guard isActive, position.isValid, !targets.isEmpty else { return [] }
        if navigator == nil {
            navigator = RouteNavigator(waypoints: [position] + targets.map(\.coordinate), policy: policy)
        }
        guard var nav = navigator else { return [] }
        var events: [NavigationEvent] = []
        // Advance through intermediate points with the full policy; the last point needs the arrival circle.
        while !nav.isFinished {
            let leg: Int = nav.activeLegIndex
            let isFinalLeg: Bool = leg == nav.waypoints.count - 2
            let legPolicy = LegAdvancePolicy(arrivalRadius: policy.arrivalRadius,
                                             advanceOnPerpendicular: policy.advanceOnPerpendicular && !isFinalLeg)
            guard Navigation.legCompletion(position: position, legStart: nav.waypoints[leg],
                                           legEnd: nav.waypoints[leg + 1], policy: legPolicy) != nil else { break }
            nav.activateLeg(leg + 1)
            if !isFinalLeg {
                events.append(.advanced(reachedName: targets[leg].name, nextName: targets[leg + 1].name))
            }
        }
        navigator = nav

        let finalTarget: NavigationTarget = targets[targets.count - 1]
        let sog: Double? = speedOverGround.flatMap { $0 > 0.05 && $0.isFinite ? $0 : nil }
        if nav.isFinished {
            let distance: Double = Geodesy.distance(from: position, to: finalTarget.coordinate)
            let bearing: Double = Geodesy.initialBearing(from: position, to: finalTarget.coordinate)
            guidance = NavigationGuidance(mode: guidanceMode, targetName: finalTarget.name,
                                          targetIndex: routeIndexOffset + targets.count - 1,
                                          pointCount: routePointCount,
                                          distanceToTarget: distance, bearingToTarget: bearing, crossTrackError: 0,
                                          remainingDistance: distance, timeToTarget: nil, timeToGo: nil, eta: nil,
                                          arrived: true)
            if !arrivedAnnounced {
                arrivedAnnounced = true
                events.append(.arrived(name: finalTarget.name))
            }
            return events
        }
        guard let progress = nav.progress(position: position, speedOverGround: sog) else { return events }
        let index: Int = progress.activeLegIndex
        guidance = NavigationGuidance(mode: guidanceMode, targetName: targets[index].name,
                                      targetIndex: routeIndexOffset + index, pointCount: routePointCount,
                                      distanceToTarget: progress.distanceToNextWaypoint,
                                      bearingToTarget: progress.bearingToNextWaypoint,
                                      crossTrackError: progress.crossTrackError,
                                      remainingDistance: progress.remainingDistance,
                                      timeToTarget: progress.timeToNextWaypoint, timeToGo: progress.timeToGo,
                                      eta: progress.eta(from: now), arrived: false)
        return events
    }

    private var guidanceMode: NavigationGuidance.Mode {
        if case .route(let id, let name) = state { return .route(id: id, name: name) }
        return .directTo
    }

    /// The line to draw from the boat to the target (direct-to) or nil.
    public func directToLine(from position: Coordinate?) -> [Coordinate]? {
        guard let target = directToTarget, let position else { return nil }
        return [position, target.coordinate]
    }
}
