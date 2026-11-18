import Foundation
import Testing
@testable import GPXKit

@Suite("ISO-8601 times")
struct ISO8601Tests {
    // Epoch seconds computed independently with Python's datetime.fromisoformat.
    @Test(arguments: [
        ("2024-03-09T14:05:07Z", 1_709_993_107.0),
        ("2024-03-09T14:05:07", 1_709_993_107.0),             // no zone: UTC
        ("2024-03-09t14:05:07z", 1_709_993_107.0),
        ("2024-03-09 14:05:07Z", 1_709_993_107.0),
        ("2023-10-01T13:45:00-05:00", 1_696_185_900.0),
        ("2023-10-01T13:45:00-0500", 1_696_185_900.0),
        ("2023-10-01T13:45:00-05", 1_696_185_900.0),
        ("2024-12-31T23:30:00-08:00", 1_735_716_600.0),       // crosses into the next year in UTC
        ("2024-05-18T12:00:11.500Z", 1_716_033_611.5),
        ("2024-05-18T12:00:11.5Z", 1_716_033_611.5),
        ("2000-02-29T23:59:59.999Z", 951_868_799.999),        // leap day
        ("1969-12-31T23:59:59.5Z", -0.5),                     // before the epoch
        ("1970-01-01T00:00:00Z", 0),
        ("2024-05-18T12:00:00.123456789Z", 1_716_033_600.123_456_789),
        ("  2024-03-09T14:05:07Z\n", 1_709_993_107.0),        // whitespace from pretty-printed XML
        ("2024-03-09", 1_709_942_400.0),
    ])
    func parses(_ c: (String, Double)) throws {
        let d = try #require(ISO8601.date(from: c.0), "\(c.0)")
        #expect(abs(d.timeIntervalSince1970 - c.1) < 1e-6, "\(c.0)")
    }

    @Test(arguments: [
        "", "not-a-time", "2024-13-01T00:00:00Z", "2023-02-29T00:00:00Z", "2024-04-31T00:00:00Z",
        "2024-03-09T25:00:00Z", "2024-03-09T14:60:00Z", "2024-03-09T14:05:07.Z", "2024-03-09T14:05:07+25:00",
        "2024-03-09T14:05:07Zjunk", "24-03-09T14:05:07Z", "2024/03/09T14:05:07Z",
    ])
    func rejects(_ s: String) {
        #expect(ISO8601.date(from: s) == nil, "\(s)")
    }

    @Test func formats() {
        #expect(ISO8601.string(from: Date(timeIntervalSince1970: 1_709_993_107)) == "2024-03-09T14:05:07Z")
        #expect(ISO8601.string(from: Date(timeIntervalSince1970: 1_716_033_611.5)) == "2024-05-18T12:00:11.500Z")
        #expect(ISO8601.string(from: Date(timeIntervalSince1970: 951_868_799.999)) == "2000-02-29T23:59:59.999Z")
        #expect(ISO8601.string(from: Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500Z")
        #expect(ISO8601.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        // Sub-millisecond parts round to the nearest millisecond, carrying into seconds.
        #expect(ISO8601.string(from: Date(timeIntervalSince1970: 59.9996)) == "1970-01-01T00:01:00Z")
    }

    @Test func civilCalendarRoundTrip() {
        // Every day from 1900 to 2100 survives days → civil → days.
        var failures: [Int] = []
        for days in stride(from: -25_567, through: 47_482, by: 1) {
            let (y, m, d) = ISO8601.civilFromDays(days)
            if ISO8601.daysFromCivil(year: y, month: m, day: d) != days { failures.append(days) }
        }
        #expect(failures.isEmpty)
        #expect(ISO8601.civilFromDays(-25_567) == (1900, 1, 1))
        #expect(ISO8601.daysFromCivil(year: 2000, month: 3, day: 1) == 11_017)
    }
}
