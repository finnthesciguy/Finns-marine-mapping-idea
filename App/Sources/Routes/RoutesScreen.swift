import AppServices
import NavCore
import Persistence
import SwiftUI

/// Routes: create on the map, edit points (reorder, delete), show on the map, follow, export, delete.
struct RoutesScreen: View {
    let plotter: PlotterModel
    let onCloseAll: () -> Void
    @State private var opened: Route?

    var body: some View {
        let rows: [RouteRow] = RouteRow.rows(plotter.data.routes, units: plotter.data.settings.units)
        NavigationStack {
            List {
                Section {
                    Button {
                        plotter.beginNewRoute()
                        onCloseAll()
                    } label: {
                        Label("New route on the chart", systemImage: "plus")
                    }
                    .accessibilityIdentifier("routes.new")
                } footer: {
                    Text("Tap the chart to add points, then Save. Routes are not checked for depth or hazards: check every leg against the chart.")
                }
                Section("Routes") {
                    if rows.isEmpty {
                        Text("No routes yet.")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { item in
                        let row: RouteRow = item.element
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name)
                                        .font(.headline)
                                        .accessibilityIdentifier("route.name.\(item.offset)")
                                    Text(row.detail)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Color.secondary)
                                        .accessibilityIdentifier("route.detail.\(item.offset)")
                                }
                                Spacer()
                                if plotter.guidance.session.activeRouteID == row.id {
                                    Image(systemName: "location.north.line.fill")
                                        .foregroundStyle(Color.pink)
                                        .accessibilityLabel("Following")
                                } else if plotter.shownRouteIDs.contains(row.id) {
                                    Image(systemName: "eye")
                                        .foregroundStyle(Color.secondary)
                                        .accessibilityLabel("Shown on the chart")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                opened = plotter.data.route(row.id)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("route.row.\(item.offset)")
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await plotter.data.deleteRoute(row.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Routes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onCloseAll)
                        .accessibilityIdentifier("routes.done")
                }
            }
            .sheet(item: $opened) { route in
                RouteDetailScreen(original: route, plotter: plotter, onClose: { opened = nil }, onLeaveForMap: onCloseAll)
            }
        }
    }
}

/// One route: name, points (reorder and delete), legs (with grade colour for auto-routes), summary,
/// follow, show on the chart, add points on the chart, export, delete.
struct RouteDetailScreen: View {
    let original: Route
    let plotter: PlotterModel
    let onClose: () -> Void
    let onLeaveForMap: () -> Void

    @State private var route: Route = Route(name: "")
    @State private var loaded = false
    @State private var confirmingDelete = false

    var body: some View {
        let display = RouteDisplay(route: route)
        let units: UnitPreferences = plotter.data.settings.units
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Name", text: $route.name)
                        .accessibilityIdentifier("route.edit.name")
                }
                Section {
                    Button {
                        Task {
                            let saved: Route = await saveIfChanged() ?? route
                            plotter.follow(saved)
                            onLeaveForMap()
                        }
                    } label: {
                        Label("Follow this route", systemImage: "location.north.line")
                    }
                    .disabled(route.points.count < 2)
                    .accessibilityIdentifier("route.follow")
                    Toggle(isOn: Binding(get: { plotter.shownRouteIDs.contains(original.id) },
                                         set: { plotter.setRouteShown(original.id, $0) })) {
                        Label("Show on the chart", systemImage: "eye")
                    }
                    .accessibilityIdentifier("route.show")
                    Button {
                        Task {
                            let saved: Route = await saveIfChanged() ?? route
                            plotter.beginEditing(saved)
                            onLeaveForMap()
                        }
                    } label: {
                        Label("Add points on the chart", systemImage: "plus.viewfinder")
                    }
                    .accessibilityIdentifier("route.addOnChart")
                }
                if let summary = display.summary {
                    RouteSummarySection(summary: summary, dataDate: display.routingPackDataDate, units: units)
                }
                Section {
                    ForEach(Array(route.points.enumerated()), id: \.offset) { item in
                        HStack {
                            Text(display.pointName(item.offset))
                            Spacer()
                            Text(NavFormat.position(item.element.coordinate))
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.secondary)
                        }
                        .accessibilityIdentifier("route.point.\(item.offset)")
                    }
                    .onMove { from, to in
                        route.points.move(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { offsets in
                        route.points.remove(atOffsets: offsets)
                    }
                } header: {
                    HStack {
                        Text("Points (\(route.points.count)), " + NavFormat.distance(display.length, unit: units.distance))
                        Spacer()
                        EditButton()
                            .accessibilityIdentifier("route.edit.reorder")
                    }
                }
                if !display.legs.isEmpty {
                    Section("Legs") {
                        ForEach(display.legs, id: \.index) { leg in
                            LegRow(leg: leg, display: display, units: units)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await plotter.export(waypoints: [], routes: [original.id], tracks: [], title: route.name) }
                    } label: {
                        Label("Export as GPX", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("route.export")
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete route", systemImage: "trash")
                    }
                    .accessibilityIdentifier("route.delete")
                }
            }
            .navigationTitle(original.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                        .accessibilityIdentifier("route.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            _ = await saveIfChanged()
                            onClose()
                        }
                    }
                    .accessibilityIdentifier("route.edit.save")
                }
            }
            .confirmationDialog("Delete \(original.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await plotter.data.deleteRoute(original.id)
                        onClose()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: exportBinding(plotter)) { file in
                ShareSheet(url: file.url)
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                route = original
            }
        }
    }

    private func saveIfChanged() async -> Route? {
        var updated: Route = route
        if updated.name.trimmingCharacters(in: .whitespaces).isEmpty { updated.name = original.name }
        if updated == original { return original }
        return await plotter.data.save(updated)
    }
}

/// One leg: from → to, length and bearing, and (for auto-routes) its grade colour and reasons.
struct LegRow: View {
    let leg: RouteDisplay.Leg
    let display: RouteDisplay
    let units: UnitPreferences

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(LegGradeStyle.color(leg.grade))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(display.pointName(leg.index)) → \(display.pointName(leg.index + 1))")
                Text(NavFormat.distance(Geodesy.distance(from: leg.from, to: leg.to), unit: units.distance) + "  "
                     + NavFormat.bearing(Geodesy.initialBearing(from: leg.from, to: leg.to)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.secondary)
                if !leg.reasonCodes.isEmpty {
                    Text(leg.reasonCodes.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("route.leg.\(leg.index)")
    }
}

/// Colours of leg grades (the same as the chart's route layers).
enum LegGradeStyle {
    static func color(_ grade: String?) -> Color {
        switch grade {
        case "green": return Color.green
        case "yellow": return Color.yellow
        case "red": return Color.red
        default: return Color.blue
        }
    }
}

/// The auto-route summary (distance, shallowest depth, lowest clearance, worst grade, data date). Shown
/// only for routes that carry `AutoRouteInfo`; manual routes have none.
struct RouteSummarySection: View {
    let summary: AutoRouteInfo.Summary
    let dataDate: Date?
    let units: UnitPreferences

    var body: some View {
        Section("Route check") {
            if let distance = summary.distanceMeters {
                LabeledContent("Distance", value: NavFormat.distance(distance, unit: units.distance))
            }
            if let depth = summary.shallowestDepthMeters {
                LabeledContent("Shallowest charted depth", value: NavFormat.depth(depth, unit: units.depth))
            }
            if let clearance = summary.lowestClearanceMeters {
                LabeledContent("Lowest clearance", value: NavFormat.depth(clearance, unit: units.depth))
            }
            if let worst = summary.worstGrade {
                LabeledContent("Worst leg", value: worst.rawValue)
            }
            if let dataDate {
                LabeledContent("Chart data", value: DataDateFormat.string(dataDate))
            }
        }
    }
}
