import AppServices
import Foundation
import NavCore
import Observation
import Persistence

/// Direct-to and route following (`AppServices.NavigationSession`), fed every fix by `AppModel`.
@MainActor
@Observable
final class GuidanceModel {
    private(set) var session: NavigationSession = NavigationSession()
    /// The latest leg-advance or arrival message, until dismissed or replaced.
    private(set) var message: String?
    /// Counts for the UI tests' status element.
    private(set) var advanceCount: Int = 0
    private(set) var arrivalCount: Int = 0

    /// Called when navigation starts, stops or the target changes (the map redraws).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var lastPosition: Coordinate?

    var isActive: Bool { session.isActive }
    var guidance: NavigationGuidance? { session.guidance }

    func goTo(_ waypoint: Waypoint, from position: Coordinate?) {
        let target = NavigationTarget(waypointID: waypoint.id, name: waypoint.name, coordinate: waypoint.coordinate)
        session.startDirectTo(target, from: position ?? lastPosition)
        message = nil
        refresh()
    }

    /// Follows `route`, joining it at the leg the boat is on (`NavigationSession.bestStartIndex`).
    func follow(_ route: Route, from position: Coordinate?) {
        let display = RouteDisplay(route: route)
        var targets: [NavigationTarget] = []
        for (index, point) in route.points.enumerated() {
            targets.append(NavigationTarget(name: display.pointName(index), coordinate: point.coordinate))
        }
        let here: Coordinate? = position ?? lastPosition
        let start: Int = NavigationSession.bestStartIndex(points: route.points.map(\.coordinate), position: here)
        session.startRoute(id: route.id, name: route.name, points: targets, from: here, startingAt: start)
        message = nil
        refresh()
    }

    func stop() {
        session.stop()
        message = nil
        onChange?()
    }

    func skipToNext() {
        session.skipToNext(position: lastPosition)
        refresh()
    }

    func dismissMessage() {
        message = nil
    }

    /// Stops following a route or going to a waypoint that has been deleted.
    func stopIfMissing(waypointIDs: Set<UUID>, routeIDs: Set<UUID>) {
        if let target = session.directToTarget, let id = target.waypointID, !waypointIDs.contains(id) {
            stop()
        } else if let routeID = session.activeRouteID, !routeIDs.contains(routeID) {
            stop()
        }
    }

    func update(fix: Fix, speedOverGround: Double?) {
        lastPosition = fix.coordinate
        guard session.isActive else { return }
        let before: Int? = session.activeRoutePointIndex
        let events: [NavigationEvent] = session.update(position: fix.coordinate, speedOverGround: speedOverGround,
                                                       now: fix.timestamp)
        handle(events)
        if before != session.activeRoutePointIndex || !events.isEmpty {
            onChange?()
        }
    }

    private func handle(_ events: [NavigationEvent]) {
        for event in events {
            switch event {
            case .advanced(let reached, let next):
                advanceCount += 1
                message = "Reached \(reached). Next: \(next)."
            case .arrived(let name):
                arrivalCount += 1
                message = "Arrived at \(name)."
            }
        }
    }

    private func refresh() {
        if let position = lastPosition {
            handle(session.update(position: position, speedOverGround: nil, now: Date()))
        }
        onChange?()
    }

    /// `idle`, `directTo` or `route` (for the status element).
    var modeName: String {
        switch session.state {
        case .idle: return "idle"
        case .directTo: return "directTo"
        case .route: return "route"
        }
    }
}
