import Foundation

public struct DownloadProgress: Equatable, Sendable, Codable {
    public var bytesReceived: Int64
    /// Total bytes to download for this install (all artifacts), if known.
    public var totalBytes: Int64?

    public init(bytesReceived: Int64, totalBytes: Int64?) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
}

/// Why an install failed. Also thrown by `ChartInstaller.install`.
public enum InstallFailure: Error, Equatable, Sendable, Codable, CustomStringConvertible {
    case insufficientDiskSpace(required: Int64, available: Int64)
    /// The download stopped part-way; installing again resumes from `bytesReceived`.
    case interrupted(bytesReceived: Int64)
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case corruptPackage(String)
    case transport(String)
    case fileSystem(String)
    case cancelled
    case invalidRequest(String)
    case alreadyInProgress

    /// True when retrying keeps the partial download (interruption, cancellation, disk full, network).
    public var isResumable: Bool {
        switch self {
        case .interrupted, .cancelled, .insufficientDiskSpace, .transport: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .insufficientDiskSpace(let r, let a): return "not enough free space: need \(r) bytes, \(a) available"
        case .interrupted(let b): return "download interrupted after \(b) bytes"
        case .checksumMismatch(let e, let a): return "checksum mismatch: expected \(e), got \(a)"
        case .sizeMismatch(let e, let a): return "size mismatch: expected \(e) bytes, got \(a)"
        case .corruptPackage(let m): return "package failed its integrity check: \(m)"
        case .transport(let m): return "network error: \(m)"
        case .fileSystem(let m): return "file system error: \(m)"
        case .cancelled: return "cancelled"
        case .invalidRequest(let m): return "invalid install request: \(m)"
        case .alreadyInProgress: return "an install for this region is already running"
        }
    }
}

/// Per-region install status shown by the UI.
public enum InstallState: Equatable, Sendable {
    case notInstalled
    case queued
    case downloading(DownloadProgress)
    case verifying
    case installing
    case installed(version: String)
    /// The last attempt failed. An older installed version, if any, is still usable
    /// (see `ChartInstaller.installedRegion(id:)`).
    case failed(InstallFailure)
    case updateAvailable(installedVersion: String, availableVersion: String)

    /// True while an install is running.
    public var isBusy: Bool {
        switch self {
        case .queued, .downloading, .verifying, .installing: return true
        default: return false
        }
    }
}

public enum InstallEvent: Equatable, Sendable {
    case enqueue
    case startDownload(DownloadProgress)
    case progress(DownloadProgress)
    case beginVerification
    case beginInstall
    case finish(version: String)
    case fail(InstallFailure)
    case updateFound(installedVersion: String, availableVersion: String)
    /// Settle an idle region to `installed(version)` or, with nil, `notInstalled`.
    case settle(installedVersion: String?)
}

/// The legal transitions, as a pure function so they can be tested and reasoned about apart from I/O.
///
///     notInstalled/installed/failed/updateAvailable --enqueue--> queued
///     queued --startDownload--> downloading --progress--> downloading
///     queued/downloading --beginVerification--> verifying --beginInstall--> installing
///     installing --finish--> installed
///     queued/downloading/verifying/installing --fail--> failed
///     installed/updateAvailable/failed --updateFound--> updateAvailable
///     any idle state --settle--> installed | notInstalled
public enum InstallStateMachine {
    /// The next state, or nil if `event` is not allowed in `state`.
    public static func transition(from state: InstallState, on event: InstallEvent) -> InstallState? {
        switch (state, event) {
        case (.notInstalled, .enqueue), (.installed, .enqueue), (.failed, .enqueue), (.updateAvailable, .enqueue):
            return .queued
        case (.queued, .startDownload(let p)):
            return .downloading(p)
        case (.downloading(let old), .progress(let p)):
            // Progress never goes backwards (late callbacks are dropped); a restart uses startDownload.
            if p.bytesReceived < old.bytesReceived { return .downloading(old) }
            return .downloading(p)
        case (.downloading, .startDownload(let p)):
            // A restart of the download (server file changed): allowed, progress resets.
            return .downloading(p)
        case (.queued, .beginVerification), (.downloading, .beginVerification):
            return .verifying
        case (.verifying, .beginInstall):
            return .installing
        case (.installing, .finish(let v)):
            return .installed(version: v)
        case (let s, .fail(let reason)) where s.isBusy:
            return .failed(reason)
        case (.installed, .updateFound(let i, let a)), (.updateAvailable, .updateFound(let i, let a)), (.failed, .updateFound(let i, let a)):
            return .updateAvailable(installedVersion: i, availableVersion: a)
        case (let s, .settle(let v)) where !s.isBusy:
            return v.map { .installed(version: $0) } ?? .notInstalled
        default:
            return nil
        }
    }
}
