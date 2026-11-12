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
    /// Shown as a banner when the app had to fall back to temporary storage.
    private(set) var startupWarning: String?

    let environment: AppEnvironment
    let charts: ChartsModel
    let map: ChartMapModel
    let navigation: NavigationModel

    @ObservationIgnored private var started = false

    init(environment: AppEnvironment, manifest: ManifestLoader.Loaded, navigation: NavigationModel,
         startupWarning: String?) {
        self.environment = environment
        self.navigation = navigation
        self.startupWarning = startupWarning
        let mapModel = ChartMapModel(library: environment.charts)
        let chartsModel = ChartsModel(library: environment.charts, regions: manifest.regions,
                                      manifestError: manifest.error)
        self.map = mapModel
        self.charts = chartsModel
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
        let navigation = NavigationModel(makeDeviceService: { CoreLocationService() })
        let manifest: ManifestLoader.Loaded = ManifestLoader.loadBundled()
        do {
            let environment: AppEnvironment = try AppEnvironment.live()
            return AppModel(environment: environment, manifest: manifest, navigation: navigation, startupWarning: nil)
        } catch {
            let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent("GulfNavFallback", isDirectory: true)
            do {
                let environment: AppEnvironment = try AppEnvironment.make(
                    paths: AppPaths(libraryDirectory: fallbackRoot), transport: URLSessionChartTransport(),
                    acknowledgements: UserDefaultsAcknowledgementStore())
                return AppModel(environment: environment, manifest: manifest, navigation: navigation,
                                startupWarning: "Storage could not be prepared (\(error.localizedDescription)). Downloaded charts will not be kept.")
            } catch {
                fatalError("Cannot create any storage for charts: \(error)")
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
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
        await charts.start()
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
