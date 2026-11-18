import Foundation

/// Reasons a coordinate string could not be parsed.
public enum CoordinateParseError: Error, Hashable, Sendable {
    /// The input had no content.
    case empty
    /// A character that is not part of any supported notation.
    case unexpectedCharacter(Character)
    /// A number could not be read.
    case malformedNumber(String)
    /// The input did not split into the expected latitude and/or longitude parts.
    case wrongComponentCount
    /// Minutes or seconds were 60 or more, a non-final part had a fraction, or a sign was misplaced.
    case invalidComponent(String)
    /// Hemisphere letters were missing, duplicated or of the wrong axis (e.g. two N).
    case invalidHemisphere
    /// The final value was outside -90...90 (latitude) or -180...180 (longitude).
    case outOfRange
}

/// Formatting and parsing of coordinates in marine notation.
///
/// The default output is degrees and decimal minutes (DDM) with zero-padded degrees, e.g.
/// `27°45.123'N 082°37.456'W`. Parsing accepts DDM, degrees-minutes-seconds and decimal degrees,
/// with hemisphere letters before or after each value or signed numbers, using `°`, `'`, `"`,
/// their Unicode prime variants or plain spaces as separators.
public enum CoordinateFormat {
    // MARK: Formatting

    /// Latitude in degrees and decimal minutes, e.g. `27°45.123'N`.
    public static func latitudeDDM(_ latitude: Double, fractionDigits: Int = 3) -> String {
        ddmComponent(latitude, degreeDigits: 2, positive: "N", negative: "S", fractionDigits: fractionDigits)
    }

    /// Longitude in degrees and decimal minutes, e.g. `082°37.456'W`.
    public static func longitudeDDM(_ longitude: Double, fractionDigits: Int = 3) -> String {
        ddmComponent(longitude, degreeDigits: 3, positive: "E", negative: "W", fractionDigits: fractionDigits)
    }

    /// Coordinate in degrees and decimal minutes, e.g. `27°45.123'N 082°37.456'W`.
    public static func ddm(_ c: Coordinate, fractionDigits: Int = 3, separator: String = " ") -> String {
        latitudeDDM(c.latitude, fractionDigits: fractionDigits) + separator
            + longitudeDDM(c.longitude, fractionDigits: fractionDigits)
    }

    /// Coordinate in degrees, minutes and seconds, e.g. `27°45'07.4"N 082°37'27.4"W`.
    public static func dms(_ c: Coordinate, fractionDigits: Int = 1, separator: String = " ") -> String {
        dmsComponent(c.latitude, degreeDigits: 2, positive: "N", negative: "S", fractionDigits: fractionDigits)
            + separator
            + dmsComponent(c.longitude, degreeDigits: 3, positive: "E", negative: "W", fractionDigits: fractionDigits)
    }

    /// Signed decimal degrees, e.g. `27.752050, -82.624267`.
    public static func decimalDegrees(_ c: Coordinate, fractionDigits: Int = 6) -> String {
        let k = min(max(fractionDigits, 0), 10)
        return String(format: "%.\(k)f, %.\(k)f", c.latitude, c.longitude)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func ddmComponent(
        _ value: Double, degreeDigits: Int, positive: String, negative: String, fractionDigits: Int
    ) -> String {
        guard value.isFinite else { return "--" }
        let k = min(max(fractionDigits, 0), 6)
        let scale = Int(pow(10, Double(k)))
        let units = Int((abs(value) * 60 * Double(scale)).rounded())
        let perDegree = 60 * scale
        let degrees = units / perDegree
        let minuteUnits = units % perDegree
        let wholeMinutes = minuteUnits / scale
        let frac = minuteUnits % scale
        let hemisphere = (value < 0 && units != 0) ? negative : positive
        let minutes = k > 0 ? "\(pad(wholeMinutes, 2)).\(pad(frac, k))" : pad(wholeMinutes, 2)
        return "\(pad(degrees, degreeDigits))°\(minutes)'\(hemisphere)"
    }

    private static func dmsComponent(
        _ value: Double, degreeDigits: Int, positive: String, negative: String, fractionDigits: Int
    ) -> String {
        guard value.isFinite else { return "--" }
        let k = min(max(fractionDigits, 0), 6)
        let scale = Int(pow(10, Double(k)))
        let units = Int((abs(value) * 3600 * Double(scale)).rounded())
        let perDegree = 3600 * scale
        let degrees = units / perDegree
        let rest = units % perDegree
        let minutes = rest / (60 * scale)
        let secondUnits = rest % (60 * scale)
        let wholeSeconds = secondUnits / scale
        let frac = secondUnits % scale
        let hemisphere = (value < 0 && units != 0) ? negative : positive
        let seconds = k > 0 ? "\(pad(wholeSeconds, 2)).\(pad(frac, k))" : pad(wholeSeconds, 2)
        return "\(pad(degrees, degreeDigits))°\(pad(minutes, 2))'\(seconds)\"\(hemisphere)"
    }

    // MARK: Parsing

    private enum Token: Equatable {
        case number(String)
        case hemisphere(Character)
        case comma
    }

    private struct Group {
        var numbers: [String] = []
        var hemisphere: Character?
    }

    /// Characters treated as plain separators.
    private static let separators: Set<Character> = [
        " ", "\t", "\n", "°", "º", "˚", "'", "′", "’", "‘", "\"", "″", "”", "“", ":", ";", "/",
    ]

    private static func tokenize(_ input: String) throws(CoordinateParseError) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(.number(current)); current = "" }
        }
        for ch in input.uppercased() {
            if ch.isASCII && (ch.isNumber || ch == ".") {
                current.append(ch)
            } else if ch == "-" || ch == "+" || ch == "−" {
                flush()
                current = ch == "−" ? "-" : String(ch)
            } else if ch == "N" || ch == "S" || ch == "E" || ch == "W" {
                flush()
                tokens.append(.hemisphere(ch))
            } else if ch == "," {
                flush()
                tokens.append(.comma)
            } else if separators.contains(ch) {
                flush()
            } else {
                throw .unexpectedCharacter(ch)
            }
        }
        flush()
        return tokens
    }

    private static func groups(_ tokens: [Token], single: Bool = false) throws(CoordinateParseError) -> [Group] {
        let hasHemisphere = tokens.contains { if case .hemisphere = $0 { true } else { false } }
        let meaningful = tokens.filter { $0 != .comma }
        guard !meaningful.isEmpty else { throw .empty }
        var result: [Group] = []
        if hasHemisphere {
            let prefix: Bool = if case .hemisphere = meaningful[0] { true } else { false }
            var g = Group()
            for t in meaningful {
                switch t {
                case .number(let n):
                    if prefix && g.hemisphere == nil { throw .invalidHemisphere }
                    g.numbers.append(n)
                case .hemisphere(let h):
                    if prefix {
                        if g.hemisphere != nil { result.append(g) }
                        g = Group(numbers: [], hemisphere: h)
                    } else {
                        guard !g.numbers.isEmpty else { throw .invalidHemisphere }
                        g.hemisphere = h
                        result.append(g)
                        g = Group()
                    }
                case .comma:
                    break
                }
            }
            if prefix {
                if g.hemisphere != nil { result.append(g) }
            } else if !g.numbers.isEmpty {
                throw .invalidHemisphere
            }
            if result.contains(where: { $0.numbers.isEmpty }) { throw .wrongComponentCount }
            return result
        }
        // No hemisphere letters: split on a single comma, or halve the number list.
        let commaCount = tokens.filter { $0 == .comma }.count
        if single {
            guard commaCount == 0 else { throw .wrongComponentCount }
            return [Group(numbers: meaningful.compactMap { if case .number(let n) = $0 { n } else { nil } })]
        }
        if commaCount == 1, let idx = tokens.firstIndex(of: .comma) {
            for part in [tokens[..<idx], tokens[(idx + 1)...]] {
                let numbers = part.compactMap { if case .number(let n) = $0 { n } else { nil } }
                result.append(Group(numbers: numbers))
            }
            return result
        }
        guard commaCount == 0 else { throw .wrongComponentCount }
        let numbers = meaningful.compactMap { if case .number(let n) = $0 { n } else { nil } }
        if numbers.count == 1 || numbers.count > 6 { return [Group(numbers: numbers)] }
        guard numbers.count % 2 == 0 else { throw .wrongComponentCount }
        let half = numbers.count / 2
        return [Group(numbers: Array(numbers[..<half])), Group(numbers: Array(numbers[half...]))]
    }

    private static func value(of group: Group) throws(CoordinateParseError) -> Double {
        guard (1...3).contains(group.numbers.count) else { throw .wrongComponentCount }
        var sign = 1.0
        var total = 0.0
        for (i, raw) in group.numbers.enumerated() {
            var text = raw
            if text.hasPrefix("-") || text.hasPrefix("+") {
                guard i == 0, group.hemisphere == nil else { throw .invalidComponent(raw) }
                if text.hasPrefix("-") { sign = -1 }
                text.removeFirst()
            }
            guard !text.isEmpty, text.filter({ $0 == "." }).count <= 1, text != ".",
                  let v = Double(text), v.isFinite else { throw .malformedNumber(raw) }
            let isLast = i == group.numbers.count - 1
            if !isLast && text.contains(".") { throw .invalidComponent(raw) }
            if i > 0 && v >= 60 { throw .invalidComponent(raw) }
            total += v / pow(60, Double(i))
        }
        if let h = group.hemisphere, h == "S" || h == "W" { sign = -1 }
        return sign * total
    }

    /// Parses a latitude and longitude, e.g. `27°45.123'N 082°37.456'W`, `N27 45.123 W82 37.456`,
    /// `27°45'07.4"N, 82°37'27.4"W` or `27.75205, -82.62427`.
    ///
    /// With hemisphere letters the two parts may come in either order; without them the
    /// latitude must come first.
    public static func parse(_ input: String) throws(CoordinateParseError) -> Coordinate {
        let gs = try groups(try tokenize(input))
        guard gs.count == 2 else { throw .wrongComponentCount }
        var lat: Double?
        var lon: Double?
        for (i, g) in gs.enumerated() {
            let v = try value(of: g)
            let isLatitude: Bool
            switch g.hemisphere {
            case "N", "S": isLatitude = true
            case "E", "W": isLatitude = false
            default: isLatitude = i == 0
            }
            if isLatitude {
                guard lat == nil else { throw .invalidHemisphere }
                lat = v
            } else {
                guard lon == nil else { throw .invalidHemisphere }
                lon = v
            }
        }
        guard let la = lat, let lo = lon else { throw .invalidHemisphere }
        guard (-90.0...90.0).contains(la), (-180.0...180.0).contains(lo) else { throw .outOfRange }
        return Coordinate(latitude: la, longitude: lo)
    }

    /// Parses a single latitude such as `27°45.123'N`, `S 33 51.5` or `-27.75`.
    public static func parseLatitude(_ input: String) throws(CoordinateParseError) -> Double {
        try parseSingle(input, allowed: ["N", "S"], limit: 90)
    }

    /// Parses a single longitude such as `082°37.456'W`, `E151 12.5` or `-82.62`.
    public static func parseLongitude(_ input: String) throws(CoordinateParseError) -> Double {
        try parseSingle(input, allowed: ["E", "W"], limit: 180)
    }

    private static func parseSingle(_ input: String, allowed: Set<Character>, limit: Double) throws(CoordinateParseError) -> Double {
        let gs = try groups(try tokenize(input), single: true)
        guard gs.count == 1 else { throw .wrongComponentCount }
        if let h = gs[0].hemisphere, !allowed.contains(h) { throw .invalidHemisphere }
        let v = try value(of: gs[0])
        guard abs(v) <= limit else { throw .outOfRange }
        return v
    }
}

extension Coordinate {
    /// Marine DDM notation, e.g. `27°45.123'N 082°37.456'W`.
    public var ddmString: String { CoordinateFormat.ddm(self) }
}
