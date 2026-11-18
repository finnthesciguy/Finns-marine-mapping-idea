import Foundation
@testable import ChartKit

/// A unique temporary directory, removed by `cleanup()`.
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chartkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Builds tiny MBTiles files for tests.
enum Fixtures {
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A fake "PNG": correct signature plus a few distinguishing bytes.
    static func png(_ tag: UInt8 = 0) -> Data { Data(pngSignature + [0, 0, 0, 13, tag, tag &+ 1, tag &+ 2]) }

    enum Schema { case flat, normalized }

    /// Writes an MBTiles file. `tiles` are XYZ addresses; they are stored with TMS rows.
    @discardableResult
    static func makeMBTiles(at url: URL, schema: Schema = .normalized,
                            metadata: [String: String] = defaultMetadata,
                            tiles: [(TileCoordinate, Data)] = defaultTiles) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let db = try SQLiteConnection(path: url.path, mode: .readWriteCreate)
        try db.execute("CREATE TABLE metadata (name text, value text)")
        switch schema {
        case .flat:
            try db.execute("CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob)")
            try db.execute("CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)")
        case .normalized:
            try db.execute("CREATE TABLE map (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_id TEXT, grid_id TEXT)")
            try db.execute("CREATE TABLE images (tile_data blob, tile_id text)")
            try db.execute("CREATE UNIQUE INDEX map_index ON map (zoom_level, tile_column, tile_row)")
            try db.execute("""
                CREATE VIEW tiles AS SELECT map.zoom_level AS zoom_level, map.tile_column AS tile_column,
                map.tile_row AS tile_row, images.tile_data AS tile_data FROM map JOIN images ON images.tile_id = map.tile_id
                """)
        }
        for (k, v) in metadata.sorted(by: { $0.key < $1.key }) {
            let s = try db.prepare("INSERT INTO metadata (name, value) VALUES (?, ?)")
            try s.bind([.text(k), .text(v)])
            _ = try s.step()
        }
        for (i, (c, data)) in tiles.enumerated() {
            switch schema {
            case .flat:
                let s = try db.prepare("INSERT INTO tiles VALUES (?, ?, ?, ?)")
                try s.bind([.int(Int64(c.zoom)), .int(Int64(c.x)), .int(Int64(c.tmsRow)), .blob(data)])
                _ = try s.step()
            case .normalized:
                let id = "t\(i)"
                let m = try db.prepare("INSERT INTO map VALUES (?, ?, ?, ?, NULL)")
                try m.bind([.int(Int64(c.zoom)), .int(Int64(c.x)), .int(Int64(c.tmsRow)), .text(id)])
                _ = try m.step()
                let im = try db.prepare("INSERT INTO images VALUES (?, ?)")
                try im.bind([.blob(data), .text(id)])
                _ = try im.step()
            }
        }
        db.close()
        return url
    }

    static let defaultMetadata: [String: String] = [
        "name": "Test Region", "format": "png", "bounds": "-90.0,28.0,-89.0,29.0",
        "minzoom": "0", "maxzoom": "8", "center": "-89.5,28.5,6", "attribution": "NOAA",
    ]

    /// z0 world tile, two z8 tiles near (-89.5, 28.5) and one at z1.
    static var defaultTiles: [(TileCoordinate, Data)] {
        let z8 = TileMath.tile(longitude: -89.5, latitude: 28.5, zoom: 8)
        return [
            (TileCoordinate(zoom: 0, x: 0, y: 0), png(1)),
            (TileCoordinate(zoom: 1, x: 0, y: 0), png(2)),
            (z8, png(3)),
            (TileCoordinate(zoom: 8, x: z8.x + 1, y: z8.y), png(4)),
        ]
    }

    /// Bytes of a freshly built valid MBTiles file (and its SHA-256).
    static func mbtilesData(tag: UInt8 = 0) throws -> (Data, String) {
        let dir = try TempDir()
        defer { dir.cleanup() }
        var tiles = defaultTiles
        tiles.append((TileCoordinate(zoom: 2, x: 1, y: 1), png(tag)))
        let url = try makeMBTiles(at: dir.file("x.mbtiles"), tiles: tiles)
        let data = try Data(contentsOf: url)
        return (data, StreamingSHA256.hash(data))
    }

    static func region(id: String = "test_1", data: Data, sha: String? = nil, version: String = "v1",
                       url: URL? = nil, routing: (Data, String)? = nil, routingVersion: String = "r1") -> ChartRegion {
        let pkgURL = url ?? URL(string: "https://charts.example.com/\(id)-\(version).mbtiles")!
        let rp = routing.map {
            RoutingPackArtifact(url: URL(string: "https://charts.example.com/\(id)-\(routingVersion).routingpack")!,
                                byteSize: Int64($0.0.count), sha256: $0.1, version: routingVersion,
                                dataDate: ChartDates.day(2026, 11, 1), formatVersion: 1)
        }
        return ChartRegion(id: id, title: "Test \(id)", bounds: BoundingBox(west: -90, south: 28, east: -89, north: 29),
                           minZoom: 0, maxZoom: 8, tileFormat: .png,
                           chartPackage: PackageArtifact(url: pkgURL, byteSize: Int64(data.count),
                                                         sha256: sha ?? StreamingSHA256.hash(data), version: version,
                                                         dataDate: ChartDates.day(2026, 11, 1)),
                           source: "test", routingPack: rp)
    }
}

/// An in-memory HTTP server implementing the transport contract, with scripted faults.
actor FakeServer: ChartTransport {
    struct File {
        var data: Data
        var etag: String
        var lastModified: String
    }

    enum Fault {
        /// Write this many body bytes, then drop the connection.
        case interruptAfter(Int)
        /// Write this many body bytes, then fail with disk full.
        case diskFullAfter(Int)
        /// Write this many body bytes, replace the server file, then drop the connection.
        case changeFileAfter(Int, newData: Data, newETag: String)
        case http(Int)
        /// Sleep before serving (to test concurrent calls).
        case delay(milliseconds: Int)
    }

    var files: [URL: File] = [:]
    var honorIfRange = true
    var faults: [Fault] = []
    private(set) var requests: [DownloadRequest] = []
    private(set) var heads: [URL] = []

    init() {}

    func put(_ url: URL, data: Data, etag: String = "\"v1\"", lastModified: String = "Tue, 28 May 2024 21:39:50 GMT") {
        files[url] = File(data: data, etag: etag, lastModified: lastModified)
    }

    func setFaults(_ f: [Fault]) { faults = f }
    func setHonorIfRange(_ v: Bool) { honorIfRange = v }

    func head(_ url: URL) async throws -> RemoteValidators {
        heads.append(url)
        guard let f = files[url] else { throw TransportError.httpStatus(404) }
        return RemoteValidators(etag: f.etag, lastModified: f.lastModified, contentLength: Int64(f.data.count), acceptsByteRanges: true)
    }

    func download(_ request: DownloadRequest, progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadResponse {
        requests.append(request)
        var fault = faults.isEmpty ? nil : faults.removeFirst()
        if case .delay(let ms) = fault {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            fault = nil
        }
        if case .http(let code) = fault { throw TransportError.httpStatus(code) }
        guard let file = files[request.url] else { throw TransportError.httpStatus(404) }

        var status = 200
        var start = 0
        if request.resumeOffset > 0 {
            let validatorMatches = request.ifRange == nil || request.ifRange == file.etag || request.ifRange == file.lastModified
            if !honorIfRange || validatorMatches {
                status = 206
                start = Int(request.resumeOffset)
            }
        }
        guard start <= file.data.count else { throw TransportError.httpStatus(416) }
        let body = file.data.subdata(in: start..<file.data.count)

        let fm = FileManager.default
        if status == 200 || !fm.fileExists(atPath: request.destination.path) {
            try Data().write(to: request.destination)
        }
        let handle = try FileHandle(forWritingTo: request.destination)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var limit = body.count
        switch fault {
        case .interruptAfter(let n), .diskFullAfter(let n), .changeFileAfter(let n, _, _): limit = min(n, body.count)
        default: break
        }
        // Write in small chunks, reporting progress as a real transport would.
        var written = 0
        while written < limit {
            let n = min(4096, limit - written)
            try handle.write(contentsOf: body.subdata(in: written..<(written + n)))
            written += n
            progress(Int64(start + written))
        }
        switch fault {
        case .interruptAfter: throw TransportError.interrupted
        case .diskFullAfter: throw TransportError.diskFull
        case .changeFileAfter(_, let newData, let newETag):
            files[request.url] = File(data: newData, etag: newETag, lastModified: "Wed, 12 Nov 2026 06:00:00 GMT")
            throw TransportError.interrupted
        default: break
        }
        return DownloadResponse(statusCode: status,
                                validators: RemoteValidators(etag: file.etag, lastModified: file.lastModified,
                                                             contentLength: Int64(body.count)),
                                totalLength: Int64(file.data.count))
    }
}

struct FakeDiskSpace: DiskSpaceProvider {
    var available: Int64
    func availableBytes(for directory: URL) throws -> Int64 { available }
}

/// Collects observer callbacks.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(String, InstallState)] = []

    func record(_ id: String, _ s: InstallState) {
        lock.lock(); defer { lock.unlock() }
        _events.append((id, s))
    }

    var states: [InstallState] {
        lock.lock(); defer { lock.unlock() }
        return _events.map(\.1)
    }
}
