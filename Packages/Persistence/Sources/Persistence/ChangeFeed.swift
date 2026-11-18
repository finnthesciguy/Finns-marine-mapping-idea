import Foundation

/// One committed change. Delivered only after the transaction that made it has committed.
public struct StoreChange: Sendable, Hashable {
    public enum Operation: Sendable, Hashable {
        case inserted, updated, deleted
    }

    public var kind: EntityKind
    public var operation: Operation
    /// Affected entity ids (empty for settings and anchor watch).
    public var ids: [UUID]
    /// Affected setting names (settings only).
    public var keys: [String]

    public init(kind: EntityKind, operation: Operation, ids: [UUID] = [], keys: [String] = []) {
        self.kind = kind
        self.operation = operation
        self.ids = ids
        self.keys = keys
    }
}

/// Fan-out of committed changes to any number of `AsyncStream` subscribers, one channel per entity kind.
///
/// Thread-safe so subscription is `nonisolated` on the store (a SwiftUI model can subscribe from any context).
final class ChangeFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [EntityKind: [UUID: AsyncStream<StoreChange>.Continuation]] = [:]
    private let bufferLimit: Int

    init(bufferLimit: Int = 512) { self.bufferLimit = bufferLimit }

    func stream(for kinds: Set<EntityKind>) -> AsyncStream<StoreChange> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<StoreChange>.makeStream(bufferingPolicy: .bufferingNewest(bufferLimit))
        lock.lock()
        for k in kinds { subscribers[k, default: [:]][token] = continuation }
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            for k in kinds { self.subscribers[k]?[token] = nil }
            self.lock.unlock()
        }
        return stream
    }

    func publish(_ changes: [StoreChange]) {
        guard !changes.isEmpty else { return }
        lock.lock()
        let targets = changes.map { (change: $0, subs: Array((subscribers[$0.kind] ?? [:]).values)) }
        lock.unlock()
        for t in targets { for c in t.subs { c.yield(t.change) } }
    }

    func finishAll() {
        lock.lock()
        let all = subscribers.values.flatMap { $0.values }
        subscribers.removeAll()
        lock.unlock()
        for c in all { c.finish() }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(subscribers.values.flatMap { $0.keys }).count
    }
}
