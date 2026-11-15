import AppServices
import Foundation
import NavCore

// Types shared by both chart maps: MapLibre on iOS (ChartMapView.swift) and MapKit on the Mac
// (ChartMapViewMac.swift, Mac Catalyst build).

/// A waypoint a tap can hit.
struct MapTapTarget: Equatable {
    var id: UUID
    var coordinate: Coordinate
}

/// Accessibility identifiers the UI tests rely on.
enum MapAccessibility {
    static let mapIdentifier = "chart-map"
    static let statusIdentifier = "map.status"

    /// Machine-readable map state for the UI tests (`AppServices.MapDiagnostics.statusValue`), e.g.
    /// `style=loaded; chartLayers=1; overlayLayers=0; styleVia=attach; willStartLoading=0; ...`.
    static func statusValue(_ diagnostics: MapDiagnostics) -> String {
        diagnostics.statusValue
    }

    /// The value before anything has happened.
    static var initialStatusValue: String {
        statusValue(MapDiagnostics())
    }
}

/// The bundled offline style (Resources/offline-style.json), with an inline copy as a fallback.
enum OfflineStyle {
    static let fallbackJSON: String = """
    {"version":8,"name":"Gulf Nav offline base","sources":{},"layers":[{"id":"water-background","type":"background","paint":{"background-color":"#b7d3e6"}}]}
    """

    static func load(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "offline-style", withExtension: "json") else { return fallbackJSON }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return fallbackJSON }
        return text
    }
}

/// Mac: what the chart's context menu (right-click or control-click on a chart point) offers. On iOS a
/// long-press drops a waypoint, as before; this enum is only acted on by the Mac map.
enum MapPointAction: String, CaseIterable {
    case dropWaypoint
    case goTo
    case routeFrom
    case routeTo
    case centerHere

    static let menuOrder: [MapPointAction] = [.dropWaypoint, .goTo, .routeFrom, .routeTo, .centerHere]

    var title: String {
        switch self {
        case .dropWaypoint: return "Drop Waypoint Here"
        case .goTo: return "Go To Here"
        case .routeFrom: return "Auto-Route From Here"
        case .routeTo: return "Auto-Route To Here"
        case .centerHere: return "Centre Chart Here"
        }
    }

    var systemImage: String {
        switch self {
        case .dropWaypoint: return "mappin.and.ellipse"
        case .goTo: return "location.north.line"
        case .routeFrom: return "point.topleft.down.to.point.bottomright.curvepath"
        case .routeTo: return "flag.checkered"
        case .centerHere: return "scope"
        }
    }
}

/// Mac: a one-off camera move requested from the menu bar (applied once per `revision`).
struct MapCameraCommand: Equatable {
    enum Kind: Equatable {
        case zoomIn
        case zoomOut
    }

    var kind: Kind
    var revision: Int
}
