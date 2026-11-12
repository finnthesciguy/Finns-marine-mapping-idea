import Foundation
import Testing
@testable import ChartKit

let sampleManifestURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Samples/gulf-manifest.sample.json")

@Suite struct ManifestTests {
    @Test func decodesTheSampleGulfManifest() throws {
        let m = try ChartManifest.decode(from: Data(contentsOf: sampleManifestURL))
        #expect(m.schemaVersion == 1)
        #expect(m.generatedAt == ChartDates.parse("2026-11-12T06:00:00Z"))
        #expect(m.regions.map(\.id) == ["ncds_10", "ncds_11", "ncds_12", "ncds_13", "ncds_14"])
        let r13 = try #require(m.region(id: "ncds_13"))
        #expect(r13.bounds == BoundingBox(west: -92.457141, south: 17.6, east: -89.069253, north: 29.333333))
        #expect(r13.minZoom == 0 && r13.maxZoom == 16)
        #expect(r13.tileFormat == .png)
        #expect(r13.chartPackage.url.absoluteString == "https://distribution.charts.noaa.gov/ncds/mbtiles/ncds_13.mbtiles")
        #expect(r13.chartPackage.byteSize == 380_833_792)
        #expect(r13.chartPackage.sha256 == "6d9b0701e3acd6a8e38855d3388138c0407e4778b4da460b6777705423b80439")
        #expect(r13.chartPackage.dataDate == ChartDates.day(2024, 5, 28))
        #expect(r13.source == "NOAA NCDS baseline 2024-05-28")
        #expect(r13.routingPack == nil)
        let total = m.regions.reduce(Int64(0)) { $0 + $1.chartPackage.byteSize }
        #expect(total == 2_666_901_504)
    }

    @Test func roundTripsWithRoutingPack() throws {
        let (data, _) = try Fixtures.mbtilesData()
        let region = Fixtures.region(data: data, routing: (Data("pack".utf8), StreamingSHA256.hash(Data("pack".utf8))))
        let m = ChartManifest(generatedAt: ChartDates.parse("2026-11-12T06:30:15Z")!, publisher: "t", regions: [region])
        let json = try m.encoded()
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"package\""))
        #expect(text.contains("\"dataDate\" : \"2026-11-01\""))
        #expect(text.contains("\"generatedAt\" : \"2026-11-12T06:30:15Z\""))
        let back = try ChartManifest.decode(from: json)
        #expect(back == m)
        #expect(back.regions[0].routingPack?.formatVersion == 1)
    }

    @Test func ignoresUnknownKeysAndRejectsNewerSchema() throws {
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sampleManifestURL)) as! [String: Any]
        obj["futureField"] = ["x": 1]
        _ = try ChartManifest.decode(from: JSONSerialization.data(withJSONObject: obj))
        obj["schemaVersion"] = 2
        #expect(throws: ManifestError.unsupportedSchemaVersion(2)) {
            _ = try ChartManifest.decode(from: JSONSerialization.data(withJSONObject: obj))
        }
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: ManifestError.self) { _ = try ChartManifest.decode(from: Data("{".utf8)) }
        #expect(throws: ManifestError.self) { _ = try ChartManifest.decode(from: Data("{\"schemaVersion\":1}".utf8)) }
    }

    @Test func validation() throws {
        let (data, _) = try Fixtures.mbtilesData()
        func check(_ mutate: (inout ChartRegion) -> Void) -> Bool {
            var r = Fixtures.region(data: data)
            mutate(&r)
            return (try? ChartManifest(generatedAt: Date(), regions: [r]).validate()) != nil
        }
        #expect(check { _ in })
        #expect(!check { $0.id = "../etc" })
        #expect(!check { $0.id = "" })
        #expect(!check { $0.id = "a b" })
        #expect(!check { $0.bounds = BoundingBox(west: 10, south: 0, east: 5, north: 1) })
        #expect(!check { $0.minZoom = 9 })
        #expect(!check { $0.chartPackage.sha256 = "abc" })
        #expect(!check { $0.chartPackage.byteSize = 0 })
        #expect(!check { $0.chartPackage.url = URL(string: "file:///etc/passwd")! })
        #expect(!check { $0.chartPackage.version = "" })
        let r = Fixtures.region(data: data)
        #expect(throws: ManifestError.invalidRegion("test_1", "duplicate id")) {
            try ChartManifest(generatedAt: Date(), regions: [r, r]).validate()
        }
    }

    @Test func dates() {
        #expect(ChartDates.parse("2024-05-28") == Date(timeIntervalSince1970: 1_716_854_400))
        #expect(ChartDates.parse("2024-02-31") == nil)
        #expect(ChartDates.parse("2026-11-12T06:00:00Z") == Date(timeIntervalSince1970: 1_794_463_200))
        #expect(ChartDates.parse("2026-11-12T06:00:00.500Z")?.timeIntervalSince1970 == 1_794_463_200.5)
        #expect(ChartDates.parse("2026-11-12T01:00:00-05:00") == Date(timeIntervalSince1970: 1_794_463_200))
        #expect(ChartDates.parse("yesterday") == nil)
        #expect(ChartDates.format(ChartDates.day(2024, 5, 28)) == "2024-05-28")
        #expect(ChartDates.format(Date(timeIntervalSince1970: 1_794_463_200)) == "2026-11-12T06:00:00Z")
    }
}

@Suite struct UpdatePlannerTests {
    func installed(_ id: String, version: String, sha: String, routing: (String, String)? = nil, date: Date = ChartDates.day(2026, 1, 1)) -> InstalledRegion {
        func art(_ v: String, _ s: String) -> InstalledArtifact {
            InstalledArtifact(version: v, sha256: s, byteSize: 10, dataDate: date, sourceURL: URL(string: "https://x/\(id)")!,
                              relativePath: "regions/\(id)/f", installedAt: date, validators: nil)
        }
        return InstalledRegion(id: id, title: id, bounds: BoundingBox(west: -90, south: 28, east: -89, north: 29),
                               minZoom: 0, maxZoom: 8, tileFormat: .png, source: "t",
                               chart: art(version, sha), routingPack: routing.map { art($0.0, $0.1) })
    }

    func offered(_ id: String, version: String, sha: String, routing: (String, String)? = nil) -> ChartRegion {
        let date = ChartDates.day(2026, 11, 1)
        return ChartRegion(id: id, title: id, bounds: BoundingBox(west: -90, south: 28, east: -89, north: 29), minZoom: 0, maxZoom: 8,
                           tileFormat: .png,
                           chartPackage: PackageArtifact(url: URL(string: "https://x/\(id)")!, byteSize: 100, sha256: sha, version: version, dataDate: date),
                           source: "t",
                           routingPack: routing.map { RoutingPackArtifact(url: URL(string: "https://x/\(id).rp")!, byteSize: 7, sha256: $0.1, version: $0.0, dataDate: date) })
    }

    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64)

    @Test func classifiesRegions() {
        let have = [
            installed("same", version: "1", sha: a),
            installed("newer", version: "1", sha: a),
            installed("rehashed", version: "1", sha: a),
            installed("gone", version: "1", sha: a),
            installed("rp_added", version: "1", sha: a),
            installed("rp_changed", version: "1", sha: a, routing: ("r1", b)),
            installed("rp_withdrawn", version: "1", sha: a, routing: ("r1", b)),
        ]
        let manifest = ChartManifest(generatedAt: Date(), regions: [
            offered("same", version: "1", sha: a.uppercased()),
            offered("newer", version: "2", sha: b),
            offered("rehashed", version: "1", sha: b),
            offered("brand_new", version: "1", sha: a),
            offered("rp_added", version: "1", sha: a, routing: ("r1", c)),
            offered("rp_changed", version: "1", sha: a, routing: ("r2", c)),
            offered("rp_withdrawn", version: "1", sha: a),
        ])
        let plan = UpdatePlanner.plan(installed: have, manifest: manifest)
        #expect(plan.new.map(\.id) == ["brand_new"])
        #expect(plan.updated.map(\.installed.id) == ["newer", "rehashed", "rp_added", "rp_changed"])
        #expect(plan.unchanged.map(\.id) == ["rp_withdrawn", "same"])
        #expect(plan.removed.map(\.id) == ["gone"])
        #expect(plan.routingPackWithdrawn == ["rp_withdrawn"])
        let byID = Dictionary(uniqueKeysWithValues: plan.updated.map { ($0.installed.id, $0) })
        #expect(byID["newer"]?.chart == .changed && byID["newer"]?.routingPack == ArtifactChange.none)
        #expect(byID["rp_added"]?.chart == ArtifactChange.none && byID["rp_added"]?.routingPack == .added)
        #expect(byID["rp_added"]?.downloadBytes == 7)
        #expect(byID["rp_changed"]?.routingPack == .changed)
        #expect(byID["newer"]?.downloadBytes == 100)
        #expect(plan.totalUpdateBytes == 100 + 100 + 7 + 7)
        #expect(plan.hasUpdates)
    }

    @Test func emptyCases() {
        let empty = UpdatePlanner.plan(installed: [], manifest: ChartManifest(generatedAt: Date(), regions: []))
        #expect(empty == UpdatePlan(new: [], updated: [], unchanged: [], removed: [], routingPackWithdrawn: []))
        #expect(!empty.hasUpdates)
    }

    @Test func staleness() {
        let data = ChartDates.day(2024, 5, 28)
        let now = ChartDates.parse("2026-11-12T12:00:00Z")!
        let age = ChartAge.evaluate(dataDate: data, now: now)
        #expect(age.days == 898)
        #expect(age.level == .critical)
        #expect(ChartAge.evaluate(dataDate: now.addingTimeInterval(-10 * 86_400), now: now).level == .current)
        #expect(ChartAge.evaluate(dataDate: now.addingTimeInterval(-90 * 86_400), now: now).level == .current)
        #expect(ChartAge.evaluate(dataDate: now.addingTimeInterval(-91 * 86_400), now: now).level == .warning)
        #expect(ChartAge.evaluate(dataDate: now.addingTimeInterval(-366 * 86_400), now: now).level == .critical)
        #expect(ChartAge.evaluate(dataDate: now.addingTimeInterval(86_400), now: now) == ChartAge(days: 0, level: .current))
        let strict = StalenessPolicy(warningAfterDays: 7, criticalAfterDays: 30)
        #expect(ChartAge.evaluate(dataDate: now.addingTimeInterval(-8 * 86_400), now: now, policy: strict).level == .warning)
        #expect(installed("x", version: "1", sha: a, date: data).age(now: now).level == .critical)
        #expect(StalenessLevel.warning > .current)
    }
}

@Suite struct RemoteValidatorTests {
    @Test func parsesHeaders() {
        let v = RemoteValidators(headers: ["ETag": "\"e4a1d69147b1da1:0\"", "Last-Modified": "Tue, 28 May 2024 21:39:50 GMT",
                                           "content-length": "380833792", "Accept-Ranges": "bytes"])
        #expect(v.etag == "\"e4a1d69147b1da1:0\"")
        #expect(v.contentLength == 380_833_792)
        #expect(v.acceptsByteRanges == true)
        #expect(v.lastModifiedDate == Date(timeIntervalSince1970: 1_716_932_390))
        #expect(v.hasStrongETag)
        #expect(v.ifRangeValue == "\"e4a1d69147b1da1:0\"")
        let weak = RemoteValidators(etag: "W/\"x\"", lastModified: "Tue, 28 May 2024 21:39:50 GMT")
        #expect(!weak.hasStrongETag)
        #expect(weak.ifRangeValue == "Tue, 28 May 2024 21:39:50 GMT")
        #expect(RemoteValidators().ifRangeValue == nil)
    }

    @Test func httpDates() {
        let expected = Date(timeIntervalSince1970: 1_716_932_390)
        #expect(HTTPDate.parse("Tue, 28 May 2024 21:39:50 GMT") == expected)
        #expect(HTTPDate.parse("Tuesday, 28-May-24 21:39:50 GMT") == expected)
        #expect(HTTPDate.parse("Tue May 28 21:39:50 2024") == expected)
        #expect(HTTPDate.parse("garbage") == nil)
        #expect(HTTPDate.format(expected) == "Tue, 28 May 2024 21:39:50 GMT")
    }

    @Test func comparison() {
        let base = RemoteValidators(etag: "\"a\"", lastModified: "Tue, 28 May 2024 21:39:50 GMT", contentLength: 100)
        #expect(RemoteFileCheck.compare(installed: base, current: base) == .unchanged)
        var newTag = base
        newTag.etag = "\"b\""
        #expect(RemoteFileCheck.compare(installed: base, current: newTag) == .changed(reasons: [.etag]))
        var weakSame = base
        weakSame.etag = "W/\"a\""
        #expect(RemoteFileCheck.compare(installed: base, current: weakSame) == .unchanged)
        var newer = base
        newer.lastModified = "Wed, 12 Nov 2026 06:00:00 GMT"
        newer.contentLength = 120
        #expect(RemoteFileCheck.compare(installed: base, current: newer) == .changed(reasons: [.lastModified, .contentLength]))
        let lengthOnly = RemoteValidators(contentLength: 100)
        #expect(RemoteFileCheck.compare(installed: lengthOnly, current: RemoteValidators(contentLength: 101)) == .changed(reasons: [.contentLength]))
        #expect(RemoteFileCheck.compare(installed: RemoteValidators(), current: base) == .unknown)
        #expect(base.sameRepresentation(as: newTag) == false)
        #expect(base.sameRepresentation(as: base) == true)
        #expect(RemoteValidators().sameRepresentation(as: base) == nil)
    }

    @Test func noaaFallbackSpec() {
        let v = RemoteValidators(etag: "\"e4a1d69147b1da1:0\"", lastModified: "Tue, 28 May 2024 21:39:50 GMT", contentLength: 380_833_792)
        let spec = RemoteFileCheck.downloadSpec(url: URL(string: "https://distribution.charts.noaa.gov/ncds/mbtiles/ncds_13.mbtiles")!, validators: v)
        #expect(spec.sha256 == nil)
        #expect(spec.expectedByteSize == 380_833_792)
        #expect(spec.version == "e4a1d69147b1da1:0")
        #expect(spec.dataDate == Date(timeIntervalSince1970: 1_716_932_390))
    }
}

@Suite struct StateMachineTests {
    typealias M = InstallStateMachine
    let p0 = DownloadProgress(bytesReceived: 0, totalBytes: 100)
    let p50 = DownloadProgress(bytesReceived: 50, totalBytes: 100)

    @Test func happyPath() {
        var s = InstallState.notInstalled
        for e: InstallEvent in [.enqueue, .startDownload(p0), .progress(p50), .beginVerification, .beginInstall, .finish(version: "v1")] {
            s = M.transition(from: s, on: e)!
        }
        #expect(s == .installed(version: "v1"))
    }

    @Test func illegalTransitionsAreRejected() {
        #expect(M.transition(from: .notInstalled, on: .beginInstall) == nil)
        #expect(M.transition(from: .notInstalled, on: .finish(version: "x")) == nil)
        #expect(M.transition(from: .installed(version: "1"), on: .progress(p0)) == nil)
        #expect(M.transition(from: .verifying, on: .enqueue) == nil)
        #expect(M.transition(from: .downloading(p0), on: .settle(installedVersion: nil)) == nil)
        #expect(M.transition(from: .notInstalled, on: .fail(.cancelled)) == nil)
        #expect(M.transition(from: .notInstalled, on: .updateFound(installedVersion: "1", availableVersion: "2")) == nil)
    }

    @Test func failuresAndUpdates() {
        #expect(M.transition(from: .downloading(p50), on: .fail(.interrupted(bytesReceived: 50))) == .failed(.interrupted(bytesReceived: 50)))
        #expect(M.transition(from: .failed(.cancelled), on: .enqueue) == .queued)
        #expect(M.transition(from: .installed(version: "1"), on: .updateFound(installedVersion: "1", availableVersion: "2"))
                == .updateAvailable(installedVersion: "1", availableVersion: "2"))
        #expect(M.transition(from: .updateAvailable(installedVersion: "1", availableVersion: "2"), on: .enqueue) == .queued)
        #expect(M.transition(from: .updateAvailable(installedVersion: "1", availableVersion: "2"), on: .settle(installedVersion: "1")) == .installed(version: "1"))
        #expect(M.transition(from: .installed(version: "1"), on: .settle(installedVersion: nil)) == .notInstalled)
    }

    @Test func progressIsMonotonicButRestartable() {
        #expect(M.transition(from: .downloading(p50), on: .progress(p0)) == .downloading(p50))
        #expect(M.transition(from: .downloading(p50), on: .startDownload(p0)) == .downloading(p0))
        #expect(p50.fractionCompleted == 0.5)
        #expect(DownloadProgress(bytesReceived: 5, totalBytes: nil).fractionCompleted == nil)
    }

    @Test func busyFlagAndResumability() {
        #expect(InstallState.queued.isBusy && InstallState.verifying.isBusy && InstallState.installing.isBusy)
        #expect(!InstallState.notInstalled.isBusy && !InstallState.failed(.cancelled).isBusy)
        #expect(InstallFailure.interrupted(bytesReceived: 1).isResumable)
        #expect(!InstallFailure.checksumMismatch(expected: "a", actual: "b").isResumable)
    }
}

@Suite struct MapLibreTests {
    func region(_ id: String, bounds: BoundingBox, maxZoom: Int = 16, date: Date = ChartDates.day(2024, 5, 28)) -> InstalledRegion {
        let art = InstalledArtifact(version: "1", sha256: "", byteSize: 1, dataDate: date, sourceURL: URL(string: "https://x")!,
                                    relativePath: "regions/\(id)/chart.mbtiles", installedAt: date, validators: nil)
        return InstalledRegion(id: id, title: id, bounds: bounds, minZoom: 0, maxZoom: maxZoom, tileFormat: .png, source: "", chart: art)
    }

    @Test func sourceURL() {
        let url = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Library/Charts/regions/ncds_13/chart-1.mbtiles")
        #expect(MapLibreSources.sourceURL(forFileAt: url)
                == "mbtiles:///var/mobile/Containers/Data/Application/ABC/Library/Charts/regions/ncds_13/chart-1.mbtiles")
        let spaced = URL(fileURLWithPath: "/a/Application Support/x.mbtiles")
        #expect(MapLibreSources.sourceURL(forFileAt: spaced) == "mbtiles:///a/Application Support/x.mbtiles")
        #expect(MapLibreSources.sourceURL(forFileAt: spaced, percentEncoded: true) == "mbtiles:///a/Application%20Support/x.mbtiles")
    }

    @Test func layerOrderingPutsDetailOnTop() {
        let coastal = region("coastal", bounds: BoundingBox(west: -98, south: 17, east: -80, north: 34), maxZoom: 12)
        let big = region("ncds_14", bounds: BoundingBox(west: -98.29, south: 17.6, east: -92.46, north: 33.93))
        let small = region("ncds_13", bounds: BoundingBox(west: -92.46, south: 17.6, east: -89.07, north: 29.33))
        let harbourOld = region("harbour_a", bounds: BoundingBox(west: -90, south: 29, east: -89.5, north: 29.3), date: ChartDates.day(2024, 1, 1))
        let harbourNew = region("harbour_b", bounds: BoundingBox(west: -90, south: 29, east: -89.5, north: 29.3), date: ChartDates.day(2026, 1, 1))
        let root = URL(fileURLWithPath: "/charts")
        let plan = MapLibreSources.layerPlan(for: [harbourNew, small, coastal, harbourOld, big]) {
            root.appendingPathComponent($0.chart.relativePath)
        }
        #expect(plan.map(\.regionID) == ["coastal", "ncds_14", "ncds_13", "harbour_a", "harbour_b"])
        #expect(plan[0].layerMaxZoom == 22 && plan[0].sourceMaxZoom == 12)
        #expect(plan[2].sourceURL == "mbtiles:///charts/regions/ncds_13/chart.mbtiles")
        #expect(plan[2].sourceID == "chart-src-ncds_13" && plan[2].layerID == "chart-layer-ncds_13")
        #expect(plan[2].drawnAbove == ["coastal"]) // touches ncds_14 only along an edge
        #expect(plan[4].drawnAbove == ["coastal", "ncds_13", "harbour_a"])
        #expect(plan[1].bounds.array == [-98.29, 17.6, -92.46, 33.93])
    }
}
