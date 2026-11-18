import Foundation

/// Course and speed over ground.
public struct CourseAndSpeed: Hashable, Sendable {
    /// Course over ground, degrees true 0..<360; nil when the vessel is effectively stationary
    /// and the direction of motion is meaningless.
    public var course: Double?
    /// Speed over ground, metres per second.
    public var speed: Double

    /// Creates a course/speed pair.
    public init(course: Double?, speed: Double) {
        self.course = course
        self.speed = speed
    }
}

/// Navigation maths built on ``Geodesy``.
public enum Navigation {
    /// Course and speed over ground implied by moving between two fixes.
    ///
    /// Returns nil if the second fix is not later than the first. The course is nil when the
    /// two positions coincide.
    public static func courseAndSpeed(from a: Fix, to b: Fix) -> CourseAndSpeed? {
        let dt = b.timestamp.timeIntervalSince(a.timestamp)
        guard dt > 0, a.coordinate.isValid, b.coordinate.isValid else { return nil }
        let inv = Geodesy.inverse(from: a.coordinate, to: b.coordinate)
        guard inv.distance.isFinite else { return nil }
        return CourseAndSpeed(course: inv.distance > 0 ? inv.initialBearing : nil, speed: inv.distance / dt)
    }

    /// Velocity made good toward a mark, metres per second: the component of the vessel's
    /// velocity along the bearing to the mark. Negative when moving away.
    public static func velocityMadeGood(speed: Double, course: Double, bearingToMark: Double) -> Double {
        speed * cos(Angle.radians(course - bearingToMark))
    }

    /// Velocity made good from `position` toward `mark` for the given course/speed over ground.
    /// Returns 0 if the course is unknown or the vessel is already at the mark.
    public static func velocityMadeGood(position: Coordinate, motion: CourseAndSpeed, toward mark: Coordinate) -> Double {
        guard let course = motion.course, position != mark else { return 0 }
        return velocityMadeGood(speed: motion.speed, course: course,
                                bearingToMark: Geodesy.initialBearing(from: position, to: mark))
    }

    /// Whether the vessel at `position` has completed the leg `legStart` → `legEnd`.
    ///
    /// The leg is complete when the vessel is inside the arrival circle around `legEnd`, or
    /// (if `policy.advanceOnPerpendicular`) has crossed the line through `legEnd` perpendicular
    /// to the leg. A zero-length leg is always complete.
    public static func legCompletion(
        position: Coordinate, legStart: Coordinate, legEnd: Coordinate, policy: LegAdvancePolicy = .init()
    ) -> LegAdvanceReason? {
        if Geodesy.distance(from: position, to: legEnd) <= policy.arrivalRadius { return .arrivalCircle }
        let p = Geodesy.project(position, legStart: legStart, legEnd: legEnd)
        if p.legLength == 0 { return .passedPerpendicular }
        if policy.advanceOnPerpendicular && p.alongTrack >= p.legLength { return .passedPerpendicular }
        return nil
    }

    /// Progress along a multi-leg route.
    ///
    /// Leg `i` runs from `waypoints[i]` to `waypoints[i + 1]`. Distances to go are measured from
    /// `position` directly to the active leg's end, then along the remaining legs. Times use the
    /// supplied speed over ground (nil times if the speed is not positive). Returns nil if the
    /// route has fewer than two waypoints or the leg index is out of range.
    public static func progress(
        position: Coordinate, waypoints: [Coordinate], activeLegIndex: Int, speedOverGround: Double?
    ) -> RouteProgress? {
        guard waypoints.count >= 2, activeLegIndex >= 0, activeLegIndex < waypoints.count - 1 else { return nil }
        let start = waypoints[activeLegIndex]
        let next = waypoints[activeLegIndex + 1]
        let toNext = Geodesy.inverse(from: position, to: next)
        let projection = Geodesy.project(position, legStart: start, legEnd: next)
        var cumulative = [toNext.distance]
        var running = toNext.distance
        if activeLegIndex + 2 < waypoints.count {
            for i in (activeLegIndex + 1)..<(waypoints.count - 1) {
                running += Geodesy.distance(from: waypoints[i], to: waypoints[i + 1])
                cumulative.append(running)
            }
        }
        let sog = speedOverGround.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        return RouteProgress(
            activeLegIndex: activeLegIndex,
            distanceToNextWaypoint: toNext.distance,
            bearingToNextWaypoint: toNext.initialBearing,
            crossTrackError: projection.crossTrack,
            distancesToGo: cumulative,
            speedOverGround: sog
        )
    }
}

/// Why a leg was considered complete.
public enum LegAdvanceReason: Hashable, Sendable {
    /// The vessel entered the arrival circle around the leg's end waypoint.
    case arrivalCircle
    /// The vessel crossed the line through the end waypoint perpendicular to the leg.
    case passedPerpendicular
}

/// Rules for deciding when to advance to the next leg.
public struct LegAdvancePolicy: Hashable, Sendable, Codable {
    /// Arrival circle radius around a waypoint, metres. Default 0.05 NM (92.6 m).
    public var arrivalRadius: Double
    /// Also advance when the perpendicular through the end waypoint is crossed.
    public var advanceOnPerpendicular: Bool

    /// Creates a policy.
    public init(arrivalRadius: Double = 0.05 * UnitConversion.metersPerNauticalMile, advanceOnPerpendicular: Bool = true) {
        self.arrivalRadius = arrivalRadius
        self.advanceOnPerpendicular = advanceOnPerpendicular
    }
}

/// Snapshot of progress along a route.
public struct RouteProgress: Hashable, Sendable {
    /// Index of the active leg (from `waypoints[i]` to `waypoints[i + 1]`).
    public var activeLegIndex: Int
    /// Distance from the current position to the active leg's end waypoint, metres.
    public var distanceToNextWaypoint: Double
    /// Initial bearing to the next waypoint, degrees true.
    public var bearingToNextWaypoint: Double
    /// Cross-track error on the active leg, metres; positive means right of track.
    public var crossTrackError: Double
    /// Distance to go to each remaining waypoint, metres: element 0 is the next waypoint,
    /// the last element is the final destination.
    public var distancesToGo: [Double]
    /// Speed over ground used for times, m/s; nil if unknown or not positive.
    public var speedOverGround: Double?

    /// Total distance to the final waypoint, metres.
    public var remainingDistance: Double { distancesToGo.last ?? 0 }

    /// Time to the next waypoint at the current SOG, seconds.
    public var timeToNextWaypoint: TimeInterval? { speedOverGround.map { distanceToNextWaypoint / $0 } }

    /// Time to go to the final waypoint at the current SOG, seconds.
    public var timeToGo: TimeInterval? { speedOverGround.map { remainingDistance / $0 } }

    /// Time to go to each remaining waypoint, seconds (aligned with ``distancesToGo``).
    public var timesToGo: [TimeInterval]? { speedOverGround.map { s in distancesToGo.map { $0 / s } } }

    /// Estimated time of arrival at the final waypoint.
    public func eta(from now: Date) -> Date? { timeToGo.map { now.addingTimeInterval($0) } }
}

/// Tracks the active leg of a route and advances it as the vessel moves.
public struct RouteNavigator: Hashable, Sendable {
    /// Route waypoints in order.
    public let waypoints: [Coordinate]
    /// Leg-advance rules.
    public var policy: LegAdvancePolicy
    /// Index of the active leg. Equal to `waypoints.count - 1` once finished.
    public private(set) var activeLegIndex: Int
    /// True once the final waypoint has been reached (or the route has fewer than two waypoints).
    public var isFinished: Bool { activeLegIndex >= waypoints.count - 1 }

    /// One leg-advance event.
    public struct Event: Hashable, Sendable {
        /// The leg that was completed.
        public var completedLegIndex: Int
        /// Why it was completed.
        public var reason: LegAdvanceReason
    }

    /// Creates a navigator starting on `startingLeg`.
    public init(waypoints: [Coordinate], startingLeg: Int = 0, policy: LegAdvancePolicy = .init()) {
        self.waypoints = waypoints
        self.policy = policy
        self.activeLegIndex = min(max(startingLeg, 0), max(waypoints.count - 1, 0))
    }

    /// Feeds a new position and advances through any legs it completes. Returns the
    /// completed legs, in order (usually empty or one element).
    public mutating func update(position: Coordinate) -> [Event] {
        var events: [Event] = []
        while !isFinished {
            let i = activeLegIndex
            guard let reason = Navigation.legCompletion(
                position: position, legStart: waypoints[i], legEnd: waypoints[i + 1], policy: policy
            ) else { break }
            events.append(Event(completedLegIndex: i, reason: reason))
            activeLegIndex += 1
        }
        return events
    }

    /// Manually sets the active leg (e.g. user chose "skip waypoint").
    public mutating func activateLeg(_ index: Int) {
        activeLegIndex = min(max(index, 0), max(waypoints.count - 1, 0))
    }

    /// Progress along the remaining route, or nil if finished.
    public func progress(position: Coordinate, speedOverGround: Double?) -> RouteProgress? {
        Navigation.progress(position: position, waypoints: waypoints, activeLegIndex: activeLegIndex,
                            speedOverGround: speedOverGround)
    }
}

/// Smooths noisy speed and course over ground from successive fixes.
///
/// Speed is smoothed as a scalar; course is smoothed as a velocity vector so that it averages
/// correctly across north (359° and 1° average to 0°, not 180°). Smoothing is a first-order
/// low-pass filter with time constant ``timeConstant``, so irregular fix intervals are handled.
public struct SOGCOGFilter: Hashable, Sendable {
    /// Filter time constant, seconds. Larger is smoother but lags more.
    public var timeConstant: TimeInterval
    /// Below this smoothed speed (m/s) the course is reported as nil.
    public var minimumSpeedForCourse: Double
    /// A gap longer than this between fixes restarts the filter, seconds.
    public var maximumGap: TimeInterval

    /// Latest smoothed values, or nil before the first usable fix.
    public private(set) var current: CourseAndSpeed?

    private var speed = 0.0
    private var vEast = 0.0
    private var vNorth = 0.0
    private var hasVector = false
    private var lastFix: Fix?
    private var lastUpdate: Date?

    /// Creates a filter.
    public init(timeConstant: TimeInterval = 4, minimumSpeedForCourse: Double = 0.25, maximumGap: TimeInterval = 30) {
        self.timeConstant = timeConstant
        self.minimumSpeedForCourse = minimumSpeedForCourse
        self.maximumGap = maximumGap
    }

    /// Clears all state.
    public mutating func reset() {
        self = SOGCOGFilter(timeConstant: timeConstant, minimumSpeedForCourse: minimumSpeedForCourse,
                            maximumGap: maximumGap)
    }

    /// Feeds a fix and returns the smoothed course/speed (nil until one is available).
    ///
    /// Uses the receiver's own speed and course when present, otherwise derives them from the
    /// previous fix. Fixes that are not newer than the previous one are ignored.
    @discardableResult
    public mutating func update(with fix: Fix) -> CourseAndSpeed? {
        if let last = lastFix, fix.timestamp <= last.timestamp { return current }
        defer { lastFix = fix }

        var measuredSpeed: Double?
        var measuredCourse: Double?
        if let s = fix.speed, s >= 0, s.isFinite {
            measuredSpeed = s
            if let c = fix.course, c >= 0, c.isFinite { measuredCourse = c }
        } else if let last = lastFix, let derived = Navigation.courseAndSpeed(from: last, to: fix) {
            measuredSpeed = derived.speed
            measuredCourse = derived.course
        }
        guard let ms = measuredSpeed else { return current }

        let dt = lastUpdate.map { fix.timestamp.timeIntervalSince($0) } ?? .infinity
        let restart = current == nil || dt > maximumGap
        let alpha = restart ? 1.0 : 1 - exp(-dt / max(timeConstant, 1e-9))
        lastUpdate = fix.timestamp

        speed += alpha * (ms - speed)
        if let mc = measuredCourse {
            let e = ms * sin(Angle.radians(mc)), n = ms * cos(Angle.radians(mc))
            if restart || !hasVector {
                vEast = e; vNorth = n
            } else {
                vEast += alpha * (e - vEast); vNorth += alpha * (n - vNorth)
            }
            hasVector = true
        } else if restart {
            hasVector = false
        }

        var course: Double?
        if hasVector, speed >= minimumSpeedForCourse, vEast != 0 || vNorth != 0 {
            course = Angle.normalizeBearing(Angle.degrees(atan2(vEast, vNorth)))
        }
        current = CourseAndSpeed(course: course, speed: speed)
        return current
    }
}
