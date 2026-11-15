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
                    // Again after the first layouts: a request made while the window is still being set up does not
                    // stick (seen on CI), so ask at 0.5, 1.5 and 3 s (only while the window is below the default size).
                    for delay in [500_000_000, 1_000_000_000, 1_500_000_000] as [UInt64] {
                        try? await Task.sleep(nanoseconds: delay)
                        MacWindow.configure()
                    }
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
