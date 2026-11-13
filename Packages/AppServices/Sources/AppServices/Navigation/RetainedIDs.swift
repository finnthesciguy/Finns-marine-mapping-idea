import Foundation

/// A set of ids chosen by the user (the selected waypoint, routes and tracks shown on the chart) that must
/// survive list reloads which may be stale.
///
/// Lists are reloaded asynchronously from the store's change feed, and a reload can finish after the user
/// chose an item that the reload did not yet see (for example: a waypoint is saved and selected while a
/// reload triggered earlier, by a settings write, is still running). Such a reload must not drop the new
/// choice. So each id remembers the reload revision current when it was added, and `reconcile` only removes
/// ids that a reload which *started after* they were added did not find.
public struct RetainedIDs: Sendable, Equatable {
    public private(set) var ids: Set<UUID> = []
    private var addedAt: [UUID: Int] = [:]

    public init() {}

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }
    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    /// The only id, for single selections.
    public var single: UUID? { ids.count == 1 ? ids.first : nil }

    /// - Parameter revision: the number of reloads started so far (`UserDataModel.reloadRevision`).
    public mutating func insert(_ id: UUID, revision: Int) {
        ids.insert(id)
        addedAt[id] = revision
    }

    public mutating func remove(_ id: UUID) {
        ids.remove(id)
        addedAt[id] = nil
    }

    public mutating func removeAll() {
        ids = []
        addedAt = [:]
    }

    /// Replaces the contents with one id (or none).
    public mutating func set(_ id: UUID?, revision: Int) {
        removeAll()
        if let id { insert(id, revision: revision) }
    }

    /// Drops ids missing from `present`, a list loaded by the reload that was started as revision
    /// `reloadStartedAt`, but only ids added before that reload started. Returns true when something was removed.
    @discardableResult
    public mutating func reconcile(present: Set<UUID>, reloadStartedAt: Int) -> Bool {
        var removed = false
        for id in ids where !present.contains(id) {
            let added: Int = addedAt[id] ?? Int.min
            if reloadStartedAt > added {
                remove(id)
                removed = true
            }
        }
        return removed
    }
}
