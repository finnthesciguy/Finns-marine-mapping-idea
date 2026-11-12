import Foundation

/// A file that is installed on the device.
public struct InstalledArtifact: Codable, Hashable, Sendable {
    public var version: String
    public var sha256: String
    public var byteSize: Int64
    public var dataDate: Date
    public var sourceURL: URL
    /// Path relative to the installer's root directory. Stored relative because iOS moves the app
    /// container between launches and updates; resolve with `ChartInstaller.fileURL(for:)`.
    public var relativePath: String
    public var installedAt: Date
    /// Validators the server returned when this file was downloaded (for HEAD-based update checks).
    public var validators: RemoteValidators?

    public init(version: String, sha256: String, byteSize: Int64, dataDate: Date, sourceURL: URL,
                relativePath: String, installedAt: Date, validators: RemoteValidators?) {
        self.version = version
        self.sha256 = sha256
        self.byteSize = byteSize
        self.dataDate = dataDate
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.installedAt = installedAt
        self.validators = validators
    }
}

/// A region the user has installed.
public struct InstalledRegion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var bounds: BoundingBox
    public var minZoom: Int
    public var maxZoom: Int
    public var tileFormat: TileFormat
    public var source: String
    public var chart: InstalledArtifact
    public var routingPack: InstalledArtifact?

    public init(id: String, title: String, bounds: BoundingBox, minZoom: Int, maxZoom: Int, tileFormat: TileFormat,
                source: String, chart: InstalledArtifact, routingPack: InstalledArtifact? = nil) {
        self.id = id
        self.title = title
        self.bounds = bounds
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.tileFormat = tileFormat
        self.source = source
        self.chart = chart
        self.routingPack = routingPack
    }

    public var totalBytes: Int64 { chart.byteSize + (routingPack?.byteSize ?? 0) }
}

// MARK: - Manifest diffing

public enum ArtifactChange: String, Equatable, Sendable {
    case none
    /// Installed copy differs from the manifest (version or checksum).
    case changed
    /// Manifest offers it, nothing installed (e.g. a routing pack newly published for the region).
    case added
    /// Installed, but the manifest no longer lists it. Keep it; it is still usable.
    case withdrawn
}

public struct RegionUpdate: Equatable, Sendable {
    public var installed: InstalledRegion
    public var available: ChartRegion
    public var chart: ArtifactChange
    public var routingPack: ArtifactChange

    /// Bytes to download to bring this region up to date.
    public var downloadBytes: Int64 {
        var n: Int64 = 0
        if chart == .changed || chart == .added { n += available.chartPackage.byteSize }
        if routingPack == .changed || routingPack == .added { n += available.routingPack?.byteSize ?? 0 }
        return n
    }

    /// True when something must be downloaded (a withdrawn routing pack alone needs no download).
    public var needsDownload: Bool { downloadBytes > 0 }
}

/// What a fresh manifest means for the installed set.
public struct UpdatePlan: Equatable, Sendable {
    /// In the manifest but not installed: offer for download.
    public var new: [ChartRegion]
    /// Installed and the manifest has something newer.
    public var updated: [RegionUpdate]
    /// Installed and identical to the manifest (a withdrawn routing pack alone also lands here, in `notes`).
    public var unchanged: [InstalledRegion]
    /// Installed but no longer in the manifest. The files stay usable; the UI may offer deletion.
    public var removed: [InstalledRegion]
    /// Regions whose routing pack was withdrawn upstream (subset of `unchanged`/`updated` ids).
    public var routingPackWithdrawn: [String]

    public var hasUpdates: Bool { !updated.isEmpty }
    public var totalUpdateBytes: Int64 { updated.reduce(0) { $0 + $1.downloadBytes } }
}

public enum UpdatePlanner {
    /// Diffs the installed regions against a manifest. A package counts as changed when its version
    /// or its SHA-256 differs; results are sorted by region id.
    public static func plan(installed: [InstalledRegion], manifest: ChartManifest) -> UpdatePlan {
        let byID = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var plan = UpdatePlan(new: [], updated: [], unchanged: [], removed: [], routingPackWithdrawn: [])
        let manifestIDs = Set(manifest.regions.map(\.id))

        for region in manifest.regions.sorted(by: { $0.id < $1.id }) {
            guard let have = byID[region.id] else {
                plan.new.append(region)
                continue
            }
            let chart = differs(have.chart, region.chartPackage) ? ArtifactChange.changed : .none
            let routing: ArtifactChange
            switch (have.routingPack, region.routingPack) {
            case (nil, nil): routing = .none
            case (nil, .some): routing = .added
            case (.some, nil): routing = .withdrawn
            case let (.some(a), .some(b)): routing = differs(a, b.artifact) ? .changed : .none
            }
            if routing == .withdrawn { plan.routingPackWithdrawn.append(region.id) }
            let update = RegionUpdate(installed: have, available: region, chart: chart, routingPack: routing)
            if update.needsDownload { plan.updated.append(update) } else { plan.unchanged.append(have) }
        }
        plan.removed = installed.filter { !manifestIDs.contains($0.id) }.sorted { $0.id < $1.id }
        return plan
    }

    static func differs(_ installed: InstalledArtifact, _ offered: PackageArtifact) -> Bool {
        installed.version != offered.version || installed.sha256.lowercased() != offered.sha256.lowercased()
    }
}

// MARK: - Chart age

public enum StalenessLevel: Int, Comparable, Codable, Sendable {
    case current = 0
    case warning = 1
    case critical = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Thresholds for chart age warnings (PLAN.md D5: every region shows its data date; a stale region
/// gets a visible warning). Defaults: warn after 90 days, critical after 365.
public struct StalenessPolicy: Equatable, Sendable {
    public var warningAfterDays: Int
    public var criticalAfterDays: Int

    public init(warningAfterDays: Int = 90, criticalAfterDays: Int = 365) {
        self.warningAfterDays = warningAfterDays
        self.criticalAfterDays = max(criticalAfterDays, warningAfterDays)
    }

    public static let `default` = StalenessPolicy()
}

public struct ChartAge: Equatable, Sendable {
    /// Whole days between the data date and now (0 if the data date is in the future).
    public var days: Int
    public var level: StalenessLevel

    public static func evaluate(dataDate: Date, now: Date = Date(), policy: StalenessPolicy = .default) -> ChartAge {
        let days = max(0, Int(floor(now.timeIntervalSince(dataDate) / 86_400)))
        let level: StalenessLevel
        if days > policy.criticalAfterDays { level = .critical }
        else if days > policy.warningAfterDays { level = .warning }
        else { level = .current }
        return ChartAge(days: days, level: level)
    }
}

public extension InstalledRegion {
    func age(now: Date = Date(), policy: StalenessPolicy = .default) -> ChartAge {
        ChartAge.evaluate(dataDate: chart.dataDate, now: now, policy: policy)
    }
}
