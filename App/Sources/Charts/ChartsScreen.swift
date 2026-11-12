import AppServices
import ChartKit
import SwiftUI

/// Chart regions: size and data date, confirm-before-download (with the size), progress, cancel, resume,
/// delete and free space.
struct ChartsScreen: View {
    let model: ChartsModel
    @Environment(\.dismiss) private var dismiss

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
                        RegionRowView(row: row,
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
            }
            .navigationTitle("Charts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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

struct RegionRowView: View {
    let row: RegionRow
    let onPrimary: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.headline)
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
                Label("Data \(DataDateFormat.string(row.dataDate))", systemImage: "calendar")
                if let age = row.age, age.level != .current {
                    Label("\(age.days) days old", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(age.level == .critical ? Color.red : Color.orange)
                }
            }
            .font(.caption)
            if let fraction = row.progressFraction {
                ProgressView(value: fraction)
            } else if row.isBusy {
                ProgressView()
            }
            HStack {
                Text(row.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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
