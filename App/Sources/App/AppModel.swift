import AppServices
import ChartKit
import Foundation
import Observation
import Persistence

/// Root of the app's state: composition (AppEnvironment), the disclaimer gate and the feature models.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case needsDisclaimer
        case ready
    }

    private(set) var phase: Phase = .starting
    /// Shown as banners on the map screen (storage fallback, recovered data, interrupted recordings).
    private(set) var notices: [StartupNotice] = []

    let environment: AppEnvironment
    let charts: ChartsModel
    let map: ChartMapModel
    let navigation: NavigationModel
    /// Waypoints, routes, tracks, navigation and recording.
    let plotter: PlotterModel
    /// Boat profiles and the auto-route planner.
    let profiles: BoatProfilesModel
    let autoRoute: AutoRouteModel
    /// A GPX file opened in the app from elsewhere ("Open in…"), waiting for the map screen to plan it.
    var pendingOpenURL: URL?
    /// Online NOAA chart tiles (disk cache under `Library/LiveCharts`, at most two requests in flight).
    let liveCharts: LiveChartTileLoader
    /// Routing packs shipped in the app and linked at start-up (`BundledRoutingPacks`), -1 until done.
    private(set) var bundledPackCount: Int = -1
    private(set) var bundledPackProblems: Int = 0
    /// For the debug `app.status` probe: `bundledPacks=… bundledProblems=… liveCharts=… liveSetting=…`.
    var statusValue: String {
        "bundledPacks=\(bundledPackCount); bundledProblems=\(bundledPackProblems); " + map.liveStatus.statusValue
            + "; liveOn=\(map.liveCharts ? "yes" : "no")"
    }
    /// A menu-bar command (Mac) waiting for the map screen to carry it out.
    private(set) var commandRequest: AppCommandRequest?
    @ObservationIgnored private var commandSerial: Int = 0

    @ObservationIgnored private var started = false
    @ObservationIgnored private var liveStatusTask: Task<Void, Never>?

    init(environment: AppEnvironment, manifest: ManifestLoader.Loaded, navigation: NavigationModel,
         notices: [StartupNotice]) {
        self.environment = environment
        self.navigation = navigation
        self.notices = notices
        let mapModel = ChartMapModel(library: environment.charts)
        let liveRoot: URL = environment.paths.libraryDirectory.appendingPathComponent("LiveCharts", isDirectory: true)
        try? FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        try? AppPaths.excludeFromBackup(liveRoot)
        self.liveCharts = LiveChartTileLoader(cache: LiveChartCache(root: liveRoot))
        let chartsModel = ChartsModel(library: environment.charts, routingPacks: environment.routingPacks,
                                      regions: manifest.regions, manifestError: manifest.error)
        self.map = mapModel
        self.charts = chartsModel
        let plotterModel = PlotterModel(store: environment.store,
                                        trackBatchSize: environment.launch.trackBatchSize ?? 10)
        self.plotter = plotterModel
        let profilesModel = BoatProfilesModel(store: environment.store)
        self.profiles = profilesModel
        let autoRouteModel = AutoRouteModel(planner: environment.planner, store: environment.store, plotter: plotterModel,
                                            profiles: profilesModel)
        self.autoRoute = autoRouteModel
        autoRouteModel.currentPosition = { [weak navigation] in
            navigation?.readout.lastFix?.coordinate
        }
        autoRouteModel.focusMap = { [weak mapModel] coordinates in
            mapModel?.focus(on: coordinates)
        }
        plotterModel.currentPosition = { [weak navigation] in
            navigation?.readout.lastFix?.coordinate
        }
        navigation.onFix = { [weak plotterModel, weak navigation] fix in
            plotterModel?.handle(fix, speedOverGround: navigation?.readout.speedOverGround)
        }
        plotterModel.recording.onRecordingChange = { [weak navigation] recording in
            navigation?.setRecording(recording)
        }
        chartsModel.onInstalledChange = { [weak mapModel] regions in
            mapModel?.update(installed: regions)
        }
        chartsModel.onLiveChartsToggle = { [weak self] on in
            self?.setLiveCharts(on)
        }
        chartsModel.prepareForRemoval = { [weak mapModel] regionID in
            guard let mapModel else { return }
            await mapModel.hideRegionAndWait(regionID)
        }
    }

    /// The real app. Falls back to a temporary directory if the sandbox Library cannot be prepared
    /// (should not happen; the user is told charts will not be kept).
    static func live() -> AppModel {
        let launch: LaunchConfiguration = AppModel.launchConfiguration()
        let navigation = NavigationModel(makeDeviceService: { CoreLocationService() },
                                         startSimulating: launch.simulateGPS,
                                         simulatedSpeedKnots: launch.simulatedSpeedKnots ?? 6,
                                         simulatedRoute: launch.preinstallFixtureRouting
                                             ? FixtureRoutingPack.simulatedTrack : SimulatedTrack.tampaBayWaypoints)
        var manifest: ManifestLoader.Loaded = ManifestLoader.loadBundled()
        var transport: any ChartTransport = URLSessionChartTransport()
        if launch.preinstallFixtureChart, let fixture = FixtureChart.bundledFile(in: Bundle.main) {
            transport = LocalFileChartTransport(files: [FixtureChart.packageURL: fixture], fallback: transport)
            // First in the list so the UI tests find its row without scrolling.
            manifest.regions.insert(FixtureChart.region, at: 0)
        }
        do {
            let environment: AppEnvironment = try AppEnvironment.live(launch: launch, transport: transport)
            return AppModel(environment: environment, manifest: manifest, navigation: navigation,
                            notices: environment.notices)
        } catch {
            let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent("GulfNavFallback", isDirectory: true)
            do {
                let environment: AppEnvironment = try AppEnvironment.open(
                    paths: AppPaths(libraryDirectory: fallbackRoot), launch: launch, transport: transport,
                    legacy: launch.usesIsolatedData ? nil : UserDefaultsAcknowledgementStore())
                var notices: [StartupNotice] = [StartupNotice(
                    kind: .storageFallback,
                    message: "Storage could not be prepared (\(error.localizedDescription)). Downloaded charts and saved data will not be kept.")]
                notices.append(contentsOf: environment.notices)
                return AppModel(environment: environment, manifest: manifest, navigation: navigation, notices: notices)
            } catch {
                fatalError("Cannot create any storage: \(error)")
            }
        }
    }

    /// Test and simulator switches (see `LaunchConfiguration`). Only debug builds read the environment.
    static func launchConfiguration() -> LaunchConfiguration {
        #if DEBUG
        return LaunchConfiguration(environment: ProcessInfo.processInfo.environment)
        #else
        return LaunchConfiguration()
        #endif
    }

    func start() async {
        guard !started else { return }
        started = true
        await environment.migrateLegacyAcknowledgement()
        // A recording interrupted less than two hours ago is resumed (new segment); older ones are closed.
        let recovery: RecordingRecovery.Outcome = await RecordingRecovery.recover(store: environment.store, now: Date())
        notices.append(contentsOf: recovery.notices)
        if environment.launch.preinstallFixtureRouting {
            await installFixtureRouting()
        }
        if environment.launch.installsBundledRoutingPacks {
            await installBundledRoutingPacks()
        }
        await startLiveCharts()
        await plotter.start(resumedRecording: recovery.resumed)
        await profiles.start()
        map.orientation = plotter.data.settings.orientationMode
        var record: DisclaimerRecord? = nil
        do {
            record = try await environment.acknowledgements.disclaimerAcknowledgement()
        } catch {
            record = nil
        }
        if Disclaimer.needsAcknowledgement(record) {
            phase = .needsDisclaimer
        } else {
            phase = .ready
            navigation.start()
        }
        if environment.launch.preinstallFixtureChart {
            await installFixtureChart()
        }
        await charts.start()
        await autoRoute.refreshPacks()
    }

    /// Links the routing packs shipped in the app (`RoutingPacks/` in the bundle) into the routing-pack library on
    /// the first launch and whenever the bundled set changes; packs that fail the check are reported in a banner.
    private func installBundledRoutingPacks() async {
        let directory: URL? = BundledRoutingPacks.directory(in: Bundle.main)
        let library: RoutingPackLibrary = environment.routingPacks
        let outcome: BundledRoutingPacks.Outcome = await Task.detached(priority: .userInitiated) {
            BundledRoutingPacks.install(from: directory, library: library)
        }.value
        let catalog: RoutingPackCatalog = await library.catalog()
        bundledPackCount = catalog.entries.filter { $0.fileURL.lastPathComponent.hasPrefix(BundledRoutingPacks.linkPrefix) }.count
        bundledPackProblems = outcome.problems.count
        if !outcome.problems.isEmpty {
            notices.append(StartupNotice(kind: .storageFallback,
                                         message: "Some routing packs shipped with the app could not be used: "
                                             + outcome.problems.joined(separator: "; ")))
        }
    }

    // MARK: Online NOAA charts

    private func startLiveCharts() async {
        var setting: Bool = SettingKey<Bool>.liveNOAACharts.defaultValue
        if let stored = try? await environment.store.setting(.liveNOAACharts) { setting = stored }
        applyLiveCharts(environment.launch.allowsLiveCharts(setting: setting))
        let loader: LiveChartTileLoader = liveCharts
        // Status for the Charts screen and the offline indicator; the cache is kept under 2 GB.
        liveStatusTask = Task { [weak self] in
            var rounds: Int = 0
            while !Task.isCancelled {
                let status: LiveChartStatus = await loader.status
                guard let self else { return }
                if self.map.liveStatus != status { self.map.liveStatus = status }
                if self.charts.liveStatus != status { self.charts.liveStatus = status }
                if rounds % 60 == 0 {
                    let cache: LiveChartCache = loader.cache
                    let bytes: Int64 = await Task.detached(priority: .utility) { () -> Int64 in
                        cache.prune(maxBytes: 2_000_000_000)
                        return cache.totalBytes()
                    }.value
                    self.charts.liveCacheBytes = bytes
                }
                rounds += 1
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// The Charts screen's switch: saved, then applied (the launch switch of a test run still wins).
    func setLiveCharts(_ on: Bool) {
        let store: PersistenceStore = environment.store
        Task { try? await store.setSetting(.liveNOAACharts, to: on) }
        applyLiveCharts(environment.launch.allowsLiveCharts(setting: on))
    }

    private func applyLiveCharts(_ on: Bool) {
        map.setLiveCharts(on ? liveCharts : nil)
        charts.liveCharts = on
    }

    /// UI tests: side-load the bundled Sarasota routing pack and add its test waypoints (debug builds bundle it).
    private func installFixtureRouting() async {
        let problems: [String] = await FixtureRoutingPack.install(packFile: FixtureRoutingPack.bundledFile(in: Bundle.main),
                                                                  library: environment.routingPacks, store: environment.store)
        for problem in problems {
            notices.append(StartupNotice(kind: .storageFallback, message: problem))
        }
    }

    /// UI tests: install the bundled 16 KB chart through the local transport (no network).
    private func installFixtureChart() async {
        let installed: InstalledRegion? = await environment.charts.installer.installedRegion(id: FixtureChart.regionID)
        if installed != nil { return }
        do {
            try await environment.charts.install(FixtureChart.region)
        } catch {
            notices.append(StartupNotice(kind: .storageFallback, message: "Test chart could not be installed: \(error)"))
        }
    }

    /// The app is going to the background: write waiting track points and the database log.
    func enteredBackground() async {
        await plotter.recording.flush()
        try? await environment.store.checkpoint()
    }

    /// A GPX file was opened in the app.
    func open(_ url: URL) {
        guard url.pathExtension.lowercased() == GPXFiles.fileExtension || url.isFileURL else { return }
        pendingOpenURL = url
    }

    /// Asks the map screen to carry out a command (Mac menu bar and keyboard shortcuts).
    func send(_ command: AppCommand) {
        commandSerial += 1
        commandRequest = AppCommandRequest(command: command, serial: commandSerial)
    }

    func dismissNotice(_ notice: StartupNotice) {
        notices.removeAll { $0 == notice }
    }

    func acceptDisclaimer() async {
        let record = DisclaimerRecord(version: Disclaimer.currentVersion, date: Date())
        do {
            try await environment.acknowledgements.acknowledgeDisclaimer(record)
        } catch {
            // Not fatal: the user has accepted for this session; they will be asked again next launch.
        }
        phase = .ready
        navigation.start()
    }
}

/// Loads the bundled region list (ChartKit's sample Gulf manifest for now).
enum ManifestLoader {
    struct Loaded {
        var regions: [ChartRegion]
        var error: String?
    }

    static let resourceName = "gulf-manifest.sample"

    static func loadBundled(bundle: Bundle = .main) -> Loaded {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            return Loaded(regions: [], error: "The chart region list is missing from the app.")
        }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try ChartManifest.decode(from: data)
            return Loaded(regions: manifest.regions, error: nil)
        } catch {
            return Loaded(regions: [], error: "The chart region list could not be read: \(error)")
        }
    }
}
