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
        ),
        .library(
            name: "WildEdgeBenchmarks",
            targets: ["WildEdgeBenchmarks"]
        )
    ],
    targets: [
        .target(
            name: "WildEdgeLoader",
            path: "Sources/WildEdgeLoader",
            publicHeadersPath: ""
        ),
        .target(
            name: "WildEdge",
            dependencies: ["WildEdgeLoader"]
        ),
        .target(
            name: "WildEdgeBenchmarks",
            dependencies: ["WildEdge"],
            sources: [
                "WildEdgeBenchmarks.swift",
                "BlobStoreScenarios.swift",
                "BlobStoreBenchmarks.swift"
            ]
        ),
        .testTarget(
            name: "WildEdgeTests",
            dependencies: ["WildEdge", "WildEdgeBenchmarks"]
        )
    ]
)
