import Foundation

/// One raster source + layer the map should add, in draw order.
public struct ChartLayerPlan: Equatable, Sendable {
    public var regionID: String
    public var sourceID: String
    public var layerID: String
    /// `mbtiles:///absolute/path/to/file.mbtiles`
    public var sourceURL: String
    /// Source zoom range (what the package actually contains).
    public var sourceMinZoom: Int
    public var sourceMaxZoom: Int
    /// Layer visibility range. MapLibre over-zooms the source's `maxzoom` tiles above it.
    public var layerMinZoom: Int
    public var layerMaxZoom: Int
    /// Set as the source `bounds` so MapLibre never requests (or draws empty tiles) outside the region.
    public var bounds: BoundingBox
    /// Regions this one overlaps and is drawn above.
    public var drawnAbove: [String]
}

public enum MapLibreSources {
    /// MapLibre's offline MBTiles URL for a local file: `mbtiles://` followed by the absolute path,
    /// giving the triple slash `mbtiles:///var/...`.
    ///
    /// By default the path is passed through verbatim, which is what MapLibre Native's MBTiles file
    /// source expects. Paths containing spaces or `%` are a risk (not verified against MapLibre's
    /// URL handling), so prefer an install root without them; `percentEncoded: true` is offered for
    /// the case where a MapLibre version turns out to decode the path.
    public static func sourceURL(forFileAt url: URL, percentEncoded: Bool = false) -> String {
        let path = url.standardizedFileURL.path
        if percentEncoded {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "%")
            return "mbtiles://" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
        }
        return "mbtiles://" + path
    }

    /// Draw order for installed regions, bottom first. When regions overlap, the one with the finer
    /// detail must be on top: higher max zoom wins, then the smaller area (a harbour package over a
    /// coastal one), then the newer data date, then the id (for a stable order).
    ///
    /// - Parameter overzoomMaxZoom: highest zoom at which layers stay visible (MapLibre over-zooms
    ///   from each source's own `maxzoom`). Default 22.
    public static func layerPlan(for regions: [InstalledRegion], resolveURL: (InstalledRegion) -> URL,
                                 overzoomMaxZoom: Int = 22, idPrefix: String = "chart") -> [ChartLayerPlan] {
        let ordered = regions.sorted { a, b in
            if a.maxZoom != b.maxZoom { return a.maxZoom < b.maxZoom }
            if a.bounds.areaDegrees != b.bounds.areaDegrees { return a.bounds.areaDegrees > b.bounds.areaDegrees }
            if a.chart.dataDate != b.chart.dataDate { return a.chart.dataDate < b.chart.dataDate }
            return a.id < b.id
        }
        var plans: [ChartLayerPlan] = []
        for (i, r) in ordered.enumerated() {
            let below = ordered[..<i].filter { $0.bounds.intersects(r.bounds) }.map(\.id)
            plans.append(ChartLayerPlan(
                regionID: r.id,
                sourceID: "\(idPrefix)-src-\(r.id)",
                layerID: "\(idPrefix)-layer-\(r.id)",
                sourceURL: sourceURL(forFileAt: resolveURL(r)),
                sourceMinZoom: r.minZoom,
                sourceMaxZoom: r.maxZoom,
                layerMinZoom: r.minZoom,
                layerMaxZoom: max(r.maxZoom, overzoomMaxZoom),
                bounds: r.bounds,
                drawnAbove: below))
        }
        return plans
    }
}
