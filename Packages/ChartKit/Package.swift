// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChartKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChartKit", targets: ["ChartKit"]),
    ],
    targets: [
        // On Linux we link the system libsqlite3 (libsqlite3-dev). Apple platforms use the SDK's SQLite3 module.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "ChartKit",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))]
        ),
        .testTarget(
            name: "ChartKitTests",
            dependencies: [
                "ChartKit",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
