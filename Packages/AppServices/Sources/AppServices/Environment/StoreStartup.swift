import Foundation
import Persistence

/// Something the user should be told once at startup (shown as a banner on the map screen).
public struct StartupNotice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// The saved-data file was damaged and has been set aside; a fresh store was created.
        case dataRecovered
        /// The saved-data file could not be opened; this session uses a temporary store that is not kept.
        case dataNotSaved
        /// Charts could not be stored in the usual place.
        case storageFallback
        /// A track recording was interrupted (the app was closed or crashed while recording).
        case recordingInterrupted
    }

    public var kind: Kind
    public var message: String
    public var id: String { kind.rawValue + ":" + message }

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Opens the Persistence store without ever failing: a damaged file is set aside by Persistence itself
/// (reported here as a notice); any other failure (for example a file written by a newer app version)
/// falls back to an in-memory store and says that changes will not be kept.
public enum StoreOpener {
    public struct Result: Sendable {
        public var store: PersistenceStore
        /// The open report of the on-disk store; nil when the in-memory fallback is in use.
        public var report: OpenReport?
        /// False when the in-memory fallback is in use.
        public var isPersistent: Bool
        public var notices: [StartupNotice]
    }

    public static func open(at url: URL, options: PersistenceStore.Options = PersistenceStore.Options()) throws -> Result {
        do {
            let store = try PersistenceStore(url: url, options: options)
            let report: OpenReport = store.openReport
            return Result(store: store, report: report, isPersistent: true, notices: notices(for: report))
        } catch {
            let reason: String = describe(error)
            let memory = try PersistenceStore(inMemoryWith: options)
            let notice = StartupNotice(kind: .dataNotSaved,
                                       message: "Your saved waypoints, routes and tracks could not be opened (\(reason)). Changes made now will not be kept.")
            return Result(store: memory, report: nil, isPersistent: false, notices: [notice])
        }
    }

    /// Notices for an open report (corrupt-file recovery). Interrupted recordings are handled by
    /// `RecordingRecovery`, which produces its own notice.
    public static func notices(for report: OpenReport) -> [StartupNotice] {
        var out: [StartupNotice] = []
        if report.recoveredCorruptFile != nil {
            out.append(StartupNotice(kind: .dataRecovered,
                                     message: "Your saved data could not be read and has been set aside; Gulf Nav started with an empty store. The damaged file is kept on this device."))
        }
        return out
    }

    static func describe(_ error: any Error) -> String {
        if let persistence = error as? PersistenceError {
            switch persistence {
            case .schemaTooNew:
                return "they were saved by a newer version of Gulf Nav"
            default:
                return persistence.description
            }
        }
        return String(describing: error)
    }
}

/// What to do with recordings that were still running when the app last stopped
/// (`OpenReport.interruptedRecordings`).
///
/// The most recent one is resumed if it was last written to within `maximumGap` (the app was probably
/// killed in the background during a passage, and the skipper expects the track to continue); every
/// other one is closed. Resuming starts a new segment, so the gap is not counted as distance or time.
public enum RecordingRecovery {
    public struct Plan: Sendable, Equatable {
        public var resume: UUID?
        public var finish: [UUID]

        public init(resume: UUID?, finish: [UUID]) {
            self.resume = resume
            self.finish = finish
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// The recording to continue (state `.recording`), if any.
        public var resumed: Track?
        /// Recordings that were closed.
        public var finished: [Track]
        public var notices: [StartupNotice]
    }

    /// Default: resume a recording interrupted less than two hours ago.
    public static let defaultMaximumGap: TimeInterval = 2 * 3600

    /// Pure decision. `allowResume: false` closes everything (no recorder available).
    public static func plan(interrupted: [Track], now: Date, maximumGap: TimeInterval = defaultMaximumGap,
                            allowResume: Bool = true) -> Plan {
        guard !interrupted.isEmpty else { return Plan(resume: nil, finish: []) }
        var newest: Track? = nil
        var newestDate: Date = .distantPast
        for track in interrupted {
            let last: Date = lastActivity(track)
            if newest == nil || last > newestDate {
                newest = track
                newestDate = last
            }
        }
        var resume: UUID? = nil
        if allowResume, let newest, now.timeIntervalSince(newestDate) <= maximumGap {
            resume = newest.id
        }
        var finish: [UUID] = []
        for track in interrupted where track.id != resume {
            finish.append(track.id)
        }
        return Plan(resume: resume, finish: finish)
    }

    static func lastActivity(_ track: Track) -> Date {
        if let end = track.endDate { return max(end, track.modifiedAt) }
        return track.modifiedAt
    }

    /// Reads the interrupted recordings, decides and applies (resume / finish) on the store.
    public static func recover(store: PersistenceStore, now: Date, maximumGap: TimeInterval = defaultMaximumGap,
                               allowResume: Bool = true) async -> Outcome {
        var interrupted: [Track] = []
        do {
            interrupted = try await store.recordingTracks()
        } catch {
            return Outcome(resumed: nil, finished: [], notices: [])
        }
        let decision: Plan = plan(interrupted: interrupted, now: now, maximumGap: maximumGap, allowResume: allowResume)
        var resumed: Track? = nil
        var finished: [Track] = []
        if let id = decision.resume {
            do {
                resumed = try await store.resumeRecording(id)
            } catch {
                resumed = nil
                if let closed = try? await store.finishRecording(id) { finished.append(closed) }
            }
        }
        for id in decision.finish {
            if let closed = try? await store.finishRecording(id) { finished.append(closed) }
        }
        var notices: [StartupNotice] = []
        if let resumed {
            notices.append(StartupNotice(kind: .recordingInterrupted,
                                         message: "Track recording “\(resumed.name)” was interrupted and has been resumed."))
        }
        if !finished.isEmpty {
            let names: String = finished.map { "“\($0.name)”" }.joined(separator: ", ")
            let noun: String = finished.count == 1 ? "recording" : "recordings"
            notices.append(StartupNotice(kind: .recordingInterrupted,
                                         message: "Interrupted track \(noun) \(names) saved."))
        }
        return Outcome(resumed: resumed, finished: finished, notices: notices)
    }
}
