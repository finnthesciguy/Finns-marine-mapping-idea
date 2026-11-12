import Foundation

public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case chart
    case routingPack

    var fileExtension: String {
        switch self {
        case .chart: return "mbtiles"
        case .routingPack: return "routingpack"
        }
    }
}

/// What to download for one artifact. Built from a manifest entry, or from HEAD results for a
/// NOAA package with no manifest (then `sha256` is nil and only size + integrity are checked).
public struct DownloadSpec: Sendable, Equatable {
    public var url: URL
    public var expectedByteSize: Int64?
    public var sha256: String?
    public var version: String
    public var dataDate: Date

    public init(url: URL, expectedByteSize: Int64?, sha256: String?, version: String, dataDate: Date) {
        self.url = url
        self.expectedByteSize = expectedByteSize
        self.sha256 = sha256?.lowercased()
        self.version = version
        self.dataDate = dataDate
    }

    public init(_ artifact: PackageArtifact) {
        self.init(url: artifact.url, expectedByteSize: artifact.byteSize, sha256: artifact.sha256,
                  version: artifact.version, dataDate: artifact.dataDate)
    }

    public init(_ artifact: RoutingPackArtifact) { self.init(artifact.artifact) }
}

/// The descriptive part of a region (everything but the files).
public struct RegionDescriptor: Sendable, Equatable {
    public var id: String
    public var title: String
    public var bounds: BoundingBox
    public var minZoom: Int
    public var maxZoom: Int
    public var tileFormat: TileFormat
    public var source: String

    public init(id: String, title: String, bounds: BoundingBox, minZoom: Int, maxZoom: Int, tileFormat: TileFormat, source: String) {
        self.id = id
        self.title = title
        self.bounds = bounds
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.tileFormat = tileFormat
        self.source = source
    }

    public init(_ region: ChartRegion) {
        self.init(id: region.id, title: region.title, bounds: region.bounds, minZoom: region.minZoom,
                  maxZoom: region.maxZoom, tileFormat: region.tileFormat, source: region.source)
    }
}

/// Bookkeeping for a partial download, persisted so a resume survives app relaunch.
public struct ResumeRecord: Codable, Sendable, Equatable {
    public var regionID: String
    public var kind: ArtifactKind
    public var url: URL
    public var version: String
    public var expectedSHA256: String?
    public var expectedByteSize: Int64?
    /// Relative to the installer root.
    public var partialRelativePath: String
    public var bytesReceived: Int64
    /// Validators of the remote file the partial bytes came from. A resume sends `If-Range` with
    /// them, and a response whose validators differ restarts the download from zero.
    public var validators: RemoteValidators?
    public var updatedAt: Date

    func matches(_ spec: DownloadSpec) -> Bool {
        url == spec.url && version == spec.version && expectedSHA256 == spec.sha256 && expectedByteSize == spec.expectedByteSize
    }
}

struct PersistedInstallState: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = PersistedInstallState.currentSchemaVersion
    var regions: [InstalledRegion] = []
    var downloads: [ResumeRecord] = []
}

/// Drives installs and updates of chart regions, independent of the network transport.
///
/// Layout under `rootDirectory` (the caller picks it, e.g. `Library/Charts` on iOS — avoid paths with
/// spaces such as "Application Support" if you can, see `MapLibreSources`):
///
///     chartkit-state.json             installed regions + resume records (atomic JSON writes)
///     staging/<id>-<kind>.partial     in-progress downloads
///     regions/<id>/<kind>-<version>-<sha12>.<ext>   installed files (immutable once installed)
///
/// An update downloads and verifies into `staging/`, renames into `regions/<id>/` under a new
/// versioned name, and then commits by atomically rewriting the state file. Until that commit the
/// old version stays installed and usable; if anything fails the new file is removed (rollback).
/// The superseded file is deleted after the commit (an open SQLite handle on it keeps working on
/// POSIX file systems until closed).
public actor ChartInstaller {
    public struct Configuration: Sendable {
        /// Extra free space required beyond the download itself.
        public var freeSpaceMargin: Int64
        /// Also run SQLite `quick_check` over the whole downloaded package (slower, stronger).
        public var deepIntegrityCheck: Bool
        /// GET attempts per artifact per `install` call (resumes after interruption count).
        public var maxAttemptsPerArtifact: Int
        /// Optional check for routing packs (format owned by RoutingKit). Throw to reject.
        public var routingPackValidator: (@Sendable (URL) throws -> Void)?

        public init(freeSpaceMargin: Int64 = 64 * 1024 * 1024, deepIntegrityCheck: Bool = false,
                    maxAttemptsPerArtifact: Int = 3, routingPackValidator: (@Sendable (URL) throws -> Void)? = nil) {
            self.freeSpaceMargin = freeSpaceMargin
            self.deepIntegrityCheck = deepIntegrityCheck
            self.maxAttemptsPerArtifact = max(1, maxAttemptsPerArtifact)
            self.routingPackValidator = routingPackValidator
        }
    }

    public static let stateFileName = "chartkit-state.json"

    public nonisolated let rootDirectory: URL
    private let transport: any ChartTransport
    private let diskSpace: any DiskSpaceProvider
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    private var persisted: PersistedInstallState
    private var states: [String: InstallState] = [:]
    private var inFlight: Set<String> = []
    private var progressTokens: [String: UUID] = [:]
    private var observer: (@Sendable (String, InstallState) -> Void)?

    /// True if the state file was unreadable at launch and was set aside (`.corrupt-*`) for diagnosis.
    /// Installed files are left on disk in that case rather than treated as orphans.
    public nonisolated let recoveredFromCorruptState: Bool

    public init(rootDirectory: URL, transport: any ChartTransport,
                diskSpace: any DiskSpaceProvider = FileSystemDiskSpace(),
                configuration: Configuration = Configuration(),
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.transport = transport
        self.diskSpace = diskSpace
        self.configuration = configuration
        self.now = now

        let fm = FileManager.default
        do {
            for dir in ["staging", "regions"] {
                try fm.createDirectory(at: self.rootDirectory.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
        } catch {
            throw InstallFailure.fileSystem("cannot create \(rootDirectory.path): \(error)")
        }
        let loaded = Self.loadState(root: self.rootDirectory, now: now())
        self.persisted = loaded.state
        self.recoveredFromCorruptState = loaded.recovered
        Self.removeOrphans(root: self.rootDirectory, state: loaded.state, keepRegionFiles: loaded.recovered)

        var initial: [String: InstallState] = [:]
        for r in loaded.state.regions { initial[r.id] = .installed(version: r.chart.version) }
        for d in loaded.state.downloads where initial[d.regionID] == nil {
            initial[d.regionID] = .failed(.interrupted(bytesReceived: d.bytesReceived))
        }
        self.states = initial
    }

    // MARK: Queries

    public func setObserver(_ observer: (@Sendable (String, InstallState) -> Void)?) {
        self.observer = observer
    }

    public func state(for regionID: String) -> InstallState { states[regionID] ?? .notInstalled }

    public func allStates() -> [String: InstallState] { states }

    public func installedRegions() -> [InstalledRegion] { persisted.regions.sorted { $0.id < $1.id } }

    public func installedRegion(id: String) -> InstalledRegion? { persisted.regions.first { $0.id == id } }

    public func pendingDownloads() -> [ResumeRecord] { persisted.downloads }

    /// Absolute location of an installed file (resolved against the current root each time).
    public nonisolated func fileURL(for artifact: InstalledArtifact) -> URL {
        rootDirectory.appendingPathComponent(artifact.relativePath)
    }

    public func chartFileURL(regionID: String) -> URL? {
        installedRegion(id: regionID).map { fileURL(for: $0.chart) }
    }

    // MARK: Update checks

    /// Diffs a freshly fetched manifest against what is installed and marks idle regions
    /// `updateAvailable` (or back to `installed`). Returns the plan for the UI.
    @discardableResult
    public func apply(_ manifest: ChartManifest) -> UpdatePlan {
        let plan = UpdatePlanner.plan(installed: persisted.regions, manifest: manifest)
        for u in plan.updated {
            let availableVersion = u.chart == .changed ? u.available.chartPackage.version
                : (u.available.routingPack?.version ?? u.available.chartPackage.version)
            let installedVersion = u.chart == .changed ? u.installed.chart.version
                : (u.installed.routingPack?.version ?? "none")
            transition(u.installed.id, .updateFound(installedVersion: installedVersion, availableVersion: availableVersion))
        }
        for r in plan.unchanged where state(for: r.id) != .installed(version: r.chart.version) {
            if case .updateAvailable = state(for: r.id) { transition(r.id, .settle(installedVersion: r.chart.version)) }
        }
        return plan
    }

    /// Manifest-less fallback (NOAA NCDS packages): HEAD the installed chart's URL and compare
    /// validators. Marks the region `updateAvailable` when the server file changed.
    public func checkRemote(regionID: String) async throws -> RemoteChange {
        guard let region = installedRegion(id: regionID) else { throw InstallFailure.invalidRequest("\(regionID) is not installed") }
        guard let have = region.chart.validators else { return .unknown }
        let current: RemoteValidators
        do {
            current = try await transport.head(region.chart.sourceURL)
        } catch {
            throw mapTransportError(error, bytesReceived: 0, remaining: 0)
        }
        let change = RemoteFileCheck.compare(installed: have, current: current)
        if case .changed = change {
            let newVersion = RemoteFileCheck.downloadSpec(url: region.chart.sourceURL, validators: current).version
            transition(regionID, .updateFound(installedVersion: region.chart.version, availableVersion: newVersion))
        }
        return change
    }

    // MARK: Install

    /// Marks a region as queued (for UI) before `install` is called.
    public func enqueue(regionID: String) {
        guard !inFlight.contains(regionID) else { return }
        transition(regionID, .enqueue)
    }

    @discardableResult
    public func install(_ region: ChartRegion) async throws -> InstalledRegion {
        try await install(RegionDescriptor(region), chart: DownloadSpec(region.chartPackage),
                          routingPack: region.routingPack.map(DownloadSpec.init))
    }

    /// Downloads (resuming any partial file), verifies, and atomically installs a region's chart
    /// package and, optionally, routing pack. Only artifacts whose version/checksum differ from what
    /// is installed are fetched. Throws `InstallFailure`; the region's previous version, if any,
    /// remains installed on failure.
    @discardableResult
    public func install(_ descriptor: RegionDescriptor, chart: DownloadSpec, routingPack: DownloadSpec? = nil) async throws -> InstalledRegion {
        let id = descriptor.id
        guard RegionID.isValid(id) else { throw InstallFailure.invalidRequest("invalid region id \(id)") }
        guard !inFlight.contains(id) else { throw InstallFailure.alreadyInProgress }
        inFlight.insert(id)
        defer {
            inFlight.remove(id)
            progressTokens[id] = nil
        }

        let existing = installedRegion(id: id)
        var work: [(ArtifactKind, DownloadSpec)] = []
        if Self.needsDownload(existing?.chart, chart) { work.append((.chart, chart)) }
        if let routingPack, Self.needsDownload(existing?.routingPack, routingPack) { work.append((.routingPack, routingPack)) }
        if work.isEmpty, let existing {
            transition(id, .settle(installedVersion: existing.chart.version))
            return existing
        }

        if state(for: id) != .queued { transition(id, .enqueue) }
        do {
            return try await runInstall(descriptor, work: work, existing: existing)
        } catch let failure as InstallFailure {
            transition(id, .fail(failure))
            throw failure
        } catch is CancellationError {
            transition(id, .fail(.cancelled))
            throw InstallFailure.cancelled
        } catch {
            let failure = InstallFailure.fileSystem(String(describing: error))
            transition(id, .fail(failure))
            throw failure
        }
    }

    /// Deletes an installed region and any partial download for it.
    public func remove(regionID: String) throws {
        guard !inFlight.contains(regionID) else { throw InstallFailure.alreadyInProgress }
        var next = persisted
        let region = next.regions.first { $0.id == regionID }
        let partials = next.downloads.filter { $0.regionID == regionID }
        next.regions.removeAll { $0.id == regionID }
        next.downloads.removeAll { $0.regionID == regionID }
        try save(next)
        persisted = next
        let fm = FileManager.default
        if let region {
            try? fm.removeItem(at: fileURL(for: region.chart))
            if let rp = region.routingPack { try? fm.removeItem(at: fileURL(for: rp)) }
            try? fm.removeItem(at: rootDirectory.appendingPathComponent("regions/\(regionID)"))
        }
        for p in partials { try? fm.removeItem(at: rootDirectory.appendingPathComponent(p.partialRelativePath)) }
        transition(regionID, .settle(installedVersion: nil))
    }

    /// Throws away a partial download so the next install starts from zero.
    public func discardPartialDownloads(regionID: String) throws {
        guard !inFlight.contains(regionID) else { throw InstallFailure.alreadyInProgress }
        for r in persisted.downloads where r.regionID == regionID { try discard(r) }
        transition(regionID, .settle(installedVersion: installedRegion(id: regionID)?.chart.version))
    }

    // MARK: Pipeline

    private struct Downloaded {
        var kind: ArtifactKind
        var spec: DownloadSpec
        var record: ResumeRecord
        var sha256: String = ""
        var byteSize: Int64 = 0
    }

    private func runInstall(_ d: RegionDescriptor, work: [(ArtifactKind, DownloadSpec)], existing: InstalledRegion?) async throws -> InstalledRegion {
        let id = d.id
        let fm = FileManager.default

        // 1. Resume bookkeeping.
        var items: [Downloaded] = []
        for (kind, spec) in work {
            items.append(Downloaded(kind: kind, spec: spec, record: try prepareRecord(regionID: id, kind: kind, spec: spec)))
        }

        // 2. Free-space precheck.
        let remaining = items.reduce(Int64(0)) { sum, item in
            sum + max(0, (item.spec.expectedByteSize ?? 0) - item.record.bytesReceived)
        }
        let required = remaining + configuration.freeSpaceMargin
        let available = (try? diskSpace.availableBytes(for: rootDirectory)) ?? Int64.max
        if available < required { throw InstallFailure.insufficientDiskSpace(required: required, available: available) }

        // 3. Download.
        let total: Int64? = items.allSatisfy({ $0.spec.expectedByteSize != nil })
            ? items.reduce(0) { $0 + ($1.spec.expectedByteSize ?? 0) } : nil
        let token = UUID()
        progressTokens[id] = token
        transition(id, .startDownload(DownloadProgress(bytesReceived: items.reduce(0) { $0 + $1.record.bytesReceived }, totalBytes: total)))
        var base: Int64 = 0
        for i in items.indices {
            items[i].record = try await download(items[i].record, spec: items[i].spec, base: base, total: total, token: token)
            base += items[i].record.bytesReceived
        }
        progressTokens[id] = nil

        // 4. Verify: size, SHA-256 (streamed off the actor), package integrity.
        transition(id, .beginVerification)
        for i in items.indices {
            let item = items[i]
            let url = rootDirectory.appendingPathComponent(item.record.partialRelativePath)
            let size = Self.fileSize(url) ?? 0
            items[i].byteSize = size
            if let expected = item.spec.expectedByteSize, size != expected {
                try discard(item.record)
                throw InstallFailure.sizeMismatch(expected: expected, actual: size)
            }
            let sha: String
            do {
                sha = try await Task.detached(priority: .utility) { try StreamingSHA256.hash(fileAt: url) }.value
            } catch {
                throw InstallFailure.fileSystem("cannot read download: \(error)")
            }
            items[i].sha256 = sha
            if let expected = item.spec.sha256, expected != sha {
                try discard(item.record)
                throw InstallFailure.checksumMismatch(expected: expected, actual: sha)
            }
            switch item.kind {
            case .chart:
                do {
                    let report = try await MBTilesReader.checkIntegrity(at: url, deep: configuration.deepIntegrityCheck)
                    if let format = report.metadata.format, format != d.tileFormat {
                        throw MBTilesError.tileFormatMismatch(declared: d.tileFormat, found: format)
                    }
                } catch let e as MBTilesError {
                    try discard(item.record)
                    throw InstallFailure.corruptPackage(e.description)
                }
            case .routingPack:
                if let validate = configuration.routingPackValidator {
                    do { try validate(url) } catch {
                        try discard(item.record)
                        throw InstallFailure.corruptPackage("routing pack rejected: \(error)")
                    }
                }
            }
        }

        // 5. Swap: rename into place under new names, then commit the state file atomically.
        transition(id, .beginInstall)
        var moved: [URL] = []
        var chartArtifact = existing?.chart
        var routingArtifact = existing?.routingPack
        var next = persisted
        do {
            let regionDir = rootDirectory.appendingPathComponent("regions/\(id)")
            try fm.createDirectory(at: regionDir, withIntermediateDirectories: true)
            for item in items {
                let name = "\(item.kind.rawValue)-\(Self.safeFileComponent(item.spec.version))-\(item.sha256.prefix(12)).\(item.kind.fileExtension)"
                let relative = "regions/\(id)/\(name)"
                let dest = rootDirectory.appendingPathComponent(relative)
                let src = rootDirectory.appendingPathComponent(item.record.partialRelativePath)
                if existing?.chart.relativePath == relative || existing?.routingPack?.relativePath == relative {
                    // Same name as the live file (same version and hash): nothing to swap.
                    try? fm.removeItem(at: src)
                } else {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.moveItem(at: src, to: dest)
                    moved.append(dest)
                }
                let artifact = InstalledArtifact(version: item.spec.version, sha256: item.sha256, byteSize: item.byteSize,
                                                 dataDate: item.spec.dataDate, sourceURL: item.spec.url, relativePath: relative,
                                                 installedAt: now(), validators: item.record.validators)
                switch item.kind {
                case .chart: chartArtifact = artifact
                case .routingPack: routingArtifact = artifact
                }
            }
            guard let chartArtifact else { throw InstallFailure.invalidRequest("no chart package for \(id)") }
            let region = InstalledRegion(id: id, title: d.title, bounds: d.bounds, minZoom: d.minZoom, maxZoom: d.maxZoom,
                                         tileFormat: d.tileFormat, source: d.source, chart: chartArtifact, routingPack: routingArtifact)
            next.regions.removeAll { $0.id == id }
            next.regions.append(region)
            next.regions.sort { $0.id < $1.id }
            next.downloads.removeAll { r in r.regionID == id && items.contains { $0.kind == r.kind } }
            try save(next) // commit point
        } catch {
            // Rollback: the old files and state were never touched.
            for url in moved { try? fm.removeItem(at: url) }
            var cleaned = persisted
            cleaned.downloads.removeAll { r in r.regionID == id && items.contains { $0.kind == r.kind } }
            if (try? save(cleaned)) != nil { persisted = cleaned }
            for item in items { try? fm.removeItem(at: rootDirectory.appendingPathComponent(item.record.partialRelativePath)) }
            if let f = error as? InstallFailure { throw f }
            throw InstallFailure.fileSystem("install failed, previous version kept: \(error)")
        }
        persisted = next

        // 6. Drop superseded files.
        let live = Set([chartArtifact?.relativePath, routingArtifact?.relativePath].compactMap { $0 })
        for old in [existing?.chart, existing?.routingPack].compactMap({ $0 }) where !live.contains(old.relativePath) {
            try? fm.removeItem(at: fileURL(for: old))
        }

        guard let installed = installedRegion(id: id) else { throw InstallFailure.fileSystem("state lost after commit") }
        transition(id, .finish(version: installed.chart.version))
        return installed
    }

    /// Reuses a matching resume record or starts a fresh one (discarding a stale partial).
    private func prepareRecord(regionID: String, kind: ArtifactKind, spec: DownloadSpec) throws -> ResumeRecord {
        if var r = persisted.downloads.first(where: { $0.regionID == regionID && $0.kind == kind }) {
            if r.matches(spec) {
                r.bytesReceived = Self.fileSize(rootDirectory.appendingPathComponent(r.partialRelativePath)) ?? 0
                try persist(r)
                return r
            }
            try discard(r)
        }
        let relative = "staging/\(regionID)-\(kind.rawValue).partial"
        try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(relative))
        let r = ResumeRecord(regionID: regionID, kind: kind, url: spec.url, version: spec.version,
                             expectedSHA256: spec.sha256, expectedByteSize: spec.expectedByteSize,
                             partialRelativePath: relative, bytesReceived: 0, validators: nil, updatedAt: now())
        try persist(r)
        return r
    }

    private func download(_ start: ResumeRecord, spec: DownloadSpec, base: Int64, total: Int64?, token: UUID) async throws -> ResumeRecord {
        var record = start
        let partial = rootDirectory.appendingPathComponent(record.partialRelativePath)
        let fm = FileManager.default
        let regionID = record.regionID

        if record.validators == nil {
            do {
                record.validators = try await transport.head(spec.url)
            } catch {
                throw mapTransportError(error, bytesReceived: record.bytesReceived, remaining: spec.expectedByteSize ?? 0)
            }
            if let expected = spec.expectedByteSize, let length = record.validators?.contentLength, length != expected {
                // The server's file is not the one the manifest describes; don't download it.
                try discard(record)
                throw InstallFailure.sizeMismatch(expected: expected, actual: length)
            }
            try persist(record)
        }

        var attempts = 0
        var restarts = 0
        while true {
            if Task.isCancelled { throw InstallFailure.cancelled }
            var offset = Self.fileSize(partial) ?? 0
            if let expected = spec.expectedByteSize {
                if offset == expected {
                    record.bytesReceived = offset
                    try persist(record)
                    return record
                }
                if offset > expected { offset = 0 }
            }
            var ifRange: String?
            if offset > 0 {
                ifRange = record.validators?.ifRangeValue
                if ifRange == nil { offset = 0 } // cannot resume safely without a validator
            }
            if offset == 0 { try? fm.removeItem(at: partial) }
            record.bytesReceived = offset
            try persist(record)

            attempts += 1
            let request = DownloadRequest(url: spec.url, destination: partial, resumeOffset: offset, ifRange: ifRange)
            let response: DownloadResponse
            do {
                response = try await transport.download(request) { [weak self] bytes in
                    guard let self else { return }
                    Task { await self.reportProgress(regionID: regionID, token: token, bytes: base + bytes, total: total) }
                }
            } catch {
                let bytes = Self.fileSize(partial) ?? 0
                record.bytesReceived = bytes
                try persist(record)
                let failure = mapTransportError(error, bytesReceived: bytes, remaining: max(0, (spec.expectedByteSize ?? 0) - bytes))
                if case .interrupted = failure, attempts < configuration.maxAttemptsPerArtifact { continue }
                throw failure
            }

            let identity = RemoteValidators(etag: response.validators.etag, lastModified: response.validators.lastModified)
            switch response.statusCode {
            case 200:
                // Whole body from byte 0: a fresh download, or the server declined the range because
                // the file changed (If-Range mismatch). Either way these are now the file's validators.
                if offset > 0 { restarts += 1 }
                if identity.etag != nil || identity.lastModified != nil {
                    record.validators = RemoteValidators(etag: identity.etag, lastModified: identity.lastModified,
                                                         contentLength: response.totalLength ?? response.validators.contentLength,
                                                         acceptsByteRanges: record.validators?.acceptsByteRanges)
                }
                if offset > 0 {
                    transition(regionID, .startDownload(DownloadProgress(bytesReceived: base, totalBytes: total)))
                }
            case 206:
                if let known = record.validators,
                   RemoteValidators(etag: known.etag, lastModified: known.lastModified).sameRepresentation(as: identity) == false {
                    // The server ignored If-Range and sent bytes of a different file: the partial is a
                    // mix of two files. Throw it away and start again.
                    restarts += 1
                    if restarts > 2 { throw InstallFailure.transport("remote file keeps changing during download") }
                    record.validators = RemoteValidators(etag: identity.etag, lastModified: identity.lastModified,
                                                         contentLength: response.totalLength, acceptsByteRanges: true)
                    try? fm.removeItem(at: partial)
                    record.bytesReceived = 0
                    try persist(record)
                    transition(regionID, .startDownload(DownloadProgress(bytesReceived: base, totalBytes: total)))
                    attempts -= 1 // a forced restart is not the transport's fault
                    continue
                }
            default:
                throw InstallFailure.transport("unexpected HTTP status \(response.statusCode)")
            }

            let bytes = Self.fileSize(partial) ?? 0
            record.bytesReceived = bytes
            try persist(record)
            if let expected = spec.expectedByteSize ?? response.totalLength, bytes < expected {
                // Body ended early without an error: treat as an interruption.
                if attempts < configuration.maxAttemptsPerArtifact { continue }
                throw InstallFailure.interrupted(bytesReceived: bytes)
            }
            return record
        }
    }

    private func reportProgress(regionID: String, token: UUID, bytes: Int64, total: Int64?) {
        guard progressTokens[regionID] == token, case .downloading = state(for: regionID) else { return }
        transition(regionID, .progress(DownloadProgress(bytesReceived: bytes, totalBytes: total)))
    }

    private func mapTransportError(_ error: Error, bytesReceived: Int64, remaining: Int64) -> InstallFailure {
        if let f = error as? InstallFailure { return f }
        if error is CancellationError { return .cancelled }
        if let t = error as? TransportError {
            switch t {
            case .interrupted: return .interrupted(bytesReceived: bytesReceived)
            case .cancelled: return .cancelled
            case .diskFull: return diskFull(remaining: remaining)
            case .httpStatus(let code): return .transport("HTTP \(code)")
            case .other(let m): return .transport(m)
            }
        }
        if let c = error as? CocoaError, c.code == .fileWriteOutOfSpace { return diskFull(remaining: remaining) }
        if let p = error as? POSIXError, p.code == .ENOSPC { return diskFull(remaining: remaining) }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return diskFull(remaining: remaining) }
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileWriteOutOfSpace.rawValue { return diskFull(remaining: remaining) }
        return .transport(String(describing: error))
    }

    private func diskFull(remaining: Int64) -> InstallFailure {
        let available = (try? diskSpace.availableBytes(for: rootDirectory)) ?? 0
        return .insufficientDiskSpace(required: remaining + configuration.freeSpaceMargin, available: available)
    }

    // MARK: State plumbing

    @discardableResult
    private func transition(_ regionID: String, _ event: InstallEvent) -> Bool {
        guard let next = InstallStateMachine.transition(from: state(for: regionID), on: event) else { return false }
        if states[regionID] == next, case .downloading = next { return true }
        states[regionID] = next
        observer?(regionID, next)
        return true
    }

    private func persist(_ record: ResumeRecord) throws {
        var r = record
        r.updatedAt = now()
        var next = persisted
        if let i = next.downloads.firstIndex(where: { $0.regionID == r.regionID && $0.kind == r.kind }) {
            next.downloads[i] = r
        } else {
            next.downloads.append(r)
        }
        try save(next)
        persisted = next
    }

    private func discard(_ record: ResumeRecord) throws {
        try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(record.partialRelativePath))
        var next = persisted
        next.downloads.removeAll { $0.regionID == record.regionID && $0.kind == record.kind }
        try save(next)
        persisted = next
    }

    private func save(_ state: PersistedInstallState) throws {
        // Default (numeric) date coding: exact round trip, unlike second-resolution ISO strings.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(state)
            try data.write(to: rootDirectory.appendingPathComponent(Self.stateFileName), options: .atomic)
        } catch {
            throw InstallFailure.fileSystem("cannot write install state: \(error)")
        }
    }

    // MARK: Static helpers

    static func needsDownload(_ installed: InstalledArtifact?, _ spec: DownloadSpec) -> Bool {
        guard let installed else { return true }
        if installed.version != spec.version { return true }
        if let sha = spec.sha256, sha != installed.sha256.lowercased() { return true }
        return false
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if let n = attrs[.size] as? NSNumber { return n.int64Value }
        if let n = attrs[.size] as? Int64 { return n }
        if let n = attrs[.size] as? Int { return Int64(n) }
        return nil
    }

    static func safeFileComponent(_ s: String) -> String {
        let mapped = String(s.unicodeScalars.map { c -> Character in
            let ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "." || c == "_" || c == "-"
            return ok ? Character(c) : "_"
        })
        let trimmed = String(mapped.prefix(40))
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "v" : trimmed
    }

    private static func loadState(root: URL, now: Date) -> (state: PersistedInstallState, recovered: Bool) {
        let url = root.appendingPathComponent(stateFileName)
        guard let data = try? Data(contentsOf: url) else { return (PersistedInstallState(), false) }
        if let s = try? JSONDecoder().decode(PersistedInstallState.self, from: data),
           s.schemaVersion <= PersistedInstallState.currentSchemaVersion,
           s.regions.allSatisfy({ RegionID.isValid($0.id) }), s.downloads.allSatisfy({ RegionID.isValid($0.regionID) }) {
            return (s, false)
        }
        let aside = root.appendingPathComponent("\(stateFileName).corrupt-\(Int(now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: aside)
        return (PersistedInstallState(), true)
    }

    /// Crash recovery: deletes staging files with no resume record and region files no installed
    /// record points at (left behind by a crash between rename and commit).
    private static func removeOrphans(root: URL, state: PersistedInstallState, keepRegionFiles: Bool) {
        let fm = FileManager.default
        let staging = root.appendingPathComponent("staging")
        let keepStaging = Set(state.downloads.map(\.partialRelativePath))
        for name in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] where !keepStaging.contains("staging/\(name)") {
            try? fm.removeItem(at: staging.appendingPathComponent(name))
        }
        guard !keepRegionFiles else { return }
        let regions = root.appendingPathComponent("regions")
        var live = Set<String>()
        for r in state.regions {
            live.insert(r.chart.relativePath)
            if let rp = r.routingPack { live.insert(rp.relativePath) }
        }
        for dir in (try? fm.contentsOfDirectory(atPath: regions.path)) ?? [] {
            let dirURL = regions.appendingPathComponent(dir)
            let files = (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? []
            var kept = 0
            for f in files {
                if live.contains("regions/\(dir)/\(f)") { kept += 1 } else { try? fm.removeItem(at: dirURL.appendingPathComponent(f)) }
            }
            if kept == 0 { try? fm.removeItem(at: dirURL) }
        }
    }
}
