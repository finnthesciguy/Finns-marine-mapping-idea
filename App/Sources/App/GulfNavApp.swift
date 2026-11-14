import SwiftUI

@main
struct GulfNavApp: App {
    @State private var model: AppModel = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
