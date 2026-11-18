import Foundation

/// Anchor-watch state.
public enum AnchorAlarmState: Int, Hashable, Sendable, Codable, Comparable {
    /// Within the swing circle.
    case inside = 0
    /// Probably outside the swing circle, but GPS uncertainty means it is not yet certain.
    case warning = 1
    /// Confidently outside the swing circle: the anchor is dragging.
    case dragging = 2

    /// Orders by severity.
    public static func < (lhs: AnchorAlarmState, rhs: AnchorAlarmState) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Tuning for ``AnchorAlarm``.
public struct AnchorAlarmConfiguration: Hashable, Sendable, Codable {
    /// Swing-circle radius around the anchor, metres.
    public var radius: Double
    /// To return to ``AnchorAlarmState/inside`` the position must be at least this far
    /// inside the radius, metres. Prevents flicker at the boundary.
    public var hysteresis: Double
    /// Fixes with horizontal accuracy worse than this (metres) are ignored entirely.
    public var maximumAccuracy: Double
    /// A change of state must be observed on at least this many consecutive fixes…
    public var confirmationFixes: Int
    /// …spanning at least this many seconds.
    public var confirmationInterval: TimeInterval
    /// When true, ``AnchorAlarmState/dragging`` persists until ``AnchorAlarm/acknowledge()``
    /// or ``AnchorAlarm/reset(anchor:)``, even if the boat drifts back inside.
    public var latchesDragging: Bool

    /// Creates a configuration.
    public init(
        radius: Double,
        hysteresis: Double = 5,
        maximumAccuracy: Double = 50,
        confirmationFixes: Int = 3,
        confirmationInterval: TimeInterval = 5,
        latchesDragging: Bool = true
    ) {
        self.radius = radius
        self.hysteresis = hysteresis
        self.maximumAccuracy = maximumAccuracy
        self.confirmationFixes = confirmationFixes
        self.confirmationInterval = confirmationInterval
        self.latchesDragging = latchesDragging
    }
}

/// Anchor-drag alarm with accuracy-aware classification and hysteresis.
///
/// Each accepted fix is classified on its own:
/// - **dragging** if even the near edge of its accuracy circle is outside the radius
///   (`distance - accuracy > radius`);
/// - **warning** if its centre is outside the radius (`distance > radius`);
/// - **inside** if it is comfortably inside (`distance <= radius - hysteresis`);
/// - otherwise it is in the dead band and supports neither escalation nor de-escalation.
///
/// The published ``state`` only escalates after `confirmationFixes` consecutive more-severe
/// observations spanning `confirmationInterval` seconds, and then to the least severe level seen
/// in that run. It returns to inside only after the same confirmation of inside observations.
/// A single wild GPS jump therefore never raises the alarm.
public struct AnchorAlarm: Hashable, Sendable {
    /// Where the anchor is.
    public private(set) var anchor: Coordinate
    /// Tuning parameters.
    public var configuration: AnchorAlarmConfiguration
    /// Current confirmed state.
    public private(set) var state: AnchorAlarmState = .inside
    /// Distance from the anchor of the last accepted fix, metres.
    public private(set) var lastDistance: Double?
    /// Bearing from the anchor to the last accepted fix, degrees true.
    public private(set) var lastBearingFromAnchor: Double?
    /// Largest distance from the anchor seen since the watch started, metres.
    public private(set) var maximumDistance: Double = 0

    private var lastTimestamp: Date?
    private var runDirection = 0  // +1 escalating, -1 de-escalating, 0 none
    private var runStart: Date?
    private var runCount = 0
    private var runLevel: AnchorAlarmState = .inside

    /// Starts an anchor watch.
    public init(anchor: Coordinate, configuration: AnchorAlarmConfiguration) {
        self.anchor = anchor
        self.configuration = configuration
    }

    /// Classifies a single fix without changing state. Nil if the fix is rejected (bad accuracy
    /// or invalid position) or lies in the dead band.
    public func classify(_ fix: Fix) -> AnchorAlarmState? {
        guard let d = acceptedDistance(fix) else { return nil }
        let accuracy = max(fix.horizontalAccuracy ?? 0, 0)
        let r = configuration.radius
        if d - accuracy > r { return .dragging }
        if d > r { return .warning }
        if d <= r - configuration.hysteresis { return .inside }
        return nil
    }

    private func acceptedDistance(_ fix: Fix) -> Double? {
        guard fix.coordinate.isValid else { return nil }
        if let a = fix.horizontalAccuracy {
            guard a >= 0, a.isFinite, a <= configuration.maximumAccuracy else { return nil }
        }
        let d = Geodesy.distance(from: anchor, to: fix.coordinate)
        return d.isFinite ? d : nil
    }

    /// Feeds a fix and returns the (possibly updated) state.
    /// Fixes older than or equal to the previous accepted fix are ignored.
    @discardableResult
    public mutating func update(with fix: Fix) -> AnchorAlarmState {
        if let t = lastTimestamp, fix.timestamp <= t { return state }
        guard let d = acceptedDistance(fix) else { return state }
        lastTimestamp = fix.timestamp
        lastDistance = d
        lastBearingFromAnchor = Geodesy.initialBearing(from: anchor, to: fix.coordinate)
        maximumDistance = max(maximumDistance, d)

        let observed = classify(fix)
        let direction: Int
        if let o = observed, o > state {
            direction = 1
        } else if observed == .inside, state > .inside,
                  !(state == .dragging && configuration.latchesDragging) {
            direction = -1
        } else {
            direction = 0
        }

        guard direction != 0, let o = observed else {
            clearRun()
            return state
        }
        if direction != runDirection {
            runDirection = direction
            runStart = fix.timestamp
            runCount = 0
            runLevel = o
        }
        runCount += 1
        runLevel = direction > 0 ? min(runLevel, o) : .inside
        let elapsed = fix.timestamp.timeIntervalSince(runStart ?? fix.timestamp)
        if runCount >= max(configuration.confirmationFixes, 1) && elapsed >= configuration.confirmationInterval {
            state = runLevel
            clearRun()
        }
        return state
    }

    private mutating func clearRun() {
        runDirection = 0
        runStart = nil
        runCount = 0
        runLevel = .inside
    }

    /// Clears a latched alarm back to inside, keeping the same anchor position.
    public mutating func acknowledge() {
        state = .inside
        clearRun()
    }

    /// Re-drops the anchor at a new position and clears all history.
    public mutating func reset(anchor: Coordinate) {
        self = AnchorAlarm(anchor: anchor, configuration: configuration)
    }
}
