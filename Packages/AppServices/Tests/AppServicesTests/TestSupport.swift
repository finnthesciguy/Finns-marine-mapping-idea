import ChartKit
import Foundation
@testable import AppServices

struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appservices-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"])
        }
        return try Data(contentsOf: url)
    }

    static let noaaURL = URL(string: "https://distribution.charts.noaa.gov/ncds/mbtiles/ncds_99.mbtiles")!

    static func region(id: String = "ncds_99", url: URL = noaaURL, byteSize: Int64 = 16_384,
                       sha256: String = String(repeating: "0", count: 64),
                       dataDate: Date = ChartDates.day(2024, 5, 28)) -> ChartRegion {
        ChartRegion(id: id, title: "Test region \(id)", summary: "A test region",
                    bounds: BoundingBox(west: -83, south: 27, east: -82, north: 28),
                    minZoom: 0, maxZoom: 2, tileFormat: .png,
                    chartPackage: PackageArtifact(url: url, byteSize: byteSize, sha256: sha256,
                                                  version: "2024-05-28", dataDate: dataDate),
                    source: "test")
    }
}

/// In-process stand-in for an HTTP server plus transport, following ChartKit's `ChartTransport` contract
/// with the same `ChartHTTP` rules the URLSession transport uses.
final class FakeServerTransport: ChartTransport, @unchecked Sendable {
    struct File {
        var data: Data
        var etag: String
        var lastModified: String
    }

    struct Call: Equatable {
        var method: String
        var url: URL
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var files: [URL: File] = [:]
    private var calls: [Call] = []
    /// When set, the next GET writes this many body bytes and then throws `.interrupted`.
    private var interruptAfter: Int?

    func publish(_ data: Data, at url: URL, etag: String, lastModified: String) {
        lock.lock()
        files[url] = File(data: data, etag: etag, lastModified: lastModified)
        lock.unlock()
    }

    func interruptNextDownload(after bytes: Int) {
        lock.lock()
        interruptAfter = bytes
        lock.unlock()
    }

    var recordedCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    private func file(at url: URL) -> File? {
        lock.lock()
        defer { lock.unlock() }
        return files[url]
    }

    private func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    private func takeInterruption() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let value = interruptAfter
        interruptAfter = nil
        return value
    }

    func head(_ url: URL) async throws -> RemoteValidators {
        record(Call(method: "HEAD", url: url, headers: ChartHTTP.headHeaders()))
        guard let file = file(at: url) else { throw TransportError.httpStatus(404) }
        return RemoteValidators(etag: file.etag, lastModified: file.lastModified,
                                contentLength: Int64(file.data.count), acceptsByteRanges: true)
    }

    func download(_ request: DownloadRequest, progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadResponse {
        let headers = ChartHTTP.downloadHeaders(for: request)
        record(Call(method: "GET", url: request.url, headers: headers))
        guard let file = file(at: request.url) else { throw TransportError.httpStatus(404) }
        let total = Int64(file.data.count)

        // Server side: honour Range only when If-Range matches the current ETag or Last-Modified.
        var status = 200
        var responseHeaders: [String: String] = ["ETag": file.etag, "Last-Modified": file.lastModified]
        var body = file.data
        if let range = headers["Range"], range.hasPrefix("bytes="), let start = Int64(range.dropFirst(6).dropLast()) {
            let ifRange = headers["If-Range"]
            if ifRange == nil || ifRange == file.etag || ifRange == file.lastModified {
                if start >= total { throw TransportError.httpStatus(416) }
                status = 206
                body = file.data.subdata(in: Int(start)..<Int(total))
                responseHeaders["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)"
            }
        }
        responseHeaders["Content-Length"] = String(body.count)

        // Client side: same decisions as URLSessionChartTransport.
        switch ChartHTTP.decide(statusCode: status, resumeOffset: request.resumeOffset, headers: responseHeaders) {
        case .fail(let error):
            throw error
        case .write(let mode):
            var existing = Data()
            if mode == .append {
                existing = try Data(contentsOf: request.destination).prefix(Int(request.resumeOffset))
            }
            var toWrite = body
            var interrupted = false
            if let limit = takeInterruption(), limit < body.count {
                toWrite = body.prefix(limit)
                interrupted = true
            }
            try (existing + toWrite).write(to: request.destination)
            progress(Int64(existing.count + toWrite.count))
            if interrupted { throw TransportError.interrupted }
        }
        return DownloadResponse(statusCode: status,
                                validators: ChartHTTP.validators(statusCode: status, headers: responseHeaders),
                                totalLength: ChartHTTP.totalLength(statusCode: status, headers: responseHeaders))
    }
}

/// Fixed free space.
struct FixedDiskSpace: DiskSpaceProvider {
    var bytes: Int64
    func availableBytes(for directory: URL) throws -> Int64 { bytes }
}
