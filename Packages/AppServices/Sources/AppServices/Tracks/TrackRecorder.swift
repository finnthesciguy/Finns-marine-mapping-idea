import Foundation
import NavCore
import Persistence

/// Which fixes become track points.
public struct TrackPointFilter: Sendable, Equatable {
    /// Seconds since the last recorded point before another is taken.
    public var minimumInterval: TimeInterval
    /// Metres moved since the last recorded point before another is taken.
    public var minimumDistance: Double
    /// Fixes less accurate than this (metres) are ignored.
    public var maximumHorizontalAccuracy: Double
    /// While stationary, still record one point this often (so a long stop shows in the track's times).
    public var stationaryInterval: TimeInterval

    public init(minimumInterval: TimeInterval = 5, minimumDistance: Double = 10, maximumHorizontalAccuracy: Double = 50,
                stationaryInterval: TimeInterval = 300) {
        self.minimumInterval = minimumInterval
        self.minimumDistance = minimumDistance
        self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
        self.stationaryInterval = stationaryInterval
    }

    public func accepts(_ fix: Fix, after last: TrackPoint?) -> Bool {
        guard fix.coordinate.isValid else { return false }
        if let accuracy = fix.horizontalAccuracy, accuracy > maximumHorizontalAccuracy { return false }
        guard let last else { return true }
        guard let lastTime = last.timestamp else { return true }
        let dt: TimeInterval = fix.timestamp.timeIntervalSince(lastTime)
        if dt <= 0 { return false }
        if dt >= stationaryInterval { return true }
        if dt < minimumInterval { return false }
        return Geodesy.distance(from: last.coordinate, to: fix.coordinate) >= minimumDistance
    }
}

/// The store operations the recorder needs (Persistence in the app, a fake in tests).
public protocol TrackRecordingStore: Sendable {
    func startRecording(name: String) async throws -> Track
    func append(_ points: [TrackPoint], to id: UUID, startNewSegment: Bool) async throws -> Track
    func finish(_ id: UUID) async throws -> Track
    /// Coordinates of a track's stored points, by segment (to redraw a resumed recording).
    func geometry(_ id: UUID) async throws -> [[Coordinate]]
}

/// `TrackRecordingStore` on a `PersistenceStore`.
public struct PersistenceTrackRecordingStore: TrackRecordingStore {
    public let store: PersistenceStore

    public init(store: PersistenceStore) {
        self.store = store
    }

    public func startRecording(name: String) async throws -> Track {
        try await store.startTrack(name: name)
    }

    public func append(_ points: [TrackPoint], to id: UUID, startNewSegment: Bool) async throws -> Track {
        let result: TrackAppendResult = try await store.appendTrackPoints(points, to: id, startNewSegment: startNewSegment)
        return result.track
    }

    public func finish(_ id: UUID) async throws -> Track {
        try await store.finishRecording(id)
    }

    public func geometry(_ id: UUID) async throws -> [[Coordinate]] {
        try await store.trackGeometry(id, detail: .full)
    }
}

/// Records fixes into a track: filters them (`TrackPointFilter`), batches them into the store (every
/// `batchSize` points or when the oldest unsaved point is `maximumBatchAge` old, and on pause, stop and
/// `flush()`, e.g. when the app goes to the background), supports pause/resume (resuming starts a new
/// segment) and continuing a recording found interrupted at launch (`adopt`).
///
/// A failed write keeps the points and retries with the next batch, so nothing is dropped silently.
public actor TrackRecorder {
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case paused
    }

    public struct Snapshot: Sendable, Equatable {
        public var state: State
        public var trackID: UUID?
        public var name: String?
        /// Points stored plus points waiting to be written.
        public var pointCount: Int
        /// Points already written to the store.
        public var storedPointCount: Int
        /// Distance of the stored track plus the unsaved points, metres.
        public var distance: Double
        public var startDate: Date?
        /// The recording so far, by segment, for the live track line.
        public var segments: [[Coordinate]]
        /// The last write error, if the latest write failed.
        public var lastError: String?

        public static let idle = Snapshot(state: .idle, trackID: nil, name: nil, pointCount: 0, storedPointCount: 0, distance: 0,
                                          startDate: nil, segments: [], lastError: nil)
    }

    private let store: any TrackRecordingStore
    public private(set) var filter: TrackPointFilter
    private let batchSize: Int
    private let maximumBatchAge: TimeInterval

    private var state: State = .idle
    private var track: Track?
    private var pending: [TrackPoint] = []
    private var pendingStartsSegment = false
    private var lastAccepted: TrackPoint?
    private var segments: [[Coordinate]] = []
    /// Distance from the previous accepted point to each pending point (0 at a segment start), metres.
    private var pendingDistances: [Double] = []
    private var lastError: String?

    public init(store: any TrackRecordingStore, filter: TrackPointFilter = TrackPointFilter(), batchSize: Int = 10,
                maximumBatchAge: TimeInterval = 30) {
        self.store = store
        self.filter = filter
        self.batchSize = max(1, batchSize)
        self.maximumBatchAge = maximumBatchAge
    }

    public func setFilter(_ filter: TrackPointFilter) {
        self.filter = filter
    }

    public var snapshot: Snapshot {
        let stored: Int = track?.statistics.pointCount ?? 0
        let storedDistance: Double = track?.statistics.distance.meters ?? 0
        return Snapshot(state: state, trackID: track?.id, name: track?.name, pointCount: stored + pending.count,
                        storedPointCount: stored,
                        distance: storedDistance + pendingDistances.reduce(0, +),
                        startDate: track?.startDate ?? track?.createdAt, segments: segments, lastError: lastError)
    }

    /// Starts a new recording. Throws if one is already running.
    @discardableResult
    public func start(name: String) async throws -> Track {
        guard state == .idle else { throw TrackRecorderError.alreadyRecording }
        let created: Track = try await store.startRecording(name: name)
        reset()
        track = created
        state = .recording
        return created
    }

    /// Continues a recording that was interrupted (already resumed in the store with `resumeRecording`).
    public func adopt(_ resumed: Track) async {
        reset()
        track = resumed
        state = .recording
        segments = (try? await store.geometry(resumed.id)) ?? []
        // The store starts a new segment on the next append after `resumeRecording`; mirror that here.
        pendingStartsSegment = !segments.isEmpty
        if pendingStartsSegment { segments.append([]) }
    }

    /// Offers a fix. Returns true when it was taken as a track point.
    @discardableResult
    public func record(_ fix: Fix) async -> Bool {
        guard state == .recording, track != nil else { return false }
        guard filter.accepts(fix, after: lastAccepted) else { return false }
        let point = TrackPoint(fix)
        var step: Double = 0
        if let last = lastAccepted {
            step = Geodesy.distance(from: last.coordinate, to: point.coordinate)
        }
        pending.append(point)
        pendingDistances.append(step)
        lastAccepted = point
        if segments.isEmpty { segments.append([]) }
        segments[segments.count - 1].append(point.coordinate)
        if pending.count >= batchSize { await flush() }
        else if let first = pending.first?.timestamp, fix.timestamp.timeIntervalSince(first) >= maximumBatchAge {
            await flush()
        }
        return true
    }

    /// Writes waiting points now.
    public func flush() async {
        guard let current = track, !pending.isEmpty else { return }
        let batch: [TrackPoint] = pending
        let newSegment: Bool = pendingStartsSegment
        do {
            let updated: Track = try await store.append(batch, to: current.id, startNewSegment: newSegment)
            track = updated
            // Points recorded while the write was in progress stay pending.
            let written: Int = min(batch.count, pending.count)
            pending.removeFirst(written)
            pendingDistances.removeFirst(min(written, pendingDistances.count))
            pendingStartsSegment = false
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Pauses: writes waiting points; the next point after `resume()` starts a new segment.
    public func pause() async {
        guard state == .recording else { return }
        await flush()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        state = .recording
        pendingStartsSegment = true
        lastAccepted = nil
        segments.append([])
    }

    /// Stops and closes the recording. Returns the finished track.
    @discardableResult
    public func stop() async throws -> Track? {
        guard state != .idle, let current = track else { return nil }
        state = .paused
        await flush()
        if !pending.isEmpty { await flush() }
        let finished: Track = try await store.finish(current.id)
        reset()
        return finished
    }

    private func reset() {
        state = .idle
        track = nil
        pending = []
        pendingStartsSegment = false
        lastAccepted = nil
        segments = []
        pendingDistances = []
        lastError = nil
    }
}

public enum TrackRecorderError: Error, Equatable, Sendable {
    case alreadyRecording
}
