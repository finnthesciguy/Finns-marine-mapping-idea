import Foundation
import NavCore

/// A GPX document: metadata plus waypoints, routes and tracks.
public struct GPXDocument: Hashable, Sendable {
    /// Application that created the file (`creator` attribute). Required by GPX 1.1.
    public var creator: String
    /// GPX version the file declared when it was read (`"1.0"` or `"1.1"`); writing always emits 1.1.
    public var version: String
    /// File-level metadata.
    public var metadata: GPXMetadata
    /// Stand-alone waypoints (`<wpt>`).
    public var waypoints: [GPXWaypoint]
    /// Routes (`<rte>`).
    public var routes: [GPXRoute]
    /// Tracks (`<trk>`).
    public var tracks: [GPXTrack]

    /// Creates a document.
    public init(
        creator: String = "GPXKit",
        version: String = "1.1",
        metadata: GPXMetadata = GPXMetadata(),
        waypoints: [GPXWaypoint] = [],
        routes: [GPXRoute] = [],
        tracks: [GPXTrack] = []
    ) {
        self.creator = creator
        self.version = version
        self.metadata = metadata
        self.waypoints = waypoints
        self.routes = routes
        self.tracks = tracks
    }
}

/// File-level metadata (`<metadata>` in GPX 1.1; top-level elements in GPX 1.0).
public struct GPXMetadata: Hashable, Sendable {
    /// File name/title.
    public var name: String?
    /// Description.
    public var description: String?
    /// Author name (`<author><name>` in 1.1, `<author>` in 1.0).
    public var author: String?
    /// Creation time.
    public var time: Date?
    /// Keywords.
    public var keywords: String?

    /// Creates metadata.
    public init(name: String? = nil, description: String? = nil, author: String? = nil, time: Date? = nil, keywords: String? = nil) {
        self.name = name
        self.description = description
        self.author = author
        self.time = time
        self.keywords = keywords
    }

    /// True when no field is set.
    public var isEmpty: Bool { name == nil && description == nil && author == nil && time == nil && keywords == nil }
}

/// A point: used for waypoints (`<wpt>`), route points (`<rtept>`) and track points (`<trkpt>`).
public struct GPXWaypoint: Hashable, Sendable {
    /// Position (WGS84).
    public var coordinate: Coordinate
    /// Elevation in metres (`<ele>`).
    public var elevation: Double?
    /// Time (`<time>`, UTC).
    public var time: Date?
    /// Name (`<name>`).
    public var name: String?
    /// Comment (`<cmt>`).
    public var comment: String?
    /// Description (`<desc>`).
    public var description: String?
    /// Symbol name (`<sym>`), e.g. `"anchor"`, `"Flag, Blue"`.
    public var symbol: String?
    /// Classification (`<type>`).
    public var type: String?
    /// Speed in m/s. Read from GPX 1.0 `<speed>`; not written (GPX 1.1 has no such element).
    public var speed: Double?
    /// Course in degrees true. Read from GPX 1.0 `<course>`; not written.
    public var course: Double?

    /// Creates a point.
    public init(
        coordinate: Coordinate,
        elevation: Double? = nil,
        time: Date? = nil,
        name: String? = nil,
        comment: String? = nil,
        description: String? = nil,
        symbol: String? = nil,
        type: String? = nil,
        speed: Double? = nil,
        course: Double? = nil
    ) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.time = time
        self.name = name
        self.comment = comment
        self.description = description
        self.symbol = symbol
        self.type = type
        self.speed = speed
        self.course = course
    }

    /// Creates a point from latitude and longitude in degrees.
    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.init(coordinate: Coordinate(latitude: latitude, longitude: longitude), name: name)
    }
}

/// A route: an ordered list of points to navigate through.
public struct GPXRoute: Hashable, Sendable {
    /// Route name.
    public var name: String?
    /// Comment.
    public var comment: String?
    /// Description.
    public var description: String?
    /// Classification.
    public var type: String?
    /// Route points in order.
    public var points: [GPXWaypoint]

    /// Creates a route.
    public init(name: String? = nil, comment: String? = nil, description: String? = nil, type: String? = nil, points: [GPXWaypoint] = []) {
        self.name = name
        self.comment = comment
        self.description = description
        self.type = type
        self.points = points
    }
}

/// A track: a recorded path made of one or more segments.
public struct GPXTrack: Hashable, Sendable {
    /// Track name.
    public var name: String?
    /// Comment.
    public var comment: String?
    /// Description.
    public var description: String?
    /// Classification.
    public var type: String?
    /// Segments; a new segment usually starts after a loss of GPS fix.
    public var segments: [GPXTrackSegment]

    /// Creates a track.
    public init(name: String? = nil, comment: String? = nil, description: String? = nil, type: String? = nil, segments: [GPXTrackSegment] = []) {
        self.name = name
        self.comment = comment
        self.description = description
        self.type = type
        self.segments = segments
    }
}

/// A continuous run of track points.
public struct GPXTrackSegment: Hashable, Sendable {
    /// Points in time order.
    public var points: [GPXWaypoint]

    /// Creates a segment.
    public init(points: [GPXWaypoint] = []) {
        self.points = points
    }
}
