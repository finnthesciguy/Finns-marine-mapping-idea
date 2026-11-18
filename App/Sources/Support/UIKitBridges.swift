import SwiftUI
import UIKit

/// Debug builds: an invisible 2×2-point accessibility element whose value the UI tests read (the same
/// technique as the map's `map.status`, which is proven on CI). Release builds draw nothing.
struct StatusProbe: UIViewRepresentable {
    let identifier: String
    let value: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        view.backgroundColor = UIColor.clear
        view.isUserInteractionEnabled = false
        #if DEBUG
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = identifier
        view.accessibilityTraits = UIAccessibilityTraits.staticText
        #else
        view.isAccessibilityElement = false
        #endif
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        #if DEBUG
        view.accessibilityValue = value
        #endif
    }
}

/// The system share sheet for one file (GPX export).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
