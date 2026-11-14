import Foundation
import NavCore

/// Builds evenly timed fixes along a polyline, for the simulator, previews and tests.
public enum SimulatedTrack {
    /// Fixes every `interval` seconds along `waypoints` at a constant speed. Each fix carries the
    /// leg's initial bearing as course and the speed in m/s.
    public static func make(waypoints: [Coordinate], speedKnots: Double, interval: TimeInterval,
                            start: Date) -> [Fix] {
        guard waypoints.count >= 2, speedKnots > 0, interval > 0 else {
            if let only = waypoints.first {
                return [Fix(coordinate: only, timestamp: start, speed: 0, course: nil, horizontalAccuracy: 5)]
            }
            return []
        }
        let speed: Double = Speed.knots(speedKnots).metersPerSecond
        let step: Double = speed * interval
        var fixes: [Fix] = []
        var time: Date = start
        for index in 0..<(waypoints.count - 1) {
            let from: Coordinate = waypoints[index]
            let to: Coordinate = waypoints[index + 1]
            let legLength: Double = Geodesy.distance(from: from, to: to)
            let bearing: Double = Geodesy.initialBearing(from: from, to: to)
            var travelled: Double = 0
            while travelled < legLength {
                let position: Coordinate = travelled == 0
                    ? from
                    : Geodesy.destination(from: from, bearing: bearing, distance: travelled)
                fixes.append(Fix(coordinate: position, timestamp: time, speed: speed, course: bearing,
                                 horizontalAccuracy: 5))
                time = time.addingTimeInterval(interval)
                travelled += step
            }
        }
        let last: Coordinate = waypoints[waypoints.count - 1]
        let lastCourse: Double = Geodesy.initialBearing(from: waypoints[waypoints.count - 2], to: last)
        fixes.append(Fix(coordinate: last, timestamp: time, speed: speed, course: lastCourse, horizontalAccuracy: 5))
        return fixes
    }

    /// A short run up the main shipping channel of lower Tampa Bay, from east of Egmont Key towards and
    /// under the Sunshine Skyway, then north-east into the bay. Approximate positions for exercising the app
    /// in the simulator only; this is not a route to navigate.
    public static let tampaBayWaypoints: [Coordinate] = [
        Coordinate(latitude: 27.6010, longitude: -82.7330),
        Coordinate(latitude: 27.6090, longitude: -82.7000),
        Coordinate(latitude: 27.6160, longitude: -82.6700),
        Coordinate(latitude: 27.6230, longitude: -82.6500),
        Coordinate(latitude: 27.6420, longitude: -82.6250),
        Coordinate(latitude: 27.6700, longitude: -82.6000),
    ]

    /// The Tampa Bay run at 6 knots with one fix per second.
    public static func tampaBay(start: Date = Date(), speedKnots: Double = 6, interval: TimeInterval = 1) -> [Fix] {
        make(waypoints: tampaBayWaypoints, speedKnots: speedKnots, interval: interval, start: start)
    }
}

/// Replays a list of fixes as if they came from GPS.
@MainActor
public final class SimulatedLocationService: LocationService {
    public struct Options: Sendable, Equatable {
        /// Real time between delivered fixes (`.zero` delivers as fast as the consumer reads).
        public var interval: Duration
        /// Start again from the first fix after the last one.
        public var loops: Bool
        /// Replace each fix's timestamp with the time it is delivered (so speed filters see real time).
        public var restampsToNow: Bool
        /// Authorization the fake reports; `requestWhenInUseAuthorization()` grants when-in-use.
        public var initialAuthorization: LocationAuthorization

        public init(interval: Duration = .seconds(1), loops: Bool = true, restampsToNow: Bool = true,
                    initialAuthorization: LocationAuthorization = .authorizedWhenInUse) {
            self.interval = interval
            self.loops = loops
            self.restampsToNow = restampsToNow
            self.initialAuthorization = initialAuthorization
        }
    }

    public private(set) var authorization: LocationAuthorization
    public private(set) var isUpdating: Bool = false
    public private(set) var isRecording: Bool = false
    /// Number of fixes delivered so far (across loops).
    public private(set) var deliveredCount: Int = 0

    private let track: [Fix]
    private let options: Options
    private let fixOut = Broadcaster<Fix>()
    private let headingOut = Broadcaster<Double>()
    private let authorizationOut = Broadcaster<LocationAuthorization>()
    private var replayTask: Task<Void, Never>?

    public init(track: [Fix], options: Options = Options()) {
        self.track = track
        self.options = options
        self.authorization = options.initialAuthorization
        authorizationOut.yield(options.initialAuthorization)
    }

    public func requestWhenInUseAuthorization() {
        guard authorization == .notDetermined else { return }
        authorization = .authorizedWhenInUse
        authorizationOut.yield(.authorizedWhenInUse)
    }

    public func startUpdates() {
        guard !isUpdating else { return }
        isUpdating = true
        guard authorization.allowsUpdates, !track.isEmpty else { return }
        let fixes: [Fix] = track
        let options: Options = self.options
        replayTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                if index >= fixes.count {
                    if !options.loops { break }
                    index = 0
                }
                var fix: Fix = fixes[index]
                if options.restampsToNow { fix.timestamp = Date() }
                guard let self else { return }
                self.deliver(fix)
                index += 1
                if options.interval > .zero {
                    do {
                        try await Task.sleep(for: options.interval)
                    } catch {
                        return
                    }
                } else {
                    await Task.yield()
                }
            }
        }
    }

    public func stopUpdates() {
        isUpdating = false
        replayTask?.cancel()
        replayTask = nil
    }

    public func setRecording(_ recording: Bool) {
        isRecording = recording
    }

    public func fixes() -> AsyncStream<Fix> { fixOut.stream() }

    public func headings() -> AsyncStream<Double> { headingOut.stream() }

    public func authorizationUpdates() -> AsyncStream<LocationAuthorization> { authorizationOut.stream() }

    private func deliver(_ fix: Fix) {
        deliveredCount += 1
        fixOut.yield(fix)
        if let course = fix.course {
            headingOut.yield(course)
        }
    }
}
