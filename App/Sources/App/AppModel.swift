import AppServices
import ChartKit
import Foundation
import Observation

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

    @ObservationIgnored private var started = false

    init(environment: AppEnvironment, manifest: ManifestLoader.Loaded, navigation: NavigationModel,
         notices: [StartupNotice]) {
        self.environment = environment
        self.navigation = navigation
        self.notices = notices
        let mapModel = ChartMapModel(library: environment.charts)
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
