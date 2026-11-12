import ChartKit
import Foundation

/// Where the app keeps its files.
///
/// Everything lives under `Library/` (not `Documents/`, which the user can see in the Files app):
///
///     Library/Charts/    ChartKit installer root: state file, staging/, regions/  (excluded from backup)
///     Library/AppData/   Persistence store (waypoints, routes, tracks, settings)  (backed up)
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
        try AppPaths.excludeFromBackup(chartsDirectory)
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

/// The app's composition root: paths, the chart library (installer + transport) and the settings store.
public final class AppEnvironment: Sendable {
    public let paths: AppPaths
    public let charts: ChartLibrary
    public let acknowledgements: any AcknowledgementStore

    public init(paths: AppPaths, charts: ChartLibrary, acknowledgements: any AcknowledgementStore) {
        self.paths = paths
        self.charts = charts
        self.acknowledgements = acknowledgements
    }

    /// Builds the environment on `paths` with the given transport.
    public static func make(paths: AppPaths, transport: any ChartTransport,
                            acknowledgements: any AcknowledgementStore,
                            diskSpace: any DiskSpaceProvider = FileSystemDiskSpace(),
                            configuration: ChartInstaller.Configuration = ChartInstaller.Configuration()) throws -> AppEnvironment {
        try paths.prepare()
        let installer = try ChartInstaller(rootDirectory: paths.chartsDirectory, transport: transport,
                                           diskSpace: diskSpace, configuration: configuration)
        let library = ChartLibrary(installer: installer, transport: transport, diskSpace: diskSpace)
        return AppEnvironment(paths: paths, charts: library, acknowledgements: acknowledgements)
    }

    #if canImport(Darwin)
    /// The real app: sandbox `Library/`, URLSession transport, disclaimer in UserDefaults (interim, see
    /// `AcknowledgementStore`).
    public static func live() throws -> AppEnvironment {
        try make(paths: try AppPaths.live(), transport: URLSessionChartTransport(),
                 acknowledgements: UserDefaultsAcknowledgementStore())
    }
    #endif
}
