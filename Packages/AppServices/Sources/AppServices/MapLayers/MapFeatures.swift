import Foundation
import NavCore
import Persistence

/// Minimal GeoJSON writer (RFC 7946: positions are `[longitude, latitude]`).
public enum GeoJSON {
    public enum Geometry: Sendable, Equatable {
        case point(Coordinate)
        case lineString([Coordinate])
        case multiLineString([[Coordinate]])
    }

    public enum Value: Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
    }

    public struct Feature: Sendable, Equatable {
        public var geometry: Geometry
        public var properties: [String: Value]

        public init(geometry: Geometry, properties: [String: Value] = [:]) {
            self.geometry = geometry
            self.properties = properties
        }
    }

    /// UTF-8 JSON of a FeatureCollection (keys sorted, so output is stable for tests).
    public static func featureCollection(_ features: [Feature]) -> Data {
        var out: String = "{\"type\":\"FeatureCollection\",\"features\":["
        for (index, feature) in features.enumerated() {
            if index > 0 { out += "," }
            out += "{\"type\":\"Feature\",\"geometry\":" + geometryJSON(feature.geometry) + ",\"properties\":{"
            let keys: [String] = feature.properties.keys.sorted()
            for (i, key) in keys.enumerated() {
                if i > 0 { out += "," }
                out += quoted(key) + ":" + valueJSON(feature.properties[key] ?? .bool(false))
            }
            out += "}}"
        }
        out += "]}"
        return Data(out.utf8)
    }

    static func geometryJSON(_ geometry: Geometry) -> String {
        switch geometry {
        case .point(let c):
            return "{\"type\":\"Point\",\"coordinates\":" + position(c) + "}"
        case .lineString(let line):
            return "{\"type\":\"LineString\",\"coordinates\":" + positions(line) + "}"
        case .multiLineString(let lines):
            return "{\"type\":\"MultiLineString\",\"coordinates\":[" + lines.map(positions).joined(separator: ",") + "]}"
        }
    }

    static func position(_ c: Coordinate) -> String {
        "[" + number(c.longitude, digits: 7) + "," + number(c.latitude, digits: 7) + "]"
    }

    static func positions(_ line: [Coordinate]) -> String {
        "[" + line.map(position).joined(separator: ",") + "]"
    }

    static func number(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "0" }
        var text: String = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text
    }

    static func valueJSON(_ value: Value) -> String {
        switch value {
        case .string(let s): return quoted(s)
        case .number(let d): return number(d, digits: 6)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    static func quoted(_ s: String) -> String {
        var out: String = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex: String = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// How one route is drawn. Built from a stored `Route`; per-leg grades come from its `AutoRouteInfo`
/// (auto-routes) and are `nil` for manual routes, so the map's per-grade line layers need no change when
/// auto-routing arrives.
public struct RouteDisplay: Sendable, Equatable {
    public struct Leg: Sendable, Equatable {
        public var index: Int
        public var from: Coordinate
        public var to: Coordinate
        /// `green` / `yellow` / `red` (or another grade string), nil for a manual route.
        public var grade: String?
        public var reasonCodes: [String]
    }

    public var id: UUID
    public var name: String
    public var points: [RoutePoint]
    public var legs: [Leg]
    /// Present for auto-routes.
    public var summary: AutoRouteInfo.Summary?
    public var routingPackDataDate: Date?

    public init(route: Route) {
        id = route.id
        name = route.name
        points = route.points
        let info: AutoRouteInfo? = route.metadata?.autoRouteInfo
        var gradeByLeg: [Int: AutoRouteInfo.Leg] = [:]
        for leg in info?.legs ?? [] { gradeByLeg[leg.index] = leg }
        var legs: [Leg] = []
        if route.points.count >= 2 {
            for i in 0..<(route.points.count - 1) {
                let graded: AutoRouteInfo.Leg? = gradeByLeg[i]
                legs.append(Leg(index: i, from: route.points[i].coordinate, to: route.points[i + 1].coordinate,
                                grade: graded?.grade.rawValue, reasonCodes: graded?.reasonCodes ?? []))
            }
        }
        self.legs = legs
        summary = info?.summary
        routingPackDataDate = info?.routingPackDataDate
    }

    public var length: Double {
        legs.reduce(0) { $0 + Geodesy.distance(from: $1.from, to: $1.to) }
    }

    /// Display name of point `index`: its own name, or "WP n".
    public func pointName(_ index: Int) -> String {
        guard index >= 0, index < points.count else { return "" }
        if let name = points[index].name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "WP \(index + 1)"
    }
}

/// GeoJSON for the map's overlay sources. Property names used by the layers are listed with each builder.
public enum MapFeatures {
    /// Waypoints as points. Properties: `id`, `name`, `symbol`, `selected` (bool), `target` (bool).
    public static func waypoints(_ waypoints: [Waypoint], selected: UUID?, target: UUID?) -> Data {
        var features: [GeoJSON.Feature] = []
        for w in waypoints where w.coordinate.isValid {
            features.append(GeoJSON.Feature(geometry: .point(w.coordinate), properties: [
                "id": .string(w.id.uuidString),
                "name": .string(w.name),
                "symbol": .string(w.symbol ?? ""),
                "selected": .bool(w.id == selected),
                "target": .bool(w.id == target),
            ]))
        }
        return GeoJSON.featureCollection(features)
    }

    /// One LineString per leg of each route. Properties: `route` (id), `leg` (index), `grade`
    /// (`none`/`green`/`yellow`/`red`), `state` (`ahead`/`active`/`done`/`plan` for a route not being
    /// followed), `editing` (bool).
    public static func routeLegs(_ routes: [RouteDisplay], activeRouteID: UUID?, activeLeg: Int?,
                                 editingRouteID: UUID? = nil) -> Data {
        var features: [GeoJSON.Feature] = []
        for route in routes {
            for leg in route.legs {
                var state: String = "plan"
                if route.id == activeRouteID, let activeLeg {
                    if leg.index < activeLeg { state = "done" } else if leg.index == activeLeg { state = "active" } else { state = "ahead" }
                }
                features.append(GeoJSON.Feature(geometry: .lineString([leg.from, leg.to]), properties: [
                    "route": .string(route.id.uuidString),
                    "leg": .number(Double(leg.index)),
                    "grade": .string(leg.grade ?? "none"),
                    "state": .string(state),
                    "editing": .bool(route.id == editingRouteID),
                ]))
            }
        }
        return GeoJSON.featureCollection(features)
    }

    /// Route points (leg markers). Properties: `route`, `index`, `name`, `kind` (`start`/`turn`/`end`),
    /// `next` (bool: the point being steered to).
    public static func routePoints(_ routes: [RouteDisplay], activeRouteID: UUID?, nextPointIndex: Int?) -> Data {
        var features: [GeoJSON.Feature] = []
        for route in routes {
            for (index, point) in route.points.enumerated() where point.coordinate.isValid {
                let kind: String = index == 0 ? "start" : (index == route.points.count - 1 ? "end" : "turn")
                features.append(GeoJSON.Feature(geometry: .point(point.coordinate), properties: [
                    "route": .string(route.id.uuidString),
                    "index": .number(Double(index)),
                    "name": .string(route.pointName(index)),
                    "kind": .string(kind),
                    "next": .bool(route.id == activeRouteID && index == nextPointIndex),
                ]))
            }
        }
        return GeoJSON.featureCollection(features)
    }

    /// Tracks as MultiLineStrings (one line per segment; segments with fewer than two points are left
    /// out). Properties: `id`, `color` (`#RRGGBB`), `live` (bool).
    public static func tracks(_ tracks: [TrackLine]) -> Data {
        var features: [GeoJSON.Feature] = []
        for track in tracks {
            let lines: [[Coordinate]] = track.segments.filter { $0.count >= 2 }
            if lines.isEmpty { continue }
            features.append(GeoJSON.Feature(geometry: .multiLineString(lines), properties: [
                "id": .string(track.id.uuidString),
                "color": .string(track.color.hex),
                "live": .bool(track.isLive),
            ]))
        }
        return GeoJSON.featureCollection(features)
    }

    /// The direct-to line from the boat to the target (empty collection when not navigating direct-to).
    public static func directTo(_ line: [Coordinate]?) -> Data {
        guard let line, line.count == 2 else { return GeoJSON.featureCollection([]) }
        return GeoJSON.featureCollection([GeoJSON.Feature(geometry: .lineString(line), properties: ["kind": .string("direct")])])
    }
}

/// A track's geometry as drawn.
public struct TrackLine: Sendable, Equatable {
    public var id: UUID
    public var color: TrackColor
    public var segments: [[Coordinate]]
    public var isLive: Bool

    public init(id: UUID, color: TrackColor = .defaultTrack, segments: [[Coordinate]], isLive: Bool) {
        self.id = id
        self.color = color
        self.segments = segments
        self.isLive = isLive
    }
}

/// Which simplification to ask Persistence for when drawing a saved track.
public enum TrackDetailPolicy {
    /// Douglas–Peucker with a tolerance of about one screen pixel at the map's zoom (rounded down to a
    /// whole zoom level so small zoom changes reuse the same geometry).
    public static func detail(forZoom zoom: Double, latitude: Double) -> GeometryDetail {
        if zoom >= 17 { return .full }
        return .zoom(bucket(forZoom: zoom), latitude: latitude, pixels: 1)
    }

    public static func bucket(forZoom zoom: Double) -> Double {
        guard zoom.isFinite else { return 10 }
        return Double(Int(max(0, min(zoom, 22)).rounded(.down)))
    }
}

/// Everything the map's overlay sources show, as GeoJSON per source plus feature counts. Equatable, so the
/// map view only replaces a source's shape when its data changed.
public struct MapOverlays: Sendable, Equatable {
    public struct Counts: Sendable, Equatable {
        public var waypoints: Int = 0
        public var routeLegs: Int = 0
        public var routePoints: Int = 0
        public var tracks: Int = 0
        public var direct: Int = 0

        public init() {}
    }

    public var waypoints: Data
    public var routeLegs: Data
    public var routePoints: Data
    public var tracks: Data
    public var direct: Data
    public var counts: Counts

    public static let empty: MapOverlays = MapOverlays(waypoints: GeoJSON.featureCollection([]),
                                                       routeLegs: GeoJSON.featureCollection([]),
                                                       routePoints: GeoJSON.featureCollection([]),
                                                       tracks: GeoJSON.featureCollection([]),
                                                       direct: GeoJSON.featureCollection([]), counts: Counts())

    /// `waypoints:2,routeLegs:2,routePoints:3,tracks:1,direct:0` (reported in the map's status).
    public var summary: String {
        "waypoints:\(counts.waypoints),routeLegs:\(counts.routeLegs),routePoints:\(counts.routePoints),"
            + "tracks:\(counts.tracks),direct:\(counts.direct)"
    }

    /// - Parameters:
    ///   - routes: routes to draw (the one being followed, the one being edited, and any the user chose to show).
    ///   - nextPointIndex: index in the followed route of the point being steered to.
    ///   - tracks: saved tracks shown plus the live recording.
    public static func make(waypoints: [Waypoint], selectedWaypoint: UUID?, targetWaypoint: UUID?,
                            routes: [RouteDisplay], activeRouteID: UUID?, nextPointIndex: Int?, editingRouteID: UUID?,
                            tracks: [TrackLine], directLine: [Coordinate]?) -> MapOverlays {
        var counts = Counts()
        counts.waypoints = waypoints.filter { $0.coordinate.isValid }.count
        counts.routeLegs = routes.reduce(0) { $0 + $1.legs.count }
        counts.routePoints = routes.reduce(0) { $0 + $1.points.filter { $0.coordinate.isValid }.count }
        counts.tracks = tracks.filter { line in line.segments.contains { $0.count >= 2 } }.count
        counts.direct = (directLine?.count == 2) ? 1 : 0
        // Leg i runs from point i to point i + 1, so steering to point n means leg n - 1 is active.
        let activeLeg: Int? = nextPointIndex.map { $0 - 1 }
        return MapOverlays(
            waypoints: MapFeatures.waypoints(waypoints, selected: selectedWaypoint, target: targetWaypoint),
            routeLegs: MapFeatures.routeLegs(routes, activeRouteID: activeRouteID, activeLeg: activeLeg,
                                             editingRouteID: editingRouteID),
            routePoints: MapFeatures.routePoints(routes, activeRouteID: activeRouteID, nextPointIndex: nextPointIndex),
            tracks: MapFeatures.tracks(tracks),
            direct: MapFeatures.directTo(directLine),
            counts: counts)
    }
}
