import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import NavCore

/// Errors raised while reading GPX.
public enum GPXError: Error, Hashable, Sendable {
    /// The input is not well-formed XML (or is empty).
    case malformedXML(line: Int, column: Int, message: String)
    /// The root element is not `<gpx>`.
    case notGPX(rootElement: String)
    /// A `wpt`, `rtept` or `trkpt` had a missing, non-numeric or out-of-range `lat`/`lon`.
    case invalidCoordinate(line: Int, latitude: String?, longitude: String?)
    /// The input file or stream could not be opened.
    case unreadable(String)
}

/// One step of a streamed GPX parse, delivered in document order.
///
/// Waypoints and routes are delivered whole (they are small); tracks, which can hold hundreds of
/// thousands of points, are delivered point by point between ``trackStart(_:)`` and ``trackEnd(_:)``.
public enum GPXEvent: Hashable, Sendable {
    /// The root `<gpx>` element: its `creator` and `version` attributes (empty if missing).
    case header(creator: String, version: String)
    /// File metadata: emitted when `<metadata>` closes (GPX 1.1), or at the end of the document
    /// for GPX 1.0 top-level `name`/`desc`/`author`/`time`/`keywords`.
    case metadata(GPXMetadata)
    /// A complete stand-alone waypoint.
    case waypoint(GPXWaypoint)
    /// A complete route.
    case route(GPXRoute)
    /// A track begins. Carries the header fields seen so far (segments always empty).
    case trackStart(GPXTrack)
    /// A new segment within the current track begins.
    case trackSegmentStart
    /// A point in the current segment.
    case trackPoint(GPXWaypoint)
    /// The current track ends. Carries the final header fields, including any that appeared
    /// after the segments (segments always empty).
    case trackEnd(GPXTrack)
}

/// GPX 1.0 / 1.1 reader built on `XMLParser` (SAX-style, so memory use does not grow with file size
/// when using the event API).
///
/// Tolerant by design: elements from other namespaces, `<extensions>` and GPX elements NavCore has no
/// use for (links, DOP values, bounds…) are skipped with their whole subtree; unparseable times or
/// elevations are dropped rather than failing the file. Points without a valid position do fail,
/// since a point with no position is meaningless.
public enum GPXParser {
    /// Parses a complete document from data.
    public static func parse(data: Data) throws -> GPXDocument {
        var builder = DocumentBuilder()
        try parse(data: data) { builder.consume($0) }
        return builder.document
    }

    /// Parses a complete document from a string.
    public static func parse(string: String) throws -> GPXDocument {
        try parse(data: Data(string.utf8))
    }

    /// Parses a complete document from a file, streaming it from disk.
    public static func parse(contentsOf url: URL) throws -> GPXDocument {
        guard let stream = InputStream(url: url) else { throw GPXError.unreadable(url.path) }
        var builder = DocumentBuilder()
        try parse(stream: stream) { builder.consume($0) }
        return builder.document
    }

    /// Streams events from data to `handler`. Throwing from the handler stops parsing and
    /// rethrows that error.
    public static func parse(data: Data, handler: (GPXEvent) throws -> Void) throws {
        try run(XMLParser(data: data), handler: handler)
    }

    /// Streams events from an input stream to `handler`, without loading the whole file.
    public static func parse(stream: InputStream, handler: (GPXEvent) throws -> Void) throws {
        try run(XMLParser(stream: stream), handler: handler)
    }

    private static func run(_ parser: XMLParser, handler: (GPXEvent) throws -> Void) throws {
        try withoutActuallyEscaping(handler) { escapable in
            let delegate = ParserDelegate(handler: escapable)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = true
            parser.shouldReportNamespacePrefixes = false
            parser.shouldResolveExternalEntities = false
            let ok = parser.parse()
            parser.delegate = nil
            if let error = delegate.failure { throw error }
            // Some XMLParser implementations accept a truncated document, so also insist on </gpx>.
            if !ok || !delegate.sawRoot || !delegate.sawRootEnd {
                let message = parser.parserError.map { String(describing: $0) }
                    ?? (delegate.sawRoot ? "unexpected end of document" : "no root element")
                throw GPXError.malformedXML(line: parser.lineNumber, column: parser.columnNumber, message: message)
            }
            delegate.finish()
            if let error = delegate.failure { throw error }
        }
    }
}

/// Accumulates streamed events into a ``GPXDocument``.
struct DocumentBuilder {
    var document = GPXDocument(creator: "", version: "")
    private var currentTrack: GPXTrack?

    mutating func consume(_ event: GPXEvent) {
        switch event {
        case .header(let creator, let version):
            document.creator = creator
            document.version = version
        case .metadata(let m):
            document.metadata.name = m.name ?? document.metadata.name
            document.metadata.description = m.description ?? document.metadata.description
            document.metadata.author = m.author ?? document.metadata.author
            document.metadata.time = m.time ?? document.metadata.time
            document.metadata.keywords = m.keywords ?? document.metadata.keywords
        case .waypoint(let w):
            document.waypoints.append(w)
        case .route(let r):
            document.routes.append(r)
        case .trackStart(let t):
            currentTrack = t
        case .trackSegmentStart:
            currentTrack?.segments.append(GPXTrackSegment())
        case .trackPoint(let p):
            if currentTrack?.segments.isEmpty ?? false { currentTrack?.segments.append(GPXTrackSegment()) }
            if let n = currentTrack?.segments.count, n > 0 { currentTrack?.segments[n - 1].points.append(p) }
        case .trackEnd(let header):
            var t = currentTrack ?? GPXTrack()
            t.name = header.name
            t.comment = header.comment
            t.description = header.description
            t.type = header.type
            document.tracks.append(t)
            currentTrack = nil
        }
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    private enum Context {
        case document, gpx, metadata, author, waypoint, route, routePoint, track, trackSegment, trackPoint
    }

    private let handler: (GPXEvent) throws -> Void
    private(set) var failure: Error?
    private(set) var sawRoot = false
    private(set) var sawRootEnd = false

    private var stack: [Context] = [.document]
    private var skipDepth = 0
    private var leaf: String?
    private var text = ""

    private var metadata = GPXMetadata()
    private var topLevelMetadata = GPXMetadata()   // GPX 1.0 fields directly under <gpx>
    private var point: GPXWaypoint?
    private var route: GPXRoute?
    private var track: GPXTrack?
    private var trackStarted = false
    private var segmentOpen = false

    init(handler: @escaping (GPXEvent) throws -> Void) {
        self.handler = handler
    }

    private func emit(_ event: GPXEvent, _ parser: XMLParser) {
        guard failure == nil else { return }
        do { try handler(event) } catch {
            failure = error
            parser.abortParsing()
        }
    }

    private func fail(_ error: GPXError, _ parser: XMLParser) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }

    func finish() {
        guard failure == nil, !topLevelMetadata.isEmpty else { return }
        do { try handler(.metadata(topLevelMetadata)) } catch { failure = error }
    }

    private static func isGPXNamespace(_ uri: String?) -> Bool {
        guard let uri, !uri.isEmpty else { return true }
        return uri.hasPrefix("http://www.topografix.com/GPX/")
    }

    private static let pointLeaves: Set<String> = ["ele", "time", "name", "cmt", "desc", "sym", "type", "speed", "course"]
    private static let routeLeaves: Set<String> = ["name", "cmt", "desc", "type"]
    private static let metadataLeaves: Set<String> = ["name", "desc", "time", "keywords"]
    private static let gpx10Leaves: Set<String> = ["name", "desc", "author", "time", "keywords"]

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if skipDepth > 0 { skipDepth += 1; return }
        let name = Self.localName(elementName)
        let context = stack.last ?? .document

        if context == .document {
            guard name == "gpx" else { return fail(.notGPX(rootElement: elementName), parser) }
            sawRoot = true
            stack.append(.gpx)
            emit(.header(creator: attributeDict["creator"] ?? "", version: attributeDict["version"] ?? ""), parser)
            return
        }
        guard Self.isGPXNamespace(namespaceURI), name != "extensions", leaf == nil else { skipDepth = 1; return }

        switch (context, name) {
        case (.gpx, "metadata"):
            stack.append(.metadata)
        case (.gpx, "wpt"), (.route, "rtept"), (.trackSegment, "trkpt"), (.track, "trkpt"):
            guard let p = makePoint(attributeDict, parser) else { return }
            if context == .track {   // tolerate trkpt without an enclosing trkseg
                startSegmentIfNeeded(parser)
            }
            point = p
            stack.append(name == "wpt" ? .waypoint : name == "rtept" ? .routePoint : .trackPoint)
        case (.gpx, "rte"):
            route = GPXRoute()
            stack.append(.route)
        case (.gpx, "trk"):
            track = GPXTrack()
            trackStarted = false
            segmentOpen = false
            stack.append(.track)
        case (.track, "trkseg"):
            startTrackIfNeeded(parser)
            emit(.trackSegmentStart, parser)
            segmentOpen = true
            stack.append(.trackSegment)
        case (.metadata, "author"):
            stack.append(.author)
        case (.author, "name"):
            startLeaf(name)
        case (.metadata, _) where Self.metadataLeaves.contains(name):
            startLeaf(name)
        case (.gpx, _) where Self.gpx10Leaves.contains(name):
            startLeaf(name)
        case (.waypoint, _), (.routePoint, _), (.trackPoint, _):
            if Self.pointLeaves.contains(name) { startLeaf(name) } else { skipDepth = 1 }
        case (.route, _), (.track, _):
            if Self.routeLeaves.contains(name) { startLeaf(name) } else { skipDepth = 1 }
        default:
            skipDepth = 1
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        if let l = leaf {
            finishLeaf(l)
            return
        }
        guard let context = stack.popLast() else { return }
        switch context {
        case .metadata:
            emit(.metadata(metadata), parser)
        case .waypoint:
            if let p = point { emit(.waypoint(p), parser) }
            point = nil
        case .routePoint:
            if let p = point { route?.points.append(p) }
            point = nil
        case .trackPoint:
            if let p = point { emit(.trackPoint(p), parser) }
            point = nil
        case .route:
            if let r = route { emit(.route(r), parser) }
            route = nil
        case .trackSegment:
            segmentOpen = false
        case .track:
            startTrackIfNeeded(parser)
            if let t = track { emit(.trackEnd(t), parser) }
            track = nil
        case .gpx:
            sawRootEnd = true
        case .author, .document:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if leaf != nil && skipDepth == 0 { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if leaf != nil && skipDepth == 0, let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    // MARK: Helpers

    private static func localName(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    private func startLeaf(_ name: String) {
        leaf = name
        text = ""
    }

    private func startTrackIfNeeded(_ parser: XMLParser) {
        guard !trackStarted, let t = track else { return }
        trackStarted = true
        emit(.trackStart(t), parser)
    }

    private func startSegmentIfNeeded(_ parser: XMLParser) {
        startTrackIfNeeded(parser)
        if !segmentOpen {
            emit(.trackSegmentStart, parser)
            segmentOpen = true
        }
    }

    private func makePoint(_ attributes: [String: String], _ parser: XMLParser) -> GPXWaypoint? {
        let latText = attributes["lat"], lonText = attributes["lon"]
        guard let latS = latText, let lonS = lonText,
              let lat = Double(latS.trimmingCharacters(in: .whitespaces)),
              let lon = Double(lonS.trimmingCharacters(in: .whitespaces)),
              let c = try? Coordinate(validatingLatitude: lat, longitude: lon) else {
            fail(.invalidCoordinate(line: parser.lineNumber, latitude: latText, longitude: lonText), parser)
            return nil
        }
        return GPXWaypoint(coordinate: c)
    }

    private func finishLeaf(_ name: String) {
        leaf = nil
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        let string: String? = value.isEmpty ? nil : value
        let context = stack.last ?? .document
        switch context {
        case .waypoint, .routePoint, .trackPoint:
            guard point != nil else { return }
            switch name {
            case "ele": point?.elevation = Double(value).flatMap { $0.isFinite ? $0 : nil }
            case "time": point?.time = ISO8601.date(from: value)
            case "name": point?.name = string
            case "cmt": point?.comment = string
            case "desc": point?.description = string
            case "sym": point?.symbol = string
            case "type": point?.type = string
            case "speed": point?.speed = Double(value).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            case "course": point?.course = Double(value).flatMap { $0.isFinite ? Angle.normalizeBearing($0) : nil }
            default: break
            }
        case .route:
            switch name {
            case "name": route?.name = string
            case "cmt": route?.comment = string
            case "desc": route?.description = string
            case "type": route?.type = string
            default: break
            }
        case .track:
            switch name {
            case "name": track?.name = string
            case "cmt": track?.comment = string
            case "desc": track?.description = string
            case "type": track?.type = string
            default: break
            }
        case .metadata:
            switch name {
            case "name": metadata.name = string
            case "desc": metadata.description = string
            case "time": metadata.time = ISO8601.date(from: value)
            case "keywords": metadata.keywords = string
            default: break
            }
        case .author:
            if name == "name" { metadata.author = string }
        case .gpx:
            switch name {
            case "name": topLevelMetadata.name = string
            case "desc": topLevelMetadata.description = string
            case "author": topLevelMetadata.author = string
            case "time": topLevelMetadata.time = ISO8601.date(from: value)
            case "keywords": topLevelMetadata.keywords = string
            default: break
            }
        case .document, .trackSegment:
            break
        }
    }
}
