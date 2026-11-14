import Foundation
import NavCore

// MARK: - Boat profiles

extension PersistenceStore {
    static let profileColumns = """
        id, name, draft_m, safety_margin_m, air_draft_m, beam_m, cruising_speed_mps, use_maintained_channels,
        accept_unknown_clearance, is_default, created_at, modified_at
        """

    static func profile(_ r: SQLiteRow) throws -> BoatProfile {
        BoatProfile(id: try r.uuid(0), name: r.text(1), draft: .meters(r.double(2)), safetyMargin: .meters(r.double(3)),
                    airDraft: r.optionalDouble(4).map(Distance.meters), beam: r.optionalDouble(5).map(Distance.meters),
                    cruisingSpeed: r.optionalDouble(6).map(Speed.metersPerSecond),
                    useMaintainedChannels: r.bool(7), acceptUnknownClearance: r.bool(8), isDefault: r.bool(9),
                    createdAt: r.date(10), modifiedAt: r.date(11))
    }

    /// Inserts or updates a profile. Saving with `isDefault == true` makes it the only default; the first
    /// profile saved becomes the default automatically.
    @discardableResult
    public func save(_ profile: BoatProfile) throws(PersistenceError) -> BoatProfile {
        guard profile.draft.meters.isFinite, profile.draft.meters >= 0,
              profile.safetyMargin.meters.isFinite, profile.safetyMargin.meters >= 0 else {
            throw .invalidArgument("boat draft and safety margin must be finite and non-negative")
        }
        let stamp = now()
        return try write {
            var p = profile
            p.modifiedAt = stamp
            if p.isDefault { try db.run("UPDATE boat_profile SET is_default = 0 WHERE is_default = 1 AND id <> ?", [.uuid(p.id)]) }
            let values: [SQLValue] = [.text(p.name), .double(p.draft.meters), .double(p.safetyMargin.meters),
                                      .optional(p.airDraft?.meters), .optional(p.beam?.meters),
                                      .optional(p.cruisingSpeed?.metersPerSecond), .bool(p.useMaintainedChannels),
                                      .bool(p.acceptUnknownClearance), .bool(p.isDefault), .date(stamp)]
            let op: StoreChange.Operation
            if let created = try db.queryFirst("SELECT created_at FROM boat_profile WHERE id = ?", [.uuid(p.id)], map: { $0.date(0) }) {
                p.createdAt = created
                op = .updated
                try db.run("""
                    UPDATE boat_profile SET name = ?, draft_m = ?, safety_margin_m = ?, air_draft_m = ?, beam_m = ?,
                        cruising_speed_mps = ?, use_maintained_channels = ?, accept_unknown_clearance = ?, is_default = ?,
                        modified_at = ? WHERE id = ?
                    """, values + [.uuid(p.id)])
            } else {
                op = .inserted
                try db.run("""
                    INSERT INTO boat_profile (name, draft_m, safety_margin_m, air_draft_m, beam_m, cruising_speed_mps,
                        use_maintained_channels, accept_unknown_clearance, is_default, modified_at, id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, values + [.uuid(p.id), .date(p.createdAt)])
            }
            try ensureDefaultProfile()
            record(.boatProfile, op, ids: [p.id])
            return try db.queryFirst("SELECT \(Self.profileColumns) FROM boat_profile WHERE id = ?", [.uuid(p.id)], map: Self.profile) ?? p
        }
    }

    /// If profiles exist but none is the default, makes the oldest one the default.
    private func ensureDefaultProfile() throws {
        let hasDefault = try db.scalarInt("SELECT count(*) FROM boat_profile WHERE is_default = 1") ?? 0 > 0
        if !hasDefault {
            try db.run("""
                UPDATE boat_profile SET is_default = 1
                WHERE key = (SELECT key FROM boat_profile ORDER BY created_at, key LIMIT 1)
                """)
        }
    }

    public func boatProfile(_ id: UUID) throws(PersistenceError) -> BoatProfile? {
        try read { try db.queryFirst("SELECT \(Self.profileColumns) FROM boat_profile WHERE id = ?", [.uuid(id)], map: Self.profile) }
    }

    /// All profiles, default first, then by name.
    public func boatProfiles() throws(PersistenceError) -> [BoatProfile] {
        try read {
            try db.query("SELECT \(Self.profileColumns) FROM boat_profile ORDER BY is_default DESC, name COLLATE NOCASE", map: Self.profile)
        }
    }

    public func defaultBoatProfile() throws(PersistenceError) -> BoatProfile? {
        try read { try db.queryFirst("SELECT \(Self.profileColumns) FROM boat_profile WHERE is_default = 1", map: Self.profile) }
    }

    /// Makes `id` the only default profile.
    public func setDefaultBoatProfile(_ id: UUID) throws(PersistenceError) {
        let stamp = now()
        try write {
            guard try db.scalarInt("SELECT count(*) FROM boat_profile WHERE id = ?", [.uuid(id)]) ?? 0 > 0 else {
                throw PersistenceError.notFound(.boatProfile, id)
            }
            let previous = try db.query("SELECT id FROM boat_profile WHERE is_default = 1 AND id <> ?", [.uuid(id)]) { try $0.uuid(0) }
            try db.run("UPDATE boat_profile SET is_default = 0, modified_at = ? WHERE is_default = 1 AND id <> ?", [.date(stamp), .uuid(id)])
            try db.run("UPDATE boat_profile SET is_default = 1, modified_at = ? WHERE id = ?", [.date(stamp), .uuid(id)])
            record(.boatProfile, .updated, ids: previous + [id])
        }
    }

    /// Deletes a profile; if it was the default, the oldest remaining profile becomes the default.
    @discardableResult
    public func deleteBoatProfile(_ id: UUID) throws(PersistenceError) -> Bool {
        try write {
            try db.run("DELETE FROM boat_profile WHERE id = ?", [.uuid(id)])
            let deleted = db.changes > 0
            if deleted {
                try ensureDefaultProfile()
                record(.boatProfile, .deleted, ids: [id])
            }
            return deleted
        }
    }
}

// MARK: - Settings

extension PersistenceStore {
    private static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Wrapper so that top-level scalars (and nil) encode the same on every platform's JSONEncoder.
    private struct Box<V: Codable>: Codable { var v: V }

    /// The stored value, or the key's default when unset (or unreadable, e.g. written by a newer app with
    /// a different type).
    public func setting<V>(_ key: SettingKey<V>) throws(PersistenceError) -> V {
        let data = try read { try db.queryFirst("SELECT value FROM setting WHERE name = ?", [.text(key.name)]) { $0.blob(0) } ?? nil }
        guard let data, let box = try? Self.jsonDecoder().decode(Box<V>.self, from: data) else { return key.defaultValue }
        return box.v
    }

    /// Stores a value. Setting a value equal to the current one does not emit a change.
    public func setSetting<V>(_ key: SettingKey<V>, to value: V) throws(PersistenceError) {
        let data: Data
        do { data = try Self.jsonEncoder().encode(Box(v: value)) } catch {
            throw .invalidArgument("setting \(key.name) could not be encoded: \(error)")
        }
        let stamp = now()
        try write {
            let old = try db.queryFirst("SELECT value FROM setting WHERE name = ?", [.text(key.name)]) { $0.blob(0) } ?? nil
            guard old != data else { return }
            try db.run("""
                INSERT INTO setting (name, value, modified_at) VALUES (?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET value = excluded.value, modified_at = excluded.modified_at
                """, [.text(key.name), .blob(data), .date(stamp)])
            record(.setting, old == nil ? .inserted : .updated, keys: [key.name])
        }
    }

    /// Removes a stored value so the default applies again.
    public func resetSetting<V>(_ key: SettingKey<V>) throws(PersistenceError) {
        try write {
            try db.run("DELETE FROM setting WHERE name = ?", [.text(key.name)])
            if db.changes > 0 { record(.setting, .deleted, keys: [key.name]) }
        }
    }

    /// Names of all stored settings.
    public func storedSettingNames() throws(PersistenceError) -> [String] {
        try read { try db.query("SELECT name FROM setting ORDER BY name") { $0.text(0) } }
    }
}

// MARK: - Anchor watch

extension PersistenceStore {
    /// The active anchor watch, if any.
    public func anchorWatch() throws(PersistenceError) -> AnchorWatchState? {
        let data = try read { try db.queryFirst("SELECT state FROM anchor_watch WHERE singleton = 1") { $0.blob(0) } ?? nil }
        guard let data else { return nil }
        do { return try Self.jsonDecoder().decode(AnchorWatchState.self, from: data) } catch {
            throw .decoding("anchor watch: \(error)")
        }
    }

    /// Stores (replaces) the active anchor watch. Call on start, on every state change and periodically.
    public func saveAnchorWatch(_ state: AnchorWatchState) throws(PersistenceError) {
        let data: Data
        do { data = try Self.jsonEncoder().encode(state) } catch { throw .invalidArgument("anchor watch: \(error)") }
        let stamp = now()
        try write {
            let existed = try db.scalarInt("SELECT count(*) FROM anchor_watch") ?? 0 > 0
            try db.run("""
                INSERT INTO anchor_watch (singleton, state, modified_at) VALUES (1, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET state = excluded.state, modified_at = excluded.modified_at
                """, [.blob(data), .date(stamp)])
            record(.anchorWatch, existed ? .updated : .inserted)
        }
    }

    /// Ends the anchor watch.
    public func clearAnchorWatch() throws(PersistenceError) {
        try write {
            try db.run("DELETE FROM anchor_watch")
            if db.changes > 0 { record(.anchorWatch, .deleted) }
        }
    }
}
