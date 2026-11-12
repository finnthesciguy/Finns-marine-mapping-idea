import Foundation

/// Fast, allocation-light ISO-8601 / RFC 3339 timestamp parsing and formatting, as used in GPX.
///
/// Parsing accepts `YYYY-MM-DDThh:mm:ss`, optional fractional seconds of any length, and a zone of
/// `Z`, `±hh:mm`, `±hhmm` or `±hh`. A missing zone is read as UTC (GPX requires UTC). A space may
/// replace the `T`, and a bare date `YYYY-MM-DD` is read as midnight UTC.
/// Formatting always produces UTC with `Z`, adding `.SSS` milliseconds only when non-zero.
public enum ISO8601 {
    /// Parses a timestamp, returning nil if it is not valid ISO-8601.
    public static func date(from string: some StringProtocol) -> Date? {
        var bytes = Array(string.utf8)
        // Trim ASCII whitespace.
        while let f = bytes.first, f == 0x20 || f == 0x09 || f == 0x0A || f == 0x0D { bytes.removeFirst() }
        while let l = bytes.last, l == 0x20 || l == 0x09 || l == 0x0A || l == 0x0D { bytes.removeLast() }
        var i = 0

        func digits(_ count: Int) -> Int? {
            guard i + count <= bytes.count else { return nil }
            var v = 0
            for k in 0..<count {
                let b = bytes[i + k]
                guard b >= 0x30 && b <= 0x39 else { return nil }
                v = v * 10 + Int(b - 0x30)
            }
            i += count
            return v
        }
        func expect(_ c: UInt8) -> Bool {
            guard i < bytes.count, bytes[i] == c else { return false }
            i += 1
            return true
        }

        guard let year = digits(4), expect(0x2D), let month = digits(2), expect(0x2D), let day = digits(2) else { return nil }
        guard (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        var offsetSeconds = 0
        if i < bytes.count {
            guard bytes[i] == 0x54 || bytes[i] == 0x74 || bytes[i] == 0x20 else { return nil }  // T t space
            i += 1
            guard let h = digits(2), expect(0x3A), let m = digits(2) else { return nil }
            hour = h; minute = m
            if expect(0x3A) {
                guard let s = digits(2) else { return nil }
                second = s
                if i < bytes.count, bytes[i] == 0x2E || bytes[i] == 0x2C {   // . or ,
                    i += 1
                    var scale = 0.1
                    var any = false
                    while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                        fraction += Double(bytes[i] - 0x30) * scale
                        scale /= 10
                        i += 1
                        any = true
                    }
                    guard any else { return nil }
                }
            }
            guard hour <= 24, minute <= 59, second <= 60 else { return nil }
            if hour == 24 && (minute != 0 || second != 0 || fraction != 0) { return nil }
            if i < bytes.count {
                let z = bytes[i]
                if z == 0x5A || z == 0x7A {   // Z z
                    i += 1
                } else if z == 0x2B || z == 0x2D {   // + -
                    i += 1
                    let sign = z == 0x2D ? -1 : 1
                    guard let oh = digits(2) else { return nil }
                    var om = 0
                    if expect(0x3A) {
                        guard let m = digits(2) else { return nil }
                        om = m
                    } else if i < bytes.count {
                        guard let m = digits(2) else { return nil }
                        om = m
                    }
                    guard oh <= 23, om <= 59 else { return nil }
                    offsetSeconds = sign * (oh * 3600 + om * 60)
                } else {
                    return nil
                }
            }
        }
        guard i == bytes.count else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let whole = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(whole) + fraction)
    }

    /// Formats a date as UTC ISO-8601, e.g. `2024-03-09T14:05:07Z` or `2024-03-09T14:05:07.250Z`.
    public static func string(from date: Date) -> String {
        let totalMillis = Int((date.timeIntervalSince1970 * 1000).rounded())
        let (secondsTotal, millis) = floorDivMod(totalMillis, 1000)
        let (days, secOfDay) = floorDivMod(secondsTotal, 86_400)
        let (y, m, d) = civilFromDays(days)
        let hh = secOfDay / 3600, mm = (secOfDay % 3600) / 60, ss = secOfDay % 60
        var s = "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(hh, 2)):\(pad(mm, 2)):\(pad(ss, 2))"
        if millis != 0 { s += ".\(pad(millis, 3))" }
        return s + "Z"
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func floorDivMod(_ a: Int, _ b: Int) -> (Int, Int) {
        var q = a / b, r = a % b
        if r < 0 { q -= 1; r += b }
        return (q, r)
    }

    private static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Inverse of ``daysFromCivil(year:month:day:)``.
    static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
