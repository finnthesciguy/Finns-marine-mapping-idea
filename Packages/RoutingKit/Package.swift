// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoutingKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RoutingKit", targets: ["RoutingKit"]),
    ],
    dependencies: [
        .package(path: "../NavCore"),
    ],
    targets: [
        // Pure Swift: zlib streams are inflated by RoutingKit's own INFLATE (Inflate.swift), so there is
        // no system library to link on any platform.
        .target(
            name: "RoutingKit",
            dependencies: [.product(name: "NavCore", package: "NavCore")]
        ),
        .testTarget(
            name: "RoutingKitTests",
            dependencies: [
                "RoutingKit",
                .product(name: "NavCore", package: "NavCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
