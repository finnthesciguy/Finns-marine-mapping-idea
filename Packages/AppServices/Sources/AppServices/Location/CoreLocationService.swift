#if os(iOS)
import CoreLocation
import Foundation
import NavCore

/// `LocationService` backed by `CLLocationManager` (iOS only).
///
/// When-in-use authorization is all the first app build asks for. The background-tracking pieces
/// (`allowsBackgroundLocationUpdates`, the background indicator, activity type `.otherNavigation`) are
/// applied from `LocationPolicy` and only switch on while `setRecording(true)` is in effect; background
/// updates additionally require `location` in the app's `UIBackgroundModes`, which is not declared yet,
/// so today they stay off even while recording.
///
/// Create it on the main thread (it is `@MainActor`): CoreLocation delivers delegate callbacks on the
/// run loop of the thread that created the manager. Delegate methods are `nonisolated` and only convert
/// values and yield them into thread-safe broadcasters, so no isolation assumptions are made about the
/// thread CoreLocation calls them on.
@MainActor
public final class CoreLocationService: NSObject, LocationService, CLLocationManagerDelegate {
    public private(set) var authorization: LocationAuthorization
    public private(set) var isUpdating: Bool = false
    public private(set) var isRecording: Bool = false

    private let manager: CLLocationManager
    private let backgroundModeDeclared: Bool
    nonisolated private let fixOut: Broadcaster<Fix>
    nonisolated private let headingOut: Broadcaster<Double>
    nonisolated private let authorizationOut: Broadcaster<LocationAuthorization>

    public init(bundle: Bundle = .main) {
        let locationManager = CLLocationManager()
        let initial: LocationAuthorization = CoreLocationService.map(locationManager.authorizationStatus)
        self.manager = locationManager
        self.backgroundModeDeclared = LocationPolicy.declaresBackgroundLocation(bundle.infoDictionary)
        self.fixOut = Broadcaster<Fix>()
        self.headingOut = Broadcaster<Double>()
        self.authorizationOut = Broadcaster<LocationAuthorization>()
        self.authorization = initial
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = 2
        authorizationOut.yield(initial)
        applySettings()
    }

    // MARK: LocationService

    public func requestWhenInUseAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    public func startUpdates() {
        isUpdating = true
        guard authorization.allowsUpdates else { return }
        applySettings()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    public func stopUpdates() {
        isUpdating = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    public func setRecording(_ recording: Bool) {
        isRecording = recording
        applySettings()
    }

    public func fixes() -> AsyncStream<Fix> { fixOut.stream() }

    public func headings() -> AsyncStream<Double> { headingOut.stream() }

    public func authorizationUpdates() -> AsyncStream<LocationAuthorization> { authorizationOut.stream() }

    // MARK: Internals

    private func applySettings() {
        let settings: LocationSettings = LocationPolicy.settings(recording: isRecording,
                                                                 backgroundModeDeclared: backgroundModeDeclared,
                                                                 authorization: authorization)
        manager.pausesLocationUpdatesAutomatically = settings.pausesAutomatically
        manager.activityType = settings.usesNavigationActivityType ? CLActivityType.otherNavigation : CLActivityType.other
        // Setting this to true without the `location` background mode raises an exception; the policy
        // only returns true when the mode is declared.
        manager.allowsBackgroundLocationUpdates = settings.allowsBackgroundUpdates
        manager.showsBackgroundLocationIndicator = settings.showsBackgroundIndicator
    }

    private func authorizationDidChange(_ status: LocationAuthorization) {
        let wasAllowed: Bool = authorization.allowsUpdates
        authorization = status
        applySettings()
        if isUpdating && status.allowsUpdates && !wasAllowed {
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        }
    }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .authorizedAlways: return .authorizedAlways
        @unknown default: return .denied
        }
    }

    nonisolated static func fix(from location: CLLocation) -> Fix? {
        FixConversion.fix(latitude: location.coordinate.latitude,
                          longitude: location.coordinate.longitude,
                          timestamp: location.timestamp,
                          speed: location.speed,
                          speedAccuracy: location.speedAccuracy,
                          course: location.course,
                          courseAccuracy: location.courseAccuracy,
                          horizontalAccuracy: location.horizontalAccuracy)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            if let fix = CoreLocationService.fix(from: location) {
                fixOut.yield(fix)
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if let heading = FixConversion.heading(trueHeading: newHeading.trueHeading,
                                               headingAccuracy: newHeading.headingAccuracy) {
            headingOut.yield(heading)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // kCLErrorLocationUnknown is transient and CoreLocation keeps trying; denial arrives as an
        // authorization change. Nothing to do here.
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status: LocationAuthorization = CoreLocationService.map(manager.authorizationStatus)
        authorizationOut.yield(status)
        Task { @MainActor [weak self] in
            self?.authorizationDidChange(status)
        }
    }
}
#endif
