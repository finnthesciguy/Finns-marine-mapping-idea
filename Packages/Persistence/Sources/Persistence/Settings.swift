import Foundation

/// A typed settings key. Values are stored as JSON, so any `Codable` type works.
///
/// ```swift
/// let units = try await store.setting(.distanceUnit)      // DistanceUnit, default .nauticalMiles
/// try await store.setSetting(.mapOrientation, to: .courseUp)
/// ```
public struct SettingKey<Value: Codable & Sendable & Equatable>: Sendable, Hashable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }

    public static func == (a: Self, b: Self) -> Bool { a.name == b.name }
    public func hash(into h: inout Hasher) { h.combine(name) }
}

/// Distance display unit.
public enum DistanceUnit: String, Codable, Sendable, CaseIterable { case nauticalMiles, statuteMiles, kilometers }
/// Depth and height display unit.
public enum DepthUnit: String, Codable, Sendable, CaseIterable { case feet, meters, fathoms }
/// Speed display unit.
public enum SpeedUnit: String, Codable, Sendable, CaseIterable { case knots, milesPerHour, kilometersPerHour }
/// Map rotation mode.
public enum MapOrientation: String, Codable, Sendable, CaseIterable { case northUp, courseUp, headingUp }

/// Record that the user accepted the navigation disclaimer.
public struct DisclaimerAcknowledgement: Codable, Sendable, Hashable {
    /// Version of the disclaimer text accepted; bump it to ask again.
    public var version: Int
    public var date: Date
    public init(version: Int, date: Date) {
        self.version = version
        self.date = date
    }
}

extension SettingKey where Value == DistanceUnit {
    public static var distanceUnit: Self { .init("units.distance", default: .nauticalMiles) }
}
extension SettingKey where Value == DepthUnit {
    public static var depthUnit: Self { .init("units.depth", default: .feet) }
}
extension SettingKey where Value == SpeedUnit {
    public static var speedUnit: Self { .init("units.speed", default: .knots) }
}
extension SettingKey where Value == MapOrientation {
    public static var mapOrientation: Self { .init("map.orientation", default: .northUp) }
}
extension SettingKey where Value == Double {
    /// Seconds between recorded track points.
    public static var trackRecordingInterval: Self { .init("track.recordingInterval", default: 5) }
    /// Minimum movement in metres before a new track point is recorded.
    public static var trackRecordingMinimumDistance: Self { .init("track.minimumDistance", default: 10) }
}
extension SettingKey where Value == DisclaimerAcknowledgement? {
    public static var disclaimerAcknowledgement: Self { .init("legal.disclaimerAcknowledgement", default: nil) }
}
extension SettingKey where Value == Bool {
    /// Keep the screen awake while navigating.
    public static var keepScreenOn: Self { .init("display.keepScreenOn", default: true) }
}
