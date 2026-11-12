import AppServices
import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                ProgressView("Loading…")
            case .needsDisclaimer:
                DisclaimerView(onAccept: {
                    Task { await model.acceptDisclaimer() }
                })
            case .ready:
                MapScreen(model: model)
            }
        }
        .task {
            await model.start()
        }
    }
}
