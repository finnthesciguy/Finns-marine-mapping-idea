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
                .frame(minWidth: MacWindow.contentMinimum.width, minHeight: MacWindow.contentMinimum.height)
                .onAppear {
                    MacWindow.configure()
                }
                .task {
                    // Again after the first layout, in case the scene was not connected or sized yet.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    MacWindow.configure()
                }
        }
        .defaultSize(width: MacWindow.defaultSize.width, height: MacWindow.defaultSize.height)
        .windowResizability(.contentMinSize)
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
