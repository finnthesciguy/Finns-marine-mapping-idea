import ChartKit
import Foundation
import XCTest
@testable import AppServices

/// Exercises the real `URLSessionChartTransport` against a local HTTP server with range support.
/// Opt-in, skipped otherwise (including on CI). Start `Scripts/range_server.py` and point the tests at it:
///
///     python3 Scripts/range_server.py 8765 Tests/AppServicesTests/Resources/tiny-a.mbtiles &
///     NO_PROXY='*' APPSERVICES_TEST_SERVER=http://127.0.0.1:8765 swift test
///
/// The server serves:
///   /file     1,000,000 deterministic bytes (byte i = i % 251), ETag "v1", Last-Modified, Accept-Ranges,
///             honouring Range only when If-Range matches the ETag
///   /drop     Content-Length 1,000,000 but closes the connection after 300,000 bytes
///   /slow     1,000,000 bytes sent slowly (for cancellation)
///   /missing  404
///   /tiny.mbtiles  the file given as the second argument
final class URLSessionTransportIntegrationTests: XCTestCase {
    var base: URL!
    var dir: TempDir!
    let transport = URLSessionChartTransport()

    override func setUpWithError() throws {
        guard let value = ProcessInfo.processInfo.environment["APPSERVICES_TEST_SERVER"], let url = URL(string: value) else {
            throw XCTSkip("set APPSERVICES_TEST_SERVER to run URLSession integration tests")
        }
        base = url
        dir = try TempDir()
    }

    override func tearDown() {
        dir?.cleanup()
    }

    static func expected(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8(i % 251) }
        return Data(bytes)
    }

    func testHead() async throws {
        let v = try await transport.head(base.appendingPathComponent("file"))
        XCTAssertEqual(v.etag, "\"v1\"")
        XCTAssertEqual(v.contentLength, 1_000_000)
        XCTAssertEqual(v.acceptsByteRanges, true)
        XCTAssertNotNil(v.lastModifiedDate)
    }

    func testFullDownloadWithProgress() async throws {
        let dest = dir.url.appendingPathComponent("a.partial")
        try Data("stale".utf8).write(to: dest)
        let box = ProgressBox()
        let response = try await transport.download(
            DownloadRequest(url: base.appendingPathComponent("file"), destination: dest, resumeOffset: 0, ifRange: nil),
            progress: { box.record($0) })
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.totalLength, 1_000_000)
        XCTAssertEqual(response.validators.etag, "\"v1\"")
        XCTAssertEqual(try Data(contentsOf: dest), Self.expected(1_000_000))
        XCTAssertEqual(box.values.last, 1_000_000)
        XCTAssertEqual(box.values, box.values.sorted())
    }

    func testResumeAppendsOn206() async throws {
        let dest = dir.url.appendingPathComponent("b.partial")
        try Self.expected(400_000).write(to: dest)
        let box = ProgressBox()
        let response = try await transport.download(
            DownloadRequest(url: base.appendingPathComponent("file"), destination: dest, resumeOffset: 400_000, ifRange: "\"v1\""),
            progress: { box.record($0) })
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.totalLength, 1_000_000)
        XCTAssertEqual(response.validators.contentLength, 1_000_000)
        XCTAssertEqual(try Data(contentsOf: dest), Self.expected(1_000_000))
        XCTAssertGreaterThanOrEqual(box.values.first ?? 0, 400_000, "progress counts resumed bytes")
    }

    func testStaleIfRangeRestartsWith200() async throws {
        let dest = dir.url.appendingPathComponent("c.partial")
        try Data(repeating: 0xFF, count: 400_000).write(to: dest)
        let response = try await transport.download(
            DownloadRequest(url: base.appendingPathComponent("file"), destination: dest, resumeOffset: 400_000, ifRange: "\"old\""),
            progress: { _ in })
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: dest), Self.expected(1_000_000))
    }

    func testDroppedConnectionThrowsInterruptedAndKeepsBytes() async throws {
        let dest = dir.url.appendingPathComponent("d.partial")
        do {
            _ = try await transport.download(
                DownloadRequest(url: base.appendingPathComponent("drop"), destination: dest, resumeOffset: 0, ifRange: nil),
                progress: { _ in })
            XCTFail("expected an interruption")
        } catch let error as TransportError {
            XCTAssertEqual(error, .interrupted)
        }
        let kept = try Data(contentsOf: dest)
        XCTAssertGreaterThan(kept.count, 0)
        XCTAssertEqual(kept, Self.expected(kept.count))
    }

    func testMissingFile() async throws {
        let dest = dir.url.appendingPathComponent("e.partial")
        do {
            _ = try await transport.download(
                DownloadRequest(url: base.appendingPathComponent("missing"), destination: dest, resumeOffset: 0, ifRange: nil),
                progress: { _ in })
            XCTFail("expected 404")
        } catch let error as TransportError {
            XCTAssertEqual(error, .httpStatus(404))
        }
        do {
            _ = try await transport.head(base.appendingPathComponent("missing"))
            XCTFail("expected 404")
        } catch let error as TransportError {
            XCTAssertEqual(error, .httpStatus(404))
        }
    }

    func testCancellation() async throws {
        let dest = dir.url.appendingPathComponent("f.partial")
        let url = base.appendingPathComponent("slow")
        let transport = self.transport
        let task = Task {
            try await transport.download(DownloadRequest(url: url, destination: dest, resumeOffset: 0, ifRange: nil),
                                         progress: { _ in })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as TransportError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    /// End to end: ChartKit's installer driving the real transport (HEAD, GET, verify, install).
    func testInstallerThroughRealTransport() async throws {
        let paths = AppPaths(libraryDirectory: dir.url)
        let env = try AppEnvironment.make(paths: paths, transport: transport, acknowledgements: InMemoryAcknowledgementStore(),
                                          diskSpace: FixedDiskSpace(bytes: 10_000_000_000),
                                          configuration: ChartInstaller.Configuration(freeSpaceMargin: 0, maxAttemptsPerArtifact: 1))
        let region = Fixtures.region(id: "tiny", url: base.appendingPathComponent("tiny.mbtiles"))
        let spec = try await env.charts.fallbackSpec(for: region)
        XCTAssertEqual(spec.expectedByteSize, 16_384)
        let installed = try await env.charts.installer.install(RegionDescriptor(region), chart: spec, routingPack: nil)
        XCTAssertEqual(installed.chart.byteSize, 16_384)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    func record(_ value: Int64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
