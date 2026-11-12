// swift-tools-version: 6.0
import PackageDescription

// Persistence is a hard dependency: the store for waypoints, routes, tracks and settings. (Its SQLite shim
// target is named `PersistenceCSQLite` so it can sit next to ChartKit's `CSQLite` in one package graph.)
let serviceDependencies: [Target.Dependency] = [
    .product(name: "NavCore", package: "NavCore"),
    .product(name: "ChartKit", package: "ChartKit"),
    .product(name: "Persistence", package: "Persistence"),
    .product(name: "GPXKit", package: "GPXKit"),
]
let packageDependencies: [Package.Dependency] = [
    .package(path: "../NavCore"),
    .package(path: "../ChartKit"),
    .package(path: "../Persistence"),
    .package(path: "../GPXKit"),
]

let package = Package(
    name: "AppServices",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AppServices", targets: ["AppServices"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // Thin adapters for the app. CoreLocationService is iOS-only (#if os(iOS)); everything else,
        // including URLSessionChartTransport (via FoundationNetworking), builds and is tested on Linux.
        .target(
            name: "AppServices",
            dependencies: serviceDependencies
        ),
        .testTarget(
            name: "AppServicesTests",
            dependencies: [
                "AppServices",
                .product(name: "NavCore", package: "NavCore"),
                .product(name: "ChartKit", package: "ChartKit"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "GPXKit", package: "GPXKit"),
            ],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
