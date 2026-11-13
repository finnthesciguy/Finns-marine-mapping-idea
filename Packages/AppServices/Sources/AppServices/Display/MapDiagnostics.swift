import Foundation

/// What the map view has done so far, reported through the debug-only `map.status` accessibility element
/// so UI tests (and their CI logs) show exactly where map start-up stops.
///
/// Value format (one line, `; `-separated `key=value` pairs, stable order):
///
///     style=loaded; chartLayers=1; overlayLayers=7; styleVia=attach; willStartLoading=0; didFinishLoadingMap=0;
///     didFinishLoadingStyle=0; didFailLoading=none; frames=12; fullFrames=3; idle=1; rendererErrors=0
///
/// `styleVia` says how the style object was first found: `attach` (already present when the coordinator
/// attached: MapLibre parses an inline style JSON synchronously inside `init(frame:styleJSON:)`, before a
/// delegate can be set, so `mapView(_:didFinishLoading:)` never fires for it), `update` (found on a later
/// SwiftUI update), `delegate` (the callback) or `none`.
public struct MapDiagnostics: Sendable, Equatable {
    public enum StyleSource: String, Sendable, Equatable {
        case none, attach, update, delegate
    }

    public var styleVia: StyleSource = .none
    public var chartLayers: Int = 0
    public var overlayLayers: Int = 0
    public var willStartLoading: Int = 0
    public var didFinishLoadingMap: Int = 0
    public var didFinishLoadingStyle: Int = 0
    public var failure: String?
    public var frames: Int = 0
    public var fullyRenderedFrames: Int = 0
    public var idle: Int = 0
    public var rendererErrors: Int = 0

    public init() {}

    public var styleLoaded: Bool { styleVia != .none }

    public var statusValue: String {
        var parts: [String] = []
        parts.append("style=\(styleLoaded ? "loaded" : "pending")")
        parts.append("chartLayers=\(chartLayers)")
        parts.append("overlayLayers=\(overlayLayers)")
        parts.append("styleVia=\(styleVia.rawValue)")
        parts.append("willStartLoading=\(willStartLoading)")
        parts.append("didFinishLoadingMap=\(didFinishLoadingMap)")
        parts.append("didFinishLoadingStyle=\(didFinishLoadingStyle)")
        parts.append("didFailLoading=\(MapDiagnostics.sanitize(failure ?? "none"))")
        parts.append("frames=\(frames)")
        parts.append("fullFrames=\(fullyRenderedFrames)")
        parts.append("idle=\(idle)")
        parts.append("rendererErrors=\(rendererErrors)")
        return parts.joined(separator: "; ")
    }

    /// Keeps a free-text error on one line without the separator characters.
    static func sanitize(_ text: String) -> String {
        var out: String = ""
        for character in text {
            if character == ";" || character == "=" || character.isNewline {
                out.append(" ")
            } else {
                out.append(character)
            }
        }
        return String(out.prefix(160))
    }

    /// Reads one integer field back (used by tests and the UI tests' parser). -1 when absent.
    public static func integer(_ key: String, in value: String) -> Int {
        guard let range = value.range(of: key + "=") else { return -1 }
        let digits: String = String(value[range.upperBound...].prefix(while: { $0.isNumber }))
        return Int(digits) ?? -1
    }
}
