import ChartKit
import Foundation

/// What a region row's main button does.
public enum RegionAction: Sendable, Equatable {
    case download
    case resume
    case update
    case cancel
    case none
}

/// One row of the Charts screen: manifest entry + installer state + what is on disk.
public struct RegionRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String?
    /// Bytes the user will download (manifest size; the HEAD result is used at install time).
    public var downloadBytes: Int64
    /// Data date shown before install (from the manifest).
    public var listedDataDate: Date
    public var installed: InstalledRegion?
    public var state: InstallState
    /// Bytes of a partial download kept for resuming.
    public var partialBytes: Int64
    /// True while the app is talking to the server before the installer has taken over (the NOAA HEAD).
    public var isPreparing: Bool
    /// Last error for this region not reflected in `state` (for example the HEAD failed).
    public var message: String?
    public var age: ChartAge?

    /// The data date to show: the installed file's when there is one.
    public var dataDate: Date { installed?.chart.dataDate ?? listedDataDate }

    public var isBusy: Bool { isPreparing || state.isBusy }

    /// Fraction for a progress bar while downloading.
    public var progressFraction: Double? {
        if case .downloading(let progress) = state { return progress.fractionCompleted }
        return nil
    }

    public var primaryAction: RegionAction {
        if isBusy { return .cancel }
        switch state {
        case .notInstalled:
            return partialBytes > 0 ? .resume : .download
        case .failed(let failure):
            if partialBytes > 0 && failure.isResumable { return .resume }
            return installed == nil ? .download : .update
        case .updateAvailable:
            return partialBytes > 0 ? .resume : .update
        case .installed:
            return partialBytes > 0 ? .resume : .none
        case .queued, .downloading, .verifying, .installing:
            return .cancel
        }
    }

    /// Delete is offered whenever something is on disk for the region and nothing is running.
    public var canDelete: Bool { !isBusy && (installed != nil || partialBytes > 0) }

    /// Short status line.
    public var statusText: String {
        if isPreparing { return "Contacting server…" }
        switch state {
        case .notInstalled:
            return partialBytes > 0 ? "Paused at \(ByteFormat.string(partialBytes))" : "Not downloaded"
        case .queued:
            return "Waiting…"
        case .downloading(let progress):
            if let total = progress.totalBytes {
                return "\(ByteFormat.string(progress.bytesReceived)) of \(ByteFormat.string(total))"
            }
            return ByteFormat.string(progress.bytesReceived)
        case .verifying:
            return "Checking the package…"
        case .installing:
            return "Installing…"
        case .installed:
            return "Installed"
        case .failed(let failure):
            return RegionRow.describe(failure)
        case .updateAvailable:
            return "Update available"
        }
    }

    /// A user-facing sentence for an install failure.
    public static func describe(_ failure: InstallFailure) -> String {
        switch failure {
        case .insufficientDiskSpace(let required, let available):
            return "Not enough free space: needs \(ByteFormat.string(required)), \(ByteFormat.string(available)) free"
        case .interrupted(let bytes):
            return "Interrupted after \(ByteFormat.string(bytes)); tap Resume"
        case .checksumMismatch:
            return "The download was damaged (checksum mismatch); try again"
        case .sizeMismatch:
            return "The file on the server is not the expected size"
        case .corruptPackage:
            return "The package failed its integrity check"
        case .transport(let message):
            return "Network error: \(message)"
        case .fileSystem(let message):
            return "Storage error: \(message)"
        case .cancelled:
            return "Paused"
        case .invalidRequest(let message):
            return "Cannot install: \(message)"
        case .alreadyInProgress:
            return "Already downloading"
        }
    }
}

public enum RegionCatalog {
    /// Rows in manifest order. Installed regions that are no longer in the manifest are appended so they
    /// can still be deleted.
    public static func rows(regions: [ChartRegion], installed: [InstalledRegion], states: [String: InstallState],
                            pending: [ResumeRecord], preparing: Set<String>, messages: [String: String],
                            now: Date, policy: StalenessPolicy = .default) -> [RegionRow] {
        var installedByID: [String: InstalledRegion] = [:]
        for region in installed { installedByID[region.id] = region }
        var partialByID: [String: Int64] = [:]
        for record in pending { partialByID[record.regionID, default: 0] += record.bytesReceived }

        var rows: [RegionRow] = []
        var seen: Set<String> = []
        for region in regions {
            seen.insert(region.id)
            let have: InstalledRegion? = installedByID[region.id]
            let size: Int64 = region.chartPackage.byteSize + (region.routingPack?.byteSize ?? 0)
            rows.append(RegionRow(id: region.id, title: region.title, summary: region.summary,
                                  downloadBytes: size, listedDataDate: region.chartPackage.dataDate,
                                  installed: have, state: states[region.id] ?? .notInstalled,
                                  partialBytes: partialByID[region.id] ?? 0,
                                  isPreparing: preparing.contains(region.id),
                                  message: messages[region.id],
                                  age: have.map { $0.age(now: now, policy: policy) }))
        }
        for region in installed where !seen.contains(region.id) {
            rows.append(RegionRow(id: region.id, title: region.title, summary: nil,
                                  downloadBytes: region.totalBytes, listedDataDate: region.chart.dataDate,
                                  installed: region, state: states[region.id] ?? .installed(version: region.chart.version),
                                  partialBytes: partialByID[region.id] ?? 0,
                                  isPreparing: preparing.contains(region.id),
                                  message: messages[region.id],
                                  age: region.age(now: now, policy: policy)))
        }
        return rows
    }
}

/// The confirmation shown before any download (App Store guideline 4.2.3: tell the user the size first).
public struct DownloadConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    /// False when the free space is clearly too small; the UI then offers no "Download" button.
    public var canProceed: Bool

    public static func make(regionTitle: String, downloadBytes: Int64, alreadyDownloaded: Int64,
                            freeBytes: Int64?, margin: Int64 = 64 * 1_000_000) -> DownloadConfirmation {
        let remaining: Int64 = max(0, downloadBytes - alreadyDownloaded)
        var lines: [String] = []
        if alreadyDownloaded > 0 {
            lines.append("\(ByteFormat.string(remaining)) left to download of \(ByteFormat.string(downloadBytes)).")
        } else {
            lines.append("This download is \(ByteFormat.string(downloadBytes)).")
        }
        lines.append("Use Wi-Fi if you can; on cellular it counts against your data plan.")
        var canProceed = true
        if let freeBytes {
            lines.append("Free space on this device: \(ByteFormat.string(freeBytes)).")
            if freeBytes < remaining + margin {
                canProceed = false
                lines.append("There is not enough free space. Free up \(ByteFormat.string(remaining + margin - freeBytes)) and try again.")
            }
        }
        lines.append("Keep the app open while it downloads; if it is interrupted, you can resume later.")
        return DownloadConfirmation(title: "Download \(regionTitle)?", message: lines.joined(separator: "\n\n"),
                                    canProceed: canProceed)
    }
}

/// Chart-age badge content (PLAN.md D5: every region shows its data date; stale data gets a warning).
public struct ChartAgeBadge: Sendable, Equatable {
    public var text: String
    public var level: StalenessLevel

    /// For the oldest installed region (the one most likely to mislead). Nil when nothing is installed.
    public static func make(installed: [InstalledRegion], now: Date,
                            policy: StalenessPolicy = .default) -> ChartAgeBadge? {
        var oldest: InstalledRegion? = nil
        for region in installed {
            if let current = oldest {
                if region.chart.dataDate < current.chart.dataDate { oldest = region }
            } else {
                oldest = region
            }
        }
        guard let region = oldest else { return nil }
        let age: ChartAge = region.age(now: now, policy: policy)
        let date: String = DataDateFormat.string(region.chart.dataDate)
        let text: String
        switch age.level {
        case .current:
            text = "Charts \(date)"
        case .warning, .critical:
            text = "Charts \(date) · \(age.days) days old"
        }
        return ChartAgeBadge(text: text, level: age.level)
    }
}
