import Foundation
import GPXKit
import NavCore
import Persistence

/// Reading and writing GPX files for the share sheet and the document picker.
public enum GPXFiles {
    public static let fileExtension = "gpx"
    /// Uniform type identifier of GPX files (declared by the app as an imported type).
    public static let typeIdentifier = "com.topografix.gpx"

    public static func parse(_ data: Data) throws -> GPXDocument {
        try GPXParser.parse(data: data)
    }

    public static func data(_ document: GPXDocument) -> Data {
        GPXWriter.data(from: document)
    }

    /// A safe file name: "Gulf Nav - Egmont Key 2026-11-12.gpx" (no path separators or reserved characters).
    public static func fileName(title: String, date: Date) -> String {
        var cleaned: String = ""
        for character in title {
            if "/\\:?%*|\"<>".contains(character) || character.isNewline {
                cleaned.append(" ")
            } else {
                cleaned.append(character)
            }
        }
        let trimmed: String = cleaned.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        let p: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let day: String = String(format: "%04d-%02d-%02d", p.year ?? 1970, p.month ?? 1, p.day ?? 1)
        let base: String = trimmed.isEmpty ? "Gulf Nav" : "Gulf Nav - " + String(trimmed.prefix(60))
        return base + " " + day + "." + fileExtension
    }

    /// Writes `document` to a new file in `directory` (for the share sheet). Returns its URL.
    public static func writeTemporary(_ document: GPXDocument, title: String, date: Date, directory: URL) throws -> URL {
        let folder: URL = directory.appendingPathComponent("GPXExport-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url: URL = folder.appendingPathComponent(fileName(title: title, date: date))
        try data(document).write(to: url, options: .atomic)
        return url
    }
}

/// The import-plan screen's rows and texts, from Persistence's `GPXImportPlan`.
public struct GPXImportRow: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case waypoint, route, track
    }

    /// `w3`, `r0`, `t1`: kind and index into the plan's list.
    public var id: String
    public var kind: Kind
    public var index: Int
    public var name: String
    public var detail: String
    /// Why this is a duplicate, nil when it is new.
    public var duplicateText: String?
    public var decision: GPXImportDecision
    /// Whether "replace existing" is possible (only for duplicates of stored items).
    public var canReplace: Bool
}

public enum GPXImportPresentation {
    public static func rows(_ plan: GPXImportPlan, units: UnitPreferences) -> [GPXImportRow] {
        var rows: [GPXImportRow] = []
        for (i, c) in plan.waypoints.enumerated() {
            rows.append(GPXImportRow(id: "w\(i)", kind: .waypoint, index: i, name: c.value.name,
                                     detail: NavFormat.position(c.value.coordinate),
                                     duplicateText: duplicateText(c.duplicate, kind: .waypoint, units: units),
                                     decision: c.decision, canReplace: isStoredDuplicate(c.duplicate)))
        }
        for (i, c) in plan.routes.enumerated() {
            let detail: String = "\(c.value.points.count) points, " + NavFormat.distance(c.value.length.meters, unit: units.distance)
            rows.append(GPXImportRow(id: "r\(i)", kind: .route, index: i, name: c.value.name, detail: detail,
                                     duplicateText: duplicateText(c.duplicate, kind: .route, units: units),
                                     decision: c.decision, canReplace: isStoredDuplicate(c.duplicate)))
        }
        for (i, c) in plan.tracks.enumerated() {
            var detail: String = "\(c.value.pointCount) points"
            if let start = c.value.startDate { detail += ", " + NavFormat.dateTime(start) }
            rows.append(GPXImportRow(id: "t\(i)", kind: .track, index: i, name: c.value.name, detail: detail,
                                     duplicateText: duplicateText(c.duplicate, kind: .track, units: units),
                                     decision: c.decision, canReplace: isStoredDuplicate(c.duplicate)))
        }
        return rows
    }

    static func isStoredDuplicate(_ d: GPXDuplicate?) -> Bool {
        if case .existing = d { return true }
        return false
    }

    static func duplicateText(_ d: GPXDuplicate?, kind: GPXImportRow.Kind, units: UnitPreferences) -> String? {
        guard let d else { return nil }
        switch d {
        case .existing(_, let name, let distance):
            if kind == .waypoint && distance > 0 {
                return "Already saved as “\(name)” (" + NavFormat.distance(distance, unit: units.distance) + " away)"
            }
            return "Already saved as “\(name)”"
        case .earlierInFile(let index):
            return "Same as \(kind.rawValue) \(index + 1) in this file"
        }
    }

    /// Sets one row's decision in the plan. `replaceExisting` is only kept for duplicates of stored items.
    public static func setDecision(_ decision: GPXImportDecision, rowID: String, in plan: inout GPXImportPlan) {
        guard let kind = rowID.first, let index = Int(rowID.dropFirst()) else { return }
        switch kind {
        case "w":
            guard plan.waypoints.indices.contains(index) else { return }
            plan.waypoints[index].decision = allowed(decision, plan.waypoints[index].duplicate)
        case "r":
            guard plan.routes.indices.contains(index) else { return }
            plan.routes[index].decision = allowed(decision, plan.routes[index].duplicate)
        case "t":
            guard plan.tracks.indices.contains(index) else { return }
            plan.tracks[index].decision = allowed(decision, plan.tracks[index].duplicate)
        default:
            return
        }
    }

    static func allowed(_ decision: GPXImportDecision, _ duplicate: GPXDuplicate?) -> GPXImportDecision {
        if decision == .replaceExisting && !isStoredDuplicate(duplicate) { return .importNew }
        return decision
    }

    /// "2 waypoints, 1 route and 1 track. 1 is already saved and will be skipped."
    public static func summary(_ plan: GPXImportPlan) -> String {
        var parts: [String] = []
        if !plan.waypoints.isEmpty { parts.append(count(plan.waypoints.count, "waypoint")) }
        if !plan.routes.isEmpty { parts.append(count(plan.routes.count, "route")) }
        if !plan.tracks.isEmpty { parts.append(count(plan.tracks.count, "track")) }
        if parts.isEmpty { return "The file contains nothing to import." }
        var text: String = joinList(parts) + "."
        let skipped: Int = plan.waypoints.filter { $0.decision == .skip }.count + plan.routes.filter { $0.decision == .skip }.count
            + plan.tracks.filter { $0.decision == .skip }.count
        let replaced: Int = plan.waypoints.filter { $0.decision == .replaceExisting }.count
            + plan.routes.filter { $0.decision == .replaceExisting }.count
            + plan.tracks.filter { $0.decision == .replaceExisting }.count
        if plan.duplicateCount > 0 {
            text += " \(plan.duplicateCount) already saved or repeated."
        }
        if skipped > 0 { text += " \(skipped) will be skipped." }
        if replaced > 0 { text += " \(replaced) will replace the saved copy." }
        return text
    }

    public static func resultText(_ result: GPXImportResult) -> String {
        let added: Int = result.insertedWaypoints.count + result.insertedRoutes.count + result.insertedTracks.count
        let replaced: Int = result.replacedWaypoints.count + result.replacedRoutes.count + result.replacedTracks.count
        var parts: [String] = ["Imported \(added)"]
        if replaced > 0 { parts.append("replaced \(replaced)") }
        if result.skipped > 0 { parts.append("skipped \(result.skipped)") }
        return parts.joined(separator: ", ") + "."
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)" + (n == 1 ? "" : "s")
    }

    static func joinList(_ parts: [String]) -> String {
        if parts.count <= 1 { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }
}

extension GPXFiles {
    /// Parses GPX bytes and plans their import against `store` (nothing is written).
    public static func plan(data: Data, store: PersistenceStore) async throws -> GPXImportPlan {
        let document: GPXDocument = try parse(data)
        return try await store.planGPXImport(document)
    }

    /// Reads a file the user picked or opened in the app (security-scoped when it comes from outside the
    /// sandbox) and plans its import.
    public static func plan(fileAt url: URL, store: PersistenceStore) async throws -> GPXImportPlan {
        let scoped: Bool = url.startAccessingSecurityScopedResourceIfAvailable()
        defer { if scoped { url.stopAccessingSecurityScopedResourceIfAvailable() } }
        let data: Data = try Data(contentsOf: url)
        return try await plan(data: data, store: store)
    }

    /// Exports stored items to a GPX file in `directory` for the share sheet. `nil` selects all of a kind,
    /// `[]` none (as `PersistenceStore.exportGPX`).
    public static func export(store: PersistenceStore, waypoints: [UUID]?, routes: [UUID]?, tracks: [UUID]?,
                              title: String, date: Date, directory: URL) async throws -> URL {
        let document: GPXDocument = try await store.exportGPX(waypoints: waypoints, routes: routes, tracks: tracks)
        return try writeTemporary(document, title: title, date: date, directory: directory)
    }
}

extension URL {
    /// `startAccessingSecurityScopedResource()` where it exists (Apple platforms); false elsewhere.
    func startAccessingSecurityScopedResourceIfAvailable() -> Bool {
        #if canImport(Darwin)
        return startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    func stopAccessingSecurityScopedResourceIfAvailable() {
        #if canImport(Darwin)
        stopAccessingSecurityScopedResource()
        #endif
    }
}
