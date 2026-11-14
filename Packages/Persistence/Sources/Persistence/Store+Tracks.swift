import Foundation
import NavCore

/// Result of appending points to a track.
public struct TrackAppendResult: Sendable, Hashable {
    /// The track with updated statistics.
    public var track: Track
    /// Points stored.
    public var appended: Int
    /// Points dropped because their coordinate was invalid (NaN or out of range).
    public var rejected: Int
}

extension PersistenceStore {
    static let trackColumns = """
        t.id, t.name, t.notes, t.color, t.state, t.start_time, t.end_time, t.point_count, t.segment_count,
        t.distance_m, t.duration_s, t.max_speed, t.min_lat, t.max_lat, t.min_lon, t.max_lon, t.created_at, t.modified_at, t.key
        """

    static func track(_ r: SQLiteRow) throws -> Track {
        let bounds: BoundingBox? = r.isNull(12) ? nil
            : BoundingBox(south: r.double(12), west: r.double(14), north: r.double(13), east: r.double(15))
        let stats = TrackStatistics(pointCount: Int(r.int(7)), segmentCount: Int(r.int(8)),
                                    distance: .meters(r.double(9)), duration: r.double(10),
                                    maxSpeed: r.optionalDouble(11).map { Speed(metersPerSecond: $0) }, bounds: bounds)
        return Track(id: try r.uuid(0), name: r.text(1), notes: r.text(2),
                     color: TrackColor(hex: r.text(3)) ?? .defaultTrack,
                     state: Track.State(rawValue: Int(r.int(4))) ?? .finished,
                     startDate: r.optionalDate(5), endDate: r.optionalDate(6), statistics: stats,
                     createdAt: r.date(16), modifiedAt: r.date(17))
    }

    func trackRow(_ id: UUID) throws -> (key: Int64, track: Track)? {
        try db.queryFirst("SELECT \(Self.trackColumns) FROM track t WHERE t.id = ?", [.uuid(id)]) { (key: $0.int(18), track: try Self.track($0)) }
    }

    func requireTrack(_ id: UUID) throws -> (key: Int64, track: Track) {
        guard let t = try trackRow(id) else { throw PersistenceError.notFound(.track, id) }
        return t
    }

    func insertTrack(_ track: Track, stamp: Date) throws -> Int64 {
        try db.run("""
            INSERT INTO track (id, name, notes, color, state, start_time, created_at, modified_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.uuid(track.id), .text(track.name), .text(track.notes), .text(track.color.hex),
                  .int(Int64(track.state.rawValue)), .optionalDate(track.startDate), .date(track.createdAt), .date(stamp)])
        return db.lastInsertRowID
    }

    func writeStatistics(key: Int64, _ acc: TrackStatisticsAccumulator, stamp: Date) throws {
        let s = acc.stats
        let b = s.bounds
        try db.run("""
            UPDATE track SET start_time = ?, end_time = ?, point_count = ?, segment_count = ?, distance_m = ?,
                duration_s = ?, max_speed = ?, min_lat = ?, max_lat = ?, min_lon = ?, max_lon = ?, modified_at = ?
            WHERE key = ?
            """, [.optionalDate(acc.startDate), .optionalDate(acc.endDate), .int(Int64(s.pointCount)),
                  .int(Int64(s.segmentCount)), .double(s.distance.meters), .double(s.duration),
                  .optional(s.maxSpeed?.metersPerSecond), .optional(b?.south), .optional(b?.north),
                  .optional(b?.west), .optional(b?.east), .date(stamp), .int(key)])
    }

    /// Appends points to the track with key `key`; returns (appended, rejected).
    func appendPoints(key: Int64, current: Track, _ points: [TrackPoint], newSegment: Bool, stamp: Date) throws -> (Int, Int) {
        // Round-trip through the storage encoding so incremental statistics use exactly the stored values
        // (speeds are stored as Float32) and therefore match a later full recompute.
        let valid = try TrackPointCodec.decode(TrackPointCodec.encode(points.filter { $0.coordinate.isValid }))
        let rejected = points.count - valid.count
        guard !valid.isEmpty else { return (0, rejected) }

        let lastChunk = try db.queryFirst("""
            SELECT seq, segment, point_count, data FROM track_chunk WHERE track_key = ? ORDER BY seq DESC LIMIT 1
            """, [.int(key)]) { (seq: $0.int(0), segment: Int($0.int(1)), count: Int($0.int(2)), data: $0.blob(3) ?? Data()) }

        var lastPoint: TrackPoint?
        if let lc = lastChunk, lc.data.count >= TrackPointCodec.bytesPerPoint {
            lastPoint = try TrackPointCodec.decode(lc.data.suffix(TrackPointCodec.bytesPerPoint)).first
        }
        var segment = lastChunk?.segment ?? 0
        if newSegment, lastChunk != nil { segment += 1 }

        var last: (point: TrackPoint, segment: Int)?
        if let lastPoint, let lc = lastChunk { last = (lastPoint, lc.segment) }
        var acc = TrackStatisticsAccumulator(stats: current.statistics, startDate: current.startDate,
                                             endDate: current.endDate, last: last)
        for p in valid { acc.add(p, segment: segment) }

        var remaining = valid[...]
        var nextSeq = (lastChunk?.seq ?? -1) + 1
        if let lc = lastChunk, lc.segment == segment, lc.count < TrackPointCodec.chunkCapacity {
            let take = min(TrackPointCodec.chunkCapacity - lc.count, remaining.count)
            var data = lc.data
            data.append(TrackPointCodec.encode(remaining.prefix(take)))
            try db.run("UPDATE track_chunk SET point_count = ?, data = ? WHERE track_key = ? AND seq = ?",
                       [.int(Int64(lc.count + take)), .blob(data), .int(key), .int(lc.seq)])
            remaining = remaining.dropFirst(take)
        }
        while !remaining.isEmpty {
            let part = remaining.prefix(TrackPointCodec.chunkCapacity)
            try db.run("INSERT INTO track_chunk (track_key, seq, segment, point_count, data) VALUES (?, ?, ?, ?, ?)",
                       [.int(key), .int(nextSeq), .int(Int64(segment)), .int(Int64(part.count)), .blob(TrackPointCodec.encode(part))])
            nextSeq += 1
            remaining = remaining.dropFirst(part.count)
        }
        try writeStatistics(key: key, acc, stamp: stamp)
        return (valid.count, rejected)
    }

    // MARK: Recording

    /// Starts a new track. With `recording: true` (the default) the track is marked as being recorded until
    /// ``finishRecording(_:)``; if the app is terminated first it is reported in ``OpenReport/interruptedRecordings``.
    @discardableResult
    public func startTrack(name: String, notes: String = "", color: TrackColor = .defaultTrack,
                           recording: Bool = true, id: UUID = UUID()) throws(PersistenceError) -> Track {
        let stamp = now()
        return try write {
            let t = Track(id: id, name: name, notes: notes, color: color, state: recording ? .recording : .finished,
                          createdAt: stamp, modifiedAt: stamp)
            _ = try insertTrack(t, stamp: stamp)
            record(.track, .inserted, ids: [id])
            return t
        }
    }

    /// Appends a batch of points (in time order) in one transaction, updating statistics incrementally.
    /// Each committed batch survives app termination. Points with invalid coordinates are dropped and counted.
    /// - Parameter startNewSegment: begin a new segment (e.g. after GPS loss). The first append after
    ///   ``resumeRecording(_:)`` always starts a new segment.
    @discardableResult
    public func appendTrackPoints(_ points: [TrackPoint], to id: UUID,
                                  startNewSegment: Bool = false) throws(PersistenceError) -> TrackAppendResult {
        let stamp = now()
        let forceBreak = segmentBreakPending.contains(id)
        let result: TrackAppendResult = try write {
            let (key, current) = try requireTrack(id)
            let (n, rejected) = try appendPoints(key: key, current: current, points,
                                                 newSegment: startNewSegment || forceBreak, stamp: stamp)
            record(.track, .updated, ids: [id])
            return TrackAppendResult(track: try requireTrack(id).track, appended: n, rejected: rejected)
        }
        if forceBreak && result.appended > 0 { segmentBreakPending.remove(id) }
        return result
    }

    /// Tracks currently marked as recording (after launch: recordings interrupted by termination).
    public func recordingTracks() throws(PersistenceError) -> [Track] {
        try read { try db.query("SELECT \(Self.trackColumns) FROM track t WHERE t.state <> 0 ORDER BY t.created_at", map: Self.track) }
    }

    /// Continues an interrupted recording. The next appended point starts a new segment, so the gap while the
    /// app was not running is not counted as distance or time.
    @discardableResult
    public func resumeRecording(_ id: UUID) throws(PersistenceError) -> Track {
        let stamp = now()
        let t: Track = try write {
            let (key, t) = try requireTrack(id)
            if t.state != .recording {
                try db.run("UPDATE track SET state = 1, modified_at = ? WHERE key = ?", [.date(stamp), .int(key)])
                record(.track, .updated, ids: [id])
            }
            return try requireTrack(id).track
        }
        if t.statistics.pointCount > 0 { segmentBreakPending.insert(id) }
        return t
    }

    /// Ends a recording (or closes an interrupted one): recomputes statistics from every stored point and
    /// marks the track finished.
    @discardableResult
    public func finishRecording(_ id: UUID) throws(PersistenceError) -> Track {
        let stamp = now()
        segmentBreakPending.remove(id)
        return try write {
            let (key, _) = try requireTrack(id)
            try recompute(key: key, stamp: stamp)
            try db.run("UPDATE track SET state = 0, modified_at = ? WHERE key = ?", [.date(stamp), .int(key)])
            record(.track, .updated, ids: [id])
            return try requireTrack(id).track
        }
    }

    /// Recomputes a track's statistics from its stored points.
    @discardableResult
    public func recomputeStatistics(_ id: UUID) throws(PersistenceError) -> Track {
        let stamp = now()
        return try write {
            let (key, _) = try requireTrack(id)
            try recompute(key: key, stamp: stamp)
            record(.track, .updated, ids: [id])
            return try requireTrack(id).track
        }
    }

    private func recompute(key: Int64, stamp: Date) throws {
        var acc = TrackStatisticsAccumulator()
        try forEachChunk(key: key) { segment, points in
            for p in points { acc.add(p, segment: segment) }
        }
        try writeStatistics(key: key, acc, stamp: stamp)
    }

    func forEachChunk(key: Int64, _ body: (Int, [TrackPoint]) throws -> Void) throws {
        let chunks = try db.query("SELECT segment, data FROM track_chunk WHERE track_key = ? ORDER BY seq", [.int(key)]) {
            (Int($0.int(0)), $0.blob(1) ?? Data())
        }
        for (segment, data) in chunks { try body(segment, try TrackPointCodec.decode(data)) }
    }

    // MARK: Whole tracks

    /// Stores a complete track (e.g. from an import) in one transaction. Statistics are computed from the points.
    @discardableResult
    public func saveTrack(name: String, notes: String = "", color: TrackColor = .defaultTrack,
                          segments: [[TrackPoint]], id: UUID = UUID()) throws(PersistenceError) -> Track {
        let stamp = now()
        return try write {
            let shell = Track(id: id, name: name, notes: notes, color: color, state: .finished, createdAt: stamp, modifiedAt: stamp)
            let key = try insertTrack(shell, stamp: stamp)
            var current = shell
            var first = true
            for seg in segments where !seg.isEmpty {
                let (n, _) = try appendPoints(key: key, current: current, seg, newSegment: !first, stamp: stamp)
                if n > 0 { first = false }
                current = try requireTrack(id).track
            }
            record(.track, .inserted, ids: [id])
            return try requireTrack(id).track
        }
    }

    /// Updates a track's name, notes and colour (points and statistics are not touched).
    @discardableResult
    public func updateTrackDetails(_ track: Track) throws(PersistenceError) -> Track {
        let stamp = now()
        return try write {
            try db.run("UPDATE track SET name = ?, notes = ?, color = ?, modified_at = ? WHERE id = ?",
                       [.text(track.name), .text(track.notes), .text(track.color.hex), .date(stamp), .uuid(track.id)])
            guard db.changes > 0 else { throw PersistenceError.notFound(.track, track.id) }
            record(.track, .updated, ids: [track.id])
            return try requireTrack(track.id).track
        }
    }

    public func track(_ id: UUID) throws(PersistenceError) -> Track? {
        try read { try trackRow(id)?.track }
    }

    /// All tracks (metadata and statistics only), newest first.
    public func tracks() throws(PersistenceError) -> [Track] {
        try read {
            try db.query("SELECT \(Self.trackColumns) FROM track t ORDER BY coalesce(t.start_time, t.created_at) DESC", map: Self.track)
        }
    }

    /// Tracks whose bounds intersect `box`, newest first.
    public func tracks(in box: BoundingBox) throws(PersistenceError) -> [Track] {
        try read {
            var out: [Track] = []
            var seen = Set<UUID>()
            for b in Self.split(box) {
                let v: [SQLValue] = [.double(b.south), .double(b.north), .double(b.west), .double(b.east)]
                let rows: [Track]
                switch spatialIndex {
                case .rtree:
                    rows = try db.query("""
                        SELECT \(Self.trackColumns) FROM track_rtree r JOIN track t ON t.key = r.key
                        WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4
                          AND t.max_lat >= ?1 AND t.min_lat <= ?2 AND t.max_lon >= ?3 AND t.min_lon <= ?4
                        """, v, map: Self.track)
                case .rangeIndex:
                    rows = try db.query("""
                        SELECT \(Self.trackColumns) FROM track t
                        WHERE t.min_lat <= ?2 AND t.max_lat >= ?1 AND t.max_lon >= ?3 AND t.min_lon <= ?4
                        """, v, map: Self.track)
                }
                for t in rows where seen.insert(t.id).inserted { out.append(t) }
            }
            return out.sorted { ($0.startDate ?? $0.createdAt) > ($1.startDate ?? $1.createdAt) }
        }
    }

    /// Every point of a track, grouped by segment, in recorded order.
    public func trackPoints(_ id: UUID) throws(PersistenceError) -> [[TrackPoint]] {
        try readTransaction {
            let (key, _) = try requireTrack(id)
            var segments: [[TrackPoint]] = []
            var lastSegment: Int?
            try forEachChunk(key: key) { segment, points in
                if segment != lastSegment {
                    segments.append([])
                    lastSegment = segment
                }
                segments[segments.count - 1].append(contentsOf: points)
            }
            return segments
        }
    }

    /// Track geometry for drawing, one polyline per segment, simplified to `detail`.
    public func trackGeometry(_ id: UUID, detail: GeometryDetail) throws(PersistenceError) -> [[Coordinate]] {
        let segments = try trackPoints(id).map { $0.map(\.coordinate) }
        switch detail {
        case .full: return segments
        case .everyNth(let n): return segments.map { Simplify.everyNth($0, n) }
        default:
            let tol = detail.toleranceMeters ?? 0
            return segments.map { Simplify.douglasPeucker($0, toleranceMeters: tol) }
        }
    }

    @discardableResult
    public func deleteTrack(_ id: UUID) throws(PersistenceError) -> Bool {
        segmentBreakPending.remove(id)
        return try write {
            try db.run("DELETE FROM track WHERE id = ?", [.uuid(id)])
            let deleted = db.changes > 0
            if deleted { record(.track, .deleted, ids: [id]) }
            return deleted
        }
    }
}
