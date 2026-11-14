import Foundation

/// HTTP validators for a remote file, as returned by a HEAD (or GET) response.
/// Used both to make resumed downloads safe (`If-Range`) and, for NOAA-hosted packages that have no
/// manifest, to detect a new upload.
public struct RemoteValidators: Codable, Hashable, Sendable {
    /// Raw `ETag` header including quotes and any `W/` prefix.
    public var etag: String?
    /// Raw `Last-Modified` header (RFC 1123 date).
    public var lastModified: String?
    public var contentLength: Int64?
    /// True when the server advertised `Accept-Ranges: bytes`.
    public var acceptsByteRanges: Bool?

    public init(etag: String? = nil, lastModified: String? = nil, contentLength: Int64? = nil, acceptsByteRanges: Bool? = nil) {
        self.etag = etag
        self.lastModified = lastModified
        self.contentLength = contentLength
        self.acceptsByteRanges = acceptsByteRanges
    }

    /// Builds validators from response headers (case-insensitive names).
    public init(headers: [String: String]) {
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        self.init(etag: lower["etag"], lastModified: lower["last-modified"],
                  contentLength: lower["content-length"].flatMap { Int64($0) },
                  acceptsByteRanges: lower["accept-ranges"].map { $0.lowercased().contains("bytes") })
    }

    public var lastModifiedDate: Date? { lastModified.flatMap(HTTPDate.parse) }

    /// True when the ETag is a strong validator (usable for `If-Range`).
    public var hasStrongETag: Bool {
        guard let etag, !etag.isEmpty else { return false }
        return !etag.hasPrefix("W/")
    }

    /// The value to send in `If-Range` when resuming: the strong ETag, else Last-Modified, else nil
    /// (resuming without a validator is unsafe and ChartKit restarts instead).
    public var ifRangeValue: String? {
        if hasStrongETag { return etag }
        if let lastModified, !lastModified.isEmpty { return lastModified }
        return nil
    }

    /// Whether `other` describes the same bytes, judged on the validators both sides carry.
    /// Returns nil when there is nothing to compare.
    public func sameRepresentation(as other: RemoteValidators) -> Bool? {
        if let a = etag.map(Self.normalize), let b = other.etag.map(Self.normalize) {
            if a != b { return false }
            if let la = contentLength, let lb = other.contentLength, la != lb { return false }
            return true
        }
        var compared = false
        if let la = contentLength, let lb = other.contentLength {
            if la != lb { return false }
            compared = true
        }
        if let a = lastModifiedDate, let b = other.lastModifiedDate {
            if a != b { return false }
            compared = true
        }
        return compared ? true : nil
    }

    /// Strips the weak prefix so `W/"x"` and `"x"` compare equal for change detection.
    static func normalize(_ etag: String) -> String {
        etag.hasPrefix("W/") ? String(etag.dropFirst(2)) : etag
    }
}

/// Result of comparing the validators we installed with what the server reports now.
public enum RemoteChange: Equatable, Sendable {
    case unchanged
    /// The remote file differs; `reasons` says which validators disagreed.
    case changed(reasons: [Reason])
    /// Not enough validators on one side to decide.
    case unknown

    public enum Reason: String, Equatable, Sendable {
        case etag, lastModified, contentLength
    }
}

/// Fallback update check for packages that have no manifest (NOAA's own NCDS MBTiles):
/// HEAD the URL periodically and compare.
public enum RemoteFileCheck {
    /// Compares installed validators with fresh ones. A strong signal (ETag) wins; Last-Modified
    /// counts as changed only when the remote is newer or differs; Content-Length catches the rest.
    public static func compare(installed: RemoteValidators, current: RemoteValidators) -> RemoteChange {
        var reasons: [RemoteChange.Reason] = []
        var comparable = false
        if let a = installed.etag.map(RemoteValidators.normalize), let b = current.etag.map(RemoteValidators.normalize) {
            comparable = true
            if a != b { reasons.append(.etag) }
        }
        if let a = installed.lastModifiedDate, let b = current.lastModifiedDate {
            comparable = true
            if a != b { reasons.append(.lastModified) }
        } else if let a = installed.lastModified, let b = current.lastModified {
            // Unparseable dates: fall back to string equality.
            comparable = true
            if a != b { reasons.append(.lastModified) }
        }
        if let a = installed.contentLength, let b = current.contentLength {
            comparable = true
            if a != b { reasons.append(.contentLength) }
        }
        if !reasons.isEmpty { return .changed(reasons: reasons) }
        return comparable ? .unchanged : .unknown
    }

    /// Builds a pseudo manifest region for a NOAA package that has no manifest, using HEAD results.
    /// There is no published checksum, so the installer verifies size and MBTiles integrity only.
    public static func downloadSpec(url: URL, validators: RemoteValidators, version: String? = nil) -> DownloadSpec {
        let date = validators.lastModifiedDate ?? Date(timeIntervalSince1970: 0)
        return DownloadSpec(url: url, expectedByteSize: validators.contentLength, sha256: nil,
                            version: version ?? validators.etag.map(RemoteValidators.normalize).map { $0.replacingOccurrences(of: "\"", with: "") }
                                ?? ChartDates.format(date),
                            dataDate: date)
    }
}

/// RFC 7231 HTTP-date parsing (IMF-fixdate, plus the obsolete RFC 850 and asctime forms), without
/// locale-dependent formatters.
public enum HTTPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func parse(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: ",", with: " ")
        let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var day: Int?, month: Int?, year: Int?, time: (Int, Int, Int)?
        for tok in tokens {
            let low = tok.lowercased()
            if let m = months.firstIndex(of: String(low.prefix(3))), low.count >= 3, low.allSatisfy({ $0.isLetter }) {
                month = m + 1
            } else if tok.contains(":") {
                let p = tok.split(separator: ":").compactMap { Int($0) }
                if p.count == 3 { time = (p[0], p[1], p[2]) }
            } else if tok.contains("-") {
                // RFC 850: 28-May-24
                let p = tok.split(separator: "-").map(String.init)
                if p.count == 3, let d = Int(p[0]), let m = months.firstIndex(of: p[1].lowercased().prefix(3).description),
                   let y = Int(p[2]) {
                    day = d; month = m + 1; year = y < 100 ? (y < 70 ? 2000 + y : 1900 + y) : y
                }
            } else if let n = Int(tok) {
                if n > 31 { year = n } else if day == nil { day = n }
            }
        }
        guard let d = day, let m = month, let y = year, let t = time else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: t.0, minute: t.1, second: t.2))
    }

    public static func format(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let mon = months[(c.month ?? 1) - 1].capitalized
        func pad(_ n: Int, _ w: Int) -> String {
            let d = String(n)
            return String(repeating: "0", count: max(0, w - d.count)) + d
        }
        return "\(days[(c.weekday ?? 1) - 1]), \(pad(c.day ?? 1, 2)) \(mon) \(pad(c.year ?? 1970, 4)) "
            + "\(pad(c.hour ?? 0, 2)):\(pad(c.minute ?? 0, 2)):\(pad(c.second ?? 0, 2)) GMT"
    }
}
