import Foundation
import NavCore

/// Map rotation offered by the chart screen.
public enum MapOrientationMode: String, Sendable, Equatable, CaseIterable {
    case northUp
    case courseUp

    public var label: String {
        switch self {
        case .northUp: return "North up"
        case .courseUp: return "Course up"
        }
    }

    public var toggled: MapOrientationMode {
        switch self {
        case .northUp: return .courseUp
        case .courseUp: return .northUp
        }
    }
}

/// The boat's latest position and smoothed motion, fed fix by fix. A value type so the view model just
/// stores it and tests can drive it directly.
public struct NavigationReadout: Sendable, Equatable {
    /// Below this smoothed speed the course is too noisy to orient the map or the marker by.
    public static let minimumSpeedForCourse: Double = 0.5 * UnitConversion.metersPerSecondPerKnot

    public private(set) var lastFix: Fix?
    /// Smoothed speed over ground, m/s.
    public private(set) var speedOverGround: Double?
    /// Smoothed course over ground, degrees true; nil when slower than `minimumSpeedForCourse`.
    public private(set) var courseOverGround: Double?
    /// Latest compass heading, degrees true.
    public private(set) var heading: Double?

    private var filter: SOGCOGFilter

    public init() {
        filter = SOGCOGFilter(timeConstant: 4, minimumSpeedForCourse: NavigationReadout.minimumSpeedForCourse,
                              maximumGap: 30)
    }

    public mutating func update(with fix: Fix) {
        lastFix = fix
        if let motion = filter.update(with: fix) {
            speedOverGround = motion.speed
            courseOverGround = motion.course
        }
    }

    public mutating func update(heading: Double) {
        self.heading = Angle.normalizeBearing(heading)
    }

    public mutating func reset() {
        self = NavigationReadout()
    }

    /// The direction the own-ship marker points: course over ground when moving, otherwise the
    /// compass heading, otherwise nil (draw a plain dot).
    public var markerDirection: Double? {
        if let course = courseOverGround { return course }
        return heading
    }

    /// Map camera direction (degrees clockwise from north at the top of the screen) for an orientation
    /// mode. Course up falls back to the heading, then to `current` (hold the last rotation) when stopped.
    public func mapDirection(for mode: MapOrientationMode, current: Double) -> Double {
        switch mode {
        case .northUp:
            return 0
        case .courseUp:
            if let direction = markerDirection { return direction }
            return current
        }
    }

    /// Rotation to draw the marker with, in degrees clockwise on screen, given the map's direction.
    public static func markerScreenRotation(markerDirection: Double, mapDirection: Double) -> Double {
        Angle.normalizeBearing(markerDirection - mapDirection)
    }
}
