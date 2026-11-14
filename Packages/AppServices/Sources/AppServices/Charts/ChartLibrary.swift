import ChartKit
import Foundation

/// How a region from the manifest is installed.
public enum InstallStrategy: Sendable, Equatable {
    /// Trust the manifest entry: its size, SHA-256 and version (`ChartInstaller.install(_:)`).
    case manifest
    /// NOAA's own NCDS packages, for which no real checksums are published: HEAD the URL, build the
    /// download spec from the validators (`RemoteFileCheck.downloadSpec`) and install with size and
    /// MBTiles integrity checks only (`ChartInstaller.install(_:chart:routingPack:)`).
    case noaaFallback

    /// Host of NOAA's NCDS MBTiles downloads.
    public static let noaaHost = "distribution.charts.noaa.gov"

    /// The first app build installs every NOAA-hosted package through the fallback: the bundled sample
    /// manifest has placeholder checksums for four of its five regions. Packages from our own chart
    /// build service (any other host, with real checksums) use the manifest.
    public static func choose(for region: ChartRegion) -> InstallStrategy {
        if region.chartPackage.url.host?.lowercased() == noaaHost { return .noaaFallback }
        if isPlaceholderChecksum(region.chartPackage.sha256) { return .noaaFallback }
        return .manifest
    }

    /// The sample manifest's placeholder: 64 zeros.
    public static func isPlaceholderChecksum(_ sha256: String) -> Bool {
        !sha256.isEmpty && sha256.allSatisfy { $0 == "0" }
    }
}

/// One installer state change, as delivered to the UI.
public struct RegionStateUpdate: Sendable, Equatable {
    public var regionID: String
    public var state: InstallState

    public init(regionID: String, state: InstallState) {
        self.regionID = regionID
        self.state = state
    }
}

/// The app's chart store: a `ChartInstaller` plus the transport and the install strategy.
///
/// Thin by design; the installer owns all download, verification and swap logic.
public final class ChartLibrary: Sendable {
    public let installer: ChartInstaller
    public let transport: any ChartTransport
    public let diskSpace: any DiskSpaceProvider
    private let updates = Broadcaster<RegionStateUpdate>(bufferSize: 256)

    public init(installer: ChartInstaller, transport: any ChartTransport,
                diskSpace: any DiskSpaceProvider = FileSystemDiskSpace()) {
        self.installer = installer
        self.transport = transport
        self.diskSpace = diskSpace
    }

    /// Starts forwarding installer state changes to `stateUpdates()`. Call once after creation.
    public func start() async {
        let sink: Broadcaster<RegionStateUpdate> = updates
        await installer.setObserver { regionID, state in
            sink.yield(RegionStateUpdate(regionID: regionID, state: state))
        }
    }

    /// Installer state changes (no replay of the latest value).
    public func stateUpdates() -> AsyncStream<RegionStateUpdate> {
        updates.stream(replayLatest: false)
    }

    /// Bytes free for new files on the volume that holds the charts, or nil if it cannot be read.
    public func freeBytes() -> Int64? {
        try? diskSpace.availableBytes(for: installer.rootDirectory)
    }

    /// The download spec the NOAA fallback will use: built from a HEAD of the package URL, so the size,
    /// version (ETag) and data date (Last-Modified) are the server's, not the sample manifest's.
    public func fallbackSpec(for region: ChartRegion) async throws -> DownloadSpec {
        let url: URL = region.chartPackage.url
        let validators: RemoteValidators
        do {
            validators = try await transport.head(url)
        } catch let error as TransportError {
            throw ChartLibrary.failure(for: error)
        } catch is CancellationError {
            throw InstallFailure.cancelled
        } catch {
            throw InstallFailure.transport(String(describing: error))
        }
        return RemoteFileCheck.downloadSpec(url: url, validators: validators)
    }

    /// Installs (or resumes, or updates) a region using `InstallStrategy.choose(for:)`.
    /// Throws `InstallFailure`. Cancelling the calling task pauses the download; the partial file is kept.
    @discardableResult
    public func install(_ region: ChartRegion) async throws -> InstalledRegion {
        switch InstallStrategy.choose(for: region) {
        case .manifest:
            return try await installer.install(region)
        case .noaaFallback:
            let spec: DownloadSpec = try await fallbackSpec(for: region)
            return try await installer.install(RegionDescriptor(region), chart: spec, routingPack: nil)
        }
    }

    /// Deletes a region's installed files and any partial download.
    public func remove(regionID: String) async throws {
        try await installer.remove(regionID: regionID)
    }

    /// Releases files replaced by an update. Call after the map has switched to the new files.
    @discardableResult
    public func releaseSupersededFiles() async -> [URL] {
        await installer.removeSupersededFiles()
    }

    /// Releases superseded files only if none of them is still referenced by `plan`, the layer plan the
    /// map has just applied. ChartKit can only release all superseded files at once, so when an update
    /// lands between the map computing its plan and applying it, this waits for the next plan instead of
    /// deleting a file the map is still reading. Returns the files removed (empty when it waited).
    @discardableResult
    public func releaseSupersededFiles(notReferencedBy plan: [ChartLayerPlan]) async -> [URL] {
        let candidates: [URL] = await installer.supersededFiles()
        if candidates.isEmpty { return [] }
        var inUse: Set<String> = []
        for entry in plan { inUse.insert(entry.sourceURL) }
        for url in candidates where inUse.contains(MapLibreSources.sourceURL(forFileAt: url)) {
            return []
        }
        return await installer.removeSupersededFiles()
    }

    static func failure(for error: TransportError) -> InstallFailure {
        switch error {
        case .interrupted: return .transport("the connection was lost")
        case .httpStatus(let code): return .transport("HTTP \(code)")
        case .diskFull: return .insufficientDiskSpace(required: 0, available: 0)
        case .cancelled: return .cancelled
        case .other(let message): return .transport(message)
        }
    }
}
