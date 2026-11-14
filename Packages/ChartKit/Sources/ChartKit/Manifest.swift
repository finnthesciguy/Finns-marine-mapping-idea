import Foundation

/// One downloadable file: a chart package or a routing pack.
public struct PackageArtifact: Codable, Hashable, Sendable {
    public var url: URL
    public var byteSize: Int64
    /// Lower-case hex SHA-256 of the whole file.
    public var sha256: String
    /// Opaque version string; any change means "different package".
    public var version: String
    /// Date of the source chart data in the package (date-only in JSON: `"2024-05-28"`).
    public var dataDate: Date

    public init(url: URL, byteSize: Int64, sha256: String, version: String, dataDate: Date) {
        self.url = url
        self.byteSize = byteSize
        self.sha256 = sha256.lowercased()
        self.version = version
        self.dataDate = dataDate
    }
}

/// A routing pack (see PLAN.md D3) published alongside a chart region.
public struct RoutingPackArtifact: Codable, Hashable, Sendable {
    public var url: URL
    public var byteSize: Int64
    public var sha256: String
    public var version: String
    public var dataDate: Date
    /// Version of the routing pack file format, so old apps can skip packs they cannot read.
    public var formatVersion: Int?

    public init(url: URL, byteSize: Int64, sha256: String, version: String, dataDate: Date, formatVersion: Int? = nil) {
        self.url = url
        self.byteSize = byteSize
        self.sha256 = sha256.lowercased()
        self.version = version
        self.dataDate = dataDate
        self.formatVersion = formatVersion
    }

    public var artifact: PackageArtifact {
        PackageArtifact(url: url, byteSize: byteSize, sha256: sha256, version: version, dataDate: dataDate)
    }
}

/// One chart region in the manifest.
public struct ChartRegion: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier, e.g. `ncds_13`. Restricted to `[A-Za-z0-9._-]` (it becomes a directory name).
    public var id: String
    public var title: String
    public var summary: String?
    public var bounds: BoundingBox
    public var minZoom: Int
    public var maxZoom: Int
    public var tileFormat: TileFormat
    /// The MBTiles chart package (JSON key `package`).
    public var chartPackage: PackageArtifact
    /// Human-readable provenance, e.g. "NOAA NCDS baseline 2024-05-28".
    public var source: String
    public var routingPack: RoutingPackArtifact?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, bounds, minZoom, maxZoom, tileFormat, source, routingPack
        case chartPackage = "package"
    }

    public init(id: String, title: String, summary: String? = nil, bounds: BoundingBox, minZoom: Int, maxZoom: Int,
                tileFormat: TileFormat, chartPackage: PackageArtifact, source: String, routingPack: RoutingPackArtifact? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.bounds = bounds
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.tileFormat = tileFormat
        self.chartPackage = chartPackage
        self.source = source
        self.routingPack = routingPack
    }
}

/// The `manifest.json` published by the chart build service.
public struct ChartManifest: Codable, Hashable, Sendable {
    /// Highest `schemaVersion` this build of ChartKit understands.
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var publisher: String?
    public var regions: [ChartRegion]

    public init(schemaVersion: Int = ChartManifest.supportedSchemaVersion, generatedAt: Date,
                publisher: String? = nil, regions: [ChartRegion]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.publisher = publisher
        self.regions = regions
    }

    public func region(id: String) -> ChartRegion? { regions.first { $0.id == id } }

    // MARK: Coding

    /// Decodes and validates a manifest. Unknown keys are ignored; a newer `schemaVersion` is refused.
    public static func decode(from data: Data) throws -> ChartManifest {
        let manifest: ChartManifest
        do {
            manifest = try makeDecoder().decode(ChartManifest.self, from: data)
        } catch let e as ManifestError {
            throw e
        } catch {
            throw ManifestError.malformed(String(describing: error))
        }
        try manifest.validate()
        return manifest
    }

    public func encoded() throws -> Data { try Self.makeEncoder().encode(self) }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ChartDates.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognised date \(s)")
            }
            return date
        }
        return d
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ChartDates.format(date))
        }
        return e
    }

    /// Checks invariants the installer relies on. Throws the first problem found.
    public func validate() throws {
        guard schemaVersion >= 1 else { throw ManifestError.malformed("schemaVersion must be >= 1") }
        guard schemaVersion <= Self.supportedSchemaVersion else {
            throw ManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        var seen = Set<String>()
        for r in regions {
            guard RegionID.isValid(r.id) else { throw ManifestError.invalidRegion(r.id, "invalid id") }
            guard seen.insert(r.id).inserted else { throw ManifestError.invalidRegion(r.id, "duplicate id") }
            guard r.bounds.isValid else { throw ManifestError.invalidRegion(r.id, "invalid bounds \(r.bounds)") }
            guard r.minZoom >= 0, r.minZoom <= r.maxZoom, r.maxZoom <= TileCoordinate.maximumZoom else {
                throw ManifestError.invalidRegion(r.id, "invalid zoom range \(r.minZoom)-\(r.maxZoom)")
            }
            try Self.check(r.chartPackage, region: r.id, what: "package")
            if let rp = r.routingPack { try Self.check(rp.artifact, region: r.id, what: "routingPack") }
        }
    }

    private static func check(_ a: PackageArtifact, region: String, what: String) throws {
        guard a.byteSize > 0 else { throw ManifestError.invalidRegion(region, "\(what).byteSize must be > 0") }
        guard StreamingSHA256.isValidHexDigest(a.sha256) else {
            throw ManifestError.invalidRegion(region, "\(what).sha256 is not a 64-character hex digest")
        }
        guard let scheme = a.url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ManifestError.invalidRegion(region, "\(what).url must be http(s)")
        }
        guard !a.version.isEmpty else { throw ManifestError.invalidRegion(region, "\(what).version is empty") }
    }
}

public enum ManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupportedSchemaVersion(Int)
    case invalidRegion(String, String)

    public var description: String {
        switch self {
        case .malformed(let m): return "manifest is malformed: \(m)"
        case .unsupportedSchemaVersion(let v):
            return "manifest schemaVersion \(v) is newer than this app supports (\(ChartManifest.supportedSchemaVersion))"
        case .invalidRegion(let id, let m): return "manifest region \(id): \(m)"
        }
    }
}

/// Region identifiers become directory names, so they are restricted.
public enum RegionID {
    public static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64, id != ".", id != ".." else { return false }
        return id.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "." || c == "_" || c == "-"
        }
    }
}

/// Date handling for manifests and state files: full ISO 8601 timestamps (`2026-11-12T06:00:00Z`,
/// optional fractional seconds or offset) or date-only (`2024-05-28`, read as midnight UTC).
/// Dates at exactly midnight UTC are written date-only; others as `yyyy-MM-ddTHH:mm:ssZ`.
public enum ChartDates {
    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count == 10, let d = parseDateOnly(t) { return d }
        if let d = try? Date(t, strategy: Date.ISO8601FormatStyle()) { return d }
        if let d = try? Date(t, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return nil
    }

    public static func format(_ date: Date) -> String {
        let secs = date.timeIntervalSince1970
        if secs.truncatingRemainder(dividingBy: 86_400) == 0 {
            return date.formatted(Date.ISO8601FormatStyle().year().month().day())
        }
        return date.formatted(Date.ISO8601FormatStyle())
    }

    /// Midnight UTC on a calendar date.
    public static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func parseDateOnly(_ s: String) -> Date? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              parts[0].count == 4, (1...12).contains(m), (1...31).contains(d) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: y, month: m, day: d)
        guard let date = cal.date(from: comps) else { return nil }
        // Reject rollovers such as 2024-02-31.
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return date
    }
}
