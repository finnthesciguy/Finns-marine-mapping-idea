import AppServices
import NavCore
import Persistence
import SwiftUI

/// Bearing, distance, cross-track error, time to go and ETA while going to a waypoint or following a route.
struct GuidancePanel: View {
    let guidance: GuidanceModel
    let units: UnitPreferences

    var body: some View {
        let g: NavigationGuidance? = guidance.guidance
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: g?.arrived == true ? "flag.checkered" : "scope")
                    .accessibilityHidden(true)
                Text(g?.targetName ?? "Waiting for a position…")
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("guidance.target")
                if let g, case .route = g.mode {
                    Text("\(g.targetIndex + 1)/\(g.pointCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("guidance.progress")
                }
                Spacer()
                if case .route = guidance.session.state {
                    Button("Skip") { guidance.skipToNext() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("guidance.skip")
                }
                Button("Stop", role: .destructive) { guidance.stop() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("guidance.stop")
            }
            HStack(spacing: 0) {
                value("BRG", NavFormat.bearing(g?.bearingToTarget), "guidance.bearing")
                value("DTW", NavFormat.distance(g?.distanceToTarget, unit: units.distance), "guidance.distance")
                value("XTE", NavFormat.crossTrack(g?.crossTrackError, unit: units.distance), "guidance.xte")
                value("TTG", NavFormat.duration(g?.timeToGo), "guidance.ttg")
                value("ETA", NavFormat.clockTime(g?.eta), "guidance.eta")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guidance.panel")
    }

    private func value(_ title: String, _ text: String, _ identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            Text(text)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The waypoint selected on the map.
struct WaypointCard: View {
    let waypoint: Waypoint
    let boat: Coordinate?
    let units: UnitPreferences
    let onGoTo: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        let row: WaypointRow? = WaypointRow.rows([waypoint], from: boat, units: units).first
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: WaypointSymbols.systemImage(for: waypoint.symbol))
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.name)
                    .font(.headline)
                    .accessibilityIdentifier("selection.name")
                Text((row?.distanceText ?? "—") + "  " + (row?.bearingText ?? "—"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("selection.rangeBearing")
            }
            Spacer()
            Button("Go to", action: onGoTo)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("selection.goTo")
            Button("Edit", action: onEdit)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("selection.edit")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("selection.close")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shown while a route is being created or edited on the map.
struct RouteEditBar: View {
    let draft: RouteDraft
    let plotter: PlotterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.isNew ? "New route: tap the map to add points" : "Editing \(draft.route.name): tap the map to add points")
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("\(draft.route.points.count) points, "
                     + NavFormat.distance(draft.route.length.meters, unit: plotter.data.settings.distanceUnit))
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("routeEdit.count")
                Spacer()
                Button("Undo") { plotter.undoLastDraftPoint() }
                    .buttonStyle(.bordered)
                    .disabled(draft.route.points.isEmpty)
                    .accessibilityIdentifier("routeEdit.undo")
                Button("Cancel", role: .cancel) { plotter.cancelDraft() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("routeEdit.cancel")
                Button("Save") {
                    Task { await plotter.saveDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.route.points.count < 2)
                .accessibilityIdentifier("routeEdit.save")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
