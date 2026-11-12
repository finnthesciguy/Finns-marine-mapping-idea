// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NavCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NavCore", targets: ["NavCore"]),
    ],
    targets: [
        .target(
            name: "NavCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NavCoreTests",
            dependencies: ["NavCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
