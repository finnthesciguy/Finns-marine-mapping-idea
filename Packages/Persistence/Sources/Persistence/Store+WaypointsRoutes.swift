import Foundation
import NavCore

// MARK: - Waypoints

extension PersistenceStore {
    static let waypointColumns = "w.id, w.name, w.lat, w.lon, w.symbol, w.notes, w.created_at, w.modified_at"

    static func waypoint(_ r: SQLiteRow) throws -> Waypoint {
        Waypoint(id: try r.uuid(0), name: r.text(1), coordinate: Coordinate(latitude: r.double(2), longitude: r.double(3)),
                 symbol: r.optionalText(4), notes: r.text(5), createdAt: r.date(6), modifiedAt: r.date(7))
    }

    func upsertWaypoint(_ w: Waypoint, stamp: Date) throws -> (Waypoint, StoreChange.Operation) {
        try Self.validate(w.coordinate, "waypoint '\(w.name)'")
        let existingCreated = try db.queryFirst("SELECT created_at FROM waypoint WHERE id = ?", [.uuid(w.id)]) { $0.date(0) }
        var out = w
        out.modifiedAt = stamp
        if let existingCreated {
            out.createdAt = existingCreated
            try db.run("""
                UPDATE waypoint SET name = ?, lat = ?, lon = ?, symbol = ?, notes = ?, modified_at = ? WHERE id = ?
                """, [.text(w.name), .double(w.coordinate.latitude), .double(w.coordinate.longitude),
                      .optional(w.symbol), .text(w.notes), .date(stamp), .uuid(w.id)])
            return (out, .updated)
        }
        try db.run("""
            INSERT INTO waypoint (id, name, lat, lon, symbol, notes, created_at, modified_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.uuid(w.id), .text(w.name), .double(w.coordinate.latitude), .double(w.coordinate.longitude),
                  .optional(w.symbol), .text(w.notes), .date(w.createdAt), .date(stamp)])
        return (out, .inserted)
    }

    /// Inserts or updates a waypoint (matched by id). `createdAt` of an existing waypoint is preserved and
    /// `modifiedAt` is stamped with the current time. Returns the waypoint as stored.
    @discardableResult
    public func save(_ waypoint: Waypoint) throws(PersistenceError) -> Waypoint {
        let stamp = now()
        return try write {
            let (w, op) = try upsertWaypoint(waypoint, stamp: stamp)
            record(.waypoint, op, ids: [w.id])
            return w
        }
    }

    /// Saves several waypoints in one transaction (all or none).
    @discardableResult
    public func save(_ waypoints: [Waypoint]) throws(PersistenceError) -> [Waypoint] {
        let stamp = now()
        return try write {
            var out: [Waypoint] = []
            var inserted: [UUID] = [], updated: [UUID] = []
            for w in waypoints {
                let (s, op) = try upsertWaypoint(w, stamp: stamp)
                out.append(s)
                if op == .inserted { inserted.append(s.id) } else { updated.append(s.id) }
            }
            if !inserted.isEmpty { record(.waypoint, .inserted, ids: inserted) }
            if !updated.isEmpty { record(.waypoint, .updated, ids: updated) }
            return out
        }
    }

    public func waypoint(_ id: UUID) throws(PersistenceError) -> Waypoint? {
        try read { try db.queryFirst("SELECT \(Self.waypointColumns) FROM waypoint w WHERE w.id = ?", [.uuid(id)], map: Self.waypoint) }
    }

    public func waypoints(order: ListOrder = .name) throws(PersistenceError) -> [Waypoint] {
        try read { try db.query("SELECT \(Self.waypointColumns) FROM waypoint w ORDER BY \(Self.orderClause(order))", map: Self.waypoint) }
    }

    public func waypointCount() throws(PersistenceError) -> Int {
        try read { Int(try db.scalarInt("SELECT count(*) FROM waypoint") ?? 0) }
    }

    /// Waypoints inside `box` (edges inclusive), ordered by name. A box with `west > east` spans the antimeridian.
    public func waypoints(in box: BoundingBox) throws(PersistenceError) -> [Waypoint] {
        try read {
            var out: [Waypoint] = []
            var seen = Set<UUID>()
            for b in Self.split(box) {
                let rows: [Waypoint]
                let exact: [SQLValue] = [.double(b.south), .double(b.north), .double(b.west), .double(b.east)]
                switch spatialIndex {
                case .rtree:
                    rows = try db.query("""
                        SELECT \(Self.waypointColumns) FROM waypoint_rtree r JOIN waypoint w ON w.key = r.key
                        WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4
                          AND w.lat BETWEEN ?1 AND ?2 AND w.lon BETWEEN ?3 AND ?4
                        """, exact, map: Self.waypoint)
                case .rangeIndex:
                    rows = try db.query("""
                        SELECT \(Self.waypointColumns) FROM waypoint w
                        WHERE w.lat BETWEEN ?1 AND ?2 AND w.lon BETWEEN ?3 AND ?4
                        """, exact, map: Self.waypoint)
                }
                for w in rows where seen.insert(w.id).inserted { out.append(w) }
            }
            return out.sorted { ($0.name.lowercased(), $0.createdAt) < ($1.name.lowercased(), $1.createdAt) }
        }
    }

    /// Deletes a waypoint. Returns false if it did not exist.
    @discardableResult
    public func deleteWaypoint(_ id: UUID) throws(PersistenceError) -> Bool {
        try deleteWaypoints([id]) > 0
    }

    /// Deletes waypoints; returns how many existed.
    @discardableResult
    public func deleteWaypoints(_ ids: [UUID]) throws(PersistenceError) -> Int {
        try write {
            var deleted: [UUID] = []
            for id in ids {
                try db.run("DELETE FROM waypoint WHERE id = ?", [.uuid(id)])
                if db.changes > 0 { deleted.append(id) }
            }
            if !deleted.isEmpty { record(.waypoint, .deleted, ids: deleted) }
            return deleted.count
        }
    }

    static func orderClause(_ order: ListOrder, prefix: String = "w") -> String {
        switch order {
        case .name: return "\(prefix).name COLLATE NOCASE, \(prefix).created_at"
        case .newestFirst: return "\(prefix).created_at DESC"
        case .recentlyModified: return "\(prefix).modified_at DESC"
        }
    }

    /// Splits an antimeridian-spanning box into two ordinary boxes.
    static func split(_ b: BoundingBox) -> [BoundingBox] {
        guard b.crossesAntimeridian else { return [b] }
        return [BoundingBox(south: b.south, west: b.west, north: b.north, east: 180),
                BoundingBox(south: b.south, west: -180, north: b.north, east: b.east)]
    }
}

// MARK: - Routes

extension PersistenceStore {
    func loadRoute(key: Int64, row r: SQLiteRow) throws -> Route {
        let metadata: RouteMetadata? = r.isNull(3) ? nil : RouteMetadata(version: Int(r.int(3)), json: r.blob(4) ?? Data())
        return Route(id: try r.uuid(0), name: r.text(1), notes: r.text(2), points: [], metadata: metadata,
                     createdAt: r.date(5), modifiedAt: r.date(6))
    }

    func routePoints(key: Int64) throws -> [RoutePoint] {
        try db.query("SELECT lat, lon, name FROM route_point WHERE route_key = ? ORDER BY position", [.int(key)]) {
            RoutePoint(coordinate: Coordinate(latitude: $0.double(0), longitude: $0.double(1)), name: $0.optionalText(2))
        }
    }

    func fetchRoutes(where clause: String, _ bindings: [SQLValue], order: String) throws -> [Route] {
        let heads = try db.query("""
            SELECT w.id, w.name, w.notes, w.metadata_version, w.metadata, w.created_at, w.modified_at, w.key
            FROM route w \(clause) ORDER BY \(order)
            """, bindings) { r in (key: r.int(7), route: try loadRoute(key: r.int(7), row: r)) }
        return try heads.map { h in
            var route = h.route
            route.points = try routePoints(key: h.key)
            return route
        }
    }

    /// Inserts or replaces a route (matched by id), including its points in order.
    @discardableResult
    public func save(_ route: Route) throws(PersistenceError) -> Route {
        for (i, p) in route.points.enumerated() { try Self.validate(p.coordinate, "route point \(i)") }
        let stamp = now()
        return try write {
            var out = route
            out.modifiedAt = stamp
            let key: Int64
            let op: StoreChange.Operation
            if let existing = try db.queryFirst("SELECT key, created_at FROM route WHERE id = ?", [.uuid(route.id)], map: { ($0.int(0), $0.date(1)) }) {
                key = existing.0
                out.createdAt = existing.1
                op = .updated
                try db.run("""
                    UPDATE route SET name = ?, notes = ?, metadata_version = ?, metadata = ?, modified_at = ? WHERE key = ?
                    """, [.text(route.name), .text(route.notes), route.metadata.map { .int(Int64($0.version)) } ?? .null,
                          .optional(route.metadata?.json), .date(stamp), .int(key)])
                try db.run("DELETE FROM route_point WHERE route_key = ?", [.int(key)])
            } else {
                op = .inserted
                try db.run("""
                    INSERT INTO route (id, name, notes, metadata_version, metadata, created_at, modified_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.uuid(route.id), .text(route.name), .text(route.notes),
                          route.metadata.map { .int(Int64($0.version)) } ?? .null, .optional(route.metadata?.json),
                          .date(route.createdAt), .date(stamp)])
                key = db.lastInsertRowID
            }
            for (i, p) in route.points.enumerated() {
                try db.run("INSERT INTO route_point (route_key, position, lat, lon, name) VALUES (?, ?, ?, ?, ?)",
                           [.int(key), .int(Int64(i)), .double(p.coordinate.latitude), .double(p.coordinate.longitude), .optional(p.name)])
            }
            record(.route, op, ids: [route.id])
            return out
        }
    }

    public func route(_ id: UUID) throws(PersistenceError) -> Route? {
        try readTransaction { try fetchRoutes(where: "WHERE w.id = ?", [.uuid(id)], order: "w.key").first }
    }

    /// All routes with their points.
    public func routes(order: ListOrder = .name) throws(PersistenceError) -> [Route] {
        try readTransaction { try fetchRoutes(where: "", [], order: Self.orderClause(order)) }
    }

    @discardableResult
    public func deleteRoute(_ id: UUID) throws(PersistenceError) -> Bool {
        try write {
            try db.run("DELETE FROM route WHERE id = ?", [.uuid(id)])
            let deleted = db.changes > 0
            if deleted { record(.route, .deleted, ids: [id]) }
            return deleted
        }
    }
}
