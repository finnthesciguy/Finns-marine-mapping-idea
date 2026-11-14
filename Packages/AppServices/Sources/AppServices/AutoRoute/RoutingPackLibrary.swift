import ChartKit
import Foundation
import NavCore
import RoutingKit

/// The area a routing pack covers: its header bounding box, in degrees.
public struct RoutingPackCoverage: Sendable, Equatable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public init(header: PackHeader) {
        self.init(south: Double(header.minLat) / routingUnitsPerDegree, west: Double(header.minLon) / routingUnitsPerDegree,
                  north: Double(header.maxLat) / routingUnitsPerDegree, east: Double(header.maxLon) / routingUnitsPerDegree)
    }

    /// Inclusive, like the pack's own bounding-box test.
    public func contains(_ c: Coordinate) -> Bool {
        guard c.isValid else { return false }
        return c.latitude >= south && c.latitude <= north && c.longitude >= west && c.longitude <= east
    }
}

/// One routing pack on this device (not loaded; see ``RoutingPackLibrary/open(_:)``).
public struct RoutingPackEntry: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable, Equatable {
        /// Installed by ChartKit together with a chart region (`InstalledRegion.routingPack`).
        case chartRegion
        /// Copied in by hand: the debug fixture or a file picked in a debug build.
        case sideLoaded
    }

    /// `region:<chart region id>` or `file:<file name>`.
    public var id: String
    public var origin: Origin
    /// The chart region it was installed with (nil for side-loaded packs).
    public var chartRegionID: String?
    /// Name shown to the user (the chart region's title, or the pack's region id).
    public var title: String
    /// `region_id` from the pack header, e.g. `pilot-sarasota`.
    public var packRegionID: String
    public var fileURL: URL
    public var byteSize: Int64
    /// Chart data date of the pack (nil when unknown).
    public var dataDate: Date?
    /// Pack data date as `yyyymmdd` (0 when unknown); also part of ``version``.
    public var dataDateRaw: UInt32
    /// Version string stored with saved routes: the artifact version, or `<region>-<yyyymmdd>`.
    public var version: String
    public var formatVersion: String
    public var coverage: RoutingPackCoverage

    public init(id: String, origin: Origin, chartRegionID: String?, title: String, packRegionID: String, fileURL: URL,
                byteSize: Int64, dataDate: Date?, dataDateRaw: UInt32, version: String, formatVersion: String,
                coverage: RoutingPackCoverage) {
        self.id = id
        self.origin = origin
        self.chartRegionID = chartRegionID
        self.title = title
        self.packRegionID = packRegionID
        self.fileURL = fileURL
        self.byteSize = byteSize
        self.dataDate = dataDate
        self.dataDateRaw = dataDateRaw
        self.version = version
        self.formatVersion = formatVersion
        self.coverage = coverage
    }

    /// "Sarasota pilot · chart data 23 Oct 2026 · 216 KB".
    public var descriptionLine: String {
        let date: String = dataDate.map(DataDateFormat.string) ?? "unknown date"
        return "\(title) · chart data \(date) · \(ByteFormat.string(byteSize))"
    }
}

/// A routing pack file that could not be listed (its header is unreadable).
public struct RoutingPackProblem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var fileURL: URL
    public var message: String
}

/// Everything installed, as listed by ``RoutingPackLibrary/catalog()``.
public struct RoutingPackCatalog: Sendable, Equatable {
    public var entries: [RoutingPackEntry]
    public var problems: [RoutingPackProblem]

    public init(entries: [RoutingPackEntry], problems: [RoutingPackProblem]) {
        self.entries = entries
        self.problems = problems
    }

    /// The pack installed with a chart region, if any.
    public func entry(forChartRegion id: String) -> RoutingPackEntry? {
        entries.first { $0.chartRegionID == id }
    }
}

/// Which pack a plan between two points would use.
public enum RoutingPackSelection: Sendable, Equatable {
    case pack(RoutingPackEntry)
    /// No routing pack is installed at all.
    case noPacksInstalled
    /// No installed pack covers the start and/or the destination.
    case notCovered(start: Bool, goal: Bool)
    /// Start and destination are each covered, but by different packs (routing across packs is not supported).
    case differentPacks(start: RoutingPackEntry, goal: RoutingPackEntry)

    /// Picks the pack covering both points: newest chart data first, then a chart-region pack before a
    /// side-loaded one, then by id (stable).
    public static func choose(from entries: [RoutingPackEntry], start: Coordinate, goal: Coordinate) -> RoutingPackSelection {
        if entries.isEmpty { return .noPacksInstalled }
        let ordered: [RoutingPackEntry] = entries.sorted(by: RoutingPackSelection.preferred)
        if let both = ordered.first(where: { $0.coverage.contains(start) && $0.coverage.contains(goal) }) {
            return .pack(both)
        }
        let startPack: RoutingPackEntry? = ordered.first { $0.coverage.contains(start) }
        let goalPack: RoutingPackEntry? = ordered.first { $0.coverage.contains(goal) }
        if let startPack, let goalPack { return .differentPacks(start: startPack, goal: goalPack) }
        return .notCovered(start: startPack == nil, goal: goalPack == nil)
    }

    static func preferred(_ a: RoutingPackEntry, _ b: RoutingPackEntry) -> Bool {
        if a.dataDateRaw != b.dataDateRaw { return a.dataDateRaw > b.dataDateRaw }
        if a.origin != b.origin { return a.origin == .chartRegion }
        return a.id < b.id
    }
}

/// Lists the routing packs on the device and opens them, **one at a time**: a region pack can take about
/// 80 MB once loaded, so opening a pack first releases the one held before, and validating a pack (at
/// install time) releases it too.
///
/// Packs come from two places: those ChartKit installed with a chart region (`InstalledRegion.routingPack`,
/// attach the installer with ``attach(installer:)``), and `*.pack` files in ``sideLoadDirectory`` (the debug
/// fixture and files picked in a debug build).
///
/// `open`, `validate` and `sideLoad` block while a pack is decoded (0.3–1.5 s for a region): call them off
/// the main thread. The planner does.
public final class RoutingPackLibrary: @unchecked Sendable {
    public static let sideLoadedExtension = "pack"

    public let sideLoadDirectory: URL
    /// Guards `installer` and `loaded`. Never held while a pack is decoded.
    private let stateLock = NSLock()
    /// Serialises decoding (open / validate), so two packs are never decoded at once.
    private let loadLock = NSLock()
    private var installer: ChartInstaller?
    private var loaded: (id: String, pack: RoutingPack)?

    public init(sideLoadDirectory: URL, installer: ChartInstaller? = nil) {
        self.sideLoadDirectory = sideLoadDirectory.standardizedFileURL
        self.installer = installer
    }

    /// Lets the library list packs installed by `installer`. (The installer is created after the library,
    /// because the library provides its routing-pack validator.)
    public func attach(installer: ChartInstaller) {
        stateLock.lock()
        self.installer = installer
        stateLock.unlock()
    }

    private func attachedInstaller() -> ChartInstaller? {
        stateLock.withLock { installer }
    }

    /// The id of the pack held in memory, if any.
    public var loadedPackID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return loaded?.id
    }

    /// Drops the pack held in memory (it is freed once no route computation uses it any more).
    public func release() {
        stateLock.lock()
        loaded = nil
        stateLock.unlock()
    }

    // MARK: Listing

    /// All installed packs, by reading each file's header only (cheap).
    public func catalog() async -> RoutingPackCatalog {
        var entries: [RoutingPackEntry] = []
        var problems: [RoutingPackProblem] = []
        let currentInstaller: ChartInstaller? = attachedInstaller()
        if let currentInstaller {
            let regions: [InstalledRegion] = await currentInstaller.installedRegions()
            for region in regions {
                guard let artifact = region.routingPack else { continue }
                let url: URL = currentInstaller.fileURL(for: artifact)
                let id: String = "region:\(region.id)"
                do {
                    let header: PackHeader = try RoutingPack.header(contentsOf: url)
                    entries.append(RoutingPackEntry(
                        id: id, origin: .chartRegion, chartRegionID: region.id, title: region.title,
                        packRegionID: header.regionID, fileURL: url, byteSize: artifact.byteSize,
                        dataDate: header.dataDate.date ?? artifact.dataDate, dataDateRaw: header.dataDate.rawValue,
                        version: artifact.version, formatVersion: "\(header.formatMajor).\(header.formatMinor)",
                        coverage: RoutingPackCoverage(header: header)))
                } catch {
                    problems.append(RoutingPackProblem(id: id, title: region.title, fileURL: url,
                                                       message: RoutingPackLibrary.describe(error)))
                }
            }
        }
        for url in sideLoadedFiles() {
            let id: String = "file:\(url.lastPathComponent)"
            do {
                let header: PackHeader = try RoutingPack.header(contentsOf: url)
                entries.append(RoutingPackLibrary.sideLoadedEntry(url: url, header: header, id: id))
            } catch {
                problems.append(RoutingPackProblem(id: id, title: url.lastPathComponent, fileURL: url,
                                                   message: RoutingPackLibrary.describe(error)))
            }
        }
        return RoutingPackCatalog(entries: entries, problems: problems)
    }

    /// Chooses the pack for a plan from the installed packs.
    public func select(start: Coordinate, goal: Coordinate) async -> RoutingPackSelection {
        let current: RoutingPackCatalog = await catalog()
        return RoutingPackSelection.choose(from: current.entries, start: start, goal: goal)
    }

    static func sideLoadedEntry(url: URL, header: PackHeader, id: String) -> RoutingPackEntry {
        let size: Int64 = RoutingPackLibrary.fileSize(url)
        return RoutingPackEntry(
            id: id, origin: .sideLoaded, chartRegionID: nil, title: RoutingPackLibrary.title(forPackRegion: header.regionID),
            packRegionID: header.regionID, fileURL: url, byteSize: size, dataDate: header.dataDate.date,
            dataDateRaw: header.dataDate.rawValue, version: "\(header.regionID)-\(header.dataDate.rawValue)",
            formatVersion: "\(header.formatMajor).\(header.formatMinor)", coverage: RoutingPackCoverage(header: header))
    }

    /// `pilot-sarasota` → "pilot-sarasota (side-loaded)".
    static func title(forPackRegion regionID: String) -> String {
        let name: String = regionID.isEmpty ? "Routing pack" : regionID
        return "\(name) (side-loaded)"
    }

    func sideLoadedFiles() -> [URL] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: sideLoadDirectory.path)) ?? []
        return names.filter { $0.hasSuffix("." + RoutingPackLibrary.sideLoadedExtension) && !$0.hasPrefix(".") }
            .sorted()
            .map { sideLoadDirectory.appendingPathComponent($0, isDirectory: false) }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let number = attributes?[.size] as? NSNumber { return number.int64Value }
        if let value = attributes?[.size] as? Int64 { return value }
        if let value = attributes?[.size] as? Int { return Int64(value) }
        return 0
    }

    // MARK: Opening

    /// The pack for `entry`, decoded and fully validated. Reuses the pack in memory when it is the same entry;
    /// otherwise releases it first. Blocking: call off the main thread.
    public func open(_ entry: RoutingPackEntry) throws(PackError) -> RoutingPack {
        loadLock.lock()
        defer { loadLock.unlock() }
        stateLock.lock()
        if let current = loaded, current.id == entry.id {
            stateLock.unlock()
            return current.pack
        }
        loaded = nil
        stateLock.unlock()
        let pack: RoutingPack = try RoutingPack(contentsOf: entry.fileURL)
        stateLock.lock()
        loaded = (entry.id, pack)
        stateLock.unlock()
        return pack
    }

    /// Fully decodes and validates a pack file (every check of spec A.4), after releasing the pack in memory,
    /// then frees it again. Throws ``RoutingPackRejection``. Blocking.
    public func validate(fileAt url: URL) throws {
        loadLock.lock()
        defer { loadLock.unlock() }
        release()
        _ = try RoutingPackLibrary.validatePack(at: url)
    }

    /// The `ChartInstaller.Configuration.routingPackValidator` hook: rejects a corrupt pack at install time.
    public var installValidator: @Sendable (URL) throws -> Void {
        { [self] (url: URL) throws -> Void in try self.validate(fileAt: url) }
    }

    /// Decodes a pack file and checks it is usable; returns its header.
    static func validatePack(at url: URL) throws -> PackHeader {
        do {
            let pack: RoutingPack = try RoutingPack(contentsOf: url)
            return pack.header
        } catch {
            throw RoutingPackRejection(reason: RoutingPackLibrary.describe(error))
        }
    }

    // MARK: Side-loading (debug builds)

    /// Validates `source` and copies it into ``sideLoadDirectory`` as `<region id>.pack`, replacing a pack with
    /// the same region id. Returns the new entry. Blocking.
    @discardableResult
    public func sideLoad(from source: URL) throws -> RoutingPackEntry {
        loadLock.lock()
        defer { loadLock.unlock() }
        release()
        let header: PackHeader = try RoutingPackLibrary.validatePack(at: source)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sideLoadDirectory, withIntermediateDirectories: true)
        let name: String = RoutingPackLibrary.safeFileName(header.regionID) + "." + RoutingPackLibrary.sideLoadedExtension
        let destination: URL = sideLoadDirectory.appendingPathComponent(name, isDirectory: false)
        let staging: URL = sideLoadDirectory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: false)
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: staging, to: destination)
        return RoutingPackLibrary.sideLoadedEntry(url: destination, header: header, id: "file:\(name)")
    }

    /// Deletes a side-loaded pack file. Chart-region packs are removed with their region (ChartKit).
    public func removeSideLoaded(_ entry: RoutingPackEntry) throws {
        guard entry.origin == .sideLoaded else { return }
        if loadedPackID == entry.id { release() }
        try FileManager.default.removeItem(at: entry.fileURL)
    }

    static func safeFileName(_ name: String) -> String {
        var out: String = ""
        for scalar in name.unicodeScalars {
            let ok: Bool = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_" || scalar == "."
            out.unicodeScalars.append(ok ? scalar : "_")
        }
        while out.hasPrefix(".") { out.removeFirst() }
        if out.isEmpty { return "routing" }
        return String(out.prefix(64))
    }

    static func describe(_ error: any Error) -> String {
        if let rejection = error as? RoutingPackRejection { return rejection.reason }
        if let pack = error as? PackError { return pack.description }
        return String(describing: error)
    }
}

/// Why a routing pack file was refused (corrupt, truncated, wrong format version, ...).
public struct RoutingPackRejection: Error, Sendable, Equatable, CustomStringConvertible {
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public var description: String { reason }
}
