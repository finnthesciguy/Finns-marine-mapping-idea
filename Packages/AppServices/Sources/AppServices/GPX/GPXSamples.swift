import Foundation

/// A small GPX document (two waypoints, a route and a short track in lower Tampa Bay) used by the debug
/// menu's "Import sample GPX" and by the UI tests to exercise the import plan without a file picker.
/// Approximate positions; not for navigation.
public enum GPXSamples {
    public static let tampaBay: String = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="Gulf Nav sample" xmlns="http://www.topografix.com/GPX/1/1">
      <wpt lat="27.6010" lon="-82.7330"><name>Sample Egmont Channel</name><sym>Waypoint</sym></wpt>
      <wpt lat="27.6230" lon="-82.6500"><name>Sample Skyway</name><sym>Danger Area</sym><desc>Bridge</desc></wpt>
      <rte>
        <name>Sample Bay Run</name>
        <rtept lat="27.6010" lon="-82.7330"><name>Start</name></rtept>
        <rtept lat="27.6160" lon="-82.6700"></rtept>
        <rtept lat="27.6420" lon="-82.6250"><name>End</name></rtept>
      </rte>
      <trk>
        <name>Sample Track</name>
        <trkseg>
          <trkpt lat="27.6010" lon="-82.7330"><time>2026-11-01T14:00:00Z</time></trkpt>
          <trkpt lat="27.6050" lon="-82.7160"><time>2026-11-01T14:05:00Z</time></trkpt>
          <trkpt lat="27.6090" lon="-82.7000"><time>2026-11-01T14:10:00Z</time></trkpt>
        </trkseg>
      </trk>
    </gpx>
    """
}
