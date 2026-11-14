import Foundation
import Testing
@testable import ChartKit

/// Tests against NOAA's real ncds_13.mbtiles (381 MB). Set CHARTKIT_SAMPLE_MBTILES to its path;
/// without it the suite is skipped.
private let samplePath = ProcessInfo.processInfo.environment["CHARTKIT_SAMPLE_MBTILES"].flatMap { $0.isEmpty ? nil : $0 }

@Suite(.enabled(if: samplePath != nil, "set CHARTKIT_SAMPLE_MBTILES to the path of ncds_13.mbtiles"))
struct SampleMBTilesTests {
    var url: URL { URL(fileURLWithPath: samplePath ?? "/nonexistent") }

    @Test func metadataMatchesNOAA() async throws {
        let reader = try MBTilesReader(url: url)
        let meta = try await reader.metadata()
        #expect(meta.format == .png)
        #expect(meta.minZoom == 0)
        #expect(meta.maxZoom == 16)
        #expect(meta.bounds == BoundingBox(west: -92.457141, south: 17.6, east: -89.069253, north: 29.333333))
        #expect(meta.name == "SG_AREA")
        #expect(meta.all["legend"] != nil)
    }

    @Test func knownTilesDecodeAsPNG() async throws {
        let reader = try MBTilesReader(url: url)
        let world = try #require(try await reader.tile(zoom: 0, x: 0, y: 0))
        #expect(world.count == 355)
        #expect(Array(world.prefix(8)) == Fixtures.pngSignature)
        // A detailed z16 tile in the Mississippi passes: XYZ y 27239 == TMS row 38296.
        let detail = try #require(try await reader.tile(zoom: 16, x: 16514, y: 27239))
        #expect(detail.count == 71_668)
        #expect(TileFormat.sniff(detail) == .png)
        #expect(try await reader.tile(zoom: 16, column: 16514, tmsRow: 38296) == detail)
        #expect(try await reader.tile(zoom: 16, x: 0, y: 0) == nil)
    }

    @Test func perZoomCounts() async throws {
        let counts = try await MBTilesReader(url: url).tileCountsByZoom()
        #expect(counts[16] == 81_920)
        #expect(counts[0] == 1)
        #expect(counts[8] == 16_384)
        #expect(counts.keys.sorted() == Array(0...16))
    }

    @Test func coverage() async throws {
        let reader = try MBTilesReader(url: url)
        let passes = BoundingBox(west: -89.30, south: 29.00, east: -89.28, north: 29.05)
        let galveston = BoundingBox(west: -94.9, south: 29.2, east: -94.7, north: 29.4)
        #expect(try await reader.hasTiles(zoom: 16, in: passes))
        #expect(try await !reader.hasTiles(zoom: 16, in: galveston))
        let cov = try await reader.coverage(zoom: 14, in: passes)
        #expect(cov.present == cov.expected)
    }

    @Test func integrity() async throws {
        let report = try await MBTilesReader.checkIntegrity(at: url, deep: true)
        #expect(report.schema == .tilesView)
        #expect(report.sampleTileFormat == .png)
    }

    @Test func layerPlanForTheRealPackage() async throws {
        let meta = try await MBTilesReader(url: url).metadata()
        let bounds = try #require(meta.bounds)
        let art = InstalledArtifact(version: "2024-05-28", sha256: "", byteSize: 0, dataDate: ChartDates.day(2024, 5, 28),
                                    sourceURL: url, relativePath: url.lastPathComponent, installedAt: Date(), validators: nil)
        let region = InstalledRegion(id: "ncds_13", title: "", bounds: bounds, minZoom: meta.minZoom ?? 0, maxZoom: meta.maxZoom ?? 16,
                                     tileFormat: .png, source: "", chart: art)
        let plan = MapLibreSources.layerPlan(for: [region]) { _ in url }
        #expect(plan.first?.sourceURL == "mbtiles://" + url.standardizedFileURL.path)
        #expect(plan.first?.sourceURL.hasPrefix("mbtiles:///") == true)
    }
}

/// Serves one local file over the transport contract, streaming in 1 MB chunks.
private struct LocalFileTransport: ChartTransport {
    let source: URL

    func head(_ url: URL) async throws -> RemoteValidators {
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
        return RemoteValidators(etag: "\"e4a1d69147b1da1:0\"", lastModified: "Tue, 28 May 2024 21:39:50 GMT",
                                contentLength: size, acceptsByteRanges: true)
    }

    func download(_ request: DownloadRequest, progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadResponse {
        let validators = try await head(request.url)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(request.resumeOffset))
        if request.resumeOffset == 0 { try Data().write(to: request.destination) }
        let output = try FileHandle(forWritingTo: request.destination)
        defer { try? output.close() }
        try output.seekToEnd()
        var written = request.resumeOffset
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            written += Int64(chunk.count)
            progress(written)
        }
        return DownloadResponse(statusCode: request.resumeOffset > 0 ? 206 : 200, validators: validators,
                                totalLength: validators.contentLength)
    }
}

extension SampleMBTilesTests {
    /// End to end with the real 381 MB package and the checksum published in the sample manifest:
    /// streamed SHA-256, integrity check, swap into place.
    @Test func installsTheRealPackageFromTheSampleManifest() async throws {
        let manifest = try ChartManifest.decode(from: Data(contentsOf: sampleManifestURL))
        let region = try #require(manifest.region(id: "ncds_13"))
        let dir = try TempDir()
        defer { dir.cleanup() }
        let installer = try ChartInstaller(rootDirectory: dir.url, transport: LocalFileTransport(source: url))
        let installed = try await installer.install(region)
        #expect(installed.chart.sha256 == "6d9b0701e3acd6a8e38855d3388138c0407e4778b4da460b6777705423b80439")
        #expect(installed.chart.byteSize == 380_833_792)
        let counts = try await MBTilesReader(url: installer.fileURL(for: installed.chart)).tileCountsByZoom()
        #expect(counts[16] == 81_920)
    }
}
