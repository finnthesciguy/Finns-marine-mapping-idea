import AppServices
import Foundation
import NavCore
import Observation
import Persistence

/// Waypoints, routes, tracks and settings from the Persistence store, kept current through the store's
/// change feed (so any writer, including GPX import and the track recorder, is reflected everywhere).
@MainActor
@Observable
final class UserDataModel {
    private(set) var waypoints: [Waypoint] = []
    private(set) var routes: [Route] = []
    private(set) var tracks: [Track] = []
    private(set) var settings: AppSettings = AppSettings()
    /// Last failure of a store operation, shown as a banner.
    var errorText: String?

    /// Called after any of the lists or the settings changed, with the kind reloaded and the revision at
    /// which that reload started (see `RetainedIDs`; local saves report the current revision).
    @ObservationIgnored var onChange: (@MainActor (EntityKind, Int) -> Void)?
    /// Number of reloads started so far. A choice made now is newer than every reload started before.
    @ObservationIgnored private(set) var reloadRevision: Int = 0

    let store: PersistenceStore
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(store: PersistenceStore) {
        self.store = store
    }

    func start() async {
        guard !started else { return }
        started = true
        let changes: AsyncStream<StoreChange> = store.changes([.waypoint, .route, .track, .setting])
        feedTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await self.reload(change.kind)
            }
        }
        await reload(.waypoint)
        await reload(.route)
        await reload(.track)
        await reload(.setting)
    }

    private func reload(_ kind: EntityKind) async {
        reloadRevision += 1
        let startedAt: Int = reloadRevision
        do {
            switch kind {
            case .waypoint:
                waypoints = try await store.waypoints(order: .name)
            case .route:
                routes = try await store.routes(order: .name)
            case .track:
                tracks = try await store.tracks()
            case .setting:
                settings = await AppSettings.load(from: store)
            case .boatProfile, .anchorWatch:
                return
            }
        } catch {
            errorText = "Saved data could not be read: \(error)"
        }
        onChange?(kind, startedAt)
    }

    /// Puts a just-saved waypoint into the list at once (in the store's name order), so the UI does not
    /// depend on when the change feed's reload arrives.
    private func upsertLocally(_ waypoint: Waypoint) {
        var next: [Waypoint] = waypoints.filter { $0.id != waypoint.id }
        next.append(waypoint)
        next.sort { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.createdAt < b.createdAt
        }
        waypoints = next
        onChange?(.waypoint, reloadRevision)
    }

    private func upsertLocally(_ route: Route) {
        var next: [Route] = routes.filter { $0.id != route.id }
        next.append(route)
        next.sort { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.createdAt < b.createdAt
        }
        routes = next
        onChange?(.route, reloadRevision)
    }

    func waypoint(_ id: UUID?) -> Waypoint? {
        guard let id else { return nil }
        return waypoints.first { $0.id == id }
    }

    func route(_ id: UUID?) -> Route? {
        guard let id else { return nil }
        return routes.first { $0.id == id }
    }

    func track(_ id: UUID?) -> Track? {
        guard let id else { return nil }
        return tracks.first { $0.id == id }
    }

    // MARK: Writes

    @discardableResult
    func save(_ waypoint: Waypoint) async -> Waypoint? {
        do {
            let saved: Waypoint = try await store.save(waypoint)
            upsertLocally(saved)
            return saved
        } catch {
            errorText = "The waypoint could not be saved: \(error)"
            return nil
        }
    }

    /// A new waypoint at `coordinate` named with the next "WP nnn" number, which never repeats in this
    /// store (`WaypointNumbering`), even after a rename or delete.
    @discardableResult
    func addWaypoint(at coordinate: Coordinate) async -> Waypoint? {
        let name: String = await WaypointNumbering.takeNextName(store: store, existing: waypoints.map(\.name))
        return await save(Waypoint(name: name, coordinate: coordinate))
    }

    func deleteWaypoint(_ id: UUID) async {
        do {
            _ = try await store.deleteWaypoint(id)
        } catch {
            errorText = "The waypoint could not be deleted: \(error)"
        }
    }

    @discardableResult
    func save(_ route: Route) async -> Route? {
        do {
            let saved: Route = try await store.save(route)
            upsertLocally(saved)
            return saved
        } catch {
            errorText = "The route could not be saved: \(error)"
            return nil
        }
    }

    func deleteRoute(_ id: UUID) async {
        do {
            _ = try await store.deleteRoute(id)
        } catch {
            errorText = "The route could not be deleted: \(error)"
        }
    }

    func deleteTrack(_ id: UUID) async {
        do {
            _ = try await store.deleteTrack(id)
        } catch {
            errorText = "The track could not be deleted: \(error)"
        }
    }

    func renameTrack(_ id: UUID, to name: String) async {
        guard var track = track(id) else { return }
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        track.name = trimmed
        do {
            _ = try await store.updateTrackDetails(track)
        } catch {
            errorText = "The track could not be renamed: \(error)"
        }
    }

    func updateSettings(_ next: AppSettings) async {
        let previous: AppSettings = settings
        settings = next
        do {
            try await next.save(to: store, previous: previous)
        } catch {
            errorText = "Settings could not be saved: \(error)"
        }
        onChange?(.setting, reloadRevision)
    }

    /// Simplified geometry of a saved track for the map (see `TrackDetailPolicy`).
    func trackGeometry(_ id: UUID, zoom: Double, latitude: Double) async -> [[Coordinate]] {
        do {
            return try await store.trackGeometry(id, detail: TrackDetailPolicy.detail(forZoom: zoom, latitude: latitude))
        } catch {
            return []
        }
    }

    // MARK: GPX

    /// Writes a GPX file for the share sheet. `nil` = all of a kind, `[]` = none.
    func exportGPX(waypoints: [UUID]?, routes: [UUID]?, tracks: [UUID]?, title: String) async -> URL? {
        do {
            return try await GPXFiles.export(store: store, waypoints: waypoints, routes: routes, tracks: tracks,
                                             title: title, date: Date(),
                                             directory: FileManager.default.temporaryDirectory)
        } catch {
            errorText = "The GPX file could not be written: \(error)"
            return nil
        }
    }
}
