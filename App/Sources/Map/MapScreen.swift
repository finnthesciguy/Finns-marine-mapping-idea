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
                         focusRevision: map.focusRevision)
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
                InstrumentStrip(readout: navigation.readout, speedUnit: units.speed)
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
        .onChange(of: model.plotter.routeDraft != nil) { _, editing in
            // While points are being tapped in, the chart must not move under the finger with every fix.
            if editing { model.map.follow = false }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = model.plotter.data.settings.keepScreenOn
        }
        .onChange(of: plotter.data.settings.keepScreenOn) { _, keepOn in
            UIApplication.shared.isIdleTimerDisabled = keepOn
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
                Banner(text: "Tap the chart to set the \(end == .start ? "start" : "destination"). Tap here to cancel.",
                       systemImage: "hand.tap")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("autoroute.pickBanner")
        }
        if model.autoRoute.outcome?.proposal != nil && sheet == nil {
            Button {
                sheet = .autoRoute
            } label: {
                Banner(text: "Planned route not saved yet. Tap to review, save or discard it.",
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
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Banner(text: "Location access is off. Tap to open Settings.", systemImage: "location.slash")
            }
            .buttonStyle(.plain)
        }
        if !model.map.hasCharts {
            Button {
                sheet = .charts
            } label: {
                Banner(text: "No charts installed. Tap to download a region.", systemImage: "map")
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

    var body: some View {
        let position = InstrumentFormat.position(readout.lastFix?.coordinate)
        HStack(spacing: 0) {
            cell(title: "SOG", value: InstrumentFormat.sog(metersPerSecond: readout.speedOverGround, unit: speedUnit),
                 identifier: "instrument.sog")
            Divider().frame(height: 36)
            cell(title: "COG", value: InstrumentFormat.cog(degrees: readout.courseOverGround),
                 identifier: "instrument.cog")
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
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("instrument.strip")
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
