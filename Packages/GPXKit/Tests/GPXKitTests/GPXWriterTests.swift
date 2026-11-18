import Foundation
import Testing
import NavCore
@testable import GPXKit

@Suite("Writing and round-trips")
struct WriterTests {
    let sample = GPXDocument(
        creator: "Finn's \"Gulf\" Nav <beta> & co",
        metadata: GPXMetadata(name: "Weekend <trip> & \"stuff\"", description: "Tampa → Venice",
                              author: "Skipper O'Neil", time: Date(timeIntervalSince1970: 1_709_993_107.25),
                              keywords: "gulf, anchorage"),
        waypoints: [
            GPXWaypoint(coordinate: Coordinate(latitude: 27.600833333, longitude: -82.76), elevation: 0,
                        time: Date(timeIntervalSince1970: 1_709_993_107), name: "Egmont & Fort <Dade>",
                        comment: "cmt 'quoted'", description: "line1\nline2", symbol: "anchorage", type: "WPT"),
            GPXWaypoint(latitude: -0.5, longitude: 179.999_999_999, name: nil),
        ],
        routes: [GPXRoute(name: "Skyway → Venice", comment: "c", description: "d", type: "planned", points: [
            GPXWaypoint(latitude: 27.618166667, longitude: -82.7365, name: "A"),
            GPXWaypoint(latitude: 27.078_5, longitude: -82.457_333_333, name: "B"),
        ])],
        tracks: [GPXTrack(name: "Log", segments: [
            GPXTrackSegment(points: [
                GPXWaypoint(coordinate: Coordinate(latitude: 30.408534, longitude: -87.212188), elevation: 1.24,
                            time: Date(timeIntervalSince1970: 1_716_033_601)),
                GPXWaypoint(coordinate: Coordinate(latitude: 30.408276, longitude: -87.21233), elevation: -0.5,
                            time: Date(timeIntervalSince1970: 1_716_033_611.5)),
            ]),
            GPXTrackSegment(points: []),
            GPXTrackSegment(points: [GPXWaypoint(latitude: 30.395, longitude: -87.229)]),
        ])]
    )

    @Test func roundTripPreservesEverything() throws {
        let xml = GPXWriter.string(from: sample)
        let back = try GPXParser.parse(string: xml)
        #expect(back == sample)
        // A second pass is byte-identical.
        #expect(GPXWriter.string(from: back) == xml)
    }

    @Test func roundTripOfSampleFiles() throws {
        for name in ["opencpn-route", "garmin-track", "gpx10-handheld"] {
            let original = try GPXParser.parse(contentsOf: try resource(name))
            var back = try GPXParser.parse(data: GPXWriter.data(from: original))
            #expect(back.version == "1.1")
            // GPX 1.1 cannot carry GPX 1.0 speed/course or the declared version; everything else survives.
            back.version = original.version
            var stripped = original
            for t in stripped.tracks.indices {
                for s in stripped.tracks[t].segments.indices {
                    for p in stripped.tracks[t].segments[s].points.indices {
                        stripped.tracks[t].segments[s].points[p].speed = nil
                        stripped.tracks[t].segments[s].points[p].course = nil
                    }
                }
            }
            #expect(back == stripped, "\(name)")
        }
    }

    @Test func escapingIsCorrect() {
        let xml = GPXWriter.string(from: sample)
        #expect(xml.contains(#"creator="Finn&apos;s &quot;Gulf&quot; Nav &lt;beta&gt; &amp; co""#))
        #expect(xml.contains("<name>Weekend &lt;trip&gt; &amp; \"stuff\"</name>"))
        #expect(xml.contains("<name>Egmont &amp; Fort &lt;Dade&gt;</name>"))
        #expect(!xml.contains("<Dade>"))
        #expect(GPXWriter.escapeText("a\u{0}b\u{1B}c\u{FFFE}d") == "abcd")   // XML-forbidden characters dropped
        #expect(GPXWriter.escapeAttribute("a\tb\nc") == "a&#9;b&#10;c")
        #expect(GPXWriter.escapeText("😀 ü") == "😀 ü")
    }

    @Test func documentStructure() {
        let xml = GPXWriter.string(from: sample)
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\""))
        #expect(xml.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
        #expect(xml.contains("<time>2024-03-09T14:05:07.250Z</time>"))
        #expect(xml.contains("<time>2024-03-09T14:05:07Z</time>"))
        #expect(xml.contains("<wpt lat=\"27.600833333\" lon=\"-82.76\">"))
        #expect(xml.contains("<wpt lat=\"-0.5\" lon=\"179.999999999\"/>"))
        let tiny = GPXWriter.string(from: GPXDocument(waypoints: [GPXWaypoint(latitude: -1e-10, longitude: 0)]))
        #expect(tiny.contains("<wpt lat=\"0\" lon=\"0\"/>"))   // −1e-10 rounds to 0, never "-0"
        #expect(xml.contains("<ele>1.24</ele>") && xml.contains("<ele>-0.5</ele>") && xml.contains("<ele>0</ele>"))
        #expect(xml.contains("<trkseg/>"))
        #expect(xml.contains("<author>\n      <name>Skipper O'Neil</name>\n    </author>"))
        // GPX 1.1 schema order inside wpt: ele, time, name, cmt, desc, sym, type.
        let order = ["<ele>0</ele>", "<time>2024-03-09T14:05:07Z", "<name>Egmont", "<cmt>", "<desc>", "<sym>", "<type>WPT"]
        let wpt = String(xml[xml.range(of: "<wpt ")!.lowerBound...])
        let positions = order.compactMap { wpt.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted())
        #expect(xml.hasSuffix("</gpx>\n"))
    }

    @Test func numberFormatting() {
        #expect(GPXWriter.formatNumber(27.5, maxFractionDigits: 9) == "27.5")
        #expect(GPXWriter.formatNumber(-82, maxFractionDigits: 9) == "-82")
        #expect(GPXWriter.formatNumber(1e-5, maxFractionDigits: 9) == "0.00001")
        #expect(GPXWriter.formatNumber(123_456.789_4, maxFractionDigits: 3) == "123456.789")
        #expect(GPXWriter.formatNumber(-0.0, maxFractionDigits: 3) == "0")
        #expect(GPXWriter.formatNumber(.nan, maxFractionDigits: 3) == "0")
    }

    @Test func emptyDocument() throws {
        let xml = GPXWriter.string(from: GPXDocument())
        #expect(!xml.contains("<metadata>"))
        let back = try GPXParser.parse(string: xml)
        #expect(back == GPXDocument(creator: "GPXKit", version: "1.1"))
    }
}
