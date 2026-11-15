#if targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac menu bar: the main actions of the map screen's buttons, with keyboard shortcuts. Each item sends an
/// `AppCommand` that `MapScreen` carries out exactly as the matching button does, so menus, shortcuts and
/// buttons cannot drift apart. (SwiftUI `Commands`, Mac Catalyst 14+.)
///
/// Shortcuts: ⌘N new route, ⇧⌘N plan auto-route, ⌘O import GPX, ⇧⌘E export all, ⌘, settings,
/// ⌘D drop waypoint, ⌘R start/stop recording, ⌘1 charts, ⌘2 waypoints, ⌘3 routes, ⌘4 tracks,
/// ⌘= zoom in, ⌘- zoom out, ⌘U north up, ⇧⌘U north up / course up, ⌘L follow the boat.
struct MacCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: CommandGroupPlacement.newItem) {
            Button("New Route on Chart") { model.send(.newRoute) }
                .keyboardShortcut("n", modifiers: [.command])
            Button("Plan Auto-Route…") { model.send(.autoRoute) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import GPX…") { model.send(.importGPX) }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Export All as GPX…") { model.send(.exportAll) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: CommandGroupPlacement.appSettings) {
            Button("Settings…") { model.send(.showSettings) }
                .keyboardShortcut(",", modifiers: [.command])
        }
        CommandMenu("Navigation") {
            Button("Drop Waypoint") { model.send(.dropWaypoint) }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Start or Stop Recording") { model.send(.toggleRecording) }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Button("Charts…") { model.send(.showCharts) }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Waypoints…") { model.send(.showWaypoints) }
                .keyboardShortcut("2", modifiers: [.command])
            Button("Routes…") { model.send(.showRoutes) }
                .keyboardShortcut("3", modifiers: [.command])
            Button("Tracks…") { model.send(.showTracks) }
                .keyboardShortcut("4", modifiers: [.command])
        }
        CommandMenu("Chart") {
            Button("Zoom In") { model.send(.zoomIn) }
                .keyboardShortcut("=", modifiers: [.command])
            Button("Zoom Out") { model.send(.zoomOut) }
                .keyboardShortcut("-", modifiers: [.command])
            Divider()
            Button("North Up") { model.send(.northUp) }
                .keyboardShortcut("u", modifiers: [.command])
            Button("Switch North Up / Course Up") { model.send(.toggleOrientation) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Follow the Boat") { model.send(.toggleFollow) }
                .keyboardShortcut("l", modifiers: [.command])
        }
        #if DEBUG
        CommandMenu("Debug") {
            Button("Simulate GPS (Tampa Bay) On or Off") { model.send(.toggleSimulatedGPS) }
            Button("Import Sample GPX") { model.send(.importSampleGPX) }
        }
        #endif
    }
}
#endif
