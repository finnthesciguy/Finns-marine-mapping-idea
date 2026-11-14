import AppServices
import NavCore
import Persistence
import SwiftUI

/// Recording controls and saved tracks with distance, duration and average speed; show on the chart,
/// rename, export, delete.
struct TracksScreen: View {
    let plotter: PlotterModel
    let onCloseAll: () -> Void
    @State private var renaming: Track?
    @State private var newName: String = ""

    var body: some View {
        let units: UnitPreferences = plotter.data.settings.units
        let rows: [TrackRow] = TrackRow.rows(plotter.data.tracks, units: units)
        let snapshot: TrackRecorder.Snapshot = plotter.recording.snapshot
        NavigationStack {
            List {
                Section {
                    if snapshot.state == .idle {
                        Button {
                            Task { await plotter.toggleRecording() }
                        } label: {
                            Label("Start recording", systemImage: "record.circle")
                        }
                        .accessibilityIdentifier("tracks.start")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.name ?? "Recording")
                                .font(.headline)
                            Text("\(snapshot.pointCount) points, "
                                 + NavFormat.distance(snapshot.distance, unit: units.distance)
                                 + (snapshot.state == .paused ? " (paused)" : ""))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.secondary)
                                .accessibilityIdentifier("tracks.recordingStatus")
                        }
                        HStack {
                            if snapshot.state == .paused {
                                Button("Resume") { Task { await plotter.recording.resume() } }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("tracks.resume")
                            } else {
                                Button("Pause") { Task { await plotter.recording.pause() } }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("tracks.pause")
                            }
                            Spacer()
                            Button("Stop", role: .destructive) { Task { await plotter.toggleRecording() } }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("tracks.stop")
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Recording continues with the screen locked or another app in front, using GPS in the background: this uses noticeably more battery. Stop recording when you are done.")
                }
                Section("Saved tracks") {
                    if rows.isEmpty {
                        Text("No tracks yet.")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { item in
                        let row: TrackRow = item.element
                        TrackRowView(row: row, index: item.offset,
                                     shown: Binding(get: { plotter.shownTrackIDs.contains(row.id) },
                                                    set: { plotter.setTrackShown(row.id, $0) }))
                            .swipeActions {
                                if !row.isRecording {
                                    Button(role: .destructive) {
                                        Task { await plotter.data.deleteTrack(row.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                Button {
                                    Task { await plotter.export(waypoints: [], routes: [], tracks: [row.id], title: row.name) }
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                                .tint(Color.blue)
                            }
                            .contextMenu {
                                Button("Rename") {
                                    renaming = plotter.data.track(row.id)
                                    newName = row.name
                                }
                                Button("Export as GPX") {
                                    Task { await plotter.export(waypoints: [], routes: [], tracks: [row.id], title: row.name) }
                                }
                                if !row.isRecording {
                                    Button("Delete", role: .destructive) {
                                        Task { await plotter.data.deleteTrack(row.id) }
                                    }
                                }
                            }
                    }
                }
            }
            .navigationTitle("Tracks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onCloseAll)
                        .accessibilityIdentifier("tracks.done")
                }
            }
            .alert("Rename track", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let track = renaming {
                        Task { await plotter.data.renameTrack(track.id, to: newName) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .sheet(item: exportBinding(plotter)) { file in
                ShareSheet(url: file.url)
            }
        }
    }
}

struct TrackRowView: View {
    let row: TrackRow
    let index: Int
    @Binding var shown: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if row.isRecording {
                        Image(systemName: "record.circle")
                            .foregroundStyle(Color.red)
                            .accessibilityLabel("Recording")
                    }
                    Text(row.name)
                        .font(.headline)
                        .accessibilityIdentifier("track.name.\(index)")
                }
                Text(row.date)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                HStack(spacing: 10) {
                    Text(row.distance).accessibilityIdentifier("track.distance.\(index)")
                    Text(row.duration).accessibilityIdentifier("track.duration.\(index)")
                    Text(row.averageSpeed).accessibilityIdentifier("track.speed.\(index)")
                }
                .font(.caption.monospacedDigit())
            }
            Spacer()
            Toggle("Show", isOn: $shown)
                .labelsHidden()
                .accessibilityLabel("Show on the chart")
                .accessibilityIdentifier("track.show.\(index)")
        }
    }
}
