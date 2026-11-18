#if targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac menu bar: the main actions of the map screen's buttons, with keyboard shortcuts. Each item sends an
/// `AppCommand` that `MapScreen` carries out exactly as the matching button does, so menus, shortcuts and
/// buttons cannot drift apart. (SwiftUI `Commands`, Mac Catalyst 14+.)
///
/// Shortcuts: ⌘N new route, ⇧⌘N plan auto-route, ⌘O import GPX, ⇧⌘E export all, ⌘, settings,
/// ⌘D drop waypoint, ⌘R start/stop recording, ⌘1 charts, ⌘2 waypoints, ⌘3 routes, ⌘4 tracks,
/// ⌘= zoom in, ⌘- zoom out, ⌘U north up, ⇧⌘U course up (checkmark), ⌘L follow the boat (checkmark).
///
/// Placement: everything is in our own menus (Navigation, GPX, Chart). On CI, items given to
/// `CommandGroup(replacing: .newItem)` never appeared in the File menu and ⌘N did nothing, while the
/// `CommandMenu` items worked; on Mac Catalyst that group appears to live in UIKit's "new scene" menu, which a
/// single-window app does not have. The File menu's own New item is still replaced by nothing, so ⌘N is free.
struct MacCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // Menu items reflect the app's state (Observation tracks what the body reads): titles and checkmarks
        // follow recording, follow mode, orientation and online charts, and everything is disabled until the
        // map screen is showing (disclaimer not yet accepted).
        let ready: Bool = model.phase == .ready
        let recording: Bool = model.plotter.recording.isActive
        let data = model.plotter.data
        let hasData: Bool = !data.waypoints.isEmpty || !data.routes.isEmpty || !data.tracks.isEmpty
        // One window only (UIApplicationSupportsMultipleScenes is false): no New Window item.
        CommandGroup(replacing: CommandGroupPlacement.newItem) {}
        CommandGroup(replacing: CommandGroupPlacement.appSettings) {
            Button("Settings…") { model.send(.showSettings) }
                .keyboardShortcut(",", modifiers: [.command])
                .disabled(!ready)
        }
        CommandMenu("Navigation") {
            Button("New Route on Chart") { model.send(.newRoute) }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!ready || model.plotter.routeDraft != nil)
            Button("Plan Auto-Route…") { model.send(.autoRoute) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!ready)
            Divider()
            Button("Drop Waypoint") { model.send(.dropWaypoint) }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!ready)
            Button(recording ? "Stop Recording" : "Start Recording") { model.send(.toggleRecording) }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!ready)
            Divider()
            Button("Charts…") { model.send(.showCharts) }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(!ready)
            Button("Waypoints…") { model.send(.showWaypoints) }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(!ready)
            Button("Routes…") { model.send(.showRoutes) }
                .keyboardShortcut("3", modifiers: [.command])
                .disabled(!ready)
            Button("Tracks…") { model.send(.showTracks) }
                .keyboardShortcut("4", modifiers: [.command])
                .disabled(!ready)
        }
        CommandMenu("GPX") {
            Button("Import GPX…") { model.send(.importGPX) }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(!ready)
            Button("Export All as GPX…") { model.send(.exportAll) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!ready || !hasData)
        }
        CommandMenu("Chart") {
            Button("Zoom In") { model.send(.zoomIn) }
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(!ready)
            Button("Zoom Out") { model.send(.zoomOut) }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(!ready)
            Divider()
            Button("North Up") { model.send(.northUp) }
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(!ready || model.map.orientation == .northUp)
            Toggle("Course Up", isOn: Binding(get: { model.map.orientation != .northUp },
                                              set: { _ in model.send(.toggleOrientation) }))
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!ready)
            Toggle("Follow the Boat", isOn: Binding(get: { model.map.follow }, set: { _ in model.send(.toggleFollow) }))
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(!ready)
            Divider()
            Toggle("Online NOAA Charts", isOn: Binding(get: { model.map.liveCharts }, set: { on in model.setLiveCharts(on) }))
                .disabled(!ready)
        }
        #if DEBUG
        CommandMenu("Debug") {
            Toggle("Simulate GPS (Tampa Bay)", isOn: Binding(get: { model.navigation.isSimulating },
                                                             set: { _ in model.send(.toggleSimulatedGPS) }))
            Button("Import Sample GPX") { model.send(.importSampleGPX) }
        }
        #endif
    }
}
#endif
