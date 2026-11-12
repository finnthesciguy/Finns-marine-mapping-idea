import AppServices
import ChartKit
import MapLibre
import NavCore
import SwiftUI
import UIKit

/// The chart map: an `MLNMapView` with a bundled offline style (a water-coloured background, no network
/// sources) and one raster source + layer per installed chart region, rebuilt whenever `planRevision`
/// changes. Draws the own-ship marker and moves the camera for follow mode and north-up / course-up.
///
/// MapLibre API used here (pinned 7.0.0, checked against the ios-v7.0.0 headers; see App/README.md):
/// `MLNMapView(frame:styleJSON:)`, `delegate`, `style`, `isRotateEnabled`, `isPitchEnabled`,
/// `minimumZoomLevel`, `maximumZoomLevel`, `zoomLevel`, `direction`, `setCenter(_:zoomLevel:animated:)`,
/// `setCenter(_:zoomLevel:direction:animated:)`, `setDirection(_:animated:)`, `addAnnotation(_:)`,
/// `removeAnnotation(_:)`; `MLNStyle.addSource(_:)`, `addLayer(_:)`, `removeLayer(_:)`;
/// `MLNRasterTileSource(identifier:tileURLTemplates:options:)` with `MLNTileSourceOption`
/// `.minimumZoomLevel`, `.maximumZoomLevel`, `.tileSize`, `.coordinateBounds`;
/// `NSValue(mlnCoordinateBounds:)`, `MLNCoordinateBounds(sw:ne:)`; `MLNRasterStyleLayer(identifier:source:)`;
/// `MLNPointAnnotation`, `MLNAnnotationView(reuseIdentifier:)`; delegate methods
/// `mapView(_:didFinishLoading:)`, `mapView(_:viewFor:)`, `mapView(_:regionWillChangeWith:animated:)`,
/// `mapView(_:regionIsChangingWith:)`, `mapView(_:regionDidChangeWith:animated:)`.
struct ChartMapView: UIViewRepresentable {
    let plan: [ChartLayerPlan]
    let planRevision: Int
    let readout: NavigationReadout
    let follow: Bool
    let orientation: MapOrientationMode
    /// The user dragged the map (follow mode should switch off).
    let onUserPannedMap: () -> Void
    /// The layers for this revision are now in the style.
    let onPlanApplied: (Int) -> Void

    func makeCoordinator() -> ChartMapCoordinator {
        ChartMapCoordinator()
    }

    func makeUIView(context: Context) -> ChartMapContainerView {
        let mapView = MLNMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), styleJSON: OfflineStyle.load())
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.accessibilityIdentifier = MapAccessibility.mapIdentifier
        mapView.delegate = context.coordinator
        // Rotation is driven by the north-up / course-up toggle only; no tilt on a chart.
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.minimumZoomLevel = 3
        mapView.maximumZoomLevel = 20
        // Start over Tampa Bay until the first fix arrives.
        mapView.setCenter(CLLocationCoordinate2D(latitude: 27.62, longitude: -82.70), zoomLevel: 9, animated: false)
        let container = ChartMapContainerView(mapView: mapView)
        context.coordinator.attach(mapView, probe: container.statusProbe)
        return container
    }

    func updateUIView(_ container: ChartMapContainerView, context: Context) {
        context.coordinator.update(with: self)
    }
}

/// Accessibility identifiers the UI tests rely on.
enum MapAccessibility {
    static let mapIdentifier = "chart-map"
    static let statusIdentifier = "map.status"

    /// Machine-readable map state for the UI tests: `style=loaded; chartLayers=1`.
    static func statusValue(styleLoaded: Bool, chartLayers: Int) -> String {
        "style=\(styleLoaded ? "loaded" : "pending"); chartLayers=\(chartLayers)"
    }
}

/// Hosts the map plus, in debug builds, an invisible accessibility element (`map.status`) that reports
/// whether the style has loaded and how many chart layers are in it, so UI tests can check the map
/// without comparing pixels.
final class ChartMapContainerView: UIView {
    let mapView: MLNMapView
    let statusProbe: UIView?

    init(mapView: MLNMapView) {
        self.mapView = mapView
        #if DEBUG
        let probe = UIView(frame: CGRect(x: 0, y: 120, width: 2, height: 2))
        probe.backgroundColor = UIColor.clear
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = MapAccessibility.statusIdentifier
        probe.accessibilityLabel = "Chart map status"
        probe.accessibilityTraits = UIAccessibilityTraits.staticText
        probe.accessibilityValue = MapAccessibility.statusValue(styleLoaded: false, chartLayers: 0)
        self.statusProbe = probe
        #else
        self.statusProbe = nil
        #endif
        super.init(frame: mapView.frame)
        mapView.frame = bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(mapView)
        if let statusProbe {
            addSubview(statusProbe)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Owns the MapLibre side: style layers, the marker and camera moves.
@MainActor
final class ChartMapCoordinator: NSObject, @preconcurrency MLNMapViewDelegate {
    private weak var mapView: MLNMapView?
    private weak var statusProbe: UIView?
    private var latest: ChartMapView?
    private var styleLoaded = false
    private var appliedRevision = -1
    private var addedLayers: [MLNStyleLayer] = []
    private var addedSources: [MLNSource] = []

    private let marker = MLNPointAnnotation()
    private var markerOnMap = false
    private let markerView: MLNAnnotationView
    private let arrowView: UIImageView
    private var arrowSymbol = ""

    private var lastCenteredFix: Fix?
    private var lastOrientation: MapOrientationMode = .northUp
    private var lastFollow = true

    override init() {
        let view = MLNAnnotationView(reuseIdentifier: "own-ship")
        view.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        view.isEnabled = false
        let arrow = UIImageView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        arrow.contentMode = .scaleAspectFit
        arrow.tintColor = UIColor.systemRed
        view.addSubview(arrow)
        markerView = view
        arrowView = arrow
        super.init()
    }

    func attach(_ mapView: MLNMapView, probe: UIView?) {
        self.mapView = mapView
        self.statusProbe = probe
    }

    private func updateStatusProbe() {
        statusProbe?.accessibilityValue = MapAccessibility.statusValue(styleLoaded: styleLoaded,
                                                                       chartLayers: addedLayers.count)
    }

    func update(with view: ChartMapView) {
        latest = view
        guard let mapView else { return }
        applyPlanIfNeeded(view, on: mapView)
        updateMarker(view, on: mapView)
        updateCamera(view, on: mapView)
    }

    // MARK: Layers

    private func applyPlanIfNeeded(_ view: ChartMapView, on mapView: MLNMapView) {
        guard styleLoaded, let style = mapView.style else { return }
        guard view.planRevision != appliedRevision else { return }
        for layer in addedLayers {
            style.removeLayer(layer)
        }
        for source in addedSources {
            ChartMapLayers.remove(source, from: style)
        }
        addedLayers = []
        addedSources = []
        // Plan order is bottom to top; addLayer appends above everything already there.
        for entry in view.plan {
            let source: MLNRasterTileSource = ChartMapLayers.makeSource(for: entry, revision: view.planRevision)
            style.addSource(source)
            let layer: MLNRasterStyleLayer = ChartMapLayers.makeLayer(for: entry, source: source, revision: view.planRevision)
            style.addLayer(layer)
            addedSources.append(source)
            addedLayers.append(layer)
        }
        appliedRevision = view.planRevision
        updateStatusProbe()
        let callback: (Int) -> Void = view.onPlanApplied
        let revision: Int = view.planRevision
        DispatchQueue.main.async {
            callback(revision)
        }
    }

    // MARK: Marker

    private func updateMarker(_ view: ChartMapView, on mapView: MLNMapView) {
        guard let fix = view.readout.lastFix else {
            if markerOnMap {
                mapView.removeAnnotation(marker)
                markerOnMap = false
            }
            return
        }
        marker.coordinate = CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        if !markerOnMap {
            mapView.addAnnotation(marker)
            markerOnMap = true
        }
        updateArrow(mapDirection: mapView.direction)
    }

    private func updateArrow(mapDirection: Double) {
        guard let view = latest else { return }
        if let direction = view.readout.markerDirection {
            setArrowSymbol("location.north.fill")
            let degrees: Double = NavigationReadout.markerScreenRotation(markerDirection: direction, mapDirection: mapDirection)
            arrowView.transform = CGAffineTransform(rotationAngle: CGFloat(degrees * Double.pi / 180.0))
        } else {
            setArrowSymbol("circle.circle.fill")
            arrowView.transform = CGAffineTransform.identity
        }
    }

    private func setArrowSymbol(_ name: String) {
        guard name != arrowSymbol else { return }
        arrowSymbol = name
        arrowView.image = UIImage(systemName: name)
    }

    // MARK: Camera

    private func updateCamera(_ view: ChartMapView, on mapView: MLNMapView) {
        let current: Double = mapView.direction
        let target: Double = view.readout.mapDirection(for: view.orientation, current: current)
        let orientationChanged: Bool = view.orientation != lastOrientation
        let followTurnedOn: Bool = view.follow && !lastFollow
        lastOrientation = view.orientation
        lastFollow = view.follow

        if view.follow, let fix = view.readout.lastFix {
            if fix != lastCenteredFix || orientationChanged || followTurnedOn {
                lastCenteredFix = fix
                let center = CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
                mapView.setCenter(center, zoomLevel: mapView.zoomLevel, direction: target, animated: true)
            }
            return
        }
        if orientationChanged || ChartMapCoordinator.angleBetween(current, target) > 2 {
            mapView.setDirection(target, animated: true)
        }
    }

    /// Smallest absolute difference between two bearings, degrees.
    static func angleBetween(_ a: Double, _ b: Double) -> Double {
        var d: Double = (b - a).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d > 180 ? 360 - d : d
    }

    // MARK: MLNMapViewDelegate

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        styleLoaded = true
        appliedRevision = -1
        addedLayers = []
        addedSources = []
        updateStatusProbe()
        if let latest {
            update(with: latest)
        }
    }

    func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        if let point = annotation as? MLNPointAnnotation, point === marker {
            return markerView
        }
        return nil
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        if reason.contains(.gesturePan), let callback = latest?.onUserPannedMap {
            DispatchQueue.main.async {
                callback()
            }
        }
    }

    func mapView(_ mapView: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
        updateArrow(mapDirection: mapView.direction)
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        updateArrow(mapDirection: mapView.direction)
    }
}

/// Builds MapLibre sources and layers from ChartKit's layer plan.
enum ChartMapLayers {
    /// MBTiles packages from NOAA and from our build service are 256-pixel raster tiles.
    static let tileSize: Int = 256

    /// A raster source reading the package through MapLibre's `mbtiles://` file source. The template is
    /// the same form MapLibre generates for an `mbtiles://` TileJSON (`<url>?file={x}/{y}/{z}.<ext>`); the
    /// file source reads the database path up to `?` and takes the tile address from the request. Inline
    /// templates are used (rather than a TileJSON URL) so the region box can be set as the source bounds:
    /// NOAA packages contain world-wide tiles at low zooms that would otherwise be drawn outside the region.
    static func makeSource(for entry: ChartLayerPlan, revision: Int) -> MLNRasterTileSource {
        let southWest = CLLocationCoordinate2D(latitude: entry.bounds.south, longitude: entry.bounds.west)
        let northEast = CLLocationCoordinate2D(latitude: entry.bounds.north, longitude: entry.bounds.east)
        let bounds = MLNCoordinateBounds(sw: southWest, ne: northEast)
        var options: [MLNTileSourceOption: Any] = [:]
        options[.minimumZoomLevel] = NSNumber(value: entry.sourceMinZoom)
        options[.maximumZoomLevel] = NSNumber(value: entry.sourceMaxZoom)
        options[.tileSize] = NSNumber(value: tileSize)
        options[.coordinateBounds] = NSValue(mlnCoordinateBounds: bounds)
        let template: String = entry.sourceURL + "?file={x}/{y}/{z}.png"
        return MLNRasterTileSource(identifier: "\(entry.sourceID)-r\(revision)", tileURLTemplates: [template],
                                   options: options)
    }

    static func makeLayer(for entry: ChartLayerPlan, source: MLNSource, revision: Int) -> MLNRasterStyleLayer {
        let layer = MLNRasterStyleLayer(identifier: "\(entry.layerID)-r\(revision)", source: source)
        layer.minimumZoomLevel = Float(entry.layerMinZoom)
        layer.maximumZoomLevel = Float(entry.layerMaxZoom)
        return layer
    }

    /// Removes a source. `MLNStyle` declares both `-removeSource:` and `-removeSource:error:`, which Swift
    /// imports as two `removeSource(_:)` methods (one throwing); calling the selector directly avoids
    /// relying on how the compiler resolves that pair.
    static func remove(_ source: MLNSource, from style: MLNStyle) {
        let selector: Selector = NSSelectorFromString("removeSource:")
        if style.responds(to: selector) {
            _ = style.perform(selector, with: source)
        }
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
