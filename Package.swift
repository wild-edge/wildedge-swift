// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WildEdge",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "WildEdge",
            targets: ["WildEdge"]
        )
    ],
    targets: [
        .target(
            name: "WildEdge"
        ),
        .testTarget(
            name: "WildEdgeTests",
            dependencies: ["WildEdge"]
        )
    ]
)
