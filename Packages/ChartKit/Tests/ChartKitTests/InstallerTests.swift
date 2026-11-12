import Foundation
import Testing
@testable import ChartKit

@Suite struct InstallerTests {
    let small = ChartInstaller.Configuration(freeSpaceMargin: 0, maxAttemptsPerArtifact: 1)

    func makeInstaller(_ dir: TempDir, _ server: FakeServer, config: ChartInstaller.Configuration? = nil,
                       disk: Int64 = .max) throws -> ChartInstaller {
        try ChartInstaller(rootDirectory: dir.file("charts"), transport: server, diskSpace: FakeDiskSpace(available: disk),
                           configuration: config ?? small)
    }

    @Test func freshInstallHappyPath() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, sha) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        let installer = try makeInstaller(dir, server)
        let log = StateLog()
        await installer.setObserver { log.record($0, $1) }

        #expect(await installer.state(for: region.id) == .notInstalled)
        let installed = try await installer.install(region)
        #expect(installed.chart.sha256 == sha)
        #expect(installed.chart.version == "v1")
        #expect(installed.chart.validators?.etag == "\"v1\"")
        #expect(await installer.state(for: region.id) == .installed(version: "v1"))

        let states = log.states
        #expect(states.first == .queued)
        #expect(states.contains { if case .downloading = $0 { return true } else { return false } })
        #expect(Array(states.suffix(3)) == [.verifying, .installing, .installed(version: "v1")])

        let file = try #require(await installer.chartFileURL(regionID: region.id))
        #expect(file.path.hasPrefix(dir.file("charts").standardizedFileURL.path))
        #expect(try Data(contentsOf: file) == data)
        let reader = try MBTilesReader(url: file)
        #expect(try await reader.metadata().format == .png)
        #expect(await installer.pendingDownloads().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.file("charts/staging").path).isEmpty)

        // Relaunch: state is read back from disk.
        let again = try makeInstaller(dir, server)
        #expect(await again.installedRegions() == [installed])
        #expect(await again.state(for: region.id) == .installed(version: "v1"))

        // Installing the same thing again downloads nothing.
        let before = await server.requests.count
        _ = try await again.install(region)
        #expect(await server.requests.count == before)
    }

    @Test func interruptionThenResumeAfterRelaunch() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, sha) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        await server.setFaults([.interruptAfter(5000)])

        let installer = try makeInstaller(dir, server)
        await #expect(throws: InstallFailure.interrupted(bytesReceived: 5000)) { try await installer.install(region) }
        #expect(await installer.state(for: region.id) == .failed(.interrupted(bytesReceived: 5000)))
        #expect(await installer.installedRegion(id: region.id) == nil)
        let pending = await installer.pendingDownloads()
        #expect(pending.count == 1 && pending[0].bytesReceived == 5000 && pending[0].validators?.etag == "\"v1\"")

        // New process: resume bookkeeping survives.
        let relaunched = try makeInstaller(dir, server)
        #expect(await relaunched.state(for: region.id) == .failed(.interrupted(bytesReceived: 5000)))
        let installed = try await relaunched.install(region)
        #expect(installed.chart.sha256 == sha)
        let reqs = await server.requests
        #expect(reqs.map(\.resumeOffset) == [0, 5000])
        #expect(reqs[1].ifRange == "\"v1\"")
        #expect(await server.heads.count == 1) // validators came from the record, not a second HEAD
    }

    @Test func automaticResumeWithinOneCall() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, sha) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        await server.setFaults([.interruptAfter(4096), .interruptAfter(4096)])
        let installer = try makeInstaller(dir, server, config: .init(freeSpaceMargin: 0, maxAttemptsPerArtifact: 3))
        let log = StateLog()
        await installer.setObserver { log.record($0, $1) }
        let installed = try await installer.install(region)
        #expect(installed.chart.sha256 == sha)
        #expect(await server.requests.map(\.resumeOffset) == [0, 4096, 8192])
        // Let progress hops land, then check progress reached the end and never went backwards.
        try await Task.sleep(nanoseconds: 50_000_000)
        let received = log.states.compactMap { s -> Int64? in if case .downloading(let p) = s { return p.bytesReceived } else { return nil } }
        #expect(received == received.sorted())
    }

    @Test func serverFileChangesMidDownloadIfRangeHonoured() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (v1, _) = try Fixtures.mbtilesData(tag: 1)
        let (v2, sha2) = try Fixtures.mbtilesData(tag: 2)
        let url = URL(string: "https://distribution.charts.noaa.gov/ncds/mbtiles/ncds_13.mbtiles")!
        let server = FakeServer()
        await server.put(url, data: v1, etag: "\"one\"")
        await server.setFaults([.changeFileAfter(3000, newData: v2, newETag: "\"two\"")])
        let installer = try makeInstaller(dir, server)
        // NOAA-style: no checksum, sizes only from HEAD (both fixtures have the same size here).
        let head = try await server.head(url)
        let spec = DownloadSpec(url: url, expectedByteSize: nil, sha256: nil, version: "noaa", dataDate: Date())
        let d = RegionDescriptor(id: "ncds_13", title: "13", bounds: BoundingBox(west: -92, south: 17, east: -89, north: 29),
                                 minZoom: 0, maxZoom: 8, tileFormat: .png, source: "NOAA")
        #expect(head.etag == "\"one\"")
        await #expect(throws: InstallFailure.interrupted(bytesReceived: 3000)) { try await installer.install(d, chart: spec) }
        let installed = try await installer.install(d, chart: spec)
        let reqs = await server.requests
        #expect(reqs.map(\.resumeOffset) == [0, 3000])
        #expect(reqs[1].ifRange == "\"one\"")
        // Server answered 200 with the new file; ChartKit took it whole.
        #expect(installed.chart.sha256 == sha2)
        #expect(installed.chart.validators?.etag == "\"two\"")
        #expect(try Data(contentsOf: installer.fileURL(for: installed.chart)) == v2)
    }

    @Test func serverIgnoresIfRangeAndFileChanged() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (v1, _) = try Fixtures.mbtilesData(tag: 1)
        let (v2, sha2) = try Fixtures.mbtilesData(tag: 2)
        let url = URL(string: "https://example.com/p.mbtiles")!
        let server = FakeServer()
        await server.put(url, data: v1, etag: "\"one\"")
        await server.setHonorIfRange(false)
        await server.setFaults([.changeFileAfter(3000, newData: v2, newETag: "\"two\"")])
        let installer = try makeInstaller(dir, server, config: .init(freeSpaceMargin: 0, maxAttemptsPerArtifact: 2))
        let d = RegionDescriptor(id: "p", title: "p", bounds: BoundingBox(west: -92, south: 17, east: -89, north: 29),
                                 minZoom: 0, maxZoom: 8, tileFormat: .png, source: "t")
        let installed = try await installer.install(d, chart: DownloadSpec(url: url, expectedByteSize: nil, sha256: nil, version: "x", dataDate: Date()))
        // 0 -> interrupted at 3000 -> resume got 206 with a different ETag -> restart from 0.
        #expect(await server.requests.map(\.resumeOffset) == [0, 3000, 0])
        #expect(installed.chart.sha256 == sha2)
        #expect(installed.chart.validators?.etag == "\"two\"")
    }

    @Test func manifestChangedWhilePartialDiscardsOldBytes() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (v1, _) = try Fixtures.mbtilesData(tag: 1)
        let (v2, sha2) = try Fixtures.mbtilesData(tag: 2)
        let r1 = Fixtures.region(data: v1, version: "v1")
        let r2 = Fixtures.region(data: v2, version: "v2")
        let server = FakeServer()
        await server.put(r1.chartPackage.url, data: v1)
        await server.put(r2.chartPackage.url, data: v2, etag: "\"v2\"")
        await server.setFaults([.interruptAfter(2000)])
        let installer = try makeInstaller(dir, server)
        await #expect(throws: InstallFailure.self) { try await installer.install(r1) }
        let installed = try await installer.install(r2)
        #expect(installed.chart.sha256 == sha2)
        #expect(await server.requests.map(\.resumeOffset) == [0, 0])
        #expect(await installer.pendingDownloads().isEmpty)
    }

    @Test func badChecksumIsRejectedAndDiscarded() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, sha) = try Fixtures.mbtilesData()
        let wrong = String(repeating: "0", count: 64)
        let region = Fixtures.region(data: data, sha: wrong)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        let installer = try makeInstaller(dir, server)
        await #expect(throws: InstallFailure.checksumMismatch(expected: wrong, actual: sha)) { try await installer.install(region) }
        #expect(await installer.state(for: region.id) == .failed(.checksumMismatch(expected: wrong, actual: sha)))
        #expect(await installer.installedRegion(id: region.id) == nil)
        #expect(await installer.pendingDownloads().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.file("charts/staging").path).isEmpty)
    }

    @Test func corruptMBTilesIsRejected() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let junk = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let region = Fixtures.region(data: junk) // checksum matches the junk, so only the integrity check catches it
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: junk)
        let installer = try makeInstaller(dir, server)
        do {
            try await installer.install(region)
            Issue.record("corrupt package installed")
        } catch let InstallFailure.corruptPackage(message) {
            #expect(message.contains("not an SQLite database"))
        }
        #expect(await installer.installedRegion(id: region.id) == nil)
        #expect(await installer.pendingDownloads().isEmpty)

        // A valid SQLite file that is not an MBTiles package.
        let other = dir.file("other.sqlite")
        let db = try SQLiteConnection(path: other.path, mode: .readWriteCreate)
        try db.execute("CREATE TABLE waypoints (name text)")
        db.close()
        let sqliteData = try Data(contentsOf: other)
        let region2 = Fixtures.region(data: sqliteData, version: "v2")
        await server.put(region2.chartPackage.url, data: sqliteData)
        await #expect(throws: InstallFailure.corruptPackage(MBTilesError.missingTiles.description)) { try await installer.install(region2) }
    }

    @Test func diskFullPrecheck() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, _) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        let installer = try makeInstaller(dir, server, config: .init(freeSpaceMargin: 1000, maxAttemptsPerArtifact: 1), disk: 100)
        await #expect(throws: InstallFailure.insufficientDiskSpace(required: Int64(data.count) + 1000, available: 100)) {
            try await installer.install(region)
        }
        #expect(await server.requests.isEmpty)
        #expect(await server.heads.isEmpty)
    }

    @Test func diskFullMidDownloadKeepsPartialForResume() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, sha) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        await server.setFaults([.diskFullAfter(6000)])
        let installer = try makeInstaller(dir, server, config: .init(freeSpaceMargin: 0, maxAttemptsPerArtifact: 3))
        do {
            try await installer.install(region)
            Issue.record("expected disk full")
        } catch let InstallFailure.insufficientDiskSpace(required, _) {
            #expect(required == Int64(data.count) - 6000)
        }
        #expect(await installer.pendingDownloads().first?.bytesReceived == 6000)
        let installed = try await installer.install(region)
        #expect(installed.chart.sha256 == sha)
        #expect(await server.requests.map(\.resumeOffset) == [0, 6000])
    }

    @Test func failedUpdateKeepsOldVersionAndGoodUpdateSwaps() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (v1, _) = try Fixtures.mbtilesData(tag: 1)
        let (v2, sha2) = try Fixtures.mbtilesData(tag: 2)
        let r1 = Fixtures.region(data: v1, version: "v1")
        let bad = Fixtures.region(data: v2, sha: String(repeating: "f", count: 64), version: "v2")
        let good = Fixtures.region(data: v2, version: "v2")
        let server = FakeServer()
        await server.put(r1.chartPackage.url, data: v1)
        await server.put(good.chartPackage.url, data: v2, etag: "\"v2\"")
        let installer = try makeInstaller(dir, server)

        let first = try await installer.install(r1)
        let oldFile = installer.fileURL(for: first.chart)
        let oldReader = try MBTilesReader(url: oldFile)

        // Manifest says v2 is out.
        let plan = await installer.apply(ChartManifest(generatedAt: Date(), regions: [good]))
        #expect(plan.updated.count == 1)
        #expect(await installer.state(for: r1.id) == .updateAvailable(installedVersion: "v1", availableVersion: "v2"))

        await #expect(throws: InstallFailure.self) { try await installer.install(bad) }
        #expect(await installer.installedRegion(id: r1.id) == first) // rollback: v1 still installed
        #expect(FileManager.default.fileExists(atPath: oldFile.path))
        #expect(try await oldReader.tile(zoom: 2, x: 1, y: 1) == Fixtures.png(1))

        let second = try await installer.install(good)
        #expect(second.chart.version == "v2" && second.chart.sha256 == sha2)
        #expect(await installer.state(for: r1.id) == .installed(version: "v2"))
        let newFile = installer.fileURL(for: second.chart)
        #expect(newFile != oldFile)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        // An already-open handle on the superseded file keeps working until closed.
        #expect(try await oldReader.tile(zoom: 2, x: 1, y: 1) == Fixtures.png(1))
        #expect(try await MBTilesReader(url: newFile).tile(zoom: 2, x: 1, y: 1) == Fixtures.png(2))

        let plan2 = await installer.apply(ChartManifest(generatedAt: Date(), regions: [good]))
        #expect(plan2.unchanged.count == 1)
    }

    @Test func routingPackInstallsAndUpdatesIndependently() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (chart, _) = try Fixtures.mbtilesData()
        let pack1 = Data("routing pack one".utf8), pack2 = Data("routing pack two!".utf8)
        let r1 = Fixtures.region(data: chart, routing: (pack1, StreamingSHA256.hash(pack1)), routingVersion: "r1")
        let r2 = Fixtures.region(data: chart, routing: (pack2, StreamingSHA256.hash(pack2)), routingVersion: "r2")
        let server = FakeServer()
        await server.put(r1.chartPackage.url, data: chart)
        await server.put(r1.routingPack!.url, data: pack1)
        await server.put(r2.routingPack!.url, data: pack2)
        let seen = StateLog()
        let config = ChartInstaller.Configuration(freeSpaceMargin: 0, maxAttemptsPerArtifact: 1) { url in
            seen.record(url.lastPathComponent, .verifying)
            if (try Data(contentsOf: url)).isEmpty { throw TransportError.other("empty pack") }
        }
        let installer = try makeInstaller(dir, server, config: config)
        let a = try await installer.install(r1)
        #expect(a.routingPack?.version == "r1")
        #expect(try Data(contentsOf: installer.fileURL(for: a.routingPack!)) == pack1)
        #expect(await server.requests.count == 2)
        #expect(seen.states.count == 1)

        let b = try await installer.install(r2)
        #expect(await server.requests.count == 3) // only the routing pack was fetched
        #expect(b.chart == a.chart)
        #expect(b.routingPack?.version == "r2")
        #expect(!FileManager.default.fileExists(atPath: installer.fileURL(for: a.routingPack!).path))
    }

    @Test func headSizeMismatchStopsBeforeDownloading() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, _) = try Fixtures.mbtilesData()
        var region = Fixtures.region(data: data)
        region.chartPackage.byteSize += 1
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        let installer = try makeInstaller(dir, server)
        await #expect(throws: InstallFailure.sizeMismatch(expected: Int64(data.count) + 1, actual: Int64(data.count))) {
            try await installer.install(region)
        }
        #expect(await server.requests.isEmpty)
    }

    @Test func httpErrorsAndInvalidIDs() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, _) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        await server.setFaults([.http(503)])
        let installer = try makeInstaller(dir, server)
        await #expect(throws: InstallFailure.transport("HTTP 503")) { try await installer.install(region) }
        var evil = region
        evil.id = "../../etc"
        await #expect(throws: InstallFailure.invalidRequest("invalid region id ../../etc")) { try await installer.install(evil) }
        let missing = Fixtures.region(id: "nowhere", data: data)
        await #expect(throws: InstallFailure.transport("HTTP 404")) { try await installer.install(missing) }
    }

    @Test func concurrentInstallOfSameRegionIsRefused() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, _) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        await server.setFaults([.delay(milliseconds: 300)])
        let installer = try makeInstaller(dir, server)
        let first = Task { try await installer.install(region) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await #expect(throws: InstallFailure.alreadyInProgress) { try await installer.install(region) }
        await #expect(throws: InstallFailure.alreadyInProgress) { try await installer.remove(regionID: region.id) }
        _ = try await first.value
        #expect(await installer.state(for: region.id) == .installed(version: "v1"))
    }

    @Test func removeDeletesFilesAndState() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, _) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        let installer = try makeInstaller(dir, server)
        let installed = try await installer.install(region)
        try await installer.remove(regionID: region.id)
        #expect(await installer.state(for: region.id) == .notInstalled)
        #expect(await installer.installedRegions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installer.fileURL(for: installed.chart).path))
        #expect(try await makeInstaller(dir, server).installedRegions().isEmpty)
    }

    @Test func crashRecoveryRemovesOrphansAndSurvivesCorruptState() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, _) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data)
        let server = FakeServer()
        await server.put(region.chartPackage.url, data: data)
        let installed = try await makeInstaller(dir, server).install(region)

        // Simulate a crash between rename and commit, and a stray staging file.
        let orphan = dir.file("charts/regions/test_1/chart-v9-deadbeef.mbtiles")
        try data.write(to: orphan)
        let strayDir = dir.file("charts/regions/other")
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        try data.write(to: strayDir.appendingPathComponent("chart-x.mbtiles"))
        try Data([1, 2, 3]).write(to: dir.file("charts/staging/zzz-chart.partial"))

        let relaunched = try makeInstaller(dir, server)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: strayDir.path))
        #expect(!FileManager.default.fileExists(atPath: dir.file("charts/staging/zzz-chart.partial").path))
        #expect(FileManager.default.fileExists(atPath: relaunched.fileURL(for: installed.chart).path))
        #expect(!relaunched.recoveredFromCorruptState)

        // Corrupt state file: set aside, start empty, but do not delete chart files.
        try Data("{not json".utf8).write(to: dir.file("charts/\(ChartInstaller.stateFileName)"))
        let recovered = try makeInstaller(dir, server)
        #expect(recovered.recoveredFromCorruptState)
        #expect(await recovered.installedRegions().isEmpty)
        #expect(FileManager.default.fileExists(atPath: recovered.fileURL(for: installed.chart).path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.file("charts").path).filter { $0.contains(".corrupt-") }
        #expect(aside.count == 1)
    }

    @Test func noaaFallbackCheckRemote() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let (data, _) = try Fixtures.mbtilesData()
        let url = URL(string: "https://distribution.charts.noaa.gov/ncds/mbtiles/ncds_13.mbtiles")!
        let server = FakeServer()
        await server.put(url, data: data, etag: "\"e4a1d69147b1da1:0\"")
        let installer = try makeInstaller(dir, server)
        let validators = try await server.head(url)
        let spec = RemoteFileCheck.downloadSpec(url: url, validators: validators)
        let d = RegionDescriptor(id: "ncds_13", title: "Louisiana coast", bounds: BoundingBox(west: -92.457141, south: 17.6, east: -89.069253, north: 29.333333),
                                 minZoom: 0, maxZoom: 16, tileFormat: .png, source: "NOAA NCDS baseline 2024-05-28")
        let installed = try await installer.install(d, chart: spec)
        #expect(installed.chart.version == "e4a1d69147b1da1:0")
        #expect(installed.chart.relativePath.hasPrefix("regions/ncds_13/chart-e4a1d69147b1da1_0-"))
        #expect(try await installer.checkRemote(regionID: "ncds_13") == .unchanged)

        await server.put(url, data: data + Data([0]), etag: "\"newer\"", lastModified: "Wed, 12 Nov 2026 06:00:00 GMT")
        #expect(try await installer.checkRemote(regionID: "ncds_13") == .changed(reasons: [.etag, .lastModified, .contentLength]))
        #expect(await installer.state(for: "ncds_13") == .updateAvailable(installedVersion: "e4a1d69147b1da1:0", availableVersion: "newer"))
    }
}
