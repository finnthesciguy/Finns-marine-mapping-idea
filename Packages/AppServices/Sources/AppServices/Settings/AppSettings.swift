import Foundation
import Persistence

/// The user's settings, read from and written to Persistence's typed keys.
public struct AppSettings: Sendable, Equatable {
    public var distanceUnit: DistanceUnit
    public var depthUnit: DepthUnit
    public var speedUnit: SpeedUnit
    /// Map orientation at launch. Only north up and course up are offered (heading up maps to course up).
    public var mapOrientation: MapOrientation
    /// Seconds between recorded track points.
    public var trackInterval: Double
    /// Metres the boat must move before another track point is recorded.
    public var trackMinimumDistance: Double
    public var keepScreenOn: Bool

    public init(distanceUnit: DistanceUnit = .nauticalMiles, depthUnit: DepthUnit = .feet, speedUnit: SpeedUnit = .knots,
                mapOrientation: MapOrientation = .northUp, trackInterval: Double = 5, trackMinimumDistance: Double = 10,
                keepScreenOn: Bool = true) {
        self.distanceUnit = distanceUnit
        self.depthUnit = depthUnit
        self.speedUnit = speedUnit
        self.mapOrientation = mapOrientation
        self.trackInterval = trackInterval
        self.trackMinimumDistance = trackMinimumDistance
        self.keepScreenOn = keepScreenOn
    }

    /// Choices offered for the track recording interval, seconds.
    public static let trackIntervalChoices: [Double] = [1, 2, 5, 10, 30, 60]

    public var orientationMode: MapOrientationMode {
        switch mapOrientation {
        case .northUp: return .northUp
        case .courseUp, .headingUp: return .courseUp
        }
    }

    public var units: UnitPreferences {
        UnitPreferences(distance: distanceUnit, depth: depthUnit, speed: speedUnit)
    }

    public var trackFilter: TrackPointFilter {
        TrackPointFilter(minimumInterval: max(1, trackInterval), minimumDistance: max(0, trackMinimumDistance))
    }

    /// Reads every setting; a value that cannot be read keeps its default.
    public static func load(from store: PersistenceStore) async -> AppSettings {
        var settings = AppSettings()
        if let v = try? await store.setting(.distanceUnit) { settings.distanceUnit = v }
        if let v = try? await store.setting(.depthUnit) { settings.depthUnit = v }
        if let v = try? await store.setting(.speedUnit) { settings.speedUnit = v }
        if let v = try? await store.setting(.mapOrientation) { settings.mapOrientation = v }
        if let v = try? await store.setting(.trackRecordingInterval) { settings.trackInterval = v }
        if let v = try? await store.setting(.trackRecordingMinimumDistance) { settings.trackMinimumDistance = v }
        if let v = try? await store.setting(.keepScreenOn) { settings.keepScreenOn = v }
        return settings
    }

    /// Writes the settings that differ from `previous` (all of them when `previous` is nil).
    public func save(to store: PersistenceStore, previous: AppSettings? = nil) async throws {
        if previous?.distanceUnit != distanceUnit { try await store.setSetting(.distanceUnit, to: distanceUnit) }
        if previous?.depthUnit != depthUnit { try await store.setSetting(.depthUnit, to: depthUnit) }
        if previous?.speedUnit != speedUnit { try await store.setSetting(.speedUnit, to: speedUnit) }
        if previous?.mapOrientation != mapOrientation { try await store.setSetting(.mapOrientation, to: mapOrientation) }
        if previous?.trackInterval != trackInterval { try await store.setSetting(.trackRecordingInterval, to: trackInterval) }
        if previous?.trackMinimumDistance != trackMinimumDistance {
            try await store.setSetting(.trackRecordingMinimumDistance, to: trackMinimumDistance)
        }
        if previous?.keepScreenOn != keepScreenOn { try await store.setSetting(.keepScreenOn, to: keepScreenOn) }
    }
}

extension DistanceUnit {
    public var label: String {
        switch self {
        case .nauticalMiles: return "Nautical miles"
        case .statuteMiles: return "Statute miles"
        case .kilometers: return "Kilometres"
        }
    }
}

extension DepthUnit {
    public var label: String {
        switch self {
        case .feet: return "Feet"
        case .meters: return "Metres"
        case .fathoms: return "Fathoms"
        }
    }
}

extension SpeedUnit {
    public var label: String {
        switch self {
        case .knots: return "Knots"
        case .milesPerHour: return "Miles per hour"
        case .kilometersPerHour: return "Kilometres per hour"
        }
    }
}
