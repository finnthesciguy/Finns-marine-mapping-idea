import Foundation
import NavCore

/// Writes GPX 1.1 documents.
///
/// Output is UTF-8, indented with two spaces, with elements in GPX 1.1 schema order. Text and
/// attribute values are XML-escaped and characters that XML 1.0 forbids are dropped. Coordinates
/// are written with up to 9 decimal places (sub-millimetre), elevations with up to 3; trailing zeros
/// are trimmed and exponent notation is never used. Times are UTC ISO-8601, with milliseconds only
/// when non-zero. `speed`/`course` on points are not written (GPX 1.1 has no such elements).
public enum GPXWriter {
    /// The GPX 1.1 namespace URI.
    public static let namespace = "http://www.topografix.com/GPX/1/1"

    /// Serialises a document to a GPX 1.1 string.
    public static func string(from document: GPXDocument) -> String {
        var out = ""
        write(document, to: &out)
        return out
    }

    /// Serialises a document to UTF-8 GPX 1.1 data.
    public static func data(from document: GPXDocument) -> Data {
        Data(string(from: document).utf8)
    }

    /// Serialises a document into any text stream (e.g. a buffered file writer).
    public static func write<Target: TextOutputStream>(_ document: GPXDocument, to out: inout Target) {
        out.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        let creator = document.creator.isEmpty ? "GPXKit" : document.creator
        out.write("<gpx version=\"1.1\" creator=\"\(escapeAttribute(creator))\" xmlns=\"\(namespace)\" ")
        out.write("xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" ")
        out.write("xsi:schemaLocation=\"\(namespace) \(namespace)/gpx.xsd\">\n")

        let m = document.metadata
        if !m.isEmpty {
            out.write("  <metadata>\n")
            element("name", m.name, indent: 4, &out)
            element("desc", m.description, indent: 4, &out)
            if let author = m.author.flatMap(nonEmpty) {
                out.write("    <author>\n")
                element("name", author, indent: 6, &out)
                out.write("    </author>\n")
            }
            element("time", m.time.map(ISO8601.string(from:)), indent: 4, &out)
            element("keywords", m.keywords, indent: 4, &out)
            out.write("  </metadata>\n")
        }
        for w in document.waypoints { point("wpt", w, indent: 2, &out) }
        for r in document.routes {
            out.write("  <rte>\n")
            element("name", r.name, indent: 4, &out)
            element("cmt", r.comment, indent: 4, &out)
            element("desc", r.description, indent: 4, &out)
            element("type", r.type, indent: 4, &out)
            for p in r.points { point("rtept", p, indent: 4, &out) }
            out.write("  </rte>\n")
        }
        for t in document.tracks {
            out.write("  <trk>\n")
            element("name", t.name, indent: 4, &out)
            element("cmt", t.comment, indent: 4, &out)
            element("desc", t.description, indent: 4, &out)
            element("type", t.type, indent: 4, &out)
            for s in t.segments {
                if s.points.isEmpty {
                    out.write("    <trkseg/>\n")
                    continue
                }
                out.write("    <trkseg>\n")
                for p in s.points { point("trkpt", p, indent: 6, &out) }
                out.write("    </trkseg>\n")
            }
            out.write("  </trk>\n")
        }
        out.write("</gpx>\n")
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func point<Target: TextOutputStream>(_ tag: String, _ p: GPXWaypoint, indent: Int, _ out: inout Target) {
        let pad = String(repeating: " ", count: indent)
        let attrs = "lat=\"\(formatNumber(p.coordinate.latitude, maxFractionDigits: 9))\" lon=\"\(formatNumber(p.coordinate.longitude, maxFractionDigits: 9))\""
        let time = p.time.map(ISO8601.string(from:))
        let ele = p.elevation.flatMap { $0.isFinite ? formatNumber($0, maxFractionDigits: 3) : nil }
        let children: [(String, String?)] = [
            ("ele", ele), ("time", time), ("name", p.name), ("cmt", p.comment),
            ("desc", p.description), ("sym", p.symbol), ("type", p.type),
        ]
        guard children.contains(where: { $0.1 != nil }) else {
            out.write("\(pad)<\(tag) \(attrs)/>\n")
            return
        }
        out.write("\(pad)<\(tag) \(attrs)>\n")
        for (name, value) in children { element(name, value, indent: indent + 2, &out) }
        out.write("\(pad)</\(tag)>\n")
    }

    private static func element<Target: TextOutputStream>(_ name: String, _ value: String?, indent: Int, _ out: inout Target) {
        guard let value else { return }
        out.write(String(repeating: " ", count: indent))
        out.write("<\(name)>\(escapeText(value))</\(name)>\n")
    }

    /// Formats a finite number in plain decimal notation with at most `maxFractionDigits`
    /// decimals, trimming trailing zeros (e.g. `27.5`, `-82.624267`, `0`).
    public static func formatNumber(_ value: Double, maxFractionDigits: Int) -> String {
        guard value.isFinite else { return "0" }
        var s = String(format: "%.\(min(max(maxFractionDigits, 0), 15))f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    /// Escapes text content: `&`, `<`, `>`; drops characters not allowed in XML 1.0.
    public static func escapeText(_ s: String) -> String {
        escape(s, attribute: false)
    }

    /// Escapes an attribute value: `&`, `<`, `>`, `"`, `'`, and tab/newline/carriage return as
    /// character references so they survive attribute-value normalisation.
    public static func escapeAttribute(_ s: String) -> String {
        escape(s, attribute: true)
    }

    private static func escape(_ s: String, attribute: Bool) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"" where attribute: out.append(contentsOf: "&quot;".unicodeScalars)
            case "'" where attribute: out.append(contentsOf: "&apos;".unicodeScalars)
            case "\t" where attribute: out.append(contentsOf: "&#9;".unicodeScalars)
            case "\n" where attribute: out.append(contentsOf: "&#10;".unicodeScalars)
            case "\r": out.append(contentsOf: "&#13;".unicodeScalars)
            default:
                let v = u.value
                let allowed = v == 0x9 || v == 0xA || (0x20...0xD7FF).contains(v)
                    || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
                if allowed { out.append(u) }
            }
        }
        return String(out)
    }
}
