import Foundation

/// Fans one producer out to any number of `AsyncStream` consumers.
///
/// Thread-safe (a lock guards the subscriber table), so producers may call `yield` from any thread,
/// including CoreLocation delegate callbacks. Each subscriber gets its own stream; a stream that is
/// dropped or cancelled unsubscribes itself.
public final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latestValue: Element?
    private var isFinished = false
    private let bufferSize: Int

    /// - Parameter bufferSize: how many undelivered values each subscriber keeps (newest win).
    public init(bufferSize: Int = 64) {
        self.bufferSize = max(1, bufferSize)
    }

    /// The most recent value yielded, if any.
    public var latest: Element? {
        lock.lock()
        defer { lock.unlock() }
        return latestValue
    }

    /// Number of live subscribers (for tests and diagnostics).
    public var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    /// A new stream of values. With `replayLatest`, the most recent value (if any) is delivered first.
    public func stream(replayLatest: Bool = true) -> AsyncStream<Element> {
        let pair = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(bufferSize))
        let stream: AsyncStream<Element> = pair.stream
        let continuation: AsyncStream<Element>.Continuation = pair.continuation
        let id = UUID()

        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        let replay: Element? = replayLatest ? latestValue : nil
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        if let replay {
            continuation.yield(replay)
        }
        return stream
    }

    /// Delivers a value to every subscriber.
    public func yield(_ value: Element) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        latestValue = value
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(value)
        }
    }

    /// Ends every stream; later subscribers get an already-finished stream.
    public func finish() {
        lock.lock()
        isFinished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
