import ChartKit
import Foundation
import RoutingKit

/// Routing packs shipped inside the app (`RoutingPacks/` in the app bundle: `ncds_10.pack` … `ncds_14.pack` and a
/// `manifest.json`), made available to `RoutingPackLibrary` without a download.
///
/// The library lists `*.pack` files in its side-load folder, so each bundled pack is linked there as
/// `bundled-<name>.pack` (a symbolic link to the file in the bundle: no 60–90 MB copy). Links are made on the
/// first launch and again whenever the bundled set changes (fingerprint of `manifest.json`, or of the pack names
/// and sizes when there is no manifest), each pack checked by `validate` first. The default check is cheap
/// (`quickCheck`: size and SHA-256 from the manifest, then the 256-byte header); the full decode happens when a
/// route is planned (`RoutingPackLibrary.open`, which validates the whole pack). Callers run `install` off the
/// main thread: the app starts it in the background after the first screen is up. Because the bundle can move
/// when the app is updated, links whose target is gone are repaired on every launch. A bundled pack the user
/// removed stays removed until the bundled set changes. A missing or empty `RoutingPacks/` folder is not an
/// error (nothing to install).
///
/// State is kept in `<side-load folder>/.bundled-routing.json` (a dot file, which the library ignores).
public enum BundledRoutingPacks {
    public static let directoryName: String = "RoutingPacks"
    public static let manifestName: String = "manifest.json"
    public static let linkPrefix: String = "bundled-"
    static let stateName: String = ".bundled-routing.json"

    struct State: Codable, Equatable {
        var fingerprint: String
        /// Link names made for that fingerprint.
        var links: [String]
    }

    public struct Outcome: Sendable, Equatable {
        /// Links created or repaired this time.
        public var linked: [String] = []
        /// Packs that failed the check (`<file>: <reason>`), for a notice.
        public var problems: [String] = []
        /// False when nothing had to be done.
        public var changed: Bool = false

        public init() {}
    }

    /// The `RoutingPacks` folder in `bundle`, if the app ships one.
    public static func directory(in bundle: Bundle) -> URL? {
        bundle.url(forResource: directoryName, withExtension: nil)
    }

    /// Bundled pack files, sorted by name.
    public static func packFiles(in directory: URL) -> [URL] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix("." + RoutingPackLibrary.sideLoadedExtension) && !$0.hasPrefix(".") }
            .sorted()
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// Identifies the bundled set: the manifest's bytes, or the pack names and sizes when there is none.
    public static func fingerprint(of directory: URL) -> String {
        if let manifest = try? Data(contentsOf: directory.appendingPathComponent(manifestName, isDirectory: false)) {
            return "manifest:" + StreamingSHA256.hash(manifest)
        }
        var text: String = ""
        for url in packFiles(in: directory) {
            text += url.lastPathComponent + "=" + String(RoutingPackLibrary.fileSize(url)) + ";"
        }
        return "files:" + StreamingSHA256.hash(Data(text.utf8))
    }

    /// Links the bundled packs into `library`'s side-load folder when needed (see the type comment).
    /// `validate` checks a pack (default: `quickCheck` against the bundled manifest). Blocking: call off the main
    /// thread.
    public static func install(from directory: URL?, library: RoutingPackLibrary,
                               validate: ((URL) throws -> Void)? = nil) -> Outcome {
        let expected: [String: ExpectedPack] = directory.map { manifestPacks(in: $0) } ?? [:]
        let check: (URL) throws -> Void = validate ?? { url in try quickCheck(url, expected: expected[url.lastPathComponent]) }
        return install(from: directory, into: library.sideLoadDirectory, validate: check)
    }

    // MARK: Cheap check

    /// What the manifest says about one bundled pack (`regions[].routingPack`, file `<region id>.pack`).
    public struct ExpectedPack: Sendable, Equatable {
        public var byteSize: Int64?
        /// Lowercase hex; nil when absent or a placeholder of zeros.
        public var sha256: String?
    }

    struct ManifestJSON: Decodable {
        struct Region: Decodable {
            struct Pack: Decodable {
                var byteSize: Int64?
                var sha256: String?
            }
            var id: String
            var routingPack: Pack?
        }
        var regions: [Region]
    }

    /// Expected size and checksum per pack file name, from `manifest.json` (empty when it is missing or unreadable).
    public static func manifestPacks(in directory: URL) -> [String: ExpectedPack] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName, isDirectory: false)),
              let manifest = try? JSONDecoder().decode(ManifestJSON.self, from: data) else { return [:] }
        var out: [String: ExpectedPack] = [:]
        for region in manifest.regions {
            guard let pack = region.routingPack else { continue }
            var sha: String? = pack.sha256?.lowercased()
            if let value = sha, value.isEmpty || value.allSatisfy({ $0 == "0" }) { sha = nil }
            out[region.id + "." + RoutingPackLibrary.sideLoadedExtension] = ExpectedPack(byteSize: pack.byteSize, sha256: sha)
        }
        return out
    }

    /// Size and SHA-256 against the manifest (when it lists the pack), then the header (format and region).
    /// Reads the file once for the checksum but never decodes its sections.
    public static func quickCheck(_ url: URL, expected: ExpectedPack?) throws {
        if let size = expected?.byteSize {
            let actual: Int64 = RoutingPackLibrary.fileSize(url)
            guard actual == size else {
                throw RoutingPackRejection(reason: "size \(actual) bytes, the manifest says \(size)")
            }
        }
        if let sha = expected?.sha256 {
            let actual: String
            do {
                actual = try StreamingSHA256.hash(fileAt: url)
            } catch {
                throw RoutingPackRejection(reason: "could not be read (\(error.localizedDescription))")
            }
            guard actual == sha else { throw RoutingPackRejection(reason: "checksum does not match the manifest") }
        }
        do {
            _ = try RoutingPack.header(contentsOf: url)
        } catch {
            throw RoutingPackRejection(reason: RoutingPackLibrary.describe(error))
        }
    }

    static func install(from directory: URL?, into target: URL, validate: (URL) throws -> Void) -> Outcome {
        var outcome = Outcome()
        guard let directory else { return outcome }
        let packs: [URL] = packFiles(in: directory)
        guard !packs.isEmpty else { return outcome }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let stateURL: URL = target.appendingPathComponent(stateName, isDirectory: false)
        let previous: State? = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        let current: String = fingerprint(of: directory)

        if let previous, previous.fingerprint == current {
            // Same bundled set: only repair links that exist but point nowhere (the bundle moved on update).
            for pack in packs {
                let name: String = linkName(for: pack)
                guard previous.links.contains(name) else { continue }
                let link: URL = target.appendingPathComponent(name, isDirectory: false)
                if isDanglingLink(link) {
                    try? fileManager.removeItem(at: link)
                    if (try? fileManager.createSymbolicLink(at: link, withDestinationURL: pack)) != nil {
                        outcome.linked.append(name)
                        outcome.changed = true
                    }
                }
            }
            return outcome
        }

        // New or changed bundled set: remove our old links, check and link every pack.
        for name in previous?.links ?? [] {
            try? fileManager.removeItem(at: target.appendingPathComponent(name, isDirectory: false))
        }
        var links: [String] = []
        for pack in packs {
            let name: String = linkName(for: pack)
            do {
                try validate(pack)
            } catch {
                outcome.problems.append("\(pack.lastPathComponent): \(RoutingPackLibrary.describe(error))")
                continue
            }
            let link: URL = target.appendingPathComponent(name, isDirectory: false)
            if isLinkOrFile(link) { try? fileManager.removeItem(at: link) }
            do {
                try fileManager.createSymbolicLink(at: link, withDestinationURL: pack)
                links.append(name)
                outcome.linked.append(name)
            } catch {
                outcome.problems.append("\(pack.lastPathComponent): could not be linked (\(error.localizedDescription))")
            }
        }
        outcome.changed = true
        if let data = try? JSONEncoder().encode(State(fingerprint: current, links: links)) {
            try? data.write(to: stateURL, options: .atomic)
        }
        return outcome
    }

    static func linkName(for pack: URL) -> String {
        linkPrefix + RoutingPackLibrary.safeFileName(pack.deletingPathExtension().lastPathComponent)
            + "." + RoutingPackLibrary.sideLoadedExtension
    }

    static func isLinkOrFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// A symbolic link whose target does not exist.
    static func isDanglingLink(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
