import Foundation

extension OverlaySource {
    /// This source's GeoJSON in `overlays`.
    public func data(in overlays: MapOverlays) -> Data {
        switch self {
        case .tracks: return overlays.tracks
        case .routeLegs: return overlays.routeLegs
        case .routePoints: return overlays.routePoints
        case .direct: return overlays.direct
        case .planned: return overlays.planned
        case .blocked: return overlays.blocked
        case .waypoints: return overlays.waypoints
        }
    }
}
