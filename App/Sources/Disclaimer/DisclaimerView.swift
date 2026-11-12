import AppServices
import SwiftUI

/// First-launch disclaimer (PLAN.md D5). There is no way past it except accepting.
struct DisclaimerView: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.orange)
                    Text(Disclaimer.title)
                        .font(.title.bold())
                    ForEach(Array(Disclaimer.points.enumerated()), id: \.offset) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .padding(.top, 7)
                            Text(item.element)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
            }
            Divider()
            Button(action: onAccept) {
                Text(Disclaimer.acceptButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(20)
            .frame(maxWidth: 640)
        }
        .interactiveDismissDisabled(true)
    }
}
