import ChartKit
import Foundation

/// The 16 KB test chart package (`tiny-a.mbtiles` from AppServices' test resources: three blank PNG tiles at
/// zoom 0–2 over 27–28°N, 82–83°W). The UI tests ask the app to install it at startup
/// (`LaunchConfiguration.preinstallFixtureChart`) through `LocalFileChartTransport`, so no network is used;
/// debug builds of the app bundle the file.
public enum FixtureChart {
    public static let regionID = "uitest-fixture"
    public static let resourceName = "tiny-a"
    public static let resourceExtension = "mbtiles"
    /// A reserved host (`.invalid` never resolves), so nothing can reach the network by mistake.
    public static let packageURL = URL(string: "https://fixtures.gulfnav.invalid/uitest-fixture.mbtiles")!
    public static let byteSize: Int64 = 16_384
    /// SHA-256 of `tiny-a.mbtiles` (checked by a unit test against the file).
    public static let sha256 = "112c44ecf8e2167ee940dde103c9b1c5b6330ddb1da9ff07577fa03f25639f70"
    public static let dataDate: Date = ChartDates.day(2024, 5, 28)
    public static let title = "UI test chart"

    /// The region as a manifest entry. Not a NOAA host and a real checksum, so `InstallStrategy.choose`
    /// picks `.manifest` (size + SHA-256 + integrity checks).
    public static var region: ChartRegion {
        ChartRegion(id: regionID, title: title, summary: "16 KB test package (blank tiles) used by the UI tests.",
                    bounds: BoundingBox(west: -83, south: 27, east: -82, north: 28),
                    minZoom: 0, maxZoom: 2, tileFormat: .png,
                    chartPackage: PackageArtifact(url: packageURL, byteSize: byteSize, sha256: sha256,
                                                  version: "fixture-1", dataDate: dataDate),
                    source: "test")
    }

    /// The bundled file, if this build contains it.
    public static func bundledFile(in bundle: Bundle) -> URL? {
        bundle.url(forResource: resourceName, withExtension: resourceExtension)
    }
}

/// A `ChartTransport` that serves some URLs from local files and passes every other request to `fallback`
/// (nil: every other request fails with HTTP 404). Follows ChartKit's transport contract, including resume.
public struct LocalFileChartTransport: ChartTransport {
    public let files: [URL: URL]
    public let fallback: (any ChartTransport)?

    public init(files: [URL: URL], fallback: (any ChartTransport)?) {
        self.files = files
        self.fallback = fallback
    }

    public func head(_ url: URL) async throws -> RemoteValidators {
        guard let local = files[url] else {
            if let fallback { return try await fallback.head(url) }
            throw TransportError.httpStatus(404)
        }
        let data: Data = try LocalFileChartTransport.read(local)
        return RemoteValidators(etag: LocalFileChartTransport.etag(for: data), lastModified: nil,
                                contentLength: Int64(data.count), acceptsByteRanges: true)
    }

    public func download(_ request: DownloadRequest, progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadResponse {
        guard let local = files[request.url] else {
            if let fallback { return try await fallback.download(request, progress: progress) }
            throw TransportError.httpStatus(404)
        }
        try Task.checkCancellation()
        let data: Data = try LocalFileChartTransport.read(local)
        let total = Int64(data.count)
        let etag: String = LocalFileChartTransport.etag(for: data)
        let validators = RemoteValidators(etag: etag, lastModified: nil, contentLength: total, acceptsByteRanges: true)
        let canResume: Bool = request.resumeOffset > 0 && request.resumeOffset < total
            && (request.ifRange == nil || request.ifRange == etag)
        do {
            if canResume {
                let existing: Data = try Data(contentsOf: request.destination).prefix(Int(request.resumeOffset))
                let rest: Data = data.subdata(in: Int(request.resumeOffset)..<Int(total))
                try (existing + rest).write(to: request.destination)
            } else {
                try data.write(to: request.destination)
            }
        } catch {
            throw TransportError.other("could not write \(request.destination.lastPathComponent): \(error)")
        }
        progress(total)
        return DownloadResponse(statusCode: canResume ? 206 : 200, validators: validators, totalLength: total)
    }

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TransportError.httpStatus(404)
        }
    }

    static func etag(for data: Data) -> String {
        "\"local-\(data.count)\""
    }
}
