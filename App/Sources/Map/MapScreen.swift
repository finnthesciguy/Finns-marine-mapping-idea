import AppServices
import ChartKit
import NavCore
import SwiftUI
import UIKit

/// The main screen: chart map, chart-age badge, instrument strip and map controls.
struct MapScreen: View {
    let model: AppModel
    @State private var showingCharts: Bool = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let map: ChartMapModel = model.map
        let navigation: NavigationModel = model.navigation
        ZStack {
            ChartMapView(plan: map.plan,
                         planRevision: map.planRevision,
                         readout: navigation.readout,
                         follow: map.follow,
                         orientation: map.orientation,
                         onUserPannedMap: { map.follow = false },
                         onPlanApplied: { revision in map.planApplied(revision: revision) })
                .ignoresSafeArea()

            VStack(spacing: 8) {
                topBar(map: map)
                if let warning = model.startupWarning {
                    Banner(text: warning, systemImage: "externaldrive.badge.exclamationmark")
                }
                if !navigation.authorization.allowsUpdates && navigation.authorization != .notDetermined {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Banner(text: "Location access is off. Tap to open Settings.", systemImage: "location.slash")
                    }
                    .buttonStyle(.plain)
                }
                if !map.hasCharts {
                    Button {
                        showingCharts = true
                    } label: {
                        Banner(text: "No charts installed. Tap to download a region.", systemImage: "map")
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    mapControls(map: map)
                }
                InstrumentStrip(readout: navigation.readout)
                Text("Chart data: NOAA. Not for navigation.")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingCharts) {
            ChartsScreen(model: model.charts)
        }
    }

    @ViewBuilder
    private func topBar(map: ChartMapModel) -> some View {
        HStack {
            if let badge = map.badge {
                ChartAgeBadgeView(badge: badge)
            }
            Spacer()
            #if DEBUG
            DebugMenu(navigation: model.navigation)
            #endif
            Button {
                showingCharts = true
            } label: {
                Label("Charts", systemImage: "square.stack.3d.up")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func mapControls(map: ChartMapModel) -> some View {
        VStack(spacing: 10) {
            Button {
                map.toggleOrientation()
            } label: {
                Image(systemName: map.orientation == .northUp ? "location.north.line" : "arrow.up.circle")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel(map.orientation.label)
            Button {
                map.follow.toggle()
            } label: {
                Image(systemName: map.follow ? "location.fill" : "location")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel(map.follow ? "Following position" : "Follow position")
        }
    }
}

/// SOG, COG and position.
struct InstrumentStrip: View {
    let readout: NavigationReadout

    var body: some View {
        let position = InstrumentFormat.position(readout.lastFix?.coordinate)
        HStack(spacing: 0) {
            cell(title: "SOG", value: InstrumentFormat.sog(metersPerSecond: readout.speedOverGround))
            Divider().frame(height: 36)
            cell(title: "COG", value: InstrumentFormat.cog(degrees: readout.courseOverGround))
            Divider().frame(height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("POSITION")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                Text(position.latitude)
                    .font(.system(.callout, design: .monospaced))
                Text(position.longitude)
                    .font(.system(.callout, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func cell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 90, alignment: .leading)
    }
}

/// Data date of the oldest installed region; orange or red when stale.
struct ChartAgeBadgeView: View {
    let badge: ChartAgeBadge

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(badge.text)
                .lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background, in: Capsule())
    }

    private var symbol: String {
        switch badge.level {
        case .current: return "checkmark.seal"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }

    private var foreground: Color {
        switch badge.level {
        case .current: return Color.primary
        case .warning, .critical: return Color.white
        }
    }

    private var background: Color {
        switch badge.level {
        case .current: return Color(uiColor: .secondarySystemBackground)
        case .warning: return Color.orange
        case .critical: return Color.red
        }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

#if DEBUG
/// Debug builds only: replay the Tampa Bay track instead of GPS (for the simulator).
struct DebugMenu: View {
    let navigation: NavigationModel

    var body: some View {
        Menu {
            Toggle("Simulate GPS (Tampa Bay)", isOn: Binding(get: { navigation.isSimulating },
                                                             set: { navigation.setSimulating($0) }))
        } label: {
            Image(systemName: navigation.isSimulating ? "ant.fill" : "ant")
                .padding(8)
                .background(.regularMaterial, in: Circle())
        }
    }
}
#endif
