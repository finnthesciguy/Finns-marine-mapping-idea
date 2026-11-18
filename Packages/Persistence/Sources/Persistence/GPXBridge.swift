import Foundation
import GPXKit
import NavCore

/// Pure conversions between store entities and GPXKit types.
public enum GPXBridge {
    public static func gpxWaypoint(_ w: Waypoint) -> GPXWaypoint {
        GPXWaypoint(coordinate: w.coordinate, time: w.createdAt, name: w.name,
                    description: w.notes.isEmpty ? nil : w.notes, symbol: w.symbol)
    }

    /// A waypoint from a GPX `<wpt>`. Missing names become "Waypoint n" (1-based `index`).
    public static func waypoint(from g: GPXWaypoint, index: Int, now: Date) -> Waypoint {
        let name = nonEmpty(g.name) ?? "Waypoint \(index + 1)"
        let notes = [nonEmpty(g.description), nonEmpty(g.comment)].compactMap { $0 }.joined(separator: "\n")
        return Waypoint(name: name, coordinate: g.coordinate, symbol: nonEmpty(g.symbol), notes: notes,
                        createdAt: g.time ?? now, modifiedAt: now)
    }

    public static func gpxRoute(_ r: Route) -> GPXRoute {
        GPXRoute(name: r.name, description: r.notes.isEmpty ? nil : r.notes,
                 type: r.metadata == nil ? nil : "auto-route",
                 points: r.points.map { GPXWaypoint(coordinate: $0.coordinate, name: $0.name) })
    }

    public static func route(from g: GPXRoute, index: Int, now: Date) -> Route {
        Route(name: nonEmpty(g.name) ?? "Route \(index + 1)",
              notes: [nonEmpty(g.description), nonEmpty(g.comment)].compactMap { $0 }.joined(separator: "\n"),
              points: g.points.map { RoutePoint(coordinate: $0.coordinate, name: nonEmpty($0.name)) },
              createdAt: now, modifiedAt: now)
    }

    public static func gpxTrack(_ t: Track, segments: [[TrackPoint]]) -> GPXTrack {
        GPXTrack(name: t.name, description: t.notes.isEmpty ? nil : t.notes,
                 segments: segments.map { seg in
                     GPXTrackSegment(points: seg.map {
                         GPXWaypoint(coordinate: $0.coordinate, time: $0.timestamp, speed: $0.speed, course: $0.course)
                     })
                 })
    }

    public static func trackSegments(from g: GPXTrack) -> [[TrackPoint]] {
        g.segments.map { seg in
            seg.points.map { TrackPoint(timestamp: $0.time, coordinate: $0.coordinate, speed: $0.speed, course: $0.course) }
        }.filter { !$0.isEmpty }
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func normalizedName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Rules for spotting items in a GPX file that the user already has.
public struct GPXDuplicateRules: Sendable, Hashable {
    /// Waypoints (and route points) closer than this, metres, with the same name (case-insensitive,
    /// trimmed) are duplicates.
    public var positionTolerance: Double
    /// Tracks starting within this many seconds of an existing track with the same point count are duplicates.
    public var trackStartTolerance: TimeInterval

    public init(positionTolerance: Double = 5, trackStartTolerance: TimeInterval = 1) {
        self.positionTolerance = positionTolerance
        self.trackStartTolerance = trackStartTolerance
    }
}

/// What to do with one imported item.
public enum GPXImportDecision: Sendable, Hashable {
    /// Store it as a new item.
    case importNew
    /// Leave it out.
    case skip
    /// Overwrite the existing duplicate (keeps the existing id).
    case replaceExisting
}

/// Why an item was judged a duplicate.
public enum GPXDuplicate: Sendable, Hashable {
    /// Matches an item already in the store; `distance` is the position difference in metres (0 for tracks).
    case existing(id: UUID, name: String, distance: Double)
    /// Matches an earlier item in the same file (index into the same candidate list).
    case earlierInFile(index: Int)
}

/// One item proposed for import, with its duplicate finding and the decision to apply.
public struct GPXImportCandidate<Value: Sendable & Hashable>: Sendable, Hashable {
    public var value: Value
    public var duplicate: GPXDuplicate?
    /// Defaults to ``GPXImportDecision/importNew``, or ``GPXImportDecision/skip`` for duplicates. The caller
    /// may change it (e.g. after asking the user) before ``PersistenceStore/applyGPXImport(_:)``.
    public var decision: GPXImportDecision

    public init(value: Value, duplicate: GPXDuplicate?) {
        self.value = value
        self.duplicate = duplicate
        self.decision = duplicate == nil ? .importNew : .skip
    }
}

/// An imported track: details plus points by segment.
public struct ImportedTrack: Sendable, Hashable {
    public var name: String
    public var notes: String
    public var segments: [[TrackPoint]]
    public var pointCount: Int { segments.reduce(0) { $0 + $1.count } }
    public var startDate: Date? { segments.lazy.flatMap { $0 }.compactMap(\.timestamp).min() }
}

/// The result of examining a GPX document against the store. Nothing has been written yet.
public struct GPXImportPlan: Sendable, Hashable {
    public var waypoints: [GPXImportCandidate<Waypoint>]
    public var routes: [GPXImportCandidate<Route>]
    public var tracks: [GPXImportCandidate<ImportedTrack>]
    /// Problems that did not stop the import (invalid coordinates dropped, empty tracks…).
    public var warnings: [String]

    public var duplicateCount: Int {
        waypoints.filter { $0.duplicate != nil }.count + routes.filter { $0.duplicate != nil }.count
            + tracks.filter { $0.duplicate != nil }.count
    }

    /// Sets every duplicate's decision at once.
    public mutating func setDecisionForAllDuplicates(_ d: GPXImportDecision) {
        for i in waypoints.indices where waypoints[i].duplicate != nil { waypoints[i].decision = d }
        for i in routes.indices where routes[i].duplicate != nil { routes[i].decision = d }
        for i in tracks.indices where tracks[i].duplicate != nil { tracks[i].decision = d }
    }
}

/// What ``PersistenceStore/applyGPXImport(_:)`` did.
public struct GPXImportResult: Sendable, Hashable {
    public var insertedWaypoints: [UUID] = []
    public var replacedWaypoints: [UUID] = []
    public var insertedRoutes: [UUID] = []
    public var replacedRoutes: [UUID] = []
    public var insertedTracks: [UUID] = []
    public var replacedTracks: [UUID] = []
    public var skipped = 0
}

extension PersistenceStore {
    /// Examines a GPX document: converts its contents and finds duplicates of stored items and within the
    /// file, without writing anything. Present ``GPXImportPlan/duplicateCount`` to the user, adjust decisions,
    /// then call ``applyGPXImport(_:)``.
    public func planGPXImport(_ document: GPXDocument,
                              rules: GPXDuplicateRules = GPXDuplicateRules()) throws(PersistenceError) -> GPXImportPlan {
        let stamp = now()
        return try readTransaction {
            var warnings: [String] = []
            var wpts: [GPXImportCandidate<Waypoint>] = []
            for (i, g) in document.waypoints.enumerated() {
                guard g.coordinate.isValid else {
                    warnings.append("waypoint \(i + 1) '\(g.name ?? "")' has an invalid position and was left out")
                    continue
                }
                let w = GPXBridge.waypoint(from: g, index: i, now: stamp)
                var dup: GPXDuplicate?
                if let (e, d) = try nearestSameNamedWaypoint(w, tolerance: rules.positionTolerance) {
                    dup = .existing(id: e.id, name: e.name, distance: d)
                } else if let j = wpts.firstIndex(where: { Self.sameWaypoint($0.value, w, rules) }) {
                    dup = .earlierInFile(index: j)
                }
                wpts.append(GPXImportCandidate(value: w, duplicate: dup))
            }

            var rtes: [GPXImportCandidate<Route>] = []
            let existingRoutes = document.routes.isEmpty ? [] : try fetchRoutes(where: "", [], order: "w.key")
            for (i, g) in document.routes.enumerated() {
                var r = GPXBridge.route(from: g, index: i, now: stamp)
                let before = r.points.count
                r.points.removeAll { !$0.coordinate.isValid }
                if r.points.count != before {
                    warnings.append("route '\(r.name)': \(before - r.points.count) invalid points left out")
                }
                var dup: GPXDuplicate?
                if let e = existingRoutes.first(where: { Self.sameRoute($0, r, rules) }) {
                    dup = .existing(id: e.id, name: e.name, distance: 0)
                } else if let j = rtes.firstIndex(where: { Self.sameRoute($0.value, r, rules) }) {
                    dup = .earlierInFile(index: j)
                }
                rtes.append(GPXImportCandidate(value: r, duplicate: dup))
            }

            var trks: [GPXImportCandidate<ImportedTrack>] = []
            let existingTracks = document.tracks.isEmpty ? []
                : try db.query("SELECT \(Self.trackColumns) FROM track t", map: Self.track)
            for (i, g) in document.tracks.enumerated() {
                var segs = GPXBridge.trackSegments(from: g)
                let before = segs.reduce(0) { $0 + $1.count }
                segs = segs.map { $0.filter { $0.coordinate.isValid } }.filter { !$0.isEmpty }
                let t = ImportedTrack(name: GPXBridge.nonEmpty(g.name) ?? "Track \(i + 1)",
                                      notes: GPXBridge.nonEmpty(g.description) ?? "", segments: segs)
                if t.pointCount != before { warnings.append("track '\(t.name)': \(before - t.pointCount) invalid points left out") }
                if t.pointCount == 0 {
                    warnings.append("track '\(t.name)' has no points and was left out")
                    continue
                }
                var dup: GPXDuplicate?
                if let e = existingTracks.first(where: { Self.sameTrack($0, t, rules) }) {
                    dup = .existing(id: e.id, name: e.name, distance: 0)
                } else if let j = trks.firstIndex(where: { Self.sameImportedTrack($0.value, t, rules) }) {
                    dup = .earlierInFile(index: j)
                }
                trks.append(GPXImportCandidate(value: t, duplicate: dup))
            }
            return GPXImportPlan(waypoints: wpts, routes: rtes, tracks: trks, warnings: warnings)
        }
    }

    /// Writes a plan in one transaction, following each candidate's decision. A `replaceExisting` decision on
    /// an item that is not a duplicate of a stored item is treated as `importNew`.
    @discardableResult
    public func applyGPXImport(_ plan: GPXImportPlan) throws(PersistenceError) -> GPXImportResult {
        let stamp = now()
        return try write {
            var result = GPXImportResult()
            for c in plan.waypoints {
                switch (c.decision, c.duplicate) {
                case (.skip, _): result.skipped += 1
                case (.replaceExisting, .existing(let id, _, _)?):
                    var w = c.value
                    w.id = id
                    _ = try upsertWaypoint(w, stamp: stamp)
                    result.replacedWaypoints.append(id)
                default:
                    _ = try upsertWaypoint(c.value, stamp: stamp)
                    result.insertedWaypoints.append(c.value.id)
                }
            }
            for c in plan.routes {
                switch (c.decision, c.duplicate) {
                case (.skip, _): result.skipped += 1
                case (.replaceExisting, .existing(let id, _, _)?):
                    var r = c.value
                    r.id = id
                    _ = try save(r)
                    result.replacedRoutes.append(id)
                default:
                    _ = try save(c.value)
                    result.insertedRoutes.append(c.value.id)
                }
            }
            for c in plan.tracks {
                switch (c.decision, c.duplicate) {
                case (.skip, _): result.skipped += 1
                case (.replaceExisting, .existing(let id, _, _)?):
                    _ = try deleteTrack(id)
                    _ = try saveTrack(name: c.value.name, notes: c.value.notes, segments: c.value.segments, id: id)
                    result.replacedTracks.append(id)
                default:
                    let t = try saveTrack(name: c.value.name, notes: c.value.notes, segments: c.value.segments)
                    result.insertedTracks.append(t.id)
                }
            }
            if !result.insertedWaypoints.isEmpty { record(.waypoint, .inserted, ids: result.insertedWaypoints) }
            if !result.replacedWaypoints.isEmpty { record(.waypoint, .updated, ids: result.replacedWaypoints) }
            return result
        }
    }

    /// Builds a GPX document from stored items. `nil` selects all items of that kind; `[]` selects none.
    public func exportGPX(waypoints waypointIDs: [UUID]? = nil, routes routeIDs: [UUID]? = nil,
                          tracks trackIDs: [UUID]? = nil, creator: String = "Gulf Nav") throws(PersistenceError) -> GPXDocument {
        var ws: [Waypoint] = [], rs: [Route] = [], ts: [Track] = []
        if let waypointIDs {
            for id in waypointIDs { if let w = try waypoint(id) { ws.append(w) } }
        } else {
            ws = try waypoints(order: .name)
        }
        if let routeIDs {
            for id in routeIDs { if let r = try route(id) { rs.append(r) } }
        } else {
            rs = try routes(order: .name)
        }
        if let trackIDs {
            for id in trackIDs { if let t = try track(id) { ts.append(t) } }
        } else {
            ts = try tracks().reversed()
        }
        var gtracks: [GPXTrack] = []
        for t in ts { gtracks.append(GPXBridge.gpxTrack(t, segments: try trackPoints(t.id))) }
        return GPXDocument(creator: creator, metadata: GPXMetadata(time: now()),
                           waypoints: ws.map(GPXBridge.gpxWaypoint), routes: rs.map(GPXBridge.gpxRoute), tracks: gtracks)
    }

    // MARK: Duplicate rules

    private func nearestSameNamedWaypoint(_ w: Waypoint, tolerance: Double) throws -> (Waypoint, Double)? {
        let box = BoundingBox(south: w.coordinate.latitude, west: w.coordinate.longitude,
                              north: w.coordinate.latitude, east: w.coordinate.longitude).expanded(byMeters: tolerance * 1.5 + 1)
        let name = GPXBridge.normalizedName(w.name)
        let near = try db.query("""
            SELECT \(Self.waypointColumns) FROM waypoint w WHERE w.lat BETWEEN ? AND ? AND w.lon BETWEEN ? AND ?
            """, [.double(box.south), .double(box.north), .double(box.west), .double(box.east)], map: Self.waypoint)
        return near.filter { GPXBridge.normalizedName($0.name) == name }
            .map { ($0, Geodesy.distance(from: $0.coordinate, to: w.coordinate)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }
    }

    static func sameWaypoint(_ a: Waypoint, _ b: Waypoint, _ rules: GPXDuplicateRules) -> Bool {
        GPXBridge.normalizedName(a.name) == GPXBridge.normalizedName(b.name)
            && Geodesy.distance(from: a.coordinate, to: b.coordinate) <= rules.positionTolerance
    }

    static func sameRoute(_ a: Route, _ b: Route, _ rules: GPXDuplicateRules) -> Bool {
        GPXBridge.normalizedName(a.name) == GPXBridge.normalizedName(b.name)
            && a.points.count == b.points.count
            && zip(a.points, b.points).allSatisfy {
                Geodesy.distance(from: $0.coordinate, to: $1.coordinate) <= rules.positionTolerance
            }
    }

    static func sameTrack(_ a: Track, _ b: ImportedTrack, _ rules: GPXDuplicateRules) -> Bool {
        guard a.statistics.pointCount == b.pointCount else { return false }
        if let s1 = a.startDate, let s2 = b.startDate {
            return abs(s1.timeIntervalSince(s2)) <= rules.trackStartTolerance
        }
        return a.startDate == nil && b.startDate == nil
            && GPXBridge.normalizedName(a.name) == GPXBridge.normalizedName(b.name)
    }

    static func sameImportedTrack(_ a: ImportedTrack, _ b: ImportedTrack, _ rules: GPXDuplicateRules) -> Bool {
        guard a.pointCount == b.pointCount else { return false }
        if let s1 = a.startDate, let s2 = b.startDate { return abs(s1.timeIntervalSince(s2)) <= rules.trackStartTolerance }
        return a.segments == b.segments
    }
}
