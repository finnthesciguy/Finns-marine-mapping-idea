import Foundation
import Testing
@testable import NavCore

@Suite("Coordinate formatting and parsing")
struct CoordinateFormatTests {
    // 27°45.123'N = 27 + 45.123/60 = 27.75205; 082°37.456'W = −(82 + 37.456/60) = −82.624266…
    let skyway = Coordinate(latitude: 27.75205, longitude: -(82 + 37.456 / 60))

    @Test func formatDDM() {
        #expect(CoordinateFormat.ddm(skyway) == "27°45.123'N 082°37.456'W")
        #expect(skyway.ddmString == "27°45.123'N 082°37.456'W")
        #expect(CoordinateFormat.latitudeDDM(-33.858, fractionDigits: 2) == "33°51.48'S")
        #expect(CoordinateFormat.longitudeDDM(151.2153, fractionDigits: 1) == "151°12.9'E")
        #expect(CoordinateFormat.latitudeDDM(5.0) == "05°00.000'N")
        #expect(CoordinateFormat.longitudeDDM(-5.5, fractionDigits: 0) == "005°30'W")
    }

    @Test func formatRoundingCarriesIntoDegrees() {
        // 24.99999999° = 24°59.9999994' → rounds to 25°00.000', not 24°60.000'.
        #expect(CoordinateFormat.latitudeDDM(24.999_999_99) == "25°00.000'N")
        // Tiny negatives that round to zero do not print as south/west.
        #expect(CoordinateFormat.latitudeDDM(-0.000_000_1) == "00°00.000'N")
        #expect(CoordinateFormat.longitudeDDM(-0.000_000_1) == "000°00.000'E")
        #expect(CoordinateFormat.latitudeDDM(.nan) == "--")
    }

    @Test func formatDMSAndDecimal() {
        // 27.75205° = 27°45'07.38"; 82.6242667° = 82°37'27.36"
        #expect(CoordinateFormat.dms(skyway) == "27°45'07.4\"N 082°37'27.4\"W")
        #expect(CoordinateFormat.decimalDegrees(skyway, fractionDigits: 5) == "27.75205, -82.62427")
    }

    @Test(arguments: [
        "27°45.123'N 082°37.456'W",
        "27°45.123′N, 82°37.456′W",
        "N27°45.123' W082°37.456'",
        "N 27 45.123 W 82 37.456",
        "27 45.123N 82 37.456W",
        "082°37.456'W 27°45.123'N",          // longitude first, disambiguated by letters
        "27° 45.123' n  082° 37.456' w",     // lower-case, extra spaces
        "27 45.123, -82 37.456",             // signed, no letters
        "27.75205, -82.6242667",
        "27.75205 -82.6242667",
        "27°45'07.38\"N 82°37'27.36\"W",     // DMS
    ])
    func parsesMarineNotations(_ text: String) throws {
        let c = try CoordinateFormat.parse(text)
        #expect(close(c.latitude, skyway.latitude, 1e-6), "\(text)")
        #expect(close(c.longitude, skyway.longitude, 1e-6), "\(text)")
    }

    @Test func roundTripFormatParse() throws {
        for c in [skyway, Coordinate(latitude: -33.8568, longitude: 151.2153), Coordinate(latitude: 0, longitude: 0),
                  Coordinate(latitude: 30.1, longitude: -88.05), Coordinate(latitude: 89.999, longitude: -179.999)] {
            let parsed = try CoordinateFormat.parse(CoordinateFormat.ddm(c, fractionDigits: 4))
            // 0.0001 minute ≈ 0.19 m; 1.7e-6 degrees.
            #expect(close(parsed.latitude, c.latitude, 1e-6) && close(parsed.longitude, c.longitude, 1e-6))
        }
    }

    @Test func parseSingleComponents() throws {
        #expect(close(try CoordinateFormat.parseLatitude("27°45.123'N"), 27.75205, 1e-9))
        #expect(close(try CoordinateFormat.parseLatitude("S 33 51.5"), -(33 + 51.5 / 60), 1e-9))
        #expect(close(try CoordinateFormat.parseLatitude("-27.5"), -27.5, 1e-12))
        #expect(close(try CoordinateFormat.parseLongitude("082 37.456 W"), -(82 + 37.456 / 60), 1e-9))
        #expect(throws: CoordinateParseError.invalidHemisphere) { try CoordinateFormat.parseLatitude("82 37 W") }
        #expect(throws: CoordinateParseError.outOfRange) { try CoordinateFormat.parseLatitude("91 00 N") }
    }

    @Test func rejectsBadInput() {
        #expect(throws: CoordinateParseError.empty) { try CoordinateFormat.parse("   ") }
        #expect(throws: CoordinateParseError.unexpectedCharacter("X")) { try CoordinateFormat.parse("27 45 X 82 37 W") }
        #expect(throws: CoordinateParseError.invalidComponent("60.5")) { try CoordinateFormat.parse("27 60.5 N 82 37 W") }
        #expect(throws: CoordinateParseError.invalidComponent("45.5")) { try CoordinateFormat.parse("27 45.5 10 N 82 37 W") }
        #expect(throws: CoordinateParseError.invalidHemisphere) { try CoordinateFormat.parse("27 45 N 28 37 N") }
        #expect(throws: CoordinateParseError.invalidComponent("-27")) { try CoordinateFormat.parse("-27 45 N 82 37 W") }
        #expect(throws: CoordinateParseError.outOfRange) { try CoordinateFormat.parse("95.0, 10.0") }
        #expect(throws: CoordinateParseError.wrongComponentCount) { try CoordinateFormat.parse("27.5") }
        #expect(throws: CoordinateParseError.wrongComponentCount) { try CoordinateFormat.parse("27 45 30") }
        #expect(throws: CoordinateParseError.malformedNumber("1.2.3")) { try CoordinateFormat.parse("1.2.3, 4") }
        #expect(throws: CoordinateParseError.invalidHemisphere) { try CoordinateFormat.parse("27 45 N 82 37") }
        #expect(throws: (any Error).self) { try CoordinateFormat.parse("N W") }
    }
}
