import Foundation

extension AppPaths {
    /// The Mac build's data root: `<Application Support>/<bundle identifier>/` (the macOS convention for an
    /// app's own files). Inside the app sandbox, Application Support is the container's
    /// (`~/Library/Containers/<id>/Data/Library/Application Support`), so nothing is shared with other apps.
    /// The usual subfolders (`Charts`, `AppData`, `RoutingPacks`) go below it. Charts are read by MapKit through
    /// ChartKit on the Mac, not through MapLibre `mbtiles://` URLs, so the space in "Application Support" does
    /// not matter there.
    public static func macRoot(applicationSupport: URL, bundleIdentifier: String?) -> URL {
        var name: String = bundleIdentifier ?? ""
        if name.isEmpty || name.contains("/") {
            name = "GulfNav"
        }
        return applicationSupport.appendingPathComponent(name, isDirectory: true)
    }
}
