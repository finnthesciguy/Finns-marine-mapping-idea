import ChartKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Persistence

/// Online NOAA charts: tiles rendered on demand by NOAA's Maritime Chart Service export (`MCS/NOAAChartDisplay`,
/// the current "paper chart" portrayal; see docs/spikes/chart-source.md), cached on disk.
///
/// No Gulf chart package has been built yet, so this is what a fresh install shows. Installed offline regions
/// are drawn above it. NOAA publishes no rate limits for the service; the app is polite: a generic User-Agent,
/// at most two requests in flight, only tiles inside the Gulf coast box and at zoom 3–16 (deeper zooms are cut
/// from the zoom-16 tile), and every tile is kept on disk for a week (NOAA reloads the ENC data weekly).
public enum LiveChartService {
    public static let exportURL: String =
        "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export"
    /// All chart layers, as in the pipeline's render config (`pipeline/charts/.../render.json`).
    public static let layers: String = "show:0,1,2,3,4,5,6,7"
    public static let tileSize: Int = 256
    public static let minZoom: Int = 3
    /// Highest zoom requested from NOAA; above it tiles are cut from this zoom's tile.
    public static let maxZoom: Int = 16
    /// Union of the five NCDS Gulf regions (ncds_10…14) in `pipeline/charts/.../regions.json`.
    public static let coverage: BoundingBox = BoundingBox(west: -98.291526, south: 17.6, east: -80.05, north: 33.930626)
    /// Generic, identifies the app but nothing about the user.
    public static let userAgent: String = "GulfNav/0.1 (recreational chart viewer)"
    public static let earthRadius: Double = 6_378_137.0

    /// Web Mercator (EPSG:3857) bounds of an XYZ tile: minX, minY, maxX, maxY in metres.
    public static func mercatorBounds(_ tile: ChartTileMath.Tile) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let world: Double = 2.0 * Double.pi * earthRadius
        let size: Double = world / Double(1 << tile.zoom)
        let minX: Double = -world / 2.0 + Double(tile.x) * size
        let maxY: Double = world / 2.0 - Double(tile.y) * size
        return (minX, maxY - size, minX + size, maxY)
    }

    /// Whether NOAA should be asked for this tile (inside the Gulf box, zoom within range).
    public static func shouldRequest(_ tile: ChartTileMath.Tile) -> Bool {
        tile.isValid && tile.zoom >= minZoom && tile.zoom <= maxZoom && ChartTileMath.tile(tile, overlaps: coverage)
    }

    /// The export request for one tile. `scale` 2 asks for a 512 px image at 192 dpi over the same footprint:
    /// a true retina tile (same chart content, symbols and text at twice the pixels).
    public static func tileURL(_ tile: ChartTileMath.Tile, scale: Int) -> URL? {
        let b = mercatorBounds(tile)
        let s: Int = max(1, min(scale, 2))
        let bbox: String = [b.minX, b.minY, b.maxX, b.maxY].map { String(format: "%.6f", $0) }.joined(separator: ",")
        return URL(string: query(bbox: bbox, pixels: tileSize * s, dpi: 96 * s))
    }

    /// The same request as a MapLibre tile URL template (`{bbox-epsg-3857}` is filled in by MapLibre per tile;
    /// supported by MapLibre Native 7.0.0, `src/mln/storage/resource.cpp`).
    public static func mapLibreTemplate(scale: Int) -> String {
        let s: Int = max(1, min(scale, 2))
        return query(bbox: "{bbox-epsg-3857}", pixels: tileSize * s, dpi: 96 * s)
    }

    static func query(bbox: String, pixels: Int, dpi: Int) -> String {
        exportURL + "?bbox=" + bbox + "&bboxSR=3857&imageSR=3857&size=\(pixels),\(pixels)&dpi=\(dpi)"
            + "&format=png32&transparent=true&layers=" + layers + "&f=image"
    }

    /// True for PNG data (NOAA answers errors with JSON or HTML, sometimes with HTTP 200).
    public static func isPNG(_ data: Data) -> Bool {
        TileFormat.sniff(data) == .png
    }
}

// MARK: - Cache

/// Tiles on disk: `<root>/<scale>x/<z>/<x>/<y>.png`. A tile newer than `maxAge` is used without asking NOAA; an
/// older one is used when NOAA cannot be reached.
public struct LiveChartCache: Sendable {
    public let root: URL
    public var maxAge: TimeInterval

    public init(root: URL, maxAge: TimeInterval = 7 * 24 * 3600) {
        self.root = root.standardizedFileURL
        self.maxAge = maxAge
    }

    public func fileURL(_ tile: ChartTileMath.Tile, scale: Int) -> URL {
        root.appendingPathComponent("\(scale)x", isDirectory: true)
            .appendingPathComponent("\(tile.zoom)", isDirectory: true)
            .appendingPathComponent("\(tile.x)", isDirectory: true)
            .appendingPathComponent("\(tile.y).png", isDirectory: false)
    }

    public enum Lookup: Equatable, Sendable {
        case fresh(Data)
        case stale(Data)
        case missing
    }

    public func lookup(_ tile: ChartTileMath.Tile, scale: Int, now: Date) -> Lookup {
        let url: URL = fileURL(tile, scale: scale)
        guard let data = try? Data(contentsOf: url) else { return .missing }
        let attributes: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified: Date = (attributes?[.modificationDate] as? Date) ?? .distantPast
        return now.timeIntervalSince(modified) <= maxAge ? .fresh(data) : .stale(data)
    }

    public func store(_ data: Data, tile: ChartTileMath.Tile, scale: Int) throws {
        let url: URL = fileURL(tile, scale: scale)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Total bytes of cached tiles.
    public func totalBytes() -> Int64 {
        var total: Int64 = 0
        for (_, size, _) in files() { total += size }
        return total
    }

    /// Deletes the least recently written tiles until the cache is at most `maxBytes`. Returns files removed.
    @discardableResult
    public func prune(maxBytes: Int64) -> Int {
        var entries = files()
        var total: Int64 = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return 0 }
        entries.sort { $0.modified < $1.modified }
        var removed: Int = 0
        for entry in entries where total > maxBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
                removed += 1
            }
        }
        return removed
    }

    /// Removes every cached tile.
    public func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func files() -> [(url: URL, size: Int64, modified: Date)] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(url: URL, size: Int64, modified: Date)] = []
        while let next = enumerator.nextObject() as? URL {
            guard next.pathExtension == "png" else { continue }
            let attributes: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: next.path)
            let size: Int64 = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified: Date = (attributes?[.modificationDate] as? Date) ?? .distantPast
            out.append((next, size, modified))
        }
        return out
    }
}

// MARK: - Fetching

/// One HTTP GET (injectable for tests).
public protocol LiveTileTransport: Sendable {
    func get(_ url: URL) async throws -> (data: Data, status: Int)
}

public struct URLSessionLiveTileTransport: LiveTileTransport {
    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = ["User-Agent": LiveChartService.userAgent]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.setValue(LiveChartService.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// A tile for the map.
public enum LiveTileResult: Equatable, Sendable {
    /// PNG data covering `source` (cut out `source` when it is not the whole tile: the zoom is above `maxZoom`).
    case image(Data, source: ChartTileMath.Source)
    /// Nothing to draw here (outside the Gulf box, below the minimum zoom).
    case empty
    /// Not cached and NOAA could not be reached.
    case unavailable
}

/// What the Charts screen and the map show about the online source.
public struct LiveChartStatus: Sendable, Equatable {
    public enum Connection: String, Sendable, Equatable {
        /// Nothing asked yet.
        case idle
        /// The last request to NOAA succeeded.
        case online
        /// The last request failed: cached tiles only.
        case offline
    }

    public var connection: Connection = .idle
    public var fetched: Int = 0
    public var cacheHits: Int = 0
    public var failures: Int = 0
    public var lastError: String?

    public init() {}

    /// "Online NOAA charts: connected", "…: offline, showing tiles saved on this device".
    public var line: String {
        switch connection {
        case .idle: return "Online NOAA charts: on"
        case .online: return "Online NOAA charts: connected"
        case .offline: return "Online NOAA charts: offline, showing tiles saved on this device"
        }
    }

    /// `liveCharts=online; liveFetched=12; liveCached=40; liveFailures=0` for the debug `app.status` probe (the
    /// same `; `-separated `key=value` form as the rest of it).
    public var statusValue: String {
        "liveCharts=\(connection.rawValue); liveFetched=\(fetched); liveCached=\(cacheHits); liveFailures=\(failures)"
    }
}

/// Loads tiles: disk cache first, then NOAA with at most `maxConcurrent` requests in flight.
public actor LiveChartTileLoader {
    public nonisolated let cache: LiveChartCache
    let transport: any LiveTileTransport
    let maxConcurrent: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) public var status: LiveChartStatus = LiveChartStatus()

    public init(cache: LiveChartCache, transport: any LiveTileTransport = URLSessionLiveTileTransport(), maxConcurrent: Int = 2) {
        self.cache = cache
        self.transport = transport
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// The tile at `tile` for a display of `scale` (1 or 2), now.
    public func tile(_ tile: ChartTileMath.Tile, scale: Int, now: Date = Date()) async -> LiveTileResult {
        guard tile.isValid, tile.zoom >= LiveChartService.minZoom,
              ChartTileMath.tile(tile, overlaps: LiveChartService.coverage),
              let source = ChartTileMath.source(for: tile, maxZoom: LiveChartService.maxZoom) else {
            return .empty
        }
        let s: Int = max(1, min(scale, 2))
        let stale: Data?
        switch cache.lookup(source.tile, scale: s, now: now) {
        case .fresh(let data):
            status.cacheHits += 1
            return .image(data, source: source)
        case .stale(let data):
            stale = data
        case .missing:
            stale = nil
        }
        guard let url = LiveChartService.tileURL(source.tile, scale: s) else { return .unavailable }
        await acquire()
        let outcome: Result<(data: Data, status: Int), any Error>
        do {
            outcome = .success(try await transport.get(url))
        } catch {
            outcome = .failure(error)
        }
        release()
        switch outcome {
        case .success(let response) where response.status == 200 && LiveChartService.isPNG(response.data):
            try? cache.store(response.data, tile: source.tile, scale: s)
            status.fetched += 1
            status.connection = .online
            return .image(response.data, source: source)
        case .success(let response):
            note(failure: "HTTP \(response.status)" + (LiveChartService.isPNG(response.data) ? "" : ", not a PNG"))
        case .failure(let error):
            note(failure: String(describing: error))
        }
        if let stale {
            return .image(stale, source: source)
        }
        return .unavailable
    }

    private func note(failure: String) {
        status.failures += 1
        status.connection = .offline
        status.lastError = String(failure.prefix(200))
    }

    private func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }

    /// Requests in flight now (for tests).
    public var requestsInFlight: Int { inFlight }
}

// MARK: - Setting

extension SettingKey where Value == Bool {
    /// "Online NOAA charts" in the Charts screen. On by default: without it a new install shows no chart.
    public static var liveNOAACharts: SettingKey<Bool> { SettingKey<Bool>("charts.liveNOAA", default: true) }
}
