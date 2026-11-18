import Foundation
import NavCore

/// Location permission as the app sees it (mirrors `CLAuthorizationStatus` without importing CoreLocation).
public enum LocationAuthorization: String, Sendable, Equatable, CaseIterable {
    case notDetermined
    case restricted
    case denied
    case authorizedWhenInUse
    case authorizedAlways

    /// True when the app may receive position updates (in the foreground at least).
    public var allowsUpdates: Bool {
        switch self {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .notDetermined, .restricted, .denied: return false
        }
    }
}

/// A source of position fixes: CoreLocation on a device, a replayed track in previews, tests and the simulator.
///
/// All members are main-actor isolated because the CoreLocation implementation must create and drive its
/// `CLLocationManager` on the main thread. Streams can be consumed from anywhere.
@MainActor
public protocol LocationService: AnyObject {
    var authorization: LocationAuthorization { get }
    /// True while updates have been requested with `startUpdates()`.
    var isUpdating: Bool { get }
    /// True while a track recording keeps location running in the background (when the app allows it).
    var isRecording: Bool { get }

    /// Asks for when-in-use permission if it has not been decided yet.
    func requestWhenInUseAuthorization()
    func startUpdates()
    func stopUpdates()
    /// Turns the background-tracking configuration on or off (see `LocationPolicy`).
    func setRecording(_ recording: Bool)

    /// Position fixes, newest last. A new subscriber first receives the latest fix, if any.
    func fixes() -> AsyncStream<Fix>
    /// True heading in degrees (compass), where the hardware provides one.
    func headings() -> AsyncStream<Double>
    /// Authorization changes, starting with the current value.
    func authorizationUpdates() -> AsyncStream<LocationAuthorization>
}

/// The CoreLocation configuration for a given situation, as plain values so it can be tested on Linux.
public struct LocationSettings: Sendable, Equatable {
    /// `CLLocationManager.allowsBackgroundLocationUpdates`. Must only be true when the app's Info.plist
    /// declares the `location` background mode, otherwise CoreLocation raises an exception.
    public var allowsBackgroundUpdates: Bool
    /// `CLLocationManager.showsBackgroundLocationIndicator`.
    public var showsBackgroundIndicator: Bool
    /// `CLLocationManager.pausesLocationUpdatesAutomatically`. Always false: a chart plotter must keep
    /// updating while the boat drifts or lies at anchor.
    public var pausesAutomatically: Bool
    /// Use `CLActivityType.otherNavigation` (true) or `.other` (false).
    public var usesNavigationActivityType: Bool

    public init(allowsBackgroundUpdates: Bool, showsBackgroundIndicator: Bool, pausesAutomatically: Bool,
                usesNavigationActivityType: Bool) {
        self.allowsBackgroundUpdates = allowsBackgroundUpdates
        self.showsBackgroundIndicator = showsBackgroundIndicator
        self.pausesAutomatically = pausesAutomatically
        self.usesNavigationActivityType = usesNavigationActivityType
    }
}

public enum LocationPolicy {
    /// Info.plist key and value that enable background location.
    public static let backgroundModesKey = "UIBackgroundModes"
    public static let locationBackgroundMode = "location"

    /// The settings to apply.
    ///
    /// - Parameters:
    ///   - recording: a track recording is running. Only this switches the background pieces on.
    ///   - backgroundModeDeclared: the app's Info.plist lists `location` under `UIBackgroundModes`
    ///     (not yet the case in the first app build, so background updates stay off).
    ///   - authorization: current permission.
    public static func settings(recording: Bool, backgroundModeDeclared: Bool,
                                authorization: LocationAuthorization) -> LocationSettings {
        let background = recording && backgroundModeDeclared && authorization.allowsUpdates
        return LocationSettings(allowsBackgroundUpdates: background,
                                showsBackgroundIndicator: background,
                                pausesAutomatically: false,
                                usesNavigationActivityType: recording)
    }

    /// Whether an Info.plist dictionary declares the location background mode.
    public static func declaresBackgroundLocation(_ info: [String: Any]?) -> Bool {
        guard let modes = info?[backgroundModesKey] as? [String] else { return false }
        return modes.contains(locationBackgroundMode)
    }
}

/// Converts raw CoreLocation values (negative = invalid, per CoreLocation's conventions) to a NavCore `Fix`.
public enum FixConversion {
    public static func fix(latitude: Double, longitude: Double, timestamp: Date,
                           speed: Double, speedAccuracy: Double,
                           course: Double, courseAccuracy: Double,
                           horizontalAccuracy: Double) -> Fix? {
        // A negative horizontal accuracy means the coordinate itself is invalid.
        guard horizontalAccuracy >= 0, horizontalAccuracy.isFinite else { return nil }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else { return nil }
        var fixSpeed: Double? = nil
        if speed >= 0, speed.isFinite, speedAccuracy >= 0 {
            fixSpeed = speed
        }
        var fixCourse: Double? = nil
        if course >= 0, course.isFinite, courseAccuracy >= 0 {
            fixCourse = Angle.normalizeBearing(course)
        }
        return Fix(coordinate: coordinate, timestamp: timestamp, speed: fixSpeed, course: fixCourse,
                   horizontalAccuracy: horizontalAccuracy)
    }

    /// A compass heading, or nil when CoreLocation reports it as invalid (negative).
    public static func heading(trueHeading: Double, headingAccuracy: Double) -> Double? {
        guard trueHeading >= 0, trueHeading.isFinite, headingAccuracy >= 0 else { return nil }
        return Angle.normalizeBearing(trueHeading)
    }
}
