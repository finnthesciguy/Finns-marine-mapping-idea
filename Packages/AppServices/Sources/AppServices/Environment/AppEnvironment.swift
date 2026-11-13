import ChartKit
import Foundation
import Persistence

/// Where the app keeps its files.
///
/// Everything lives under `Library/` (not `Documents/`, which the user can see in the Files app):
///
///     Library/Charts/    ChartKit installer root: state file, staging/, regions/  (excluded from backup)
///     Library/AppData/   Persistence store (waypoints, routes, tracks, settings)  (backed up)
///     Library/RoutingPacks/  side-loaded routing packs (debug fixture, debug document picker)  (excluded from backup)
///
/// `Library/Application Support` is avoided for charts because its path contains a space and the map
/// engine reads packages through `mbtiles://` URLs (MapLibre percent-decodes the path; a plain path
/// with no spaces or `%` needs no escaping at all).
public struct AppPaths: Sendable, Equatable {
    public var libraryDirectory: URL

    public init(libraryDirectory: URL) {
        self.libraryDirectory = libraryDirectory.standardizedFileURL
    }

    /// The app sandbox's `Library/` directory.
    public static func live() throws -> AppPaths {
        let library: URL = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
        return AppPaths(libraryDirectory: library)
    }

    public var chartsDirectory: URL { libraryDirectory.appendingPathComponent("Charts", isDirectory: true) }
    public var dataDirectory: URL { libraryDirectory.appendingPathComponent("AppData", isDirectory: true) }
    public var storeURL: URL { dataDirectory.appendingPathComponent("gulfnav.sqlite", isDirectory: false) }
    /// Side-loaded routing packs (packs installed with a chart region live under `chartsDirectory`).
    public var routingPacksDirectory: URL { libraryDirectory.appendingPathComponent("RoutingPacks", isDirectory: true) }

    /// True when `url`'s path can go into an `mbtiles://` URL verbatim.
    public static func isSafeForMBTilesURL(_ url: URL) -> Bool {
        let path: String = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return false }
        for character in path {
            if character == " " || character == "%" || character == "?" || character == "#" { return false }
            if character.isNewline { return false }
        }
        return true
    }

    /// Creates the directories and marks the charts directory as excluded from iCloud/iTunes backup
    /// (packages are hundreds of MB and can be downloaded again).
    public func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: chartsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: routingPacksDirectory, withIntermediateDirectories: true)
        try AppPaths.excludeFromBackup(chartsDirectory)
        try AppPaths.excludeFromBackup(routingPacksDirectory)
    }

    public static func excludeFromBackup(_ url: URL) throws {
        #if canImport(Darwin)
        var target: URL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        #endif
    }

    /// Whether `url` is marked excluded from backup (always false where the flag does not exist).
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        #if canImport(Darwin)
        let values: URLResourceValues? = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values?.isExcludedFromBackup ?? false
        #else
        return false
        #endif
    }
}

/// The app's composition root: paths, the chart library (installer + transport), the Persistence store and
/// the disclaimer store.
public final class AppEnvironment: Sendable {
    public let paths: AppPaths
    public let charts: ChartLibrary
    public let acknowledgements: any AcknowledgementStore
    /// User data: waypoints, routes, tracks, settings.
    public let store: PersistenceStore
    /// False when the store could not be opened and an in-memory store stands in (nothing is kept).
    public let storeIsPersistent: Bool
    /// The on-disk store's open report (nil for the in-memory fallback).
    public let openReport: OpenReport?
    /// Messages for the user from opening storage.
    public let notices: [StartupNotice]
    /// Where a disclaimer acceptance from a build before Persistence may still be stored (nil: none to migrate).
    public let legacyAcknowledgements: (any RemovableAcknowledgementStore)?
    public let launch: LaunchConfiguration
    /// Installed routing packs (with chart regions, plus side-loaded ones), opened one at a time.
    public let routingPacks: RoutingPackLibrary
    /// The auto-route planner on `routingPacks`, gated by the auto-route notice in `store`.
    public let planner: AutoRoutePlanner

    public init(paths: AppPaths, charts: ChartLibrary, acknowledgements: any AcknowledgementStore,
                store: PersistenceStore, storeIsPersistent: Bool = true, openReport: OpenReport? = nil,
                notices: [StartupNotice] = [], legacyAcknowledgements: (any RemovableAcknowledgementStore)? = nil,
                launch: LaunchConfiguration = LaunchConfiguration(), routingPacks: RoutingPackLibrary? = nil) {
        self.paths = paths
        self.charts = charts
        self.acknowledgements = acknowledgements
        self.store = store
        self.storeIsPersistent = storeIsPersistent
        self.openReport = openReport
        self.notices = notices
        self.legacyAcknowledgements = legacyAcknowledgements
        self.launch = launch
        let library: RoutingPackLibrary = routingPacks
            ?? RoutingPackLibrary(sideLoadDirectory: paths.routingPacksDirectory, installer: charts.installer)
        library.attach(installer: charts.installer)
        self.routingPacks = library
        self.planner = AutoRoutePlanner(library: library, noticeGate: AutoRouteNoticeGate(store: store))
    }

    /// The installer configuration with RoutingKit's full pack check as the routing-pack validator (unless the
    /// caller set one), so a corrupt routing pack is rejected at install time.
    static func withRoutingPackValidator(_ configuration: ChartInstaller.Configuration,
                                         library: RoutingPackLibrary) -> ChartInstaller.Configuration {
        var out: ChartInstaller.Configuration = configuration
        if out.routingPackValidator == nil { out.routingPackValidator = library.installValidator }
        return out
    }

    /// Builds the environment on `paths` with the given transport. Without `store`, an in-memory store is
    /// used (tests); without `acknowledgements`, the disclaimer is kept in `store`.
    public static func make(paths: AppPaths, transport: any ChartTransport,
                            acknowledgements: (any AcknowledgementStore)? = nil,
                            store: PersistenceStore? = nil,
                            diskSpace: any DiskSpaceProvider = FileSystemDiskSpace(),
                            configuration: ChartInstaller.Configuration = ChartInstaller.Configuration()) throws -> AppEnvironment {
        try paths.prepare()
        let packs = RoutingPackLibrary(sideLoadDirectory: paths.routingPacksDirectory)
        let installer = try ChartInstaller(rootDirectory: paths.chartsDirectory, transport: transport,
                                           diskSpace: diskSpace,
                                           configuration: withRoutingPackValidator(configuration, library: packs))
        let library = ChartLibrary(installer: installer, transport: transport, diskSpace: diskSpace)
        let userStore: PersistenceStore = try store ?? PersistenceStore(inMemoryWith: PersistenceStore.Options())
        let ack: any AcknowledgementStore = acknowledgements ?? PersistenceAcknowledgementStore(store: userStore)
        return AppEnvironment(paths: paths, charts: library, acknowledgements: ack, store: userStore,
                              storeIsPersistent: store != nil, routingPacks: packs)
    }

    /// The real app: sandbox `Library/` (or an isolated test directory, see `LaunchConfiguration`), the
    /// Persistence store at `paths.storeURL` (opened by `StoreOpener`, never fatal), the disclaimer in that
    /// store, and UserDefaults as the legacy acknowledgement to migrate.
    ///
    /// - Parameters:
    ///   - transport: chart transport (default `URLSessionChartTransport`).
    ///   - temporaryDirectory: parent of isolated test data roots.
    public static func live(launch: LaunchConfiguration = LaunchConfiguration(),
                            transport: (any ChartTransport)? = nil,
                            temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                            diskSpace: any DiskSpaceProvider = FileSystemDiskSpace()) throws -> AppEnvironment {
        let paths: AppPaths = try launch.resolvePaths(temporaryDirectory: temporaryDirectory, live: { try AppPaths.live() })
        return try open(paths: paths, launch: launch, transport: transport ?? URLSessionChartTransport(),
                        diskSpace: diskSpace,
                        legacy: launch.usesIsolatedData ? nil : UserDefaultsAcknowledgementStore())
    }

    /// `live` on explicit paths (also used for the temporary-directory fallback and in tests).
    public static func open(paths: AppPaths, launch: LaunchConfiguration, transport: any ChartTransport,
                            diskSpace: any DiskSpaceProvider = FileSystemDiskSpace(),
                            configuration: ChartInstaller.Configuration = ChartInstaller.Configuration(),
                            legacy: (any RemovableAcknowledgementStore)?) throws -> AppEnvironment {
        try paths.prepare()
        let opened: StoreOpener.Result = try StoreOpener.open(at: paths.storeURL)
        let packs = RoutingPackLibrary(sideLoadDirectory: paths.routingPacksDirectory)
        let installer = try ChartInstaller(rootDirectory: paths.chartsDirectory, transport: transport,
                                           diskSpace: diskSpace,
                                           configuration: withRoutingPackValidator(configuration, library: packs))
        let library = ChartLibrary(installer: installer, transport: transport, diskSpace: diskSpace)
        return AppEnvironment(paths: paths, charts: library,
                              acknowledgements: PersistenceAcknowledgementStore(store: opened.store),
                              store: opened.store, storeIsPersistent: opened.isPersistent,
                              openReport: opened.report, notices: opened.notices,
                              legacyAcknowledgements: legacy, launch: launch, routingPacks: packs)
    }

    /// Copies a disclaimer acceptance from the legacy store into the Persistence store (removing the legacy
    /// copy only when the store is on disk). Call once at startup, before reading the acknowledgement.
    @discardableResult
    public func migrateLegacyAcknowledgement() async -> AcknowledgementMigration.Outcome {
        guard let legacy = legacyAcknowledgements else { return .nothingToMigrate }
        return await AcknowledgementMigration.run(from: legacy, to: acknowledgements, removeLegacy: storeIsPersistent)
    }
}
