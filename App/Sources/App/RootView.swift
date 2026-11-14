import AppServices
import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

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
        .onOpenURL { url in
            model.open(url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await model.enteredBackground() }
            }
        }
    }
}
