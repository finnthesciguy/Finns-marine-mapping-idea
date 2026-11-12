import Foundation
import Testing
@testable import NavCore

/// Deterministic pseudo-random generator so jitter tests are repeatable.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Anchor alarm")
struct AnchorAlarmTests {
    let anchor = Coordinate(latitude: 27.6, longitude: -82.7)

    func fix(at distance: Double, bearing: Double = 0, second: Int, accuracy: Double? = 5) -> Fix {
        Fix(coordinate: Geodesy.destination(from: anchor, bearing: bearing, distance: distance),
            timestamp: t0.addingTimeInterval(Double(second)), horizontalAccuracy: accuracy)
    }

    func makeAlarm(latch: Bool = true) -> AnchorAlarm {
        AnchorAlarm(anchor: anchor, configuration: AnchorAlarmConfiguration(
            radius: 50, hysteresis: 5, maximumAccuracy: 50, confirmationFixes: 3, confirmationInterval: 5,
            latchesDragging: latch))
    }

    @Test func classifyUsesAccuracy() {
        let alarm = makeAlarm()
        #expect(alarm.classify(fix(at: 30, second: 0)) == .inside)
        #expect(alarm.classify(fix(at: 48, second: 0)) == nil)                    // dead band 45..50
        #expect(alarm.classify(fix(at: 52, second: 0, accuracy: 10)) == .warning) // 52 - 10 < 50
        #expect(alarm.classify(fix(at: 70, second: 0, accuracy: 10)) == .dragging)
        #expect(alarm.classify(fix(at: 70, second: 0, accuracy: 40)) == .warning)
        #expect(alarm.classify(fix(at: 300, second: 0, accuracy: 120)) == nil)    // rejected: poor accuracy
        #expect(alarm.classify(fix(at: 300, second: 0, accuracy: -1)) == nil)     // invalid accuracy (CoreLocation -1)
    }

    @Test func gpsJitterNeverAlarms() {
        // Boat swinging within 40 m; GPS noise up to ±8 m plus an occasional single-fix multipath
        // jump of 150 m. None of this should leave `.inside`.
        var alarm = makeAlarm()
        var rng = SplitMix64(state: 42)
        for s in 0..<3600 {
            let swing = 25 + 15 * sin(Double(s) / 120)
            let noise = Double.random(in: -8...8, using: &rng)
            let d = s % 300 == 299 ? 150 : swing + noise
            let state = alarm.update(with: fix(at: d, bearing: Double(s % 360), second: s, accuracy: 6))
            #expect(state == .inside, "false alarm at t=\(s)s, d=\(d)")
            if state != .inside { break }
        }
    }

    @Test func sustainedDriftRaisesDragging() {
        var alarm = makeAlarm()
        // Drag steadily from 40 m out to 100 m at 1 m/s.
        var states: [AnchorAlarmState] = []
        for s in 0...60 {
            states.append(alarm.update(with: fix(at: 40 + Double(s), bearing: 200, second: s, accuracy: 5)))
        }
        // d first exceeds 50 m at s = 11; warning needs ≥3 fixes spanning ≥5 s → s = 16.
        #expect(states[15] == .inside)
        #expect(states[16] == .warning)
        // From s = 17 every fix is confidently outside (d − 5 > 50); confirmed 5 s later at s = 22.
        #expect(states[21] == .warning)
        #expect(states[22] == .dragging)
        #expect(states.last == .dragging)
        #expect(alarm.maximumDistance > 99)
        #expect(alarm.lastBearingFromAnchor.map { bearingClose($0, 200, 0.01) } == true)
    }

    @Test func poorAccuracyOnlyWarns() {
        var alarm = makeAlarm()
        for s in 0...20 { alarm.update(with: fix(at: 70, second: s, accuracy: 40)) }
        #expect(alarm.state == .warning)
    }

    @Test func hysteresisAndRecoveryFromWarning() {
        var alarm = makeAlarm()
        for s in 0...6 { alarm.update(with: fix(at: 53, second: s)) }
        #expect(alarm.state == .warning)
        // Back to 48 m (dead band): remains warning however long it stays there.
        for s in 7...30 { alarm.update(with: fix(at: 48, second: s)) }
        #expect(alarm.state == .warning)
        // Comfortably inside for 3 fixes spanning 5 s: back to inside.
        for s in 31...35 { alarm.update(with: fix(at: 40, second: s)) }
        #expect(alarm.state == .warning)
        alarm.update(with: fix(at: 40, second: 36))
        #expect(alarm.state == .inside)
    }

    @Test func draggingLatchesUntilAcknowledged() {
        var alarm = makeAlarm(latch: true)
        for s in 0...10 { alarm.update(with: fix(at: 90, second: s)) }
        #expect(alarm.state == .dragging)
        for s in 11...40 { alarm.update(with: fix(at: 10, second: s)) }
        #expect(alarm.state == .dragging)
        alarm.acknowledge()
        #expect(alarm.state == .inside)

        var unlatched = makeAlarm(latch: false)
        for s in 0...10 { unlatched.update(with: fix(at: 90, second: s)) }
        #expect(unlatched.state == .dragging)
        for s in 11...40 { unlatched.update(with: fix(at: 10, second: s)) }
        #expect(unlatched.state == .inside)
    }

    @Test func fewFastFixesAreNotEnough() {
        // Five fixes within one second outside the circle: count is met but not the interval.
        var alarm = makeAlarm()
        for i in 0..<5 {
            alarm.update(with: Fix(coordinate: Geodesy.destination(from: anchor, bearing: 0, distance: 90),
                                   timestamp: t0.addingTimeInterval(Double(i) * 0.2), horizontalAccuracy: 3))
        }
        #expect(alarm.state == .inside)
    }

    @Test func staleAndInvalidFixesIgnored() {
        var alarm = makeAlarm()
        alarm.update(with: fix(at: 10, second: 100))
        for s in 0..<50 { alarm.update(with: fix(at: 500, second: s)) }   // older than last accepted
        #expect(alarm.state == .inside && alarm.lastDistance.map { close($0, 10, 1e-6) } == true)
        alarm.update(with: Fix(coordinate: Coordinate(latitude: .nan, longitude: 0), timestamp: t0.addingTimeInterval(200)))
        #expect(alarm.state == .inside)
        alarm.reset(anchor: Coordinate(latitude: 27.7, longitude: -82.7))
        #expect(alarm.anchor == Coordinate(latitude: 27.7, longitude: -82.7) && alarm.lastDistance == nil)
    }
}
