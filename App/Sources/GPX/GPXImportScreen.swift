import AppServices
import Persistence
import SwiftUI

/// What a GPX file contains, which items are already saved (duplicates) and what to do with each, before
/// anything is written (Persistence's import plan).
struct GPXImportScreen: View {
    let plotter: PlotterModel

    var body: some View {
        NavigationStack {
            if let plan = plotter.importPlan {
                content(plan)
            } else {
                Text("Nothing to import.")
            }
        }
    }

    @ViewBuilder
    private func content(_ plan: GPXImportPlan) -> some View {
        let rows: [GPXImportRow] = GPXImportPresentation.rows(plan, units: plotter.data.settings.units)
        List {
            Section {
                Text(GPXImportPresentation.summary(plan))
                    .accessibilityIdentifier("gpx.summary")
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { item in
                    Label(item.element, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }
            if plan.duplicateCount > 0 {
                Section("Items already saved") {
                    HStack {
                        Button("Skip all") { plotter.setImportDecisionForAllDuplicates(.skip) }
                            .accessibilityIdentifier("gpx.skipAll")
                        Spacer()
                        Button("Replace all") { plotter.setImportDecisionForAllDuplicates(.replaceExisting) }
                            .accessibilityIdentifier("gpx.replaceAll")
                        Spacer()
                        Button("Import as new") { plotter.setImportDecisionForAllDuplicates(.importNew) }
                            .accessibilityIdentifier("gpx.importAllNew")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section("Contents") {
                ForEach(rows) { row in
                    GPXImportRowView(row: row,
                                     onDecision: { decision in plotter.setImportDecision(decision, rowID: row.id) })
                }
            }
        }
        .navigationTitle("Import GPX")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { plotter.importPlan = nil }
                    .accessibilityIdentifier("gpx.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    Task { await plotter.applyImport() }
                }
                .accessibilityIdentifier("gpx.import")
            }
        }
    }
}

struct GPXImportRowView: View {
    let row: GPXImportRow
    let onDecision: (GPXImportDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(row.name)
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Import as new") { onDecision(.importNew) }
                    Button("Skip") { onDecision(.skip) }
                    if row.canReplace {
                        Button("Replace saved copy") { onDecision(.replaceExisting) }
                    }
                } label: {
                    Text(decisionText)
                        .font(.caption.weight(.semibold))
                }
                .accessibilityIdentifier("gpx.decision.\(row.id)")
            }
            Text(row.detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
            if let duplicate = row.duplicateText {
                Text(duplicate)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .accessibilityIdentifier("gpx.duplicate.\(row.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gpx.row.\(row.id)")
    }

    private var symbol: String {
        switch row.kind {
        case .waypoint: return "mappin"
        case .route: return "point.topleft.down.to.point.bottomright.curvepath"
        case .track: return "scribble.variable"
        }
    }

    private var decisionText: String {
        switch row.decision {
        case .importNew: return "Import"
        case .skip: return "Skip"
        case .replaceExisting: return "Replace"
        }
    }
}
