// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WildEdgeExamples",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .executable(name: "WildEdgeExamples", targets: ["WildEdgeExamples"])
    ],
    dependencies: [
        .package(path: "../WildEdge")
    ],
    targets: [
        .executableTarget(
            name: "WildEdgeExamples",
            dependencies: [
                .product(name: "WildEdge", package: "WildEdge")
            ]
        )
    ]
)
