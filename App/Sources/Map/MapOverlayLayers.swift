import AppServices
import Foundation
import MapLibre
import UIKit

/// MapLibre style sources and layers for waypoints, routes, tracks and the direct-to line, drawn above the
/// chart rasters. Each source is an `MLNShapeSource` whose shape is replaced with GeoJSON from
/// `AppServices.MapOverlays`; the layers select features by the properties `MapFeatures` writes.
///
/// No text labels: the offline style has no glyphs (no network), and a symbol layer with `text` would
/// request them. Names are shown in SwiftUI (selection card, lists) instead.
///
/// API (MapLibre Native iOS 7.0.0, checked against `platform/darwin/src/MLNShapeSource.h`, `MLNShape.h`,
/// `MLNStyle.h`, `MLNStyleLayer.h`, `MLNVectorStyleLayer.h`, the layer template `MLNStyleLayer.h.ejs` with
/// `scripts/style-spec-cocoa-conventions-v8.json` for property names, and the Swift doc tests):
/// `MLNShapeSource(identifier:shape:options:)`, `MLNShapeSource.shape`, `MLNShape(data:encoding:)` (throws),
/// `MLNLineStyleLayer(identifier:source:)`, `lineColor`, `lineWidth`, `lineCap`, `lineJoin`,
/// `lineDashPattern` (style-spec `line-dasharray`), `lineOpacity`, `MLNCircleStyleLayer(identifier:source:)`,
/// `circleColor`, `circleRadius`, `circleStrokeColor`, `circleStrokeWidth`, `MLNVectorStyleLayer.predicate`,
/// `NSExpression(forConstantValue:)`, `MLNStyle.insertLayer(_:below:)`, `MLNStyle.source(withIdentifier:)`.
enum MapOverlayLayers {
    enum SourceID: String, CaseIterable {
        case tracks = "gn-tracks"
        case routeLegs = "gn-route-legs"
        case routePoints = "gn-route-points"
        case direct = "gn-direct"
        case waypoints = "gn-waypoints"
    }

    /// Sources and layers, bottom to top.
    struct Built {
        var sources: [SourceID: MLNShapeSource]
        var layers: [MLNStyleLayer]
    }

    static func build() -> Built {
        var sources: [SourceID: MLNShapeSource] = [:]
        for id in SourceID.allCases {
            sources[id] = MLNShapeSource(identifier: id.rawValue, shape: nil, options: nil)
        }
        var layers: [MLNStyleLayer] = []
        if let tracks = sources[.tracks] {
            layers.append(line("gn-tracks-saved", tracks, predicate: NSPredicate(format: "live == NO"),
                               color: UIColor(red: 0.82, green: 0.13, blue: 0.56, alpha: 1), width: 3))
            layers.append(line("gn-tracks-live", tracks, predicate: NSPredicate(format: "live == YES"),
                               color: UIColor.systemRed, width: 3.5))
        }
        if let legs = sources[.routeLegs] {
            layers.append(line("gn-route-active-casing", legs, predicate: NSPredicate(format: "state == %@", "active"),
                               color: UIColor.white, width: 9))
            // Per-leg grade colours: manual routes are "none"; auto-routes carry green/yellow/red.
            layers.append(line("gn-route-none", legs, predicate: NSPredicate(format: "grade == %@", "none"),
                               color: UIColor.systemBlue, width: 4))
            layers.append(line("gn-route-green", legs, predicate: NSPredicate(format: "grade == %@", "green"),
                               color: UIColor.systemGreen, width: 4))
            layers.append(line("gn-route-yellow", legs, predicate: NSPredicate(format: "grade == %@", "yellow"),
                               color: UIColor.systemYellow, width: 4))
            layers.append(line("gn-route-red", legs, predicate: NSPredicate(format: "grade == %@", "red"),
                               color: UIColor.systemRed, width: 4))
            let done: MLNLineStyleLayer = line("gn-route-done", legs, predicate: NSPredicate(format: "state == %@", "done"),
                                               color: UIColor.gray, width: 4)
            done.lineOpacity = NSExpression(forConstantValue: NSNumber(value: 0.8))
            layers.append(done)
            let editing: MLNLineStyleLayer = line("gn-route-editing", legs, predicate: NSPredicate(format: "editing == YES"),
                                                  color: UIColor.systemOrange, width: 3)
            editing.lineDashPattern = NSExpression(forConstantValue: [NSNumber(value: 2), NSNumber(value: 1.5)])
            layers.append(editing)
        }
        if let points = sources[.routePoints] {
            layers.append(circle("gn-route-points", points, predicate: nil, color: UIColor.white, radius: 5,
                                 stroke: UIColor.systemBlue, strokeWidth: 2))
            layers.append(circle("gn-route-next", points, predicate: NSPredicate(format: "next == YES"),
                                 color: UIColor.systemPink, radius: 8, stroke: UIColor.white, strokeWidth: 2))
        }
        if let direct = sources[.direct] {
            let directLine: MLNLineStyleLayer = line("gn-direct", direct, predicate: nil, color: UIColor.systemPink, width: 3)
            directLine.lineDashPattern = NSExpression(forConstantValue: [NSNumber(value: 3), NSNumber(value: 2)])
            layers.append(directLine)
        }
        if let waypoints = sources[.waypoints] {
            layers.append(circle("gn-waypoints", waypoints, predicate: nil, color: UIColor.systemOrange, radius: 6,
                                 stroke: UIColor.white, strokeWidth: 2))
            layers.append(circle("gn-waypoints-target", waypoints, predicate: NSPredicate(format: "target == YES"),
                                 color: UIColor.systemPink, radius: 8, stroke: UIColor.white, strokeWidth: 2))
            layers.append(circle("gn-waypoints-selected", waypoints, predicate: NSPredicate(format: "selected == YES"),
                                 color: UIColor.clear, radius: 12, stroke: UIColor.systemOrange, strokeWidth: 3))
        }
        return Built(sources: sources, layers: layers)
    }

    static func line(_ id: String, _ source: MLNSource, predicate: NSPredicate?, color: UIColor,
                     width: Double) -> MLNLineStyleLayer {
        let layer = MLNLineStyleLayer(identifier: id, source: source)
        layer.predicate = predicate
        layer.lineColor = NSExpression(forConstantValue: color)
        layer.lineWidth = NSExpression(forConstantValue: NSNumber(value: width))
        layer.lineCap = NSExpression(forConstantValue: "round")
        layer.lineJoin = NSExpression(forConstantValue: "round")
        return layer
    }

    static func circle(_ id: String, _ source: MLNSource, predicate: NSPredicate?, color: UIColor, radius: Double,
                       stroke: UIColor, strokeWidth: Double) -> MLNCircleStyleLayer {
        let layer = MLNCircleStyleLayer(identifier: id, source: source)
        layer.predicate = predicate
        layer.circleColor = NSExpression(forConstantValue: color)
        layer.circleRadius = NSExpression(forConstantValue: NSNumber(value: radius))
        layer.circleStrokeColor = NSExpression(forConstantValue: stroke)
        layer.circleStrokeWidth = NSExpression(forConstantValue: NSNumber(value: strokeWidth))
        return layer
    }

    /// Replaces a source's shape with GeoJSON. Returns an error text on failure.
    static func setShape(_ data: Data, on source: MLNShapeSource) -> String? {
        do {
            let shape: MLNShape = try MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            source.shape = shape
            return nil
        } catch {
            return "overlay \(source.identifier): \(error.localizedDescription)"
        }
    }

    static func data(for id: SourceID, in overlays: MapOverlays) -> Data {
        switch id {
        case .tracks: return overlays.tracks
        case .routeLegs: return overlays.routeLegs
        case .routePoints: return overlays.routePoints
        case .direct: return overlays.direct
        case .waypoints: return overlays.waypoints
        }
    }
}
