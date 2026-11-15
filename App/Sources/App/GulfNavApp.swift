import SwiftUI

@main
struct GulfNavApp: App {
    @State private var model: AppModel = AppModel.live()

    var body: some Scene {
        #if targetEnvironment(macCatalyst)
        // Mac: a resizable window that opens at a size where the chart has room next to the panels, with a
        // minimum below which the map controls and instrument strip would overlap.
        WindowGroup {
            RootView(model: model)
                .onAppear {
                    MacWindow.applySizeLimits()
                }
        }
        .defaultSize(width: MacWindow.defaultSize.width, height: MacWindow.defaultSize.height)
        .commands {
            MacCommands(model: model)
        }
        #else
        WindowGroup {
            RootView(model: model)
        }
        #endif
    }
}
