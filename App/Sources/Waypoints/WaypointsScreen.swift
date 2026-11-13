import AppServices
import NavCore
import Persistence
import SwiftUI

/// Waypoints sorted by distance from the boat, with bearing; drop at the boat, edit, delete, export.
struct WaypointsScreen: View {
    let plotter: PlotterModel
    let boat: Coordinate?
    /// Closes this sheet and returns to the map.
    let onCloseAll: () -> Void
    @State private var editing: Waypoint?

    var body: some View {
        let units: UnitPreferences = plotter.data.settings.units
        let rows: [WaypointRow] = WaypointRow.rows(plotter.data.waypoints, from: boat, units: units)
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await plotter.dropWaypointAtBoat() }
                    } label: {
                        Label("Drop waypoint at boat", systemImage: "mappin.circle")
                    }
                    .accessibilityIdentifier("waypoints.dropAtBoat")
                } footer: {
                    Text("You can also long-press the chart to drop a waypoint there.")
                }
                Section {
                    if rows.isEmpty {
                        Text("No waypoints yet.")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(rows) { row in
                        // Not a Button: a button merges its label into one accessibility element, and the
                        // UI tests read the distance and bearing texts individually.
                        WaypointRowView(row: row)
                            .onTapGesture {
                                editing = plotter.data.waypoint(row.id)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("waypoint.row.\(row.name)")
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await plotter.data.deleteWaypoint(row.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(boat == nil ? "Waypoints" : "Waypoints, nearest first")
                }
            }
            .navigationTitle("Waypoints")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onCloseAll)
                        .accessibilityIdentifier("waypoints.done")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await plotter.export(waypoints: nil, routes: nil, tracks: nil, title: "All") }
                    } label: {
                        Label("Export all as GPX", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("waypoints.exportAll")
                }
            }
            .sheet(item: $editing) { waypoint in
                WaypointEditor(original: waypoint, plotter: plotter, boat: boat, onClose: { editing = nil },
                               onLeaveForMap: onCloseAll)
            }
            .sheet(item: exportBinding(plotter)) { file in
                ShareSheet(url: file.url)
            }
        }
    }
}

/// Binding to the plotter's pending export file, for `.sheet(item:)`.
@MainActor
func exportBinding(_ plotter: PlotterModel) -> Binding<PlotterModel.ExportFile?> {
    Binding(get: { plotter.exportFile }, set: { plotter.exportFile = $0 })
}

struct WaypointRowView: View {
    let row: WaypointRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: WaypointSymbols.systemImage(for: row.symbol))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.headline)
                    .accessibilityIdentifier("waypoint.name.\(row.name)")
                Text(row.position)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.distanceText)
                    .font(.callout.monospacedDigit())
                    .accessibilityIdentifier("waypoint.distance.\(row.name)")
                Text(row.bearingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("waypoint.bearing.\(row.name)")
            }
        }
        .contentShape(Rectangle())
    }
}

/// Name, symbol and notes of one waypoint, plus go-to, export and delete.
struct WaypointEditor: View {
    let original: Waypoint
    let plotter: PlotterModel
    let boat: Coordinate?
    let onClose: () -> Void
    /// Close every sheet (after "Go to" or "Show on map").
    var onLeaveForMap: (() -> Void)? = nil

    @State private var name: String = ""
    @State private var symbol: String = "Waypoint"
    @State private var notes: String = ""
    @State private var loaded = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("waypoint.edit.name")
                }
                Section("Symbol") {
                    Picker("Symbol", selection: $symbol) {
                        ForEach(WaypointSymbols.choices) { choice in
                            Label(choice.title, systemImage: choice.systemImage).tag(choice.gpxName)
                        }
                    }
                    .accessibilityIdentifier("waypoint.edit.symbol")
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("waypoint.edit.notes")
                }
                Section("Position") {
                    Text(NavFormat.position(original.coordinate))
                        .font(.callout.monospaced())
                    if let row = WaypointRow.rows([original], from: boat, units: plotter.data.settings.units).first {
                        Text("\(row.distanceText) at \(row.bearingText) from the boat")
                            .foregroundStyle(Color.secondary)
                    }
                }
                Section {
                    Button {
                        Task {
                            let saved: Waypoint = await saveEdits() ?? original
                            plotter.goTo(saved)
                            close(toMap: true)
                        }
                    } label: {
                        Label("Go to", systemImage: "scope")
                    }
                    .accessibilityIdentifier("waypoint.edit.goTo")
                    Button {
                        plotter.select(original.id)
                        close(toMap: true)
                    } label: {
                        Label("Show on map", systemImage: "map")
                    }
                    .accessibilityIdentifier("waypoint.edit.showOnMap")
                    Button {
                        Task { await plotter.export(waypoints: [original.id], routes: [], tracks: [], title: name) }
                    } label: {
                        Label("Export as GPX", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("waypoint.edit.export")
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete waypoint", systemImage: "trash")
                    }
                    .accessibilityIdentifier("waypoint.edit.delete")
                }
            }
            .navigationTitle(original.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                        .accessibilityIdentifier("waypoint.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            _ = await saveEdits()
                            onClose()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("waypoint.edit.save")
                }
            }
            .confirmationDialog("Delete \(original.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await plotter.data.deleteWaypoint(original.id)
                        onClose()
                    }
                }
                .accessibilityIdentifier("waypoint.edit.confirmDelete")
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: exportBinding(plotter)) { file in
                ShareSheet(url: file.url)
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = original.name
                symbol = original.symbol ?? "Waypoint"
                notes = original.notes
            }
        }
    }

    private func close(toMap: Bool) {
        if toMap, let onLeaveForMap {
            onLeaveForMap()
        } else {
            onClose()
        }
    }

    private func saveEdits() async -> Waypoint? {
        var updated: Waypoint = original
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmed.isEmpty ? original.name : trimmed
        updated.symbol = symbol
        updated.notes = notes
        if updated == original { return original }
        return await plotter.data.save(updated)
    }
}
