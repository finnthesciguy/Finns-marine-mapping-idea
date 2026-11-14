import AppServices
import Foundation
import NavCore
import Observation
import Persistence

/// Track recording on top of `AppServices.TrackRecorder`. Fixes are queued into one consumer task so they
/// reach the recorder in order; the snapshot (state, counts, live line) is published back on the main actor.
@MainActor
@Observable
final class RecordingModel {
    private(set) var snapshot: TrackRecorder.Snapshot = .idle
    var errorText: String?

    /// Called when recording starts or stops (background location policy) and when the snapshot changes.
    @ObservationIgnored var onRecordingChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var onSnapshot: (@MainActor () -> Void)?

    let recorder: TrackRecorder
    @ObservationIgnored private let continuation: AsyncStream<Fix>.Continuation
    @ObservationIgnored private var consumer: Task<Void, Never>?

    var isRecording: Bool { snapshot.state == .recording }
    var isActive: Bool { snapshot.state != .idle }

    init(store: PersistenceStore, filter: TrackPointFilter, batchSize: Int) {
        let recorder = TrackRecorder(store: PersistenceTrackRecordingStore(store: store), filter: filter,
                                     batchSize: batchSize, maximumBatchAge: 30)
        self.recorder = recorder
        let (stream, continuation) = AsyncStream<Fix>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        consumer = Task { [weak self] in
            for await fix in stream {
                let taken: Bool = await recorder.record(fix)
                if taken {
                    let next: TrackRecorder.Snapshot = await recorder.snapshot
                    self?.publish(next)
                }
            }
        }
    }

    func record(_ fix: Fix) {
        guard snapshot.state == .recording else { return }
        continuation.yield(fix)
    }

    func setFilter(_ filter: TrackPointFilter) {
        let recorder: TrackRecorder = self.recorder
        Task {
            await recorder.setFilter(filter)
        }
    }

    func start(at date: Date = Date()) async {
        do {
            try await recorder.start(name: DefaultNames.trackName(start: date))
            errorText = nil
        } catch {
            errorText = "Recording could not start: \(error)"
        }
        await refresh()
        onRecordingChange?(isActive)
    }

    /// Continues a recording found interrupted at launch (already resumed in the store).
    func adopt(_ track: Track) async {
        await recorder.adopt(track)
        await refresh()
        onRecordingChange?(isActive)
    }

    func pause() async {
        await recorder.pause()
        await refresh()
    }

    func resume() async {
        await recorder.resume()
        await refresh()
    }

    func stop() async {
        do {
            try await recorder.stop()
        } catch {
            errorText = "The recording could not be closed: \(error)"
        }
        await refresh()
        onRecordingChange?(isActive)
    }

    /// Writes waiting points (when the app goes to the background).
    func flush() async {
        await recorder.flush()
        await refresh()
    }

    private func refresh() async {
        let next: TrackRecorder.Snapshot = await recorder.snapshot
        publish(next)
    }

    private func publish(_ next: TrackRecorder.Snapshot) {
        if let error = next.lastError {
            errorText = "Track points could not be saved yet (will retry): \(error)"
        }
        guard next != snapshot else { return }
        snapshot = next
        onSnapshot?()
    }

    /// `idle`, `recording` or `paused` (for the status element).
    var stateName: String {
        switch snapshot.state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .paused: return "paused"
        }
    }
}
