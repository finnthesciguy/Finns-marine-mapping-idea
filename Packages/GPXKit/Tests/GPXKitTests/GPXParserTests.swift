import Foundation
import Testing
import NavCore
@testable import GPXKit

func resource(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "gpx", subdirectory: "Resources"))
}

@Suite("Reading realistic GPX files")
struct SampleFileTests {
    @Test func openCPNRouteExport() throws {
        let doc = try GPXParser.parse(contentsOf: try resource("opencpn-route"))
        #expect(doc.creator == "OpenCPN" && doc.version == "1.1")
        #expect(doc.metadata.isEmpty)
        #expect(doc.waypoints.count == 2 && doc.routes.count == 1 && doc.tracks.isEmpty)

        let egmont = doc.waypoints[0]
        #expect(egmont.coordinate == Coordinate(latitude: 27.600833333, longitude: -82.76))
        #expect(egmont.name == "Egmont Key Anch")
        #expect(egmont.description == "Good holding in sand, 12 ft. Watch the current & ferry wake.")
        #expect(egmont.symbol == "anchorage" && egmont.type == "WPT")
        #expect(egmont.time == Date(timeIntervalSince1970: 1_709_993_107))
        #expect(egmont.elevation == nil)
        // Marine DDM rendering of the parsed position.
        #expect(egmont.coordinate.ddmString == "27°36.050'N 082°45.600'W")

        let route = doc.routes[0]
        #expect(route.name == "Skyway to Venice")   // not clobbered by <opencpn:start>/<end>
        #expect(route.points.map(\.name) == ["Skyway Channel", "SWC sea buoy", "001", "Venice Inlet"])
        #expect(route.points.allSatisfy { $0.symbol != nil })
        #expect(route.points[0].time == Date(timeIntervalSince1970: 1_709_996_400))

        // Route length via NavCore; GeographicLib gives 72 927.955 m (39.38 NM) for these points.
        let coords = route.points.map(\.coordinate)
        let total = zip(coords, coords.dropFirst()).map { Geodesy.distance(from: $0, to: $1) }.reduce(0, +)
        #expect(abs(total - 72_927.955) < 0.01)
    }

    @Test func garminTrackWithExtensionsAndSegments() throws {
        let doc = try GPXParser.parse(contentsOf: try resource("garmin-track"))
        #expect(doc.creator == "GPSMAP 86sci")
        // <link><text> inside metadata must not become the name.
        #expect(doc.metadata.name == nil)
        #expect(doc.metadata.time == Date(timeIntervalSince1970: 1_716_033_600))
        #expect(doc.tracks.count == 1)
        let trk = doc.tracks[0]
        #expect(trk.name == "Pensacola Pass 18-MAY-24")
        #expect(trk.description == "Outbound <fast> run & return")   // CDATA
        #expect(trk.segments.count == 2)
        #expect(trk.segments.map(\.points.count) == [3, 2])
        let p0 = trk.segments[0].points[0]
        #expect(p0.coordinate == Coordinate(latitude: 30.408534, longitude: -87.212188))
        #expect(p0.elevation == 1.24)
        #expect(p0.time == Date(timeIntervalSince1970: 1_716_033_601))
        #expect(p0.speed == nil && p0.course == nil)   // Garmin extension values are skipped
        #expect(trk.segments[0].points[1].time == Date(timeIntervalSince1970: 1_716_033_611.5))
        #expect(trk.segments[1].points[0].elevation == -0.5)
        // An unparseable time is dropped, not fatal.
        #expect(trk.segments[1].points[1].time == nil)
    }

    @Test func gpx10Handheld() throws {
        let doc = try GPXParser.parse(contentsOf: try resource("gpx10-handheld"))
        #expect(doc.version == "1.0" && doc.creator.hasPrefix("GPSBabel"))
        #expect(doc.metadata.name == "Galveston Bay trip")
        #expect(doc.metadata.description == "Downloaded from handheld")
        #expect(doc.metadata.author == "J. Skipper")
        #expect(doc.metadata.time == Date(timeIntervalSince1970: 1_696_185_900))
        let w = try #require(doc.waypoints.first)
        #expect(w.name == "BOLIVR" && w.comment == "Bolivar Roads" && w.symbol == "Anchor")
        #expect(w.elevation == 0 && w.time == Date(timeIntervalSince1970: 1_696_185_900))
        let trk = try #require(doc.tracks.first)
        #expect(trk.name == "ACTIVE LOG")
        let pts = trk.segments.flatMap(\.points)
        #expect(pts.count == 2)
        #expect(pts[0].speed == 2.5 && pts[0].course == 45)
        #expect(pts[1].speed == 2.6 && pts[1].course == 44.2)
        // Cross-check the recorded GPX 1.0 speed with NavCore's computed speed between the fixes.
        let a = Fix(coordinate: pts[0].coordinate, timestamp: try #require(pts[0].time))
        let b = Fix(coordinate: pts[1].coordinate, timestamp: try #require(pts[1].time))
        let cs = try #require(Navigation.courseAndSpeed(from: a, to: b))
        #expect(abs(cs.speed - 2.4) < 0.2)
        #expect(abs(Angle.difference(from: try #require(cs.course), to: 44.5)) < 2)
    }
}

@Suite("Parser tolerance and errors")
struct ParserBehaviourTests {
    @Test func noNamespaceAndPrefixedNamespace() throws {
        let plain = try GPXParser.parse(string: """
        <gpx version="1.1" creator="x"><wpt lat="1" lon="2"><name>A</name></wpt></gpx>
        """)
        #expect(plain.waypoints == [GPXWaypoint(latitude: 1, longitude: 2, name: "A")])
        let prefixed = try GPXParser.parse(string: """
        <g:gpx xmlns:g="http://www.topografix.com/GPX/1/1" version="1.1" creator="x">
          <g:wpt lat="1" lon="2"><g:name>A</g:name></g:wpt>
        </g:gpx>
        """)
        #expect(prefixed.waypoints == plain.waypoints)
    }

    @Test func unknownElementsAnywhereAreSkipped() throws {
        let doc = try GPXParser.parse(string: """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1" xmlns:v="urn:vendor">
          <v:header><name>WRONG</name></v:header>
          <wpt lat="27.5" lon="-82.5">
            <v:depth units="ft">12</v:depth>
            <name>Mark<v:inline>WRONG</v:inline></name>
            <futureElement><name>WRONG</name><deeper><x/></deeper></futureElement>
            <sym>buoy</sym>
          </wpt>
          <rte><number>3</number><name>R</name><rtept lat="1" lon="1"/><extensions><rtept lat="9" lon="9"/></extensions></rte>
          <trk><name>T</name><trkpt lat="1" lon="1"/><trkpt lat="1.1" lon="1"/></trk>
          <extensions><wpt lat="5" lon="5"/></extensions>
        </gpx>
        """)
        #expect(doc.waypoints.count == 1)
        #expect(doc.waypoints[0].name == "Mark" && doc.waypoints[0].symbol == "buoy")
        #expect(doc.routes.count == 1 && doc.routes[0].name == "R" && doc.routes[0].points.count == 1)
        // trkpt without trkseg becomes an implicit segment.
        #expect(doc.tracks.count == 1 && doc.tracks[0].segments.count == 1 && doc.tracks[0].segments[0].points.count == 2)
    }

    @Test func badPointCoordinatesFail() {
        let cases = [
            #"<gpx version="1.1" creator="x"><wpt lat="91" lon="0"/></gpx>"#,
            #"<gpx version="1.1" creator="x"><wpt lat="abc" lon="0"/></gpx>"#,
            #"<gpx version="1.1" creator="x"><trk><trkseg><trkpt lon="0"/></trkseg></trk></gpx>"#,
        ]
        for xml in cases {
            #expect(throws: GPXError.self) { try GPXParser.parse(string: xml) }
        }
        do {
            _ = try GPXParser.parse(string: "<gpx version=\"1.1\" creator=\"x\">\n<wpt lat=\"95\" lon=\"0\"/></gpx>")
            Issue.record("expected failure")
        } catch let GPXError.invalidCoordinate(line, lat, lon) {
            #expect(line == 2 && lat == "95" && lon == "0")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func malformedAndNonGPXInput() {
        #expect(throws: GPXError.notGPX(rootElement: "kml")) { try GPXParser.parse(string: "<kml><Placemark/></kml>") }
        for bad in ["", "   ", "<gpx><wpt lat=\"1\" lon=\"2\"></gpx>", "not xml at all", "<gpx version=\"1.1\""] {
            #expect(throws: GPXError.self, "\(bad)") { try GPXParser.parse(string: bad) }
        }
    }

    @Test func badElevationIgnoredAndWhitespaceTrimmed() throws {
        let doc = try GPXParser.parse(string: """
        <gpx version="1.1" creator="x"><wpt lat=" 27.5 " lon="-82.5"><ele>n/a</ele><name>
            Spaced Name
        </name><desc></desc></wpt></gpx>
        """)
        #expect(doc.waypoints[0].elevation == nil)
        #expect(doc.waypoints[0].name == "Spaced Name")
        #expect(doc.waypoints[0].description == nil)
    }

    @Test func streamingEventsInOrder() throws {
        let xml = """
        <gpx version="1.1" creator="s" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>M</name><author><name>Ann</name><email id="a" domain="b"/></author></metadata>
          <wpt lat="1" lon="1"/>
          <trk><name>T</name><trkseg><trkpt lat="1" lon="1"/><trkpt lat="2" lon="2"/></trkseg><trkseg/><desc>late</desc></trk>
        </gpx>
        """
        var events: [GPXEvent] = []
        try GPXParser.parse(stream: InputStream(data: Data(xml.utf8))) { events.append($0) }
        #expect(events == [
            .header(creator: "s", version: "1.1"),
            .metadata(GPXMetadata(name: "M", author: "Ann")),
            .waypoint(GPXWaypoint(latitude: 1, longitude: 1)),
            .trackStart(GPXTrack(name: "T")),
            .trackSegmentStart,
            .trackPoint(GPXWaypoint(latitude: 1, longitude: 1)),
            .trackPoint(GPXWaypoint(latitude: 2, longitude: 2)),
            .trackSegmentStart,
            .trackEnd(GPXTrack(name: "T", description: "late")),
        ])
    }

    struct Stop: Error {}

    @Test func handlerCanStopParsing() {
        var points = 0
        #expect(throws: Stop.self) {
            try GPXParser.parse(data: Data("""
            <gpx version="1.1" creator="x"><wpt lat="1" lon="1"/><wpt lat="2" lon="2"/><wpt lat="3" lon="3"/></gpx>
            """.utf8)) { event in
                if case .waypoint = event {
                    points += 1
                    if points == 2 { throw Stop() }
                }
            }
        }
        #expect(points == 2)
    }

    @Test func largeTrackStreamsWithoutBuildingDocument() throws {
        var xml = "<gpx version=\"1.1\" creator=\"x\"><trk><trkseg>"
        for i in 0..<20_000 {
            xml += "<trkpt lat=\"\(27 + Double(i) * 1e-5)\" lon=\"-82.5\"><time>\(ISO8601.string(from: Date(timeIntervalSince1970: Double(i))))</time></trkpt>"
        }
        xml += "</trkseg></trk></gpx>"
        var count = 0
        var last: Date?
        try GPXParser.parse(data: Data(xml.utf8)) { e in
            if case .trackPoint(let p) = e { count += 1; last = p.time }
        }
        #expect(count == 20_000)
        #expect(last == Date(timeIntervalSince1970: 19_999))
    }
}
