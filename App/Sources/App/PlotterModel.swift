import AppServices
import Foundation
import NavCore
import Observation
import Persistence

/// A route being created or edited on the map: points are added by tapping the map.
struct RouteDraft: Equatable {
    var route: Route
    var isNew: Bool
}

/// The chart plotter's navigation data on the map: waypoints, routes and tracks (`UserDataModel`), direct-to
/// and route following (`GuidanceModel`), track recording (`RecordingModel`), what is shown on the map
/// (`MapOverlays`), map taps, route editing and GPX import/export. UI-free, so the views stay thin.
@MainActor
@Observable
final class PlotterModel {
    let data: UserDataModel
    let guidance: GuidanceModel
    let recording: RecordingModel

    /// GeoJSON for the map's overlay sources, rebuilt by `refreshOverlays()`.
    private(set) var overlays: MapOverlays = MapOverlays.empty
    /// The selected waypoint and the routes and tracks shown, kept across stale list reloads (`RetainedIDs`).
    private var selection: RetainedIDs = RetainedIDs()
    private var shownRoutes: RetainedIDs = RetainedIDs()
    private var shownTracks: RetainedIDs = RetainedIDs()
    var selectedWaypointID: UUID? { selection.single }
    var shownRouteIDs: Set<UUID> { shownRoutes.ids }
    var shownTrackIDs: Set<UUID> { shownTracks.ids }
    /// Route being created or edited by tapping the map.
    private(set) var routeDraft: RouteDraft?
    /// The auto-route planner's unsaved route or blocked places (set by `AutoRouteModel`).
    private(set) var plannedLayer: PlannedRouteLayer = .empty

    /// The import plan waiting for the user's decision (presented as a sheet).
    var importPlan: GPXImportPlan?
    private(set) var importResultText: String?
    private(set) var lastImportSummary: String = "none"
    /// A GPX file ready for the share sheet.
    var exportFile: ExportFile?
    private(set) var lastExportName: String = "none"

    struct ExportFile: Identifiable, Equatable {
        let url: URL
        var id: String { url.path }
    }

    /// The boat's latest position (from `NavigationModel`).
    @ObservationIgnored var currentPosition: @MainActor () -> Coordinate? = { nil }
    @ObservationIgnored private var trackGeometry: [UUID: [[Coordinate]]] = [:]
    @ObservationIgnored private var geometryZoomBucket: Double = -1
    @ObservationIgnored private var mapZoom: Double = 9
    @ObservationIgnored private var mapLatitude: Double = 27.6

    init(store: PersistenceStore, trackBatchSize: Int) {
        let dataModel = UserDataModel(store: store)
        self.data = dataModel
        self.guidance = GuidanceModel()
        self.recording = RecordingModel(store: store, filter: TrackPointFilter(), batchSize: trackBatchSize)
        dataModel.onChange = { [weak self] kind, startedAt in self?.dataChanged(kind, startedAt: startedAt) }
        guidance.onChange = { [weak self] in self?.refreshOverlays() }
        recording.onSnapshot = { [weak self] in self?.refreshOverlays() }
    }

    /// Loads the lists and settings, then continues an interrupted recording if startup recovery resumed one.
    func start(resumedRecording: Track?) async {
        await data.start()
        recording.setFilter(data.settings.trackFilter)
        if let resumedRecording {
            await recording.adopt(resumedRecording)
        }
        refreshOverlays()
    }

    func handle(_ fix: Fix, speedOverGround: Double?) {
        guidance.update(fix: fix, speedOverGround: speedOverGround)
        recording.record(fix)
        if guidance.session.directToTarget != nil {
            // The direct-to line starts at the boat.
            refreshOverlays()
        }
    }

    /// A list was reloaded (by a reload that started at revision `startedAt`) or changed locally.
    private func dataChanged(_ kind: EntityKind, startedAt: Int) {
        switch kind {
        case .setting:
            recording.setFilter(data.settings.trackFilter)
        case .waypoint:
            let waypointIDs: Set<UUID> = Set(data.waypoints.map(\.id))
            selection.reconcile(present: waypointIDs, reloadStartedAt: startedAt)
            guidance.stopIfMissing(waypointIDs: waypointIDs, routeIDs: Set(data.routes.map(\.id)))
        case .route:
            let routeIDs: Set<UUID> = Set(data.routes.map(\.id))
            shownRoutes.reconcile(present: routeIDs, reloadStartedAt: startedAt)
            guidance.stopIfMissing(waypointIDs: Set(data.waypoints.map(\.id)), routeIDs: routeIDs)
        case .track:
            let trackIDs: Set<UUID> = Set(data.tracks.map(\.id))
            if shownTracks.reconcile(present: trackIDs, reloadStartedAt: startedAt) {
                trackGeometry = trackGeometry.filter { trackIDs.contains($0.key) }
            }
        case .boatProfile, .anchorWatch:
            break
        }
        refreshOverlays()
    }

    // MARK: Map interaction

    func select(_ waypointID: UUID?) {
        guard waypointID != selectedWaypointID else { return }
        selection.set(waypointID, revision: data.reloadRevision)
        refreshOverlays()
    }

    /// A tap on the map: adds a route point while editing, otherwise selects the tapped waypoint (or clears).
    func mapTapped(at coordinate: Coordinate, waypoint: UUID?) {
        if routeDraft != nil {
            var point = RoutePoint(coordinate: coordinate)
            if let hit = data.waypoint(waypoint) {
                point = RoutePoint(coordinate: hit.coordinate, name: hit.name)
            }
            routeDraft?.route.points.append(point)
            refreshOverlays()
            return
        }
        select(waypoint)
    }

    /// A long press: a route point while editing, otherwise a new waypoint there.
    func mapLongPressed(at coordinate: Coordinate) async {
        if routeDraft != nil {
            mapTapped(at: coordinate, waypoint: nil)
            return
        }
        if let created = await data.addWaypoint(at: coordinate) {
            select(created.id)
        }
    }

    /// The map's zoom and centre latitude changed: reload shown tracks at a matching simplification.
    func mapCameraChanged(zoom: Double, latitude: Double) {
        mapZoom = zoom
        mapLatitude = latitude
        let bucket: Double = TrackDetailPolicy.bucket(forZoom: zoom)
        guard bucket != geometryZoomBucket, !shownTrackIDs.isEmpty else { return }
        geometryZoomBucket = bucket
        Task { await reloadTrackGeometry() }
    }

    // MARK: Waypoints

    @discardableResult
    func dropWaypointAtBoat() async -> Waypoint? {
        guard let position = currentPosition() else {
            data.errorText = "No position yet: a waypoint can be dropped once the GPS has a fix."
            return nil
        }
        let created: Waypoint? = await data.addWaypoint(at: position)
        if let created { select(created.id) }
        return created
    }

    func goTo(_ waypoint: Waypoint) {
        guidance.goTo(waypoint, from: currentPosition())
        refreshOverlays()
    }

    // MARK: Routes

    func beginNewRoute() {
        routeDraft = RouteDraft(route: Route(name: DefaultNames.routeName(existingCount: data.routes.count)), isNew: true)
        refreshOverlays()
    }

    func beginEditing(_ route: Route) {
        routeDraft = RouteDraft(route: route, isNew: false)
        refreshOverlays()
    }

    func updateDraft(_ route: Route) {
        guard routeDraft != nil else { return }
        routeDraft?.route = route
        refreshOverlays()
    }

    func undoLastDraftPoint() {
        guard let count = routeDraft?.route.points.count, count > 0 else { return }
        routeDraft?.route.points.removeLast()
        refreshOverlays()
    }

    func cancelDraft() {
        routeDraft = nil
        refreshOverlays()
    }

    /// Saves the draft (a route needs at least two points). Returns false when it could not be saved.
    @discardableResult
    func saveDraft() async -> Bool {
        guard let draft = routeDraft else { return false }
        guard draft.route.points.count >= 2 else {
            data.errorText = "A route needs at least two points. Tap the map to add points."
            return false
        }
        guard let saved = await data.save(draft.route) else { return false }
        routeDraft = nil
        shownRoutes.insert(saved.id, revision: data.reloadRevision)
        refreshOverlays()
        return true
    }

    func setRouteShown(_ id: UUID, _ shown: Bool) {
        if shown { shownRoutes.insert(id, revision: data.reloadRevision) } else { shownRoutes.remove(id) }
        refreshOverlays()
    }

    func follow(_ route: Route) {
        shownRoutes.insert(route.id, revision: data.reloadRevision)
        guidance.follow(route, from: currentPosition())
        refreshOverlays()
    }

    /// Shows the planner's result on the chart (`.empty` clears it).
    func setPlannedLayer(_ layer: PlannedRouteLayer) {
        guard layer != plannedLayer else { return }
        plannedLayer = layer
        refreshOverlays()
    }

    // MARK: Tracks

    func setTrackShown(_ id: UUID, _ shown: Bool) {
        if shown {
            shownTracks.insert(id, revision: data.reloadRevision)
            Task { await reloadTrackGeometry() }
        } else {
            shownTracks.remove(id)
            trackGeometry[id] = nil
            refreshOverlays()
        }
    }

    private func reloadTrackGeometry() async {
        var loaded: [UUID: [[Coordinate]]] = [:]
        for id in shownTrackIDs {
            loaded[id] = await data.trackGeometry(id, zoom: mapZoom, latitude: mapLatitude)
        }
        trackGeometry = loaded
        refreshOverlays()
    }

    func toggleRecording() async {
        if recording.isActive {
            let id: UUID? = recording.snapshot.trackID
            await recording.stop()
            if let id {
                // Keep the finished track on the map.
                setTrackShown(id, true)
            }
        } else {
            await recording.start()
        }
        refreshOverlays()
    }

    // MARK: GPX

    func planImport(fileAt url: URL) async {
        do {
            importPlan = try await GPXFiles.plan(fileAt: url, store: data.store)
            importResultText = nil
        } catch {
            data.errorText = "The GPX file could not be read: \(error)"
        }
    }

    func planImport(data bytes: Data) async {
        do {
            importPlan = try await GPXFiles.plan(data: bytes, store: data.store)
            importResultText = nil
        } catch {
            data.errorText = "The GPX file could not be read: \(error)"
        }
    }

    func setImportDecision(_ decision: GPXImportDecision, rowID: String) {
        guard var plan = importPlan else { return }
        GPXImportPresentation.setDecision(decision, rowID: rowID, in: &plan)
        importPlan = plan
    }

    func setImportDecisionForAllDuplicates(_ decision: GPXImportDecision) {
        guard var plan = importPlan else { return }
        plan.setDecisionForAllDuplicates(decision)
        importPlan = plan
    }

    func applyImport() async {
        guard let plan = importPlan else { return }
        do {
            let result: GPXImportResult = try await data.store.applyGPXImport(plan)
            let text: String = GPXImportPresentation.resultText(result)
            importResultText = text
            lastImportSummary = text
            for id in result.insertedRoutes + result.replacedRoutes {
                shownRoutes.insert(id, revision: data.reloadRevision)
            }
            importPlan = nil
        } catch {
            data.errorText = "The import failed: \(error)"
        }
        refreshOverlays()
    }

    func dismissImportResult() {
        importResultText = nil
    }

    /// Exports and offers the file through the share sheet. `nil` = all of a kind, `[]` = none.
    func export(waypoints: [UUID]?, routes: [UUID]?, tracks: [UUID]?, title: String) async {
        guard let url = await data.exportGPX(waypoints: waypoints, routes: routes, tracks: tracks, title: title) else {
            return
        }
        lastExportName = url.lastPathComponent
        exportFile = ExportFile(url: url)
    }

    // MARK: Overlays

    func refreshOverlays() {
        let position: Coordinate? = currentPosition()
        var routeIDs: Set<UUID> = shownRouteIDs
        if let active = guidance.session.activeRouteID { routeIDs.insert(active) }
        var displays: [RouteDisplay] = []
        for route in data.routes where routeIDs.contains(route.id) && route.id != routeDraft?.route.id {
            displays.append(RouteDisplay(route: route))
        }
        if let draft = routeDraft {
            displays.append(RouteDisplay(route: draft.route))
        }
        var lines: [TrackLine] = []
        for track in data.tracks where shownTrackIDs.contains(track.id) && track.id != recording.snapshot.trackID {
            if let segments = trackGeometry[track.id] {
                lines.append(TrackLine(id: track.id, color: track.color, segments: segments, isLive: false))
            }
        }
        if recording.isActive, let id = recording.snapshot.trackID {
            lines.append(TrackLine(id: id, segments: recording.snapshot.segments, isLive: true))
        }
        let next = MapOverlays.make(waypoints: data.waypoints, selectedWaypoint: selectedWaypointID,
                                    targetWaypoint: guidance.session.directToTarget?.waypointID,
                                    routes: displays, activeRouteID: guidance.session.activeRouteID,
                                    nextPointIndex: guidance.session.activeRoutePointIndex,
                                    editingRouteID: routeDraft?.route.id, tracks: lines,
                                    directLine: guidance.session.directToLine(from: position),
                                    planned: plannedLayer)
        if next != overlays {
            overlays = next
        }
    }

    // MARK: Status for the UI tests

    /// One line of `key=value` pairs read by the UI tests through the debug-only `app.status` element.
    var statusValue: String {
        var parts: [String] = []
        parts.append("waypoints=\(data.waypoints.count)")
        parts.append("routes=\(data.routes.count)")
        parts.append("tracks=\(data.tracks.count)")
        parts.append("recording=\(recording.stateName)")
        parts.append("trackPoints=\(recording.snapshot.pointCount)")
        parts.append("trackStored=\(recording.snapshot.storedPointCount)")
        parts.append("nav=\(guidance.modeName)")
        parts.append("navTarget=\(guidance.guidance?.targetName ?? "none")")
        parts.append("navAdvances=\(guidance.advanceCount)")
        parts.append("navArrivals=\(guidance.arrivalCount)")
        parts.append("editPoints=\(routeDraft?.route.points.count ?? -1)")
        parts.append("selected=\(data.waypoint(selectedWaypointID)?.name ?? "none")")
        parts.append("shownRoutes=\(shownRouteIDs.count)")
        parts.append("shownTracks=\(shownTrackIDs.count)")
        parts.append("speedUnit=\(data.settings.speedUnit.rawValue)")
        parts.append("lastExport=\(lastExportName)")
        parts.append("lastImport=\(lastImportSummary)")
        return parts.joined(separator: "; ")
    }
}
