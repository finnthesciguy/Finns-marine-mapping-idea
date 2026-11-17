// The Mac (Mac Catalyst) chart map. MapLibre Native 7.0.0 ships no Mac Catalyst slice (its xcframework has
// only ios-arm64 and ios-arm64_x86_64-simulator; see App/README-macOS.md), so the Mac build draws the same
// charts and overlays with MapKit, which Mac Catalyst has:
//
// - charts: one `MKTileOverlay` subclass per installed region (ChartKit's layer plan, same order as on iOS)
//   that reads tiles from the region's MBTiles package through ChartKit's `MBTilesReader`, limited to the
//   region box, over-zooming above the package's highest zoom (`AppServices.ChartTileMath`);
// - base: a water-coloured tile overlay that replaces Apple's map content, so the chart is offline-only as on
//   iOS (the colour of `offline-style.json`);
// - overlays: the GeoJSON from `AppServices.MapOverlays` parsed by `OverlayShapes` and styled by
//   `OverlayStyling` (the MapLibre layer table as data): lines as `MKPolyline` overlays, points as annotation
//   views with drawn circles;
// - the own-ship marker, follow, north-up / course-up, taps, long-press, and on the Mac a context menu
//   (right-click / control-click) and zoom commands.
//
// MapKit API used (checked against MKMapView.h, MKTileOverlay.h, MKAnnotationView.h, MKOverlayPathRenderer.h of
// the iOS 18 SDK headers and Apple's documentation pages for Swift spellings and Mac Catalyst availability):
// `MKMapView` `delegate`, `isPitchEnabled`, `isRotateEnabled`, `showsCompass`, `showsZoomControls` (Mac Catalyst
// 13+), `showsScale`, `cameraZoomRange` (`MKMapView.CameraZoomRange(minCenterCoordinateDistance:
// maxCenterCoordinateDistance:)`), `camera`, `setCamera(_:animated:)`, `region`, `setRegion(_:animated:)`,
// `addOverlay(_:level:)`, `removeOverlays(_:)`, `addAnnotation(_:)`, `addAnnotations(_:)`, `removeAnnotations(_:)`,
// `convert(_:toCoordinateFrom:)`, `convert(_:toPointTo:)`, `centerCoordinate`; `MKTileOverlay(urlTemplate:)`,
// `tileSize`, `minimumZ`, `maximumZ`, `canReplaceMapContent`, `boundingMapRect`,
// `loadTile(at:result:)` (`@escaping @Sendable` result); `MKTileOverlayRenderer(tileOverlay:)`;
// `MKPolyline(coordinates:count:)`; `MKPolylineRenderer(polyline:)` with `strokeColor`, `lineWidth`, `lineCap`,
// `lineJoin`, `lineDashPattern`; `MKAnnotationView(annotation:reuseIdentifier:)` with `image`, `isEnabled`,
// `displayPriority` (`.required`), `zPriority` (`.max`), `canShowCallout`; delegate methods
// `mapView(_:rendererFor:)`, `mapView(_:viewFor:)`,
// `mapView(_:regionDidChangeAnimated:)`, `mapViewDidChangeVisibleRegion(_:)`, `mapViewWillStartLoadingMap(_:)`,
// `mapViewDidFinishLoadingMap(_:)`, `mapViewDidFailLoadingMap(_:withError:)`,
// `mapViewDidFinishRenderingMap(_:fullyRendered:)`; `UIContextMenuInteraction(delegate:)`,
// `contextMenuInteraction(_:configurationForMenuAtLocation:)`, `location(in:)`; for the input layer
// `MKMapCamera.centerCoordinateDistance` (MKMapCamera.h, iOS 13+), `UIPanGestureRecognizer.allowedScrollTypesMask`
// with `allowedTouchTypes = []` for scroll-only recognition (UIPanGestureRecognizer.h and its documentation page),
// `UIPinchGestureRecognizer.scale`.
#if targetEnvironment(macCatalyst)
import AppServices
import ChartKit
import CoreGraphics
import Foundation
import ImageIO
import MapKit
import NavCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChartMapView: UIViewRepresentable {
    let plan: [ChartLayerPlan]
    let planRevision: Int
    let readout: NavigationReadout
    let follow: Bool
    let orientation: MapOrientationMode
    /// The user dragged the map (follow mode should switch off).
    let onUserPannedMap: () -> Void
    /// The layers for this revision are now on the map.
    let onPlanApplied: (Int) -> Void
    /// Waypoints, routes, tracks and the direct-to line.
    let overlays: MapOverlays
    /// Waypoints a click can select.
    let tapTargets: [MapTapTarget]
    /// A single click: the coordinate and the waypoint within reach, if any.
    let onTap: (Coordinate, UUID?) -> Void
    let onLongPress: (Coordinate) -> Void
    /// Zoom level and centre latitude after the camera settled.
    let onCameraChanged: (Double, Double) -> Void
    /// Move the camera here once, when `focusRevision` changes (framing a planned auto-route).
    var focus: MapFocus? = nil
    var focusRevision: Int = 0
    /// Mac: an item of the chart's context menu (right-click or control-click) was chosen.
    var onPointAction: ((MapPointAction, Coordinate) -> Void)? = nil
    /// Mac: zoom in / out from the menu bar, applied once per revision.
    var cameraCommand: MapCameraCommand? = nil
    /// Mac: the centre of the chart after the camera settled (drop a waypoint there when there is no position).
    var onCenterChanged: ((Coordinate) -> Void)? = nil
    /// Online NOAA charts are on.
    var liveCharts: Bool = false
    /// Where the online tiles come from (disk cache, then NOAA); nil when online charts are off.
    var liveLoader: LiveChartTileLoader? = nil

    func makeCoordinator() -> ChartMapCoordinator {
        ChartMapCoordinator()
    }

    func makeUIView(context: Context) -> ChartMapContainerView {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.accessibilityIdentifier = MapAccessibility.mapIdentifier
        mapView.delegate = context.coordinator
        mapView.isPitchEnabled = false
        // Rotation must stay enabled for course-up: with it off, MapKit ignores the camera heading and keeps
        // north up. The coordinator turns the chart back to north when north-up is selected.
        mapView.isRotateEnabled = true
        // MapKit's zoom buttons and compass would sit under the input layer (see `ChartInputLayer`) and get no
        // clicks; zoom is scroll / pinch / double-click / ⌘= ⌘-, and north-up is the map button and ⌘U.
        mapView.showsCompass = false
        mapView.showsZoomControls = false
        mapView.showsScale = true
        // About 150 m to 12,000 km from the camera: harbour detail to the whole Gulf and beyond.
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 150,
                                                            maxCenterCoordinateDistance: 12_000_000)
        let container = ChartMapContainerView(mapView: mapView)
        context.coordinator.attach(mapView, probe: container.statusProbe)
        context.coordinator.installGestures(on: container.inputLayer)
        // Start over Tampa Bay until the first fix arrives (zoom 9, as on iOS).
        context.coordinator.setCenter(CLLocationCoordinate2D(latitude: 27.62, longitude: -82.70), zoom: 9, animated: false)
        return container
    }

    func updateUIView(_ container: ChartMapContainerView, context: Context) {
        context.coordinator.update(with: self)
    }
}

/// A transparent view over the map that receives all pointer input for the chart (click, double-click,
/// click-and-hold, drag, scroll, pinch, right-click). On the first CI run of the Mac UI tests a single click on the
/// MKMapView never reached the UIKit tap recognizer added to it (a route got no points), while right-click through
/// `UIContextMenuInteraction` did work. Why is not established (MapKit's own click handling on Mac Catalyst is the
/// likely cause). With this layer the app's recognizers are on a plain UIView, which is the ordinary UIKit case, and
/// map panning and zooming are done by the coordinator through MapKit's camera API. It is not an accessibility
/// element, so `chart-map` (the map view) is still what the tests find.
final class ChartInputLayer: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        isOpaque = false
        isUserInteractionEnabled = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Hosts the map, the input layer above it and, in debug builds, the invisible `map.status` accessibility element.
final class ChartMapContainerView: UIView {
    let mapView: MKMapView
    let inputLayer: ChartInputLayer
    let statusProbe: UIView?

    init(mapView: MKMapView) {
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
        self.inputLayer = ChartInputLayer(frame: mapView.frame)
        super.init(frame: mapView.frame)
        mapView.frame = bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(mapView)
        inputLayer.frame = bounds
        inputLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(inputLayer)
        if let statusProbe {
            addSubview(statusProbe)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

// MARK: - Tile overlays

/// Encodes tile images (CoreGraphics and ImageIO only, so it is safe on MapKit's tile-loading queues).
enum ChartTileImage {
    static let side: Int = 256

    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func context(side: Int = ChartTileImage.side) -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// A fully transparent tile.
    static func transparent() -> Data? {
        guard let context = context() else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return nil }
        return png(image)
    }

    /// A tile of one colour (the water background).
    static func solid(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
        guard let context = context() else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return nil }
        return png(image)
    }

    /// The part of a stored tile that covers a deeper tile, scaled up to a whole tile.
    static func crop(_ data: Data, _ source: ChartTileMath.Source) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // CGImage cropping uses the image's own pixel grid, origin at the top left (as the fractions are).
        let rect = CGRect(x: CGFloat(source.cropX) * width, y: CGFloat(source.cropY) * height,
                          width: max(1, CGFloat(source.cropSize) * width),
                          height: max(1, CGFloat(source.cropSize) * height)).integral
        // Keep the source's resolution (512 px for a retina tile), so a scaled-up tile is not also blurred.
        let out: Int = max(ChartTileImage.side, image.width)
        guard let part = image.cropping(to: rect), let context = context(side: out) else { return nil }
        context.interpolationQuality = CGInterpolationQuality.medium
        context.draw(part, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let scaled = context.makeImage() else { return nil }
        return png(scaled)
    }
}

/// A tile the package does not have (outside the region box, a zoom it lacks, a gap) is answered with a
/// transparent tile, not an error: MapKit reported such errors through `mapViewDidFailLoadingMap` (seen on CI as
/// `didFailLoading=…NoChartTile…`), which is for real failures only.
enum EmptyTile {
    static let data: Data? = ChartTileImage.transparent()
}

/// Error passed to MapKit only when not even the transparent tile could be made.
struct NoChartTile: Error {}

/// The offline base: water colour everywhere, replacing Apple's map (as the offline MapLibre style does on iOS).
final class WaterTileOverlay: MKTileOverlay {
    /// `#b7d3e6`, the background of `offline-style.json`.
    static let tile: Data? = ChartTileImage.solid(red: 0xB7 / 255.0, green: 0xD3 / 255.0, blue: 0xE6 / 255.0)

    /// A distinct initializer (not `init()`), so no question arises about overriding an inherited `init()`.
    init(replacingMapContent: Bool) {
        super.init(urlTemplate: nil)
        canReplaceMapContent = replacingMapContent
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 22
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        if let tile = WaterTileOverlay.tile {
            result(tile, nil)
        } else {
            result(nil, NoChartTile())
        }
    }
}

/// One installed chart region, read from its MBTiles package.
final class ChartTileOverlay: MKTileOverlay {
    let entry: ChartLayerPlan
    private let reader: MBTilesReader?
    private let region: MKMapRect

    init(entry: ChartLayerPlan) {
        self.entry = entry
        var opened: MBTilesReader? = nil
        if let path = ChartTileMath.filePath(fromSourceURL: entry.sourceURL) {
            opened = try? MBTilesReader(url: URL(fileURLWithPath: path))
        }
        self.reader = opened
        let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: entry.bounds.north, longitude: entry.bounds.west))
        let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: entry.bounds.south, longitude: entry.bounds.east))
        self.region = MKMapRect(x: min(northWest.x, southEast.x), y: min(northWest.y, southEast.y),
                                width: abs(southEast.x - northWest.x), height: abs(southEast.y - northWest.y))
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = entry.sourceMinZoom
        maximumZ = min(max(entry.layerMaxZoom, entry.sourceMaxZoom), 22)
    }

    var isReadable: Bool { reader != nil }

    override var boundingMapRect: MKMapRect { region }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let tile = ChartTileMath.Tile(zoom: path.z, x: path.x, y: path.y)
        guard let reader, tile.zoom >= entry.sourceMinZoom, ChartTileMath.tile(tile, overlaps: entry.bounds),
              let source = ChartTileMath.source(for: tile, maxZoom: entry.sourceMaxZoom) else {
            ChartTileOverlay.noTile(result)
            return
        }
        Task.detached {
            let data: Data? = try? await reader.tile(zoom: source.tile.zoom, x: source.tile.x, y: source.tile.y)
            guard let data else {
                ChartTileOverlay.noTile(result)
                return
            }
            if source.isWholeTile {
                result(data, nil)
            } else if let scaled = ChartTileImage.crop(data, source) {
                result(scaled, nil)
            } else {
                ChartTileOverlay.noTile(result)
            }
        }
    }

    /// Answers a request for a tile the package does not have.
    static func noTile(_ result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        if let empty = EmptyTile.data {
            result(empty, nil)
        } else {
            result(nil, NoChartTile())
        }
    }
}

/// Online NOAA charts (AppServices `LiveChartTileLoader`: disk cache, then NOAA's export service). Under the
/// installed regions. On a Retina display MapKit asks with `contentScaleFactor` 2 and gets NOAA's true 2× tile
/// (512 px rendered at 192 dpi), so chart text and symbols are sharp.
final class LiveChartTileOverlay: MKTileOverlay {
    let loader: LiveChartTileLoader
    private let region: MKMapRect

    init(loader: LiveChartTileLoader) {
        self.loader = loader
        let box = LiveChartService.coverage
        let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: box.north, longitude: box.west))
        let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: box.south, longitude: box.east))
        self.region = MKMapRect(x: min(northWest.x, southEast.x), y: min(northWest.y, southEast.y),
                                width: abs(southEast.x - northWest.x), height: abs(southEast.y - northWest.y))
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = LiveChartService.minZoom
        maximumZ = 22
    }

    override var boundingMapRect: MKMapRect { region }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let tile = ChartTileMath.Tile(zoom: path.z, x: path.x, y: path.y)
        let scale: Int = path.contentScaleFactor >= 1.5 ? 2 : 1
        let loader: LiveChartTileLoader = self.loader
        Task.detached {
            let answer: LiveTileResult = await loader.tile(tile, scale: scale)
            switch answer {
            case .image(let data, let source):
                if source.isWholeTile {
                    result(data, nil)
                } else if let cut = ChartTileImage.crop(data, source) {
                    result(cut, nil)
                } else {
                    ChartTileOverlay.noTile(result)
                }
            case .empty, .unavailable:
                ChartTileOverlay.noTile(result)
            }
        }
    }
}

// MARK: - Overlay shapes

/// A line of one overlay style layer.
final class StyledPolyline: MKPolyline {
    var style: OverlayLineStyle = OverlayLineStyle(layerID: "", color: .systemBlue, width: 3)
}

/// A point feature (waypoint, route point, blocked place) with its circles.
final class StyledPointAnnotation: MKPointAnnotation {
    var styled: StyledOverlayPoint?
}

/// The boat.
final class OwnShipAnnotation: MKPointAnnotation {}

enum OverlayColors {
    static func color(_ color: OverlayColor) -> UIColor {
        switch color {
        case .savedTrack:
            let c = OverlayColor.savedTrackRGBA
            return UIColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
        case .systemRed: return UIColor.systemRed
        case .systemBlue: return UIColor.systemBlue
        case .systemGreen: return UIColor.systemGreen
        case .systemYellow: return UIColor.systemYellow
        case .systemOrange: return UIColor.systemOrange
        case .systemPink: return UIColor.systemPink
        case .gray: return UIColor.gray
        case .white: return UIColor.white
        case .clear: return UIColor.clear
        }
    }

    /// The circles of one point, bottom to top, centred in one image.
    @MainActor
    static func image(for circles: [OverlayCircleStyle]) -> UIImage {
        let side = CGFloat(OverlayStyling.imageSide(for: circles))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            let cg: CGContext = context.cgContext
            for circle in circles {
                let radius = CGFloat(circle.radius)
                let rect = CGRect(x: side / 2 - radius, y: side / 2 - radius, width: 2 * radius, height: 2 * radius)
                cg.setFillColor(color(circle.fill).cgColor)
                cg.fillEllipse(in: rect)
                if circle.strokeWidth > 0 {
                    cg.setStrokeColor(color(circle.stroke).cgColor)
                    cg.setLineWidth(CGFloat(circle.strokeWidth))
                    cg.strokeEllipse(in: rect)
                }
            }
        }
    }
}

// MARK: - Coordinator

/// Owns the MapKit side: tile overlays, overlay shapes, the marker, camera moves, clicks and the context menu.
@MainActor
final class ChartMapCoordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    private weak var mapView: MKMapView?
    private weak var statusProbe: UIView?
    private var latest: ChartMapView?
    private var diagnostics = MapDiagnostics()
    private var appliedRevision = -1
    private let water = WaterTileOverlay(replacingMapContent: true)
    private var chartOverlays: [ChartTileOverlay] = []
    private var liveOverlay: LiveChartTileOverlay?
    private var lineOverlays: [StyledPolyline] = []
    private var pointAnnotations: [StyledPointAnnotation] = []
    private var appliedOverlays: [OverlaySource: Data] = [:]
    /// Parsed shapes per source (kept so a change to one source re-styles only what is needed).
    private var shapes: [OverlaySource: [OverlayShape]] = [:]

    private let marker = OwnShipAnnotation()
    private var markerOnMap = false
    private var markerView: MKAnnotationView?
    private let arrowView = UIImageView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
    private var arrowSymbol = ""

    private var lastCenteredFix: Fix?
    private var appliedFocusRevision: Int = 0
    private var appliedCameraRevision: Int = 0
    private var lastOrientation: MapOrientationMode = .northUp
    private var lastFollow = true
    /// The location of the last context-menu click, in map view coordinates.
    private var menuLocation: CGPoint = .zero

    override init() {
        arrowView.contentMode = .scaleAspectFit
        arrowView.tintColor = UIColor.systemRed
        super.init()
    }

    func attach(_ mapView: MKMapView, probe: UIView?) {
        self.mapView = mapView
        self.statusProbe = probe
        mapView.addOverlay(water, level: MKOverlayLevel.aboveRoads)
        // MapKit has no style object to wait for: the map is usable as soon as it exists.
        diagnostics.styleVia = .attach
        diagnostics.overlayLayers = OverlayStyling.layerCount
        updateStatusProbe()
    }

    private func updateStatusProbe() {
        diagnostics.chartLayers = chartOverlays.count
        statusProbe?.accessibilityValue = MapAccessibility.statusValue(diagnostics)
    }

    func update(with view: ChartMapView) {
        latest = view
        guard let mapView else { return }
        applyLiveIfNeeded(view, on: mapView)
        applyPlanIfNeeded(view, on: mapView)
        applyOverlays(view, on: mapView)
        updateMarker(view, on: mapView)
        updateCamera(view, on: mapView)
    }

    // MARK: Charts

    /// Online NOAA charts directly above the water base and under the installed regions.
    private func applyLiveIfNeeded(_ view: ChartMapView, on mapView: MKMapView) {
        let wanted: LiveChartTileLoader? = view.liveCharts ? view.liveLoader : nil
        if let current = liveOverlay, let wanted, current.loader === wanted { return }
        if liveOverlay == nil && wanted == nil { return }
        if let current = liveOverlay {
            mapView.removeOverlay(current)
            liveOverlay = nil
        }
        if let wanted {
            let overlay = LiveChartTileOverlay(loader: wanted)
            mapView.insertOverlay(overlay, above: water)
            liveOverlay = overlay
        }
    }

    private func applyPlanIfNeeded(_ view: ChartMapView, on mapView: MKMapView) {
        guard view.planRevision != appliedRevision else { return }
        mapView.removeOverlays(chartOverlays)
        var next: [ChartTileOverlay] = []
        var unreadable: [String] = []
        // Plan order is bottom to top; later overlays at the same level draw above earlier ones (and above
        // the water overlay added at attach).
        for entry in view.plan {
            let overlay = ChartTileOverlay(entry: entry)
            if !overlay.isReadable { unreadable.append(entry.regionID) }
            mapView.addOverlay(overlay, level: MKOverlayLevel.aboveRoads)
            next.append(overlay)
        }
        chartOverlays = next
        if !unreadable.isEmpty {
            diagnostics.failure = "chart package not readable: " + unreadable.joined(separator: ",")
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

    private func applyOverlays(_ view: ChartMapView, on mapView: MKMapView) {
        var linesChanged = false
        var pointsChanged = false
        for source in OverlaySource.allCases {
            let data: Data = source.data(in: view.overlays)
            guard appliedOverlays[source] != data else { continue }
            do {
                shapes[source] = try OverlayShapes.parse(data)
                appliedOverlays[source] = data
            } catch {
                diagnostics.failure = "overlay \(source.rawValue): \(error)"
                shapes[source] = []
                appliedOverlays[source] = data
            }
            if source.isPoints { pointsChanged = true } else { linesChanged = true }
        }
        if linesChanged { rebuildLines(on: mapView) }
        if pointsChanged { rebuildPoints(on: mapView) }
        if linesChanged || pointsChanged {
            diagnostics.overlayFeatures = view.overlays.summary
            updateStatusProbe()
        }
    }

    /// All line layers in draw order (MapKit draws later overlays of a level above earlier ones).
    private func rebuildLines(on mapView: MKMapView) {
        mapView.removeOverlays(lineOverlays)
        var layers: [StyledOverlayLines] = []
        for source in OverlaySource.allCases where !source.isPoints {
            layers.append(contentsOf: OverlayStyling.lines(shapes[source] ?? [], source: source))
        }
        layers.sort { $0.order < $1.order }
        var next: [StyledPolyline] = []
        for layer in layers {
            for line in layer.lines {
                let coordinates: [CLLocationCoordinate2D] = line.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let polyline = StyledPolyline(coordinates: coordinates, count: coordinates.count)
                polyline.style = layer.style
                next.append(polyline)
            }
        }
        for polyline in next {
            mapView.addOverlay(polyline, level: MKOverlayLevel.aboveLabels)
        }
        lineOverlays = next
    }

    private func rebuildPoints(on mapView: MKMapView) {
        mapView.removeAnnotations(pointAnnotations)
        var next: [StyledPointAnnotation] = []
        // Same bottom-to-top source order as the MapLibre layers: route points, blocked places, waypoints.
        for source in OverlaySource.allCases where source.isPoints {
            for point in OverlayStyling.points(shapes[source] ?? [], source: source) {
                let annotation = StyledPointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: point.coordinate.latitude,
                                                               longitude: point.coordinate.longitude)
                annotation.title = point.label
                annotation.styled = point
                next.append(annotation)
            }
        }
        mapView.addAnnotations(next)
        pointAnnotations = next
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        if let line = overlay as? StyledPolyline {
            let renderer = MKPolylineRenderer(polyline: line)
            let style: OverlayLineStyle = line.style
            renderer.strokeColor = OverlayColors.color(style.color).withAlphaComponent(CGFloat(style.opacity))
            renderer.lineWidth = CGFloat(style.width)
            renderer.lineCap = CGLineCap.round
            renderer.lineJoin = CGLineJoin.round
            if let dash = style.dash {
                // MapLibre dash lengths are multiples of the line width; MapKit's are points.
                renderer.lineDashPattern = dash.map { NSNumber(value: $0 * style.width) }
            }
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === marker {
            if let markerView { return markerView }
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "own-ship")
            view.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
            view.isEnabled = false
            view.canShowCallout = false
            view.displayPriority = MKFeatureDisplayPriority.required
            view.zPriority = MKAnnotationViewZPriority.max
            arrowView.frame = view.bounds
            view.addSubview(arrowView)
            markerView = view
            return view
        }
        if let point = annotation as? StyledPointAnnotation, let styled = point.styled {
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.image = OverlayColors.image(for: styled.circles)
            view.isEnabled = false
            view.canShowCallout = false
            view.displayPriority = MKFeatureDisplayPriority.required
            return view
        }
        return nil
    }

    // MARK: Clicks, long press and the context menu

    func installGestures(on layer: ChartInputLayer) {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        longPress.delegate = self
        layer.addGestureRecognizer(longPress)
        // A double click zooms in; a single click waits for it to fail so it does not also add a route point.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        layer.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        tap.delegate = self
        layer.addGestureRecognizer(tap)
        // Drag with the mouse or one finger on the trackpad: pan the chart.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.delegate = self
        layer.addGestureRecognizer(drag)
        // As in Apple's Maps on the Mac: two-finger trackpad scroll (continuous) pans, a mouse wheel (discrete)
        // zooms. Both are scroll-only recognizers (no touch types, per the `allowedScrollTypesMask` documentation).
        let trackpadScroll = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll(_:)))
        trackpadScroll.allowedScrollTypesMask = UIScrollTypeMask.continuous
        trackpadScroll.allowedTouchTypes = []
        trackpadScroll.delegate = self
        layer.addGestureRecognizer(trackpadScroll)
        trackpadRecognizer = trackpadScroll
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        wheel.allowedScrollTypesMask = UIScrollTypeMask.discrete
        wheel.allowedTouchTypes = []
        wheel.delegate = self
        layer.addGestureRecognizer(wheel)
        scrollRecognizer = wheel
        // Trackpad pinch: zoom.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        layer.addGestureRecognizer(pinch)
        pinchRecognizer = pinch
        layer.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private weak var scrollRecognizer: UIGestureRecognizer?
    private weak var trackpadRecognizer: UIGestureRecognizer?
    private var lastTrackpad: CGPoint = .zero
    private weak var pinchRecognizer: UIGestureRecognizer?
    private var lastDrag: CGPoint = .zero
    private var lastScroll: CGPoint = .zero
    private var pinchStartDistance: Double = 0

    /// Scroll and pinch may run together with anything; clicks, holds and drags are exclusive.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let free: [UIGestureRecognizer?] = [scrollRecognizer, pinchRecognizer, trackpadRecognizer]
        return free.contains { $0 === gestureRecognizer || $0 === otherGestureRecognizer }
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            lastDrag = recognizer.translation(in: mapView)
            if let callback = latest?.onUserPannedMap {
                DispatchQueue.main.async {
                    callback()
                }
            }
        case .changed:
            let translation: CGPoint = recognizer.translation(in: mapView)
            let dx: CGFloat = translation.x - lastDrag.x
            let dy: CGFloat = translation.y - lastDrag.y
            lastDrag = translation
            // The point that must come to the centre is the centre moved against the drag.
            let target = CGPoint(x: mapView.bounds.midX - dx, y: mapView.bounds.midY - dy)
            mapView.setCenter(mapView.convert(target, toCoordinateFrom: mapView), animated: false)
        default:
            break
        }
    }

    /// Two-finger trackpad scroll: moves the chart with the fingers (natural scrolling), like a drag.
    @objc private func handleTrackpadScroll(_ recognizer: UIPanGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            lastTrackpad = recognizer.translation(in: mapView)
            if let callback = latest?.onUserPannedMap {
                DispatchQueue.main.async {
                    callback()
                }
            }
        case .changed:
            let translation: CGPoint = recognizer.translation(in: mapView)
            let dx: CGFloat = translation.x - lastTrackpad.x
            let dy: CGFloat = translation.y - lastTrackpad.y
            lastTrackpad = translation
            let target = CGPoint(x: mapView.bounds.midX - dx, y: mapView.bounds.midY - dy)
            mapView.setCenter(mapView.convert(target, toCoordinateFrom: mapView), animated: false)
        default:
            break
        }
    }

    /// Mouse wheel: zoom.
    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            lastScroll = recognizer.translation(in: mapView)
        case .changed:
            let translation: CGPoint = recognizer.translation(in: mapView)
            let dy: Double = Double(translation.y - lastScroll.y)
            lastScroll = translation
            // 120 points of scrolling per zoom level; scrolling the content down (wheel up) zooms in.
            zoom(byLevels: dy / 120.0, animated: false)
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            pinchStartDistance = mapView.camera.centerCoordinateDistance
        case .changed:
            guard pinchStartDistance > 0, recognizer.scale > 0.01 else { return }
            guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
            camera.centerCoordinateDistance = pinchStartDistance / Double(recognizer.scale)
            mapView.setCamera(camera, animated: false)
        default:
            break
        }
    }

    /// Zooms by `levels` zoom levels (positive: in), keeping the centre and heading (MapKit clamps the distance to
    /// `cameraZoomRange`).
    func zoom(byLevels levels: Double, animated: Bool) {
        guard let mapView, levels.isFinite, levels != 0 else { return }
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
        camera.centerCoordinateDistance = camera.centerCoordinateDistance / pow(2.0, levels)
        mapView.setCamera(camera, animated: animated)
    }

    private func coordinate(at point: CGPoint, in mapView: MKMapView) -> Coordinate {
        let location: CLLocationCoordinate2D = mapView.convert(point, toCoordinateFrom: mapView)
        return Coordinate(latitude: location.latitude, longitude: location.longitude)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let mapView, let view = latest else { return }
        view.onLongPress(coordinate(at: recognizer.location(in: mapView), in: mapView))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        // Zoom in one level on the clicked point.
        guard recognizer.state == .ended, let mapView else { return }
        let point: CGPoint = recognizer.location(in: mapView)
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
        camera.centerCoordinate = mapView.convert(point, toCoordinateFrom: mapView)
        camera.centerCoordinateDistance = camera.centerCoordinateDistance / 2.0
        mapView.setCamera(camera, animated: true)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let mapView, let view = latest else { return }
        let point: CGPoint = recognizer.location(in: mapView)
        view.onTap(coordinate(at: point, in: mapView), waypointHit(near: point, in: mapView, targets: view.tapTargets))
    }

    /// The nearest waypoint within 30 points of `point`.
    private func waypointHit(near point: CGPoint, in mapView: MKMapView, targets: [MapTapTarget]) -> UUID? {
        var hit: UUID? = nil
        var best: CGFloat = 30
        for target in targets {
            let location = CLLocationCoordinate2D(latitude: target.coordinate.latitude, longitude: target.coordinate.longitude)
            let screen: CGPoint = mapView.convert(location, toPointTo: mapView)
            let distance: CGFloat = hypot(screen.x - point.x, screen.y - point.y)
            if distance < best {
                best = distance
                hit = target.id
            }
        }
        return hit
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let mapView, let view = latest, let handler = view.onPointAction else { return nil }
        let point: CGPoint = interaction.location(in: mapView)
        menuLocation = point
        let target: Coordinate = coordinate(at: point, in: mapView)
        let hit: UUID? = waypointHit(near: point, in: mapView, targets: view.tapTargets)
        var actions: [UIMenuElement] = []
        for action in MapPointAction.menuOrder {
            let item = UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in
                handler(action, target)
            }
            actions.append(item)
        }
        if let hit {
            let select = UIAction(title: "Select Waypoint", image: UIImage(systemName: "mappin")) { _ in
                view.onTap(target, hit)
            }
            actions.insert(select, at: 0)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: actions)
        }
    }

    // MARK: Marker

    private func updateMarker(_ view: ChartMapView, on mapView: MKMapView) {
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
        updateArrow(mapDirection: mapView.camera.heading)
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

    /// MapLibre-style zoom level of the current view (256-point tiles).
    var zoomLevel: Double {
        guard let mapView else { return 9 }
        return ChartTileMath.zoomLevel(longitudeDelta: mapView.region.span.longitudeDelta,
                                       widthPoints: Double(max(mapView.bounds.width, 1)))
    }

    /// Centres the chart at a MapLibre-style zoom level, keeping the heading.
    func setCenter(_ center: CLLocationCoordinate2D, zoom: Double, animated: Bool) {
        guard let mapView else { return }
        let width: Double = Double(max(mapView.bounds.width, 100))
        let height: Double = Double(max(mapView.bounds.height, 100))
        let longitudeDelta: Double = min(ChartTileMath.longitudeDelta(zoom: zoom, widthPoints: width), 359)
        // Web Mercator: a degree of latitude spans 1/cos(latitude) times a degree of longitude on screen.
        let latitudeDelta: Double = min(longitudeDelta * height / width * cos(center.latitude * Double.pi / 180.0), 170)
        let region = MKCoordinateRegion(center: center,
                                        span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
        mapView.setRegion(region, animated: animated)
    }

    private func setCamera(center: CLLocationCoordinate2D?, heading: Double, animated: Bool, on mapView: MKMapView) {
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
        if let center { camera.centerCoordinate = center }
        camera.heading = heading
        mapView.setCamera(camera, animated: animated)
    }

    private func updateCamera(_ view: ChartMapView, on mapView: MKMapView) {
        let current: Double = mapView.camera.heading
        let target: Double = view.readout.mapDirection(for: view.orientation, current: current)
        let orientationChanged: Bool = view.orientation != lastOrientation
        let followTurnedOn: Bool = view.follow && !lastFollow
        lastOrientation = view.orientation
        lastFollow = view.follow

        if let command = view.cameraCommand, command.revision != appliedCameraRevision {
            appliedCameraRevision = command.revision
            zoom(byLevels: command.kind == .zoomIn ? 1 : -1, animated: true)
            return
        }
        if view.focusRevision != appliedFocusRevision {
            appliedFocusRevision = view.focusRevision
            if let focus = view.focus {
                let center = CLLocationCoordinate2D(latitude: focus.center.latitude, longitude: focus.center.longitude)
                setCenter(center, zoom: focus.zoom, animated: true)
                return
            }
        }
        if view.follow, let fix = view.readout.lastFix {
            if fix != lastCenteredFix || orientationChanged || followTurnedOn {
                lastCenteredFix = fix
                let center = CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
                setCamera(center: center, heading: target, animated: true, on: mapView)
            }
            return
        }
        if orientationChanged || ChartMapCoordinator.angleBetween(current, target) > 2 {
            setCamera(center: nil, heading: target, animated: true, on: mapView)
        }
    }

    /// Smallest absolute difference between two bearings, degrees.
    static func angleBetween(_ a: Double, _ b: Double) -> Double {
        var d: Double = (b - a).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d > 180 ? 360 - d : d
    }

    // MARK: MKMapViewDelegate

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        updateArrow(mapDirection: mapView.camera.heading)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        updateArrow(mapDirection: mapView.camera.heading)
        let zoom: Double = zoomLevel
        let center: CLLocationCoordinate2D = mapView.centerCoordinate
        if let callback = latest?.onCameraChanged {
            DispatchQueue.main.async {
                callback(zoom, center.latitude)
            }
        }
        if let callback = latest?.onCenterChanged {
            let coordinate = Coordinate(latitude: center.latitude, longitude: center.longitude)
            DispatchQueue.main.async {
                callback(coordinate)
            }
        }
    }

    func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
        diagnostics.willStartLoading += 1
        updateStatusProbe()
    }

    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        diagnostics.didFinishLoadingMap += 1
        updateStatusProbe()
    }

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
        diagnostics.failure = error.localizedDescription
        updateStatusProbe()
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        diagnostics.frames += 1
        if fullyRendered {
            diagnostics.fullyRenderedFrames += 1
            diagnostics.idle += 1
        }
        updateStatusProbe()
    }
}
#endif
