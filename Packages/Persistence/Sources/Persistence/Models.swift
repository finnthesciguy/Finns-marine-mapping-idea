import Foundation
import NavCore

/// The kinds of entity the store holds; also the channels of the change feed.
public enum EntityKind: String, Sendable, Hashable, CaseIterable, Codable {
    case waypoint, route, track, boatProfile, setting, anchorWatch
}

// MARK: - Waypoint

/// A user waypoint.
public struct Waypoint: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var coordinate: Coordinate
    /// Symbol name (GPX `<sym>` vocabulary, e.g. `"anchor"`), nil for the app default.
    public var symbol: String?
    public var notes: String
    /// Set when first saved; preserved by later saves.
    public var createdAt: Date
    /// Stamped by the store on every save.
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, coordinate: Coordinate, symbol: String? = nil, notes: String = "",
                createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.symbol = symbol
        self.notes = notes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }
}

/// Sort orders for waypoint and route lists.
public enum ListOrder: Sendable, Hashable {
    /// Case-insensitive name, then creation date.
    case name
    /// Newest first.
    case newestFirst
    /// Most recently modified first.
    case recentlyModified
}

// MARK: - Route

/// One point of a route.
public struct RoutePoint: Hashable, Sendable, Codable {
    public var coordinate: Coordinate
    public var name: String?

    public init(coordinate: Coordinate, name: String? = nil) {
        self.coordinate = coordinate
        self.name = name
    }
}

/// A planned route: an ordered list of points, optionally produced by the auto-router.
public struct Route: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    /// Points in navigation order. Order is preserved exactly by the store.
    public var points: [RoutePoint]
    /// Present for auto-generated routes. See ``RouteMetadata``.
    public var metadata: RouteMetadata?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, notes: String = "", points: [RoutePoint] = [],
                metadata: RouteMetadata? = nil, createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.notes = notes
        self.points = points
        self.metadata = metadata
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    /// Total great-circle length of the route, metres (ellipsoidal).
    public var length: Distance {
        Distance(meters: zip(points, points.dropFirst()).reduce(0) {
            $0 + Geodesy.distance(from: $1.0.coordinate, to: $1.1.coordinate)
        })
    }
}

/// Opaque, versioned JSON describing how a route was generated.
///
/// Stored as a blob next to the route so the routing engine's types can evolve without a database
/// schema change. ``AutoRouteInfo`` is the format this package understands (version 1); a newer
/// writer can store a higher `version` and older readers still load the route (they just cannot decode
/// the details). Unknown JSON keys are ignored by ``AutoRouteInfo`` and preserved in ``json``.
public struct RouteMetadata: Hashable, Sendable {
    /// Format version of ``json``.
    public var version: Int
    /// UTF-8 JSON.
    public var json: Data

    public init(version: Int, json: Data) {
        self.version = version
        self.json = json
    }

    /// Encodes any value as metadata.
    public init<T: Encodable>(version: Int, encoding value: T) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.init(version: version, json: try e.encode(value))
    }

    /// Wraps an ``AutoRouteInfo`` as version ``AutoRouteInfo/formatVersion``.
    public init(_ info: AutoRouteInfo) throws {
        try self.init(version: AutoRouteInfo.formatVersion, encoding: info)
    }

    /// Decodes the JSON as `type`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(type, from: json)
    }

    /// The details as ``AutoRouteInfo`` when the version is one this package reads, else nil.
    public var autoRouteInfo: AutoRouteInfo? {
        guard version == AutoRouteInfo.formatVersion else { return nil }
        return try? decode(AutoRouteInfo.self)
    }
}

/// Safety grade of a route leg. An open set of values so the routing engine can add grades.
public struct LegGrade: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let green = LegGrade(rawValue: "green")
    public static let yellow = LegGrade(rawValue: "yellow")
    public static let red = LegGrade(rawValue: "red")
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Version-1 description of an auto-generated route (see ``RouteMetadata``).
public struct AutoRouteInfo: Hashable, Sendable, Codable {
    /// The ``RouteMetadata/version`` this type is stored under.
    public static let formatVersion = 1

    /// Boat dimensions used for the calculation (a snapshot; the profile may later change or be deleted).
    public struct BoatSnapshot: Hashable, Sendable, Codable {
        public var profileID: UUID?
        public var name: String
        public var draftMeters: Double
        public var safetyMarginMeters: Double
        public var airDraftMeters: Double?
        public var useMaintainedChannels: Bool
        public var acceptUnknownClearance: Bool

        public init(profileID: UUID? = nil, name: String, draftMeters: Double, safetyMarginMeters: Double,
                    airDraftMeters: Double? = nil, useMaintainedChannels: Bool, acceptUnknownClearance: Bool) {
            self.profileID = profileID
            self.name = name
            self.draftMeters = draftMeters
            self.safetyMarginMeters = safetyMarginMeters
            self.airDraftMeters = airDraftMeters
            self.useMaintainedChannels = useMaintainedChannels
            self.acceptUnknownClearance = acceptUnknownClearance
        }

        /// Snapshot of a stored profile.
        public init(_ p: BoatProfile) {
            self.init(profileID: p.id, name: p.name, draftMeters: p.draft.meters, safetyMarginMeters: p.safetyMargin.meters,
                      airDraftMeters: p.airDraft?.meters, useMaintainedChannels: p.useMaintainedChannels,
                      acceptUnknownClearance: p.acceptUnknownClearance)
        }
    }

    /// Grade of the leg from point `index` to point `index + 1`.
    public struct Leg: Hashable, Sendable, Codable {
        public var index: Int
        public var grade: LegGrade
        /// Machine-readable reasons, e.g. `"maintained-channel-depth"`, `"unknown-clearance"`.
        public var reasonCodes: [String]
        public var leastDepthMeters: Double?
        public var leastClearanceMeters: Double?

        public init(index: Int, grade: LegGrade, reasonCodes: [String] = [], leastDepthMeters: Double? = nil,
                    leastClearanceMeters: Double? = nil) {
            self.index = index
            self.grade = grade
            self.reasonCodes = reasonCodes
            self.leastDepthMeters = leastDepthMeters
            self.leastClearanceMeters = leastClearanceMeters
        }
    }

    /// Whole-route summary shown before the skipper accepts the route.
    public struct Summary: Hashable, Sendable, Codable {
        public var distanceMeters: Double?
        public var shallowestDepthMeters: Double?
        public var lowestClearanceMeters: Double?
        public var worstGrade: LegGrade?

        public init(distanceMeters: Double? = nil, shallowestDepthMeters: Double? = nil,
                    lowestClearanceMeters: Double? = nil, worstGrade: LegGrade? = nil) {
            self.distanceMeters = distanceMeters
            self.shallowestDepthMeters = shallowestDepthMeters
            self.lowestClearanceMeters = lowestClearanceMeters
            self.worstGrade = worstGrade
        }
    }

    public var boat: BoatSnapshot
    public var legs: [Leg]
    public var summary: Summary
    /// Date of the chart data the routing pack was built from.
    public var routingPackDataDate: Date?
    /// Identifier/version of the routing pack, e.g. `"tampa-2026-11-10"`.
    public var routingPackVersion: String?
    public var generatedAt: Date

    public init(boat: BoatSnapshot, legs: [Leg], summary: Summary, routingPackDataDate: Date? = nil,
                routingPackVersion: String? = nil, generatedAt: Date = Date()) {
        self.boat = boat
        self.legs = legs
        self.summary = summary
        self.routingPackDataDate = routingPackDataDate
        self.routingPackVersion = routingPackVersion
        self.generatedAt = generatedAt
    }
}

// MARK: - Track

/// One recorded position.
public struct TrackPoint: Hashable, Sendable, Codable {
    /// Nil only for imported points whose file had no time.
    public var timestamp: Date?
    public var coordinate: Coordinate
    /// Speed over ground, m/s.
    public var speed: Double?
    /// Course over ground, degrees true.
    public var course: Double?
    /// Horizontal accuracy, metres.
    public var horizontalAccuracy: Double?

    public init(timestamp: Date?, coordinate: Coordinate, speed: Double? = nil, course: Double? = nil,
                horizontalAccuracy: Double? = nil) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
    }

    /// Creates a point from a NavCore fix.
    public init(_ fix: Fix) {
        self.init(timestamp: fix.timestamp, coordinate: fix.coordinate, speed: fix.speed, course: fix.course,
                  horizontalAccuracy: fix.horizontalAccuracy)
    }
}

/// An sRGB colour stored as `#RRGGBB`.
public struct TrackColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` or `RRGGBB`.
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: UInt8((v >> 16) & 0xFF), green: UInt8((v >> 8) & 0xFF), blue: UInt8(v & 0xFF))
    }

    public var hex: String {
        let v = (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
        let s = String(v, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - s.count) + s
    }

    public var description: String { hex }

    /// Default track colour (a magenta that reads on paper-chart colours).
    public static let defaultTrack = TrackColor(red: 0xD0, green: 0x20, blue: 0x90)
}

/// Summary statistics of a track, maintained incrementally while recording.
public struct TrackStatistics: Hashable, Sendable {
    public var pointCount: Int
    public var segmentCount: Int
    /// Sum of leg distances within segments (gaps between segments are not counted).
    public var distance: Distance
    /// Time spent recording: sum of each segment's time span, seconds.
    public var duration: TimeInterval
    /// Highest reported speed; where a point has no reported speed, the speed derived from the previous
    /// point in the same segment (only for steps of at least one second).
    public var maxSpeed: Speed?
    /// `distance / duration`, nil when duration is zero.
    public var averageSpeed: Speed? {
        duration > 0 ? Speed(metersPerSecond: distance.meters / duration) : nil
    }
    /// Bounds of all points, nil when empty.
    public var bounds: BoundingBox?

    public init(pointCount: Int = 0, segmentCount: Int = 0, distance: Distance = .meters(0), duration: TimeInterval = 0,
                maxSpeed: Speed? = nil, bounds: BoundingBox? = nil) {
        self.pointCount = pointCount
        self.segmentCount = segmentCount
        self.distance = distance
        self.duration = duration
        self.maxSpeed = maxSpeed
        self.bounds = bounds
    }
}

/// A recorded or imported track (its points are fetched separately; see ``PersistenceStore/trackPoints(_:)``).
public struct Track: Identifiable, Hashable, Sendable {
    /// Recording state.
    public enum State: Int, Hashable, Sendable {
        /// Complete.
        case finished = 0
        /// Being recorded — or, if found at launch, interrupted by app termination.
        case recording = 1
    }

    public var id: UUID
    public var name: String
    public var notes: String
    public var color: TrackColor
    public var state: State
    /// Time of the first point (or creation time when empty).
    public var startDate: Date?
    /// Time of the last point.
    public var endDate: Date?
    public var statistics: TrackStatistics
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, notes: String = "", color: TrackColor = .defaultTrack,
                state: State = .finished, startDate: Date? = nil, endDate: Date? = nil,
                statistics: TrackStatistics = TrackStatistics(), createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.notes = notes
        self.color = color
        self.state = state
        self.startDate = startDate
        self.endDate = endDate
        self.statistics = statistics
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }
}

// MARK: - Boat profile

/// The boat's dimensions and routing preferences.
public struct BoatProfile: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var draft: Distance
    /// Extra depth under the keel required on top of the draft.
    public var safetyMargin: Distance
    /// Height above the waterline; nil if unknown (bridges/cables are then not checked).
    public var airDraft: Distance?
    public var beam: Distance?
    public var cruisingSpeed: Speed?
    /// Allow legs that rely on Army Corps maintained (project) channel depth (graded yellow).
    public var useMaintainedChannels: Bool
    /// Allow passing under bridges/cables whose clearance is not charted (graded yellow).
    public var acceptUnknownClearance: Bool
    /// Exactly one profile at most is the default; the store enforces this.
    public var isDefault: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, draft: Distance, safetyMargin: Distance = .feet(1),
                airDraft: Distance? = nil, beam: Distance? = nil, cruisingSpeed: Speed? = nil,
                useMaintainedChannels: Bool = false, acceptUnknownClearance: Bool = false, isDefault: Bool = false,
                createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.draft = draft
        self.safetyMargin = safetyMargin
        self.airDraft = airDraft
        self.beam = beam
        self.cruisingSpeed = cruisingSpeed
        self.useMaintainedChannels = useMaintainedChannels
        self.acceptUnknownClearance = acceptUnknownClearance
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    /// Minimum charted depth the boat needs: draft plus safety margin.
    public var requiredDepth: Distance { draft + safetyMargin }
}

// MARK: - Anchor watch

/// Persisted anchor-watch state, so an active alarm survives the app being terminated and relaunched.
public struct AnchorWatchState: Hashable, Sendable, Codable {
    public var anchor: Coordinate
    public var configuration: AnchorAlarmConfiguration
    public var droppedAt: Date
    /// Last confirmed alarm state (restore it so a latched "dragging" is not lost on relaunch).
    public var lastState: AnchorAlarmState
    public var maximumDistance: Double
    public var lastFixAt: Date?

    public init(anchor: Coordinate, configuration: AnchorAlarmConfiguration, droppedAt: Date = Date(),
                lastState: AnchorAlarmState = .inside, maximumDistance: Double = 0, lastFixAt: Date? = nil) {
        self.anchor = anchor
        self.configuration = configuration
        self.droppedAt = droppedAt
        self.lastState = lastState
        self.maximumDistance = maximumDistance
        self.lastFixAt = lastFixAt
    }

    /// Snapshot of a live alarm.
    public init(_ alarm: AnchorAlarm, droppedAt: Date, lastFixAt: Date? = nil) {
        self.init(anchor: alarm.anchor, configuration: alarm.configuration, droppedAt: droppedAt,
                  lastState: alarm.state, maximumDistance: alarm.maximumDistance, lastFixAt: lastFixAt)
    }
}
