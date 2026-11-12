import AppServices
import Foundation
import NavCore
import Observation

/// Position, speed and course for the chart screen, from the device (CoreLocation) or, in debug builds,
/// from the simulated Tampa Bay track.
@MainActor
@Observable
final class NavigationModel {
    private(set) var readout: NavigationReadout = NavigationReadout()
    private(set) var authorization: LocationAuthorization = .notDetermined
    private(set) var isSimulating: Bool = false

    private let makeDeviceService: @MainActor () -> any LocationService
    @ObservationIgnored private var service: (any LocationService)?
    @ObservationIgnored private var streamTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var running = false

    init(makeDeviceService: @escaping @MainActor () -> any LocationService) {
        self.makeDeviceService = makeDeviceService
    }

    /// Starts location updates after the disclaimer has been accepted (asks for when-in-use permission).
    func start() {
        guard !running else { return }
        running = true
        let next: any LocationService = isSimulating ? NavigationModel.makeSimulatedService() : makeDeviceService()
        attach(next)
    }

    /// Debug only (the toggle is compiled into debug builds only): replay a track instead of GPS.
    func setSimulating(_ simulate: Bool) {
        guard simulate != isSimulating else { return }
        isSimulating = simulate
        guard running else { return }
        let next: any LocationService = simulate ? NavigationModel.makeSimulatedService() : makeDeviceService()
        attach(next)
    }

    private static func makeSimulatedService() -> any LocationService {
        SimulatedLocationService(track: SimulatedTrack.tampaBay(),
                                 options: SimulatedLocationService.Options(interval: .seconds(1), loops: true,
                                                                           restampsToNow: true))
    }

    private func attach(_ next: any LocationService) {
        for task in streamTasks { task.cancel() }
        streamTasks = []
        service?.stopUpdates()
        readout.reset()
        service = next

        let fixes: AsyncStream<Fix> = next.fixes()
        let headings: AsyncStream<Double> = next.headings()
        let authorizations: AsyncStream<LocationAuthorization> = next.authorizationUpdates()

        let fixTask = Task { [weak self] in
            for await fix in fixes {
                self?.readout.update(with: fix)
            }
        }
        let headingTask = Task { [weak self] in
            for await heading in headings {
                self?.readout.update(heading: heading)
            }
        }
        let authorizationTask = Task { [weak self] in
            for await status in authorizations {
                self?.authorization = status
            }
        }
        streamTasks = [fixTask, headingTask, authorizationTask]

        authorization = next.authorization
        next.requestWhenInUseAuthorization()
        next.startUpdates()
    }
}
