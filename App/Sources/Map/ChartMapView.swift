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
/// `mapView(_:regionIsChangingWith:)`, `mapView(_:regionDidChangeWith:animated:)`; for map taps
/// `gestureRecognizers`, `convert(_:toCoordinateFrom:)` (from `LineTapMapView.swift` in app-swift) and
/// `convert(_:toPointTo:)` (`-convertCoordinate:toPointToView:`), `centerCoordinate`. Overlay layers: see
/// `MapOverlayLayers`.
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
    /// Waypoints, routes, tracks and the direct-to line.
    let overlays: MapOverlays
    /// Waypoints a tap can select.
    let tapTargets: [MapTapTarget]
    /// A single tap: the coordinate and the waypoint within reach of the finger, if any.
    let onTap: (Coordinate, UUID?) -> Void
    let onLongPress: (Coordinate) -> Void
    /// Zoom level and centre latitude after the camera settled.
    let onCameraChanged: (Double, Double) -> Void
    /// Move the camera here once, when `focusRevision` changes (framing a planned auto-route).
    var focus: MapFocus? = nil
    var focusRevision: Int = 0

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
        context.coordinator.installGestures(on: mapView)
        return container
    }

    func updateUIView(_ container: ChartMapContainerView, context: Context) {
        context.coordinator.update(with: self)
    }
}

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
        probe.accessibilityValue = MapAccessibility.statusValue(MapDiagnostics())
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
    /// Which delegate callbacks have fired and how the style object was found (shown in `map.status`).
    private var diagnostics = MapDiagnostics()
    private var appliedRevision = -1
    private var addedLayers: [MLNStyleLayer] = []
    private var addedSources: [MLNSource] = []
    /// Overlay sources and layers in the current style (empty until the style is available).
    private var overlaySources: [MapOverlayLayers.SourceID: MLNShapeSource] = [:]
    private var overlayLayers: [MLNStyleLayer] = []
    private var overlayStyle: ObjectIdentifier?
    private var appliedOverlays: [MapOverlayLayers.SourceID: Data] = [:]

    private let marker = MLNPointAnnotation()
    private var markerOnMap = false
    private let markerView: MLNAnnotationView
    private let arrowView: UIImageView
    private var arrowSymbol = ""

    private var lastCenteredFix: Fix?
    private var appliedFocusRevision: Int = 0
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

    /// Called right after the delegate is set. `MLNMapView(frame:styleJSON:)` parses an inline style
    /// synchronously inside the initializer (`-setStyleJSON:` calls mbgl's `loadJSON`, which reports the
    /// style loaded before returning), so `mapView(_:didFinishLoading:)` has already happened, with no
    /// delegate, by the time one can be set. The style object is therefore picked up here, and again on
    /// each update if it was still missing, rather than waiting for a callback that never comes.
    func attach(_ mapView: MLNMapView, probe: UIView?) {
        self.mapView = mapView
        self.statusProbe = probe
        if mapView.style != nil {
            styleBecameAvailable(via: .attach)
        }
        updateStatusProbe()
    }

    /// Marks the style usable; layers are (re)applied on the next `update(with:)`. Does not depend on a
    /// frame having been rendered.
    private func styleBecameAvailable(via source: MapDiagnostics.StyleSource) {
        if !styleLoaded {
            diagnostics.styleVia = source
        }
        styleLoaded = true
    }

    private func updateStatusProbe() {
        diagnostics.chartLayers = addedLayers.count
        statusProbe?.accessibilityValue = MapAccessibility.statusValue(diagnostics)
    }

    func update(with view: ChartMapView) {
        latest = view
        guard let mapView else { return }
        if !styleLoaded, mapView.style != nil {
            styleBecameAvailable(via: .update)
            updateStatusProbe()
        }
        installOverlaysIfNeeded(on: mapView)
        applyPlanIfNeeded(view, on: mapView)
        applyOverlays(view)
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
        // Plan order is bottom to top. Charts go below the overlay layers (waypoints, routes, tracks).
        let firstOverlay: MLNStyleLayer? = overlayLayers.first
        for entry in view.plan {
            let source: MLNRasterTileSource = ChartMapLayers.makeSource(for: entry, revision: view.planRevision)
            style.addSource(source)
            let layer: MLNRasterStyleLayer = ChartMapLayers.makeLayer(for: entry, source: source, revision: view.planRevision)
            if let firstOverlay {
                style.insertLayer(layer, below: firstOverlay)
            } else {
                style.addLayer(layer)
            }
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

    // MARK: Overlays

    /// Adds the overlay sources and layers once per style object.
    private func installOverlaysIfNeeded(on mapView: MLNMapView) {
        guard styleLoaded, let style = mapView.style else { return }
        let identity = ObjectIdentifier(style)
        if overlayStyle == identity, style.source(withIdentifier: MapOverlayLayers.SourceID.waypoints.rawValue) != nil {
            return
        }
        let built: MapOverlayLayers.Built = MapOverlayLayers.build()
        for id in MapOverlayLayers.SourceID.allCases {
            if let source = built.sources[id], style.source(withIdentifier: id.rawValue) == nil {
                style.addSource(source)
            }
        }
        for layer in built.layers where style.layer(withIdentifier: layer.identifier) == nil {
            style.addLayer(layer)
        }
        overlaySources = built.sources
        overlayLayers = built.layers
        overlayStyle = identity
        appliedOverlays = [:]
        diagnostics.overlayLayers = overlayLayers.count
        updateStatusProbe()
    }

    /// Replaces the shape of each overlay source whose GeoJSON changed.
    private func applyOverlays(_ view: ChartMapView) {
        guard !overlaySources.isEmpty else { return }
        var changed = false
        for id in MapOverlayLayers.SourceID.allCases {
            let data: Data = MapOverlayLayers.data(for: id, in: view.overlays)
            guard appliedOverlays[id] != data, let source = overlaySources[id] else { continue }
            if let failure = MapOverlayLayers.setShape(data, on: source) {
                diagnostics.failure = failure
            } else {
                appliedOverlays[id] = data
            }
            changed = true
        }
        if changed {
            diagnostics.overlayFeatures = view.overlays.summary
            updateStatusProbe()
        }
    }

    // MARK: Gestures

    func installGestures(on mapView: MLNMapView) {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        mapView.addGestureRecognizer(longPress)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // Let the map's own double-tap (zoom) win, as in MapLibre's LineTapMapView example.
        for recognizer in mapView.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
            tap.require(toFail: recognizer)
        }
        mapView.addGestureRecognizer(tap)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let mapView, let view = latest else { return }
        let point: CGPoint = recognizer.location(in: mapView)
        let coordinate: CLLocationCoordinate2D = mapView.convert(point, toCoordinateFrom: mapView)
        view.onLongPress(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let mapView, let view = latest else { return }
        let point: CGPoint = recognizer.location(in: mapView)
        let coordinate: CLLocationCoordinate2D = mapView.convert(point, toCoordinateFrom: mapView)
        // The nearest waypoint within 30 points of the finger.
        var hit: UUID? = nil
        var best: CGFloat = 30
        for target in view.tapTargets {
            let location = CLLocationCoordinate2D(latitude: target.coordinate.latitude, longitude: target.coordinate.longitude)
            let screen: CGPoint = mapView.convert(location, toPointTo: mapView)
            let distance: CGFloat = hypot(screen.x - point.x, screen.y - point.y)
            if distance < best {
                best = distance
                hit = target.id
            }
        }
        view.onTap(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude), hit)
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

        if view.focusRevision != appliedFocusRevision {
            appliedFocusRevision = view.focusRevision
            if let focus = view.focus {
                let center = CLLocationCoordinate2D(latitude: focus.center.latitude, longitude: focus.center.longitude)
                mapView.setCenter(center, zoomLevel: focus.zoom, animated: true)
                return
            }
        }
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
        diagnostics.didFinishLoadingStyle += 1
        styleBecameAvailable(via: .delegate)
        // A newly loaded style object has none of our layers: forget them so they are added again. If our
        // layers are still in this style (the callback for a style already picked up at attach), keep them;
        // adding a source with an existing identifier would raise.
        var ourLayersPresent: Bool = false
        if let first = addedLayers.first, style.layer(withIdentifier: first.identifier) != nil {
            ourLayersPresent = true
        }
        if !ourLayersPresent {
            appliedRevision = -1
            addedLayers = []
            addedSources = []
        }
        if style.source(withIdentifier: MapOverlayLayers.SourceID.waypoints.rawValue) == nil {
            overlayStyle = nil
            overlaySources = [:]
            overlayLayers = []
        }
        updateStatusProbe()
        if let latest {
            update(with: latest)
        }
    }

    func mapViewWillStartLoadingMap(_ mapView: MLNMapView) {
        diagnostics.willStartLoading += 1
        updateStatusProbe()
    }

    func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
        diagnostics.didFinishLoadingMap += 1
        if !styleLoaded, mapView.style != nil {
            styleBecameAvailable(via: .update)
            if let latest {
                update(with: latest)
            }
        }
        updateStatusProbe()
    }

    func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
        diagnostics.failure = error.localizedDescription
        updateStatusProbe()
    }

    func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
        diagnostics.frames += 1
        if fullyRendered { diagnostics.fullyRenderedFrames += 1 }
        // Every frame would be wasteful; the first few and then every 30th are enough to see progress.
        if diagnostics.frames <= 5 || diagnostics.frames % 30 == 0 {
            updateStatusProbe()
        }
    }

    func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
        diagnostics.idle += 1
        updateStatusProbe()
    }

    func mapViewRendererDidError(_ mapView: MLNMapView) {
        diagnostics.rendererErrors += 1
        updateStatusProbe()
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
        if let callback = latest?.onCameraChanged {
            let zoom: Double = mapView.zoomLevel
            let latitude: Double = mapView.centerCoordinate.latitude
            DispatchQueue.main.async {
                callback(zoom, latitude)
            }
        }
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
