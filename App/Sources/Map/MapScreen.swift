import AppServices
import ChartKit
import NavCore
import Persistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The sheets the map screen presents (one at a time).
enum MapSheet: String, Identifiable {
    case charts, waypoints, routes, tracks, settings, autoRoute
    var id: String { rawValue }
}

/// The main screen: chart map with waypoints, routes and tracks, chart-age badge, instrument strip,
/// navigation guidance, map controls and the entry points to the other screens.
struct MapScreen: View {
    let model: AppModel
    @State private var sheet: MapSheet?
    @State private var showingImporter: Bool = false
    @State private var editingWaypoint: Waypoint?
    /// Mac: zoom commands for the chart, and the chart centre (where "Drop Waypoint" puts one without a position).
    @State private var cameraCommand: MapCameraCommand?
    @State private var mapCenter: Coordinate?
    @State private var dropTargeted: Bool = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let map: ChartMapModel = model.map
        let navigation: NavigationModel = model.navigation
        let plotter: PlotterModel = model.plotter
        let units: UnitPreferences = plotter.data.settings.units
        ZStack {
            ChartMapView(plan: map.plan,
                         planRevision: map.planRevision,
                         readout: navigation.readout,
                         follow: map.follow,
                         orientation: map.orientation,
                         onUserPannedMap: { map.follow = false },
                         onPlanApplied: { revision in map.planApplied(revision: revision) },
                         overlays: plotter.overlays,
                         tapTargets: plotter.data.waypoints.map { MapTapTarget(id: $0.id, coordinate: $0.coordinate) },
                         onTap: { coordinate, hit in
                             if model.autoRoute.picking != nil {
                                 model.autoRoute.picked(coordinate)
                                 sheet = .autoRoute
                                 return
                             }
                             plotter.mapTapped(at: coordinate, waypoint: hit)
                         },
                         onLongPress: { coordinate in
                             Task { await plotter.mapLongPressed(at: coordinate) }
                         },
                         onCameraChanged: { zoom, latitude in plotter.mapCameraChanged(zoom: zoom, latitude: latitude) },
                         focus: map.focus,
                         focusRevision: map.focusRevision,
                         onPointAction: { action, coordinate in
                             Task { await perform(action, at: coordinate) }
                         },
                         cameraCommand: cameraCommand,
                         onCenterChanged: { center in mapCenter = center })
                .ignoresSafeArea()

            VStack(spacing: 8) {
                topBar(map: map)
                banners(navigation: navigation, plotter: plotter)
                Spacer()
                if let draft = plotter.routeDraft {
                    RouteEditBar(draft: draft, plotter: plotter)
                } else if let selected = plotter.data.waypoint(plotter.selectedWaypointID) {
                    WaypointCard(waypoint: selected, boat: navigation.readout.lastFix?.coordinate, units: units,
                                 onGoTo: { plotter.goTo(selected) },
                                 onEdit: { editingWaypoint = selected },
                                 onClose: { plotter.select(nil) })
                }
                HStack(alignment: .bottom) {
                    screenButtons(plotter: plotter)
                    Spacer()
                    mapControls(map: map, plotter: plotter)
                }
                if plotter.guidance.isActive {
                    GuidancePanel(guidance: plotter.guidance, units: units)
                }
                #if targetEnvironment(macCatalyst)
                // A Mac usually has no GPS: show "no position" rather than a stale fix (re-evaluated every 5 s).
                TimelineView(.periodic(from: Date(), by: 5)) { context in
                    InstrumentStrip(readout: navigation.readout, speedUnit: units.speed,
                                    positionState: PositionStatus.state(lastFix: navigation.readout.lastFix,
                                                                        authorization: navigation.authorization,
                                                                        now: context.date))
                }
                #else
                InstrumentStrip(readout: navigation.readout, speedUnit: units.speed)
                #endif
                Text("Chart data: NOAA. Not for navigation.")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            VStack {
                HStack {
                    StatusProbe(identifier: "app.status",
                                value: model.autoRoute.statusValue + "; " + model.profiles.statusValue + "; " + plotter.statusValue)
                        .frame(width: 2, height: 2)
                    #if targetEnvironment(macCatalyst)
                    // Debug probe for the UI tests: the window and screen size as macOS reports them.
                    GeometryReader { geometry in
                        StatusProbe(identifier: "mac.window",
                                    value: "content=\(Int(geometry.size.width))x\(Int(geometry.size.height)); " + MacWindow.describe())
                    }
                    .frame(width: 2, height: 2)
                    #endif
                    Spacer()
                }
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .sheet(item: $sheet) { which in
            sheetContent(which)
        }
        .sheet(item: $editingWaypoint) { waypoint in
            WaypointEditor(original: waypoint, plotter: plotter, boat: navigation.readout.lastFix?.coordinate,
                           onClose: { editingWaypoint = nil })
        }
        .sheet(isPresented: importShown) {
            GPXImportScreen(plotter: plotter)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: GPXDocumentTypes.allowed,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await plotter.planImport(fileAt: url) }
                }
            case .failure(let error):
                plotter.data.errorText = "The file could not be opened: \(error.localizedDescription)"
            }
        }
        .onChange(of: model.pendingOpenURL) { _, url in
            guard let url else { return }
            model.pendingOpenURL = nil
            // Close whatever is open first so the import sheet can be presented.
            sheet = nil
            editingWaypoint = nil
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await plotter.planImport(fileAt: url)
            }
        }
        .onChange(of: model.commandRequest) { _, request in
            guard let request else { return }
            perform(request.command)
        }
        .modifier(MacMapScreenSupport(plotter: plotter, dropTargeted: $dropTargeted))
        .onChange(of: model.plotter.routeDraft != nil) { _, editing in
            // While points are being tapped in, the chart must not move under the finger with every fix.
            if editing { model.map.follow = false }
        }
        .onAppear {
            #if targetEnvironment(macCatalyst)
            MacWindow.configure()
            #endif
            KeepScreenOn.set(model.plotter.data.settings.keepScreenOn)
        }
        .onChange(of: plotter.data.settings.keepScreenOn) { _, keepOn in
            KeepScreenOn.set(keepOn)
        }
    }

    // MARK: Commands (Mac menu bar) and chart context menu

    /// Carries out a menu-bar command the same way the matching button does.
    private func perform(_ command: AppCommand) {
        let plotter: PlotterModel = model.plotter
        switch command {
        case .dropWaypoint:
            Task {
                if PlatformText.isMac && model.navigation.readout.lastFix == nil {
                    // No position (usual on a Mac): drop it at the centre of the chart instead. Before the chart
                    // has reported a centre it is still at its start position over Tampa Bay.
                    let center: Coordinate = mapCenter ?? Coordinate(latitude: 27.62, longitude: -82.70)
                    await perform(.dropWaypoint, at: center)
                } else {
                    await plotter.dropWaypointAtBoat()
                }
            }
        case .newRoute:
            sheet = nil
            model.map.follow = false
            plotter.beginNewRoute()
        case .autoRoute:
            sheet = .autoRoute
        case .toggleRecording:
            Task { await plotter.toggleRecording() }
        case .importGPX:
            sheet = nil
            showingImporter = true
        case .exportAll:
            sheet = nil
            Task { await plotter.export(waypoints: nil, routes: nil, tracks: nil, title: "All") }
        case .showCharts:
            sheet = .charts
        case .showWaypoints:
            sheet = .waypoints
        case .showRoutes:
            sheet = .routes
        case .showTracks:
            sheet = .tracks
        case .showSettings:
            sheet = .settings
        case .zoomIn:
            cameraCommand = MapCameraCommand(kind: .zoomIn, revision: (cameraCommand?.revision ?? 0) + 1)
        case .zoomOut:
            cameraCommand = MapCameraCommand(kind: .zoomOut, revision: (cameraCommand?.revision ?? 0) + 1)
        case .northUp:
            model.map.orientation = .northUp
        case .toggleOrientation:
            model.map.toggleOrientation()
        case .toggleFollow:
            model.map.follow.toggle()
        #if DEBUG
        case .toggleSimulatedGPS:
            model.navigation.setSimulating(!model.navigation.isSimulating)
        case .importSampleGPX:
            Task { await plotter.planImport(data: Data(GPXSamples.tampaBay.utf8)) }
        #endif
        }
    }

    /// A chart context-menu item (Mac: right-click or control-click on the chart).
    private func perform(_ action: MapPointAction, at coordinate: Coordinate) async {
        let plotter: PlotterModel = model.plotter
        switch action {
        case .dropWaypoint:
            if let created = await plotter.data.addWaypoint(at: coordinate) {
                plotter.select(created.id)
            }
        case .goTo:
            if let created = await plotter.data.addWaypoint(at: coordinate) {
                plotter.select(created.id)
                plotter.goTo(created)
            }
        case .routeFrom:
            model.autoRoute.choose(.chartPoint(coordinate), for: .start)
            sheet = .autoRoute
        case .routeTo:
            model.autoRoute.choose(.chartPoint(coordinate), for: .goal)
            sheet = .autoRoute
        }
    }

    private var importShown: Binding<Bool> {
        Binding(get: { model.plotter.importPlan != nil },
                set: { shown in
                    if !shown { model.plotter.importPlan = nil }
                })
    }

    @ViewBuilder
    private func sheetContent(_ which: MapSheet) -> some View {
        let plotter: PlotterModel = model.plotter
        let boat: Coordinate? = model.navigation.readout.lastFix?.coordinate
        switch which {
        case .charts:
            ChartsScreen(model: model.charts)
        case .waypoints:
            WaypointsScreen(plotter: plotter, boat: boat, onCloseAll: { sheet = nil })
        case .routes:
            RoutesScreen(plotter: plotter, onCloseAll: { sheet = nil }, onAutoRoute: {
                sheet = nil
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    sheet = .autoRoute
                }
            })
        case .tracks:
            TracksScreen(plotter: plotter, onCloseAll: { sheet = nil })
        case .settings:
            SettingsScreen(plotter: plotter, profiles: model.profiles, installed: model.charts.installedRegions)
        case .autoRoute:
            AutoRouteScreen(model: model.autoRoute, units: plotter.data.settings.units, onClose: {
                sheet = nil
                if model.autoRoute.picking != nil { model.map.follow = false }
            })
        }
    }

    @ViewBuilder
    private func banners(navigation: NavigationModel, plotter: PlotterModel) -> some View {
        ForEach(model.notices) { notice in
            Button {
                model.dismissNotice(notice)
            } label: {
                Banner(text: notice.message, systemImage: NoticeStyle.symbol(for: notice.kind))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notice.\(notice.kind.rawValue)")
            .accessibilityHint("Dismisses this message")
        }
        if let error = plotter.data.errorText {
            Button {
                plotter.data.errorText = nil
            } label: {
                Banner(text: error, systemImage: "exclamationmark.circle")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("banner.error")
        }
        if let error = plotter.recording.errorText {
            Button {
                plotter.recording.errorText = nil
            } label: {
                Banner(text: error, systemImage: "record.circle")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("banner.recordingError")
        }
        if let message = plotter.guidance.message {
            Button {
                plotter.guidance.dismissMessage()
            } label: {
                Banner(text: message, systemImage: "flag.checkered")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("guidance.message")
        }
        if let end = model.autoRoute.picking {
            Button {
                model.autoRoute.picking = nil
                sheet = .autoRoute
            } label: {
                Banner(text: "\(PlatformText.tap) the chart to set the \(end == .start ? "start" : "destination"). \(PlatformText.tap) here to cancel.",
                       systemImage: "hand.tap")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("autoroute.pickBanner")
        }
        if model.autoRoute.outcome?.proposal != nil && sheet == nil {
            Button {
                sheet = .autoRoute
            } label: {
                Banner(text: "Planned route not saved yet. \(PlatformText.tap) to review, save or discard it.",
                       systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("autoroute.pendingBanner")
        }
        if let result = plotter.importResultText {
            Button {
                plotter.dismissImportResult()
            } label: {
                Banner(text: result, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gpx.result")
        }
        if !navigation.authorization.allowsUpdates && navigation.authorization != .notDetermined {
            Button {
                if let url = URL(string: PlatformText.locationSettingsURL) {
                    openURL(url)
                }
            } label: {
                Banner(text: PlatformText.locationOff, systemImage: "location.slash")
            }
            .buttonStyle(.plain)
        }
        if !model.map.hasCharts {
            Button {
                sheet = .charts
            } label: {
                Banner(text: "No charts installed. \(PlatformText.tap) to download a region.", systemImage: "map")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.noChartsBanner")
        }
    }

    @ViewBuilder
    private func topBar(map: ChartMapModel) -> some View {
        HStack {
            if let badge = map.badge {
                ChartAgeBadgeView(badge: badge)
                    .accessibilityIdentifier("map.chartAgeBadge")
            }
            Spacer()
            #if DEBUG
            DebugMenu(navigation: model.navigation, plotter: model.plotter)
            #endif
            Button {
                sheet = .charts
            } label: {
                Label("Charts", systemImage: "square.stack.3d.up")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .accessibilityIdentifier("map.chartsButton")
        }
    }

    /// Entry points to the other screens (bottom left).
    @ViewBuilder
    private func screenButtons(plotter: PlotterModel) -> some View {
        VStack(spacing: 10) {
            RoundButton(systemImage: "mappin.and.ellipse", label: "Waypoints", identifier: "map.waypointsButton") {
                sheet = .waypoints
            }
            RoundButton(systemImage: "point.topleft.down.to.point.bottomright.curvepath", label: "Routes",
                        identifier: "map.routesButton") {
                sheet = .routes
            }
            RoundButton(systemImage: "wand.and.stars", label: "Auto-route", identifier: "map.autoRouteButton") {
                sheet = .autoRoute
            }
            RoundButton(systemImage: "scribble.variable", label: "Tracks", identifier: "map.tracksButton") {
                sheet = .tracks
            }
            RoundButton(systemImage: "square.and.arrow.down", label: "Import GPX", identifier: "map.importButton") {
                showingImporter = true
            }
            RoundButton(systemImage: "gearshape", label: "Settings", identifier: "map.settingsButton") {
                sheet = .settings
            }
        }
    }

    @ViewBuilder
    private func mapControls(map: ChartMapModel, plotter: PlotterModel) -> some View {
        VStack(spacing: 10) {
            RoundButton(systemImage: plotter.recording.isActive ? "stop.circle.fill" : "record.circle",
                        label: plotter.recording.isActive ? "Stop recording" : "Record track",
                        identifier: "map.recordButton",
                        tint: plotter.recording.isActive ? Color.red : nil) {
                Task { await plotter.toggleRecording() }
            }
            RoundButton(systemImage: "mappin.circle", label: "Drop waypoint at boat", identifier: "map.dropWaypoint") {
                Task { await plotter.dropWaypointAtBoat() }
            }
            RoundButton(systemImage: map.orientation == .northUp ? "location.north.line" : "arrow.up.circle",
                        label: map.orientation.label, identifier: "map.orientationButton") {
                map.toggleOrientation()
            }
            RoundButton(systemImage: map.follow ? "location.fill" : "location",
                        label: map.follow ? "Following position" : "Follow position", identifier: "map.followButton") {
                map.follow.toggle()
            }
        }
    }
}

/// A 44-point circular map button with an accessibility label and identifier.
struct RoundButton: View {
    let systemImage: String
    let label: String
    let identifier: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint ?? Color.accentColor)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// File types offered by the GPX document picker.
enum GPXDocumentTypes {
    static var allowed: [UTType] {
        var types: [UTType] = []
        if let gpx = UTType(GPXFiles.typeIdentifier) { types.append(gpx) }
        if let byExtension = UTType(filenameExtension: GPXFiles.fileExtension), !types.contains(byExtension) {
            types.append(byExtension)
        }
        types.append(UTType.xml)
        return types
    }
}

/// SOG, COG and position.
struct InstrumentStrip: View {
    let readout: NavigationReadout
    let speedUnit: SpeedUnit
    /// Mac: whether there is a current position (nil on iOS, which shows the values as they are).
    var positionState: PositionState? = nil

    var body: some View {
        let showsValues: Bool = positionState.map { PositionStatus.showsValues($0) } ?? true
        let position = InstrumentFormat.position(showsValues ? readout.lastFix?.coordinate : nil)
        let sog: String = showsValues
            ? InstrumentFormat.sog(metersPerSecond: readout.speedOverGround, unit: speedUnit) : InstrumentFormat.placeholder
        let cog: String = showsValues ? InstrumentFormat.cog(degrees: readout.courseOverGround) : InstrumentFormat.placeholder
        VStack(alignment: .leading, spacing: 4) {
            if let state = positionState, let message = PositionStatus.message(state) {
                // The identifier goes on the text: on a Label it reached the symbol image, whose accessibility
                // label is "Location Services Off" (seen on CI).
                HStack(spacing: 6) {
                    Image(systemName: "location.slash")
                        .accessibilityHidden(true)
                    Text(message)
                        .accessibilityIdentifier("instrument.positionStatus")
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 10)
            }
            values(sog: sog, cog: cog, position: position)
        }
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("instrument.strip")
    }

    private func values(sog: String, cog: String, position: (latitude: String, longitude: String)) -> some View {
        HStack(spacing: 0) {
            cell(title: "SOG", value: sog, identifier: "instrument.sog")
            Divider().frame(height: 36)
            cell(title: "COG", value: cog, identifier: "instrument.cog")
            Divider().frame(height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("POSITION")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                Text(position.latitude)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityIdentifier("instrument.latitude")
                Text(position.longitude)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityIdentifier("instrument.longitude")
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cell(title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 90, alignment: .leading)
    }
}

/// Data date of the oldest installed region; orange or red when stale.
struct ChartAgeBadgeView: View {
    let badge: ChartAgeBadge

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(badge.text)
                .lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background, in: Capsule())
    }

    private var symbol: String {
        switch badge.level {
        case .current: return "checkmark.seal"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }

    private var foreground: Color {
        switch badge.level {
        case .current: return Color.primary
        case .warning, .critical: return Color.white
        }
    }

    private var background: Color {
        switch badge.level {
        case .current: return Color(uiColor: .secondarySystemBackground)
        case .warning: return Color.orange
        case .critical: return Color.red
        }
    }
}

enum NoticeStyle {
    static func symbol(for kind: StartupNotice.Kind) -> String {
        switch kind {
        case .dataRecovered: return "exclamationmark.arrow.triangle.2.circlepath"
        case .dataNotSaved: return "externaldrive.badge.xmark"
        case .storageFallback: return "externaldrive.badge.exclamationmark"
        case .recordingInterrupted: return "point.bottomleft.forward.to.point.topright.scurvepath"
        }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

#if DEBUG
/// Debug builds only: replay the Tampa Bay track instead of GPS (for the simulator).
struct DebugMenu: View {
    let navigation: NavigationModel
    let plotter: PlotterModel

    var body: some View {
        Menu {
            Toggle("Simulate GPS (Tampa Bay)", isOn: Binding(get: { navigation.isSimulating },
                                                             set: { navigation.setSimulating($0) }))
            Button("Import sample GPX") {
                Task { await plotter.planImport(data: Data(GPXSamples.tampaBay.utf8)) }
            }
        } label: {
            Image(systemName: navigation.isSimulating ? "ant.fill" : "ant")
                .padding(8)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityIdentifier("map.debugMenu")
    }
}
#endif
