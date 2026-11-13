import AppServices
import ChartKit
import SwiftUI
import UniformTypeIdentifiers

/// Chart regions: size and data date, confirm-before-download (with the size), progress, cancel, resume,
/// delete and free space.
struct ChartsScreen: View {
    let model: ChartsModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickingPack: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.manifestError {
                    Section {
                        Text(error).foregroundStyle(Color.red)
                    }
                }
                Section {
                    ForEach(model.rows) { row in
                        RegionRowView(row: row, routingPack: model.routingCatalog.entry(forChartRegion: row.id),
                                      onPrimary: { model.primaryAction(for: row) },
                                      onDelete: { model.askToDelete(row) })
                    }
                } header: {
                    Text("Gulf Coast regions")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let free = model.freeBytes {
                            Text("Free space on this device: \(ByteFormat.string(free))")
                        }
                        Text("Charts are NOAA's offline packages, provided as-is. Each region shows the date of its chart data.")
                    }
                }
                RoutingPacksSection(model: model, onPick: { pickingPack = true })
            }
            .navigationTitle("Charts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("charts.done")
                }
            }
            .fileImporter(isPresented: $pickingPack, allowedContentTypes: [UTType.data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await model.sideLoadRoutingPack(from: url) }
                }
            }
            .refreshable {
                await model.refresh()
            }
            .task {
                await model.refresh()
            }
            .alert(model.pendingDownload?.confirmation.title ?? "Download",
                   isPresented: downloadAlertShown,
                   presenting: model.pendingDownload) { pending in
                if pending.confirmation.canProceed {
                    Button("Download") { model.confirmPendingDownload() }
                }
                Button("Cancel", role: .cancel) { model.pendingDownload = nil }
            } message: { pending in
                Text(pending.confirmation.message)
            }
            .confirmationDialog("Delete \(model.pendingDeletion?.title ?? "region")?",
                                isPresented: deleteDialogShown,
                                titleVisibility: .visible,
                                presenting: model.pendingDeletion) { _ in
                Button("Delete", role: .destructive) { model.confirmPendingDeletion() }
                Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
            } message: { row in
                Text("This removes \(ByteFormat.string(max(row.installed?.totalBytes ?? 0, row.partialBytes))) from this device. You can download it again later.")
            }
        }
    }

    private var downloadAlertShown: Binding<Bool> {
        Binding(get: { model.pendingDownload != nil },
                set: { shown in
                    if !shown { model.pendingDownload = nil }
                })
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { model.pendingDeletion != nil },
                set: { shown in
                    if !shown { model.pendingDeletion = nil }
                })
    }
}

/// Routing packs on the device: presence, data date and size, plus (debug builds) installing a pack file.
struct RoutingPacksSection: View {
    let model: ChartsModel
    let onPick: () -> Void

    static func detail(_ entry: RoutingPackEntry) -> String {
        var date: String = "unknown"
        if let d = entry.dataDate { date = DataDateFormat.string(d) }
        return "Chart data \(date) · \(ByteFormat.string(entry.byteSize)) · format \(entry.formatVersion)"
    }

    var body: some View {
        Section {
            if model.routingCatalog.entries.isEmpty {
                Text("No routing packs installed.")
                    .foregroundStyle(Color.secondary)
            }
            ForEach(model.routingCatalog.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(RoutingPacksSection.detail(entry))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("routingPack.detail.\(entry.packRegionID)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("routingPack.row.\(entry.packRegionID)")
                .swipeActions {
                    if entry.origin == .sideLoaded {
                        Button(role: .destructive) {
                            Task { await model.removeSideLoaded(entry) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            ForEach(model.routingCatalog.problems, id: \.id) { problem in
                Text("\(problem.title): \(problem.message)")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
            #if DEBUG
            Button("Install a routing pack file…", action: onPick)
                .accessibilityIdentifier("charts.sideLoadPack")
            #endif
            if let message = model.sideLoadMessage {
                Text(message)
                    .font(.caption)
                    .accessibilityIdentifier("charts.sideLoadMessage")
            }
        } header: {
            Text("Routing packs")
        } footer: {
            Text("Auto-routing uses the routing pack of the region. Packs will download with their chart region once they are published.")
        }
    }
}

struct RegionRowView: View {
    let row: RegionRow
    /// The routing pack installed with this region, if any.
    var routingPack: RoutingPackEntry? = nil
    let onPrimary: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.headline)
                    .accessibilityIdentifier("region.title.\(row.id)")
                Spacer()
                primaryButton
            }
            if let summary = row.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 12) {
                Label(ByteFormat.string(row.downloadBytes), systemImage: "arrow.down.circle")
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .accessibilityHidden(true)
                    Text("Data \(DataDateFormat.string(row.dataDate))")
                        .accessibilityIdentifier("region.dataDate.\(row.id)")
                }
                if let age = row.age, age.level != .current {
                    Label("\(age.days) days old", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(age.level == .critical ? Color.red : Color.orange)
                }
            }
            .font(.caption)
            Text(routingPackText)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier("region.routingPack.\(row.id)")
            if let fraction = row.progressFraction {
                ProgressView(value: fraction)
            } else if row.isBusy {
                ProgressView()
            }
            HStack {
                Text(row.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("region.status.\(row.id)")
                Spacer()
                if row.canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let message = row.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var routingPackText: String {
        guard let pack = routingPack else { return "No routing pack for this region yet" }
        var date: String = "unknown"
        if let d = pack.dataDate { date = DataDateFormat.string(d) }
        return "Routing pack: data \(date), \(ByteFormat.string(pack.byteSize))"
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch row.primaryAction {
        case .download:
            Button("Download", action: onPrimary).buttonStyle(.borderedProminent)
        case .resume:
            Button("Resume", action: onPrimary).buttonStyle(.borderedProminent)
        case .update:
            Button("Update", action: onPrimary).buttonStyle(.borderedProminent)
        case .cancel:
            Button("Cancel", role: .cancel, action: onPrimary).buttonStyle(.bordered)
        case .none:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        }
    }
}
