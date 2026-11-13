import AppServices
import ChartKit
import Persistence
import SwiftUI

/// Units, map orientation at launch, track recording interval, keep-screen-on, and the about text
/// (disclaimer, NOAA attribution, chart data dates). Changes are saved immediately.
struct SettingsScreen: View {
    let plotter: PlotterModel
    let installed: [InstalledRegion]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings: AppSettings = plotter.data.settings
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Distance", selection: binding(\.distanceUnit)) {
                        Text("nm").tag(DistanceUnit.nauticalMiles)
                        Text("mi").tag(DistanceUnit.statuteMiles)
                        Text("km").tag(DistanceUnit.kilometers)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.distanceUnit")
                    Picker("Speed", selection: binding(\.speedUnit)) {
                        Text("kn").tag(SpeedUnit.knots)
                        Text("mph").tag(SpeedUnit.milesPerHour)
                        Text("km/h").tag(SpeedUnit.kilometersPerHour)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.speedUnit")
                    Picker("Depth", selection: binding(\.depthUnit)) {
                        Text("ft").tag(DepthUnit.feet)
                        Text("m").tag(DepthUnit.meters)
                        Text("fm").tag(DepthUnit.fathoms)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.depthUnit")
                }
                Section("Chart") {
                    Picker("Orientation at launch", selection: binding(\.mapOrientation)) {
                        Text("North up").tag(MapOrientation.northUp)
                        Text("Course up").tag(MapOrientation.courseUp)
                    }
                    .accessibilityIdentifier("settings.orientation")
                    Toggle("Keep the screen on", isOn: binding(\.keepScreenOn))
                        .accessibilityIdentifier("settings.keepScreenOn")
                }
                Section {
                    Picker("Record a point every", selection: binding(\.trackInterval)) {
                        ForEach(AppSettings.trackIntervalChoices, id: \.self) { seconds in
                            Text(NavFormat.duration(seconds)).tag(seconds)
                        }
                    }
                    .accessibilityIdentifier("settings.trackInterval")
                } header: {
                    Text("Track recording")
                } footer: {
                    Text("A point is also skipped until the boat has moved \(Int(settings.trackMinimumDistance)) m. Shorter intervals give smoother tracks; background recording uses GPS continuously either way.")
                }
                Section("About") {
                    Text(Disclaimer.title)
                        .font(.headline)
                    ForEach(Array(Disclaimer.points.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.callout)
                    }
                    Text("Chart data: NOAA Office of Coast Survey, public domain, provided as-is. Gulf Nav is not affiliated with or endorsed by NOAA.")
                        .font(.callout)
                        .accessibilityIdentifier("settings.attribution")
                }
                Section("Installed chart data") {
                    if installed.isEmpty {
                        Text("No charts installed.")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(installed, id: \.id) { region in
                        LabeledContent(region.title, value: DataDateFormat.string(region.chart.dataDate))
                            .accessibilityIdentifier("settings.chartDate.\(region.id)")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
    }

    /// A binding to one setting that saves the whole settings value on change.
    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { plotter.data.settings[keyPath: keyPath] },
                set: { newValue in
                    var next: AppSettings = plotter.data.settings
                    next[keyPath: keyPath] = newValue
                    Task { await plotter.data.updateSettings(next) }
                })
    }
}
