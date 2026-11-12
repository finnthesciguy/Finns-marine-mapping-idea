import Foundation
import NavCore

/// Coordinate scale of the pack: 1 unit = 1e-7 degree (spec A.1).
public let routingUnitsPerDegree: Double = 1e7

/// A point in pack units (1e-7 degree). `x` is longitude, `y` latitude.
public struct GridPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Int32
    public var y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }

    /// Degrees, computed as `Double(units) / 1e7` (spec A.1).
    public var coordinate: Coordinate {
        Coordinate(latitude: Double(y) / 1e7, longitude: Double(x) / 1e7)
    }

    public var description: String { "(\(x), \(y))" }
}

/// A `yyyymmdd` date as stored in the pack (0 = unknown).
public struct PackDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public var isKnown: Bool { rawValue != 0 }
    public var year: Int { Int(rawValue / 10000) }
    public var month: Int { Int(rawValue / 100 % 100) }
    public var day: Int { Int(rawValue % 100) }

    /// Midnight UTC of the date, or nil when unknown or not a valid calendar date.
    public var date: Date? {
        guard isKnown else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: year, month: month, day: day)
        guard comps.isValidDate(in: cal) else { return nil }
        return cal.date(from: comps)
    }

    public static func < (a: PackDate, b: PackDate) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        guard isKnown else { return "unknown" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// The 256-byte header (spec A.3).
public struct PackHeader: Hashable, Sendable {
    public var formatMajor: Int
    public var formatMinor: Int
    public var headerSize: Int
    public var fileSize: Int
    public var sectionCount: Int
    public var sectionTableOffset: Int
    public var flags: UInt32
    public var regionID: String
    public var minLon: Int32
    public var minLat: Int32
    public var maxLon: Int32
    public var maxLat: Int32
    /// Newest ENC issue date that contributed data: the "chart data date" shown to the user.
    public var dataDate: PackDate
    public var buildDate: PackDate
    /// `hhmmss` UTC.
    public var buildTime: UInt32
    public var vertexCount: Int
    public var triangleCount: Int
    /// Safety clearance by which water was shrunk from land and structures, dm.
    public var clearanceDm: Int
    /// Hazard radius used by leg validation (B.10), dm.
    public var checkDm: Int
    public var shoreRing0M: Int
    public var shoreRing1M: Int
    public var headerCRC32: UInt32

    /// True when header flag bit 0 says an `ADJC` section is present.
    public var hasStoredAdjacency: Bool { flags & 1 != 0 }
}

/// One section-table entry (spec A.4).
public struct PackSection: Hashable, Sendable {
    public var tag: String
    public var encoding: Int
    public var offset: UInt64
    public var storedLength: Int
    public var rawLength: Int
    public var crc32: UInt32
    public var count: Int
}

/// `SRCS` record: an ENC cell that the pack was built from.
public struct SourceCell: Hashable, Sendable {
    public var name: UInt32
    public var edition: UInt16
    public var update: UInt16
    public var issueDate: PackDate
    public var compilationScale: UInt32
    public var usageBand: UInt8
    public var used: Bool
}

/// Geometry type of an `OVHD`/`HAZD` record.
public enum PackGeometryType: UInt8, Hashable, Sendable {
    case point = 1, polyline = 2, ring = 3
}

/// `OVHD` record: bridge part, overhead cable or pipe.
public struct OverheadObject: Hashable, Sendable {
    /// 1 bridge part, 2 overhead cable, 3 overhead pipe.
    public var kind: UInt8
    /// Bit 0 opening span; bit 1 clearance not charted (solid).
    public var flags: UInt8
    public var catbrg: UInt16
    /// Closed clearance (dm) for an opening span, else VERCLR; `0xFFFE` unknown.
    public var clearanceDm: UInt16
    public var openClearanceDm: UInt16
    public var horizontalClearanceDm: UInt16
    public var name: UInt32
    public var lon: Int32
    public var lat: Int32
    public var geomFirst: UInt32
    public var geomCount: UInt32
    public var geomType: PackGeometryType

    public var isOpeningSpan: Bool { flags & 1 != 0 }
}

/// `HAZD` record: obstruction, wreck or rock.
public struct Hazard: Hashable, Sendable {
    /// 1 OBSTRN, 2 WRECKS, 3 UWTROC.
    public var cls: UInt8
    public var watlev: UInt8
    public var category: UInt8
    public var geomType: PackGeometryType
    /// Least depth (dm), `-32768` unknown.
    public var valsouDm: Int16
    public var lon: Int32
    public var lat: Int32
    public var geomFirst: UInt32
    public var geomCount: UInt32
    public var name: UInt32
}

/// `CHAN` record: a named channel.
public struct Channel: Hashable, Sendable {
    /// 1 USACE NCF reach, 2 ENC FAIRWY, 3 ENC DRGARE, 4 ENC RECTRC/NAVLNE.
    public var source: UInt8
    public var flags: UInt8
    public var maintDm: Int16
    public var authDm: Int16
    public var name: UInt32
    public var ident: UInt32
    public var desc: UInt32
    public var date: PackDate
    public var lon: Int32
    public var lat: Int32

    public var isIntracoastalWaterway: Bool { flags & 1 != 0 }
}

/// `AREA` record: a regulated area.
public struct RegulatedArea: Hashable, Sendable {
    /// 1 prohibited, 2 restricted, 3 caution.
    public var kind: UInt8
    /// 1 RESARE, 2 CTNARE.
    public var source: UInt8
    public var name: UInt32
    public var text: UInt32
    public var lon: Int32
    public var lat: Int32
}

/// The per-triangle `ATTR` columns of one triangle (spec A.5).
public struct TriangleAttributes: Hashable, Sendable {
    public var depthDm: Int16
    public var bandDepthDm: Int16
    public var maintDm: Int16
    public var clearanceDm: UInt16
    public var flags: UInt16
    public var channel: UInt16
    public var overhead: UInt16
    public var area: UInt16
    public var quality: UInt8

    /// CATZOC code (0 unknown, 1 A1, 2 A2, 3 B, 4 C, 5 D, 6 U).
    public var catzoc: Int { Int(quality & 7) }
    /// Survey decade start year, or nil when unknown.
    public var surveyDecade: Int? {
        let d = Int(quality >> 3)
        return d == 0 ? nil : 1850 + 10 * d
    }
    /// Shore class from flags bits 11-12.
    public var shoreClass: Int { Int((flags >> 11) & 3) }
}

/// Triangle flag bits (spec A.5 ATTR flags).
public struct TriangleFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let channel = TriangleFlags(rawValue: 1 << 0)
    public static let highway = TriangleFlags(rawValue: 1 << 1)
    public static let openingBridge = TriangleFlags(rawValue: 1 << 2)
    public static let unknownClearance = TriangleFlags(rawValue: 1 << 3)
    public static let restricted = TriangleFlags(rawValue: 1 << 4)
    public static let caution = TriangleFlags(rawValue: 1 << 5)
    public static let nearHazard = TriangleFlags(rawValue: 1 << 6)
    public static let hazardDepth = TriangleFlags(rawValue: 1 << 7)
    public static let prohibited = TriangleFlags(rawValue: 1 << 8)
    public static let outside = TriangleFlags(rawValue: 1 << 9)
    public static let soundingRefined = TriangleFlags(rawValue: 1 << 10)
}

/// Sentinels used in the pack.
public enum PackSentinel {
    /// "No depth" in depth columns and valsou.
    public static let noDepth: Int16 = -32768
    /// "No overhead object" in clearance_dm.
    public static let noOverhead: UInt16 = 0xFFFF
    /// "Unknown clearance".
    public static let unknownClearance: UInt16 = 0xFFFE
    /// "No record" in channel/overhead/area indices.
    public static let noIndex: UInt16 = 0xFFFF
}
