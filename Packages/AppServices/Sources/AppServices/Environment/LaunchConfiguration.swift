import Foundation

/// Launch options read from the process environment, used by the UI tests (and handy in the simulator).
/// The app reads them in debug builds only; release builds always use `LaunchConfiguration()`.
///
/// | Variable | Effect |
/// |---|---|
/// | `GULFNAV_DATA_ROOT=<name>` | keep all data (charts, store) in `<tmp>/GulfNavTestData/<name>/` instead of `Library/`, and ignore UserDefaults |
/// | `GULFNAV_RESET_DATA=1` | delete that directory first (clean state); only together with `GULFNAV_DATA_ROOT` |
/// | `GULFNAV_SIMULATE_GPS=1` | start with the simulated Tampa Bay track instead of CoreLocation |
/// | `GULFNAV_PREINSTALL_FIXTURE_CHART=1` | install the bundled 16 KB test chart (`FixtureChart`) at startup, no network |
/// | `GULFNAV_PREINSTALL_FIXTURE_ROUTING=1` | side-load the bundled Sarasota routing test pack (`FixtureRoutingPack`), add its test waypoints, and run the simulated GPS in Sarasota Bay |
/// | `GULFNAV_SIM_SPEED_KNOTS=<n>` | speed of the simulated track (default 6 kn; UI tests use a high speed to reach route points quickly) |
/// | `GULFNAV_TRACK_BATCH_SIZE=<n>` | track points per database write (default 10; UI tests use 2 so points are stored quickly) |
public struct LaunchConfiguration: Sendable, Equatable {
    public static let dataRootKey = "GULFNAV_DATA_ROOT"
    public static let resetDataKey = "GULFNAV_RESET_DATA"
    public static let simulateGPSKey = "GULFNAV_SIMULATE_GPS"
    public static let preinstallFixtureChartKey = "GULFNAV_PREINSTALL_FIXTURE_CHART"
    public static let preinstallFixtureRoutingKey = "GULFNAV_PREINSTALL_FIXTURE_ROUTING"
    public static let simulatedSpeedKey = "GULFNAV_SIM_SPEED_KNOTS"
    public static let trackBatchSizeKey = "GULFNAV_TRACK_BATCH_SIZE"
    /// Directory under the temporary directory that holds isolated data roots.
    public static let testDataDirectoryName = "GulfNavTestData"

    /// Sanitised name of an isolated data root (letters, digits, `-`, `_`; at most 64 characters).
    public var dataRootName: String?
    public var resetData: Bool
    public var simulateGPS: Bool
    public var preinstallFixtureChart: Bool
    /// Side-load the routing test pack and its waypoints; simulated GPS runs in Sarasota Bay.
    public var preinstallFixtureRouting: Bool
    /// Simulated track speed in knots (1...1000), nil for the default.
    public var simulatedSpeedKnots: Double?
    /// Track points per write (1...100), nil for the default.
    public var trackBatchSize: Int?

    public init(dataRootName: String? = nil, resetData: Bool = false, simulateGPS: Bool = false,
                preinstallFixtureChart: Bool = false, simulatedSpeedKnots: Double? = nil, trackBatchSize: Int? = nil,
                preinstallFixtureRouting: Bool = false) {
        self.dataRootName = dataRootName.flatMap(LaunchConfiguration.sanitize)
        self.resetData = resetData && self.dataRootName != nil
        self.simulateGPS = simulateGPS
        self.preinstallFixtureChart = preinstallFixtureChart
        self.preinstallFixtureRouting = preinstallFixtureRouting
        self.simulatedSpeedKnots = simulatedSpeedKnots.flatMap { $0.isFinite && $0 >= 1 && $0 <= 1000 ? $0 : nil }
        self.trackBatchSize = trackBatchSize.flatMap { $0 >= 1 && $0 <= 100 ? $0 : nil }
    }

    /// Parses a process environment (`ProcessInfo.processInfo.environment`).
    public init(environment: [String: String]) {
        self.init(dataRootName: environment[LaunchConfiguration.dataRootKey],
                  resetData: LaunchConfiguration.flag(environment[LaunchConfiguration.resetDataKey]),
                  simulateGPS: LaunchConfiguration.flag(environment[LaunchConfiguration.simulateGPSKey]),
                  preinstallFixtureChart: LaunchConfiguration.flag(environment[LaunchConfiguration.preinstallFixtureChartKey]),
                  simulatedSpeedKnots: environment[LaunchConfiguration.simulatedSpeedKey].flatMap { Double($0) },
                  trackBatchSize: environment[LaunchConfiguration.trackBatchSizeKey].flatMap { Int($0) },
                  preinstallFixtureRouting: LaunchConfiguration.flag(environment[LaunchConfiguration.preinstallFixtureRoutingKey]))
    }

    /// True when data is kept in an isolated directory (UI tests): UserDefaults are then neither read nor written.
    public var usesIsolatedData: Bool { dataRootName != nil }

    /// The isolated `Library`-equivalent directory, or nil to use the sandbox `Library/`.
    public func isolatedLibraryDirectory(temporaryDirectory: URL) -> URL? {
        guard let name = dataRootName else { return nil }
        return temporaryDirectory
            .appendingPathComponent(LaunchConfiguration.testDataDirectoryName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The paths to use, deleting an isolated root first when `resetData` is set.
    public func resolvePaths(temporaryDirectory: URL, live: () throws -> AppPaths) throws -> AppPaths {
        guard let root = isolatedLibraryDirectory(temporaryDirectory: temporaryDirectory) else { return try live() }
        if resetData, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        return AppPaths(libraryDirectory: root)
    }

    static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    static func sanitize(_ name: String) -> String? {
        var out: String = ""
        for scalar in name.unicodeScalars {
            let isAllowed: Bool = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_"
            if isAllowed { out.unicodeScalars.append(scalar) }
        }
        if out.isEmpty { return nil }
        return String(out.prefix(64))
    }
}
