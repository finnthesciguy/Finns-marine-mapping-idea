// swift-tools-version: 6.0
import PackageDescription

// Persistence cannot be linked next to ChartKit yet: both packages declare a target named `CSQLite`, and
// SwiftPM rejects the graph ("target names need to be unique across the package graph"). Once one of
// them is renamed (App/README.md, "Needed in existing packages"), set this to true: it adds the dependency
// and compiles PersistenceAcknowledgementStore and AppPaths.openStore().
let includePersistence = true

var serviceDependencies: [Target.Dependency] = [
    .product(name: "NavCore", package: "NavCore"),
    .product(name: "ChartKit", package: "ChartKit"),
]
var packageDependencies: [Package.Dependency] = [
    .package(path: "../NavCore"),
    .package(path: "../ChartKit"),
]
var serviceSettings: [SwiftSetting] = []
if includePersistence {
    serviceDependencies.append(.product(name: "Persistence", package: "Persistence"))
    packageDependencies.append(.package(path: "../Persistence"))
    serviceSettings.append(.define("APPSERVICES_PERSISTENCE"))
}

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
            dependencies: serviceDependencies,
            swiftSettings: serviceSettings
        ),
        .testTarget(
            name: "AppServicesTests",
            dependencies: [
                "AppServices",
                .product(name: "NavCore", package: "NavCore"),
                .product(name: "ChartKit", package: "ChartKit"),
            ],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
