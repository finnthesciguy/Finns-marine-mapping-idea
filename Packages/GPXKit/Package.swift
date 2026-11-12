// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GPXKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GPXKit", targets: ["GPXKit"]),
    ],
    dependencies: [
        .package(path: "../NavCore"),
    ],
    targets: [
        .target(
            name: "GPXKit",
            dependencies: [.product(name: "NavCore", package: "NavCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GPXKitTests",
            dependencies: ["GPXKit"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
