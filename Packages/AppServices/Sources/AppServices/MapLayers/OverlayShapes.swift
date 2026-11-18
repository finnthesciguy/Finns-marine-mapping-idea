import Foundation
import NavCore

/// The overlay GeoJSON written by `MapFeatures`, read back into plain values, plus the drawing styles of the
/// MapLibre overlay layers (`App/Sources/Map/MapOverlayLayers.swift`) as data.
///
/// MapLibre draws the GeoJSON directly through shape sources and style layers. Map engines without a GeoJSON
/// style source (MapKit, used by the Mac Catalyst build because MapLibre Native 7.0.0 ships no Mac Catalyst
/// slice) need the features and the per-feature style decisions themselves; both live here so they are
/// tested on Linux and both maps draw the same thing.

/// A GeoJSON property value as `MapFeatures` writes it.
public enum OverlayValue: Sendable, Equatable, Decodable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool first: JSONDecoder does not decode `true` as a number or a number as a Bool.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

/// One feature: a point or one or more lines, with its properties.
public struct OverlayShape: Sendable, Equatable {
    public enum Geometry: Sendable, Equatable {
        case point(Coordinate)
        /// A LineString is one line; a MultiLineString several.
        case lines([[Coordinate]])
    }

    public var geometry: Geometry
    public var properties: [String: OverlayValue]

    public init(geometry: Geometry, properties: [String: OverlayValue] = [:]) {
        self.geometry = geometry
        self.properties = properties
    }

    /// A boolean property (false when absent or not a boolean).
    public func flag(_ key: String) -> Bool {
        if case .bool(let value)? = properties[key] { return value }
        return false
    }

    /// A string property, or nil.
    public func text(_ key: String) -> String? {
        if case .string(let value)? = properties[key] { return value }
        return nil
    }
}

public enum OverlayShapesError: Error, Equatable, Sendable {
    case notAFeatureCollection
    case badGeometry(String)
}

public enum OverlayShapes {
    /// Parses a GeoJSON FeatureCollection (Point, LineString and MultiLineString geometries; positions are
    /// `[longitude, latitude]`). Features of other geometry types are skipped.
    public static func parse(_ data: Data) throws -> [OverlayShape] {
        let collection: FeatureCollectionJSON
        do {
            collection = try JSONDecoder().decode(FeatureCollectionJSON.self, from: data)
        } catch {
            throw OverlayShapesError.notAFeatureCollection
        }
        guard collection.type == "FeatureCollection" else { throw OverlayShapesError.notAFeatureCollection }
        var shapes: [OverlayShape] = []
        for feature in collection.features {
            let properties: [String: OverlayValue] = feature.properties ?? [:]
            switch feature.geometry.type {
            case "Point":
                shapes.append(OverlayShape(geometry: .point(try position(feature.geometry.coordinates)),
                                           properties: properties))
            case "LineString":
                shapes.append(OverlayShape(geometry: .lines([try line(feature.geometry.coordinates)]),
                                           properties: properties))
            case "MultiLineString":
                guard case .array(let parts) = feature.geometry.coordinates else {
                    throw OverlayShapesError.badGeometry("MultiLineString")
                }
                var lines: [[Coordinate]] = []
                for part in parts {
                    lines.append(try line(part))
                }
                shapes.append(OverlayShape(geometry: .lines(lines), properties: properties))
            default:
                continue
            }
        }
        return shapes
    }

    static func position(_ value: NestedNumbers) throws -> Coordinate {
        guard case .array(let items) = value, items.count >= 2,
              case .number(let longitude) = items[0], case .number(let latitude) = items[1] else {
            throw OverlayShapesError.badGeometry("position")
        }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    static func line(_ value: NestedNumbers) throws -> [Coordinate] {
        guard case .array(let items) = value else { throw OverlayShapesError.badGeometry("line") }
        var out: [Coordinate] = []
        for item in items {
            out.append(try position(item))
        }
        return out
    }

    /// Arbitrarily nested arrays of numbers (GeoJSON `coordinates`).
    indirect enum NestedNumbers: Decodable, Equatable {
        case number(Double)
        case array([NestedNumbers])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .array(try container.decode([NestedNumbers].self))
            }
        }
    }

    struct GeometryJSON: Decodable {
        var type: String
        var coordinates: NestedNumbers
    }

    struct FeatureJSON: Decodable {
        var geometry: GeometryJSON
        var properties: [String: OverlayValue]?
    }

    struct FeatureCollectionJSON: Decodable {
        var type: String
        var features: [FeatureJSON]
    }
}

// MARK: - Styles

/// Colours of the overlay layers. Engines map these to their platform colours (`system…` are the UIKit
/// dynamic system colours MapLibre's layers use).
public enum OverlayColor: String, Sendable, Equatable, CaseIterable {
    case savedTrack
    case systemRed
    case systemBlue
    case systemGreen
    case systemYellow
    case systemOrange
    case systemPink
    case gray
    case white
    case clear

    /// RGBA for `savedTrack`, the one colour that is not a system colour.
    public static let savedTrackRGBA: (red: Double, green: Double, blue: Double, alpha: Double) = (0.82, 0.13, 0.56, 1)
}

/// The overlay sources, with the identifiers the MapLibre style uses.
public enum OverlaySource: String, Sendable, Equatable, CaseIterable {
    case tracks = "gn-tracks"
    case routeLegs = "gn-route-legs"
    case routePoints = "gn-route-points"
    case direct = "gn-direct"
    case planned = "gn-planned"
    case blocked = "gn-blocked"
    case waypoints = "gn-waypoints"

    /// Sources whose features are points (drawn as circles); the others are lines.
    public var isPoints: Bool {
        switch self {
        case .routePoints, .blocked, .waypoints: return true
        case .tracks, .routeLegs, .direct, .planned: return false
        }
    }
}

public struct OverlayLineStyle: Sendable, Equatable {
    public var layerID: String
    public var color: OverlayColor
    /// Line width in screen points.
    public var width: Double
    /// Dash pattern in multiples of the line width (MapLibre's `line-dasharray`), nil for solid.
    public var dash: [Double]?
    public var opacity: Double

    public init(layerID: String, color: OverlayColor, width: Double, dash: [Double]? = nil, opacity: Double = 1) {
        self.layerID = layerID
        self.color = color
        self.width = width
        self.dash = dash
        self.opacity = opacity
    }
}

public struct OverlayCircleStyle: Sendable, Equatable {
    public var layerID: String
    public var fill: OverlayColor
    /// Radius in screen points.
    public var radius: Double
    public var stroke: OverlayColor
    public var strokeWidth: Double

    public init(layerID: String, fill: OverlayColor, radius: Double, stroke: OverlayColor, strokeWidth: Double) {
        self.layerID = layerID
        self.fill = fill
        self.radius = radius
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }
}

/// Lines of one layer, ready to draw. `order` is the layer's position bottom to top over all sources.
public struct StyledOverlayLines: Sendable, Equatable {
    public var order: Int
    public var source: OverlaySource
    public var style: OverlayLineStyle
    public var lines: [[Coordinate]]
}

/// A point with the circles drawn for it, bottom to top.
public struct StyledOverlayPoint: Sendable, Equatable {
    public var source: OverlaySource
    public var coordinate: Coordinate
    public var circles: [OverlayCircleStyle]
    /// The feature's `id` or `name` property, if any (for accessibility labels).
    public var label: String?
}

/// The layer table of `MapOverlayLayers` (MapLibre) as data: which features each layer draws and how.
public enum OverlayStyling {
    struct LineLayer {
        var source: OverlaySource
        var style: OverlayLineStyle
        var matches: @Sendable (OverlayShape) -> Bool
    }

    struct CircleLayer {
        var source: OverlaySource
        var style: OverlayCircleStyle
        var matches: @Sendable (OverlayShape) -> Bool
    }

    static let all: @Sendable (OverlayShape) -> Bool = { _ in true }

    /// Same layers, predicates and values as `MapOverlayLayers.build()`, bottom to top.
    static let lineLayers: [LineLayer] = [
        LineLayer(source: .tracks, style: OverlayLineStyle(layerID: "gn-tracks-saved", color: .savedTrack, width: 3),
                  matches: { !$0.flag("live") }),
        LineLayer(source: .tracks, style: OverlayLineStyle(layerID: "gn-tracks-live", color: .systemRed, width: 3.5),
                  matches: { $0.flag("live") }),
        LineLayer(source: .routeLegs, style: OverlayLineStyle(layerID: "gn-route-active-casing", color: .white, width: 9),
                  matches: { $0.text("state") == "active" }),
        LineLayer(source: .routeLegs, style: OverlayLineStyle(layerID: "gn-route-none", color: .systemBlue, width: 4),
                  matches: { $0.text("grade") == "none" }),
        LineLayer(source: .routeLegs, style: OverlayLineStyle(layerID: "gn-route-green", color: .systemGreen, width: 4),
                  matches: { $0.text("grade") == "green" }),
        LineLayer(source: .routeLegs, style: OverlayLineStyle(layerID: "gn-route-yellow", color: .systemYellow, width: 4),
                  matches: { $0.text("grade") == "yellow" }),
        LineLayer(source: .routeLegs, style: OverlayLineStyle(layerID: "gn-route-red", color: .systemRed, width: 4),
                  matches: { $0.text("grade") == "red" }),
        LineLayer(source: .routeLegs, style: OverlayLineStyle(layerID: "gn-route-done", color: .gray, width: 4, opacity: 0.8),
                  matches: { $0.text("state") == "done" }),
        LineLayer(source: .routeLegs, style: OverlayLineStyle(layerID: "gn-route-editing", color: .systemOrange, width: 3,
                                                              dash: [2, 1.5]),
                  matches: { $0.flag("editing") }),
        LineLayer(source: .direct, style: OverlayLineStyle(layerID: "gn-direct", color: .systemPink, width: 3, dash: [3, 2]),
                  matches: all),
        LineLayer(source: .planned, style: OverlayLineStyle(layerID: "gn-planned-casing", color: .white, width: 9),
                  matches: all),
        LineLayer(source: .planned, style: OverlayLineStyle(layerID: "gn-planned-green", color: .systemGreen, width: 5),
                  matches: { $0.text("grade") == "green" }),
        LineLayer(source: .planned, style: OverlayLineStyle(layerID: "gn-planned-yellow", color: .systemYellow, width: 5),
                  matches: { $0.text("grade") == "yellow" }),
        LineLayer(source: .planned, style: OverlayLineStyle(layerID: "gn-planned-red", color: .systemRed, width: 5),
                  matches: { $0.text("grade") == "red" }),
    ]

    static let circleLayers: [CircleLayer] = [
        CircleLayer(source: .routePoints, style: OverlayCircleStyle(layerID: "gn-route-points", fill: .white, radius: 5,
                                                                    stroke: .systemBlue, strokeWidth: 2),
                    matches: all),
        CircleLayer(source: .routePoints, style: OverlayCircleStyle(layerID: "gn-route-next", fill: .systemPink, radius: 8,
                                                                    stroke: .white, strokeWidth: 2),
                    matches: { $0.flag("next") }),
        CircleLayer(source: .blocked, style: OverlayCircleStyle(layerID: "gn-blocked", fill: .systemRed, radius: 9,
                                                                stroke: .white, strokeWidth: 3),
                    matches: all),
        CircleLayer(source: .waypoints, style: OverlayCircleStyle(layerID: "gn-waypoints", fill: .systemOrange, radius: 6,
                                                                  stroke: .white, strokeWidth: 2),
                    matches: all),
        CircleLayer(source: .waypoints, style: OverlayCircleStyle(layerID: "gn-waypoints-target", fill: .systemPink, radius: 8,
                                                                  stroke: .white, strokeWidth: 2),
                    matches: { $0.flag("target") }),
        CircleLayer(source: .waypoints, style: OverlayCircleStyle(layerID: "gn-waypoints-selected", fill: .clear, radius: 12,
                                                                  stroke: .systemOrange, strokeWidth: 3),
                    matches: { $0.flag("selected") }),
    ]

    /// Number of style layers (lines and circles), as MapLibre's `overlayLayers` count.
    public static var layerCount: Int { lineLayers.count + circleLayers.count }

    /// Line layers drawn for the given shapes of `source`, bottom to top; empty layers are left out.
    public static func lines(_ shapes: [OverlayShape], source: OverlaySource) -> [StyledOverlayLines] {
        var out: [StyledOverlayLines] = []
        for (order, layer) in lineLayers.enumerated() where layer.source == source {
            var lines: [[Coordinate]] = []
            for shape in shapes where layer.matches(shape) {
                if case .lines(let parts) = shape.geometry {
                    for part in parts where part.count >= 2 {
                        lines.append(part)
                    }
                }
            }
            if !lines.isEmpty {
                out.append(StyledOverlayLines(order: order, source: source, style: layer.style, lines: lines))
            }
        }
        return out
    }

    /// Points of `source` with their circles, bottom to top (a point no circle layer matches is left out).
    public static func points(_ shapes: [OverlayShape], source: OverlaySource) -> [StyledOverlayPoint] {
        var out: [StyledOverlayPoint] = []
        for shape in shapes {
            guard case .point(let coordinate) = shape.geometry else { continue }
            var circles: [OverlayCircleStyle] = []
            for layer in circleLayers where layer.source == source && layer.matches(shape) {
                circles.append(layer.style)
            }
            if !circles.isEmpty {
                out.append(StyledOverlayPoint(source: source, coordinate: coordinate, circles: circles,
                                              label: shape.text("name") ?? shape.text("id")))
            }
        }
        return out
    }

    /// Size of the square image that holds all of `circles` (diameter of the largest circle plus its stroke).
    public static func imageSide(for circles: [OverlayCircleStyle]) -> Double {
        var side: Double = 0
        for circle in circles {
            side = max(side, 2 * circle.radius + circle.strokeWidth)
        }
        return side.rounded(.up) + 2
    }
}
