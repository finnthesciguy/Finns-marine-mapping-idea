// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(path: "../NavCore"),
        .package(path: "../GPXKit"),
    ],
    targets: [
        // On Linux we link the system libsqlite3 (libsqlite3-dev). Apple platforms use the SDK's SQLite3 module.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "NavCore", package: "NavCore"),
                .product(name: "GPXKit", package: "GPXKit"),
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: [
                "Persistence",
                .product(name: "NavCore", package: "NavCore"),
                .product(name: "GPXKit", package: "GPXKit"),
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
