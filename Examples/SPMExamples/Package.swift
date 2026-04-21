// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WildEdgeExamples",
    platforms: [
        .iOS(.v13),
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WildEdgeExamples", targets: ["WildEdgeExamples"])
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2")
    ],
    targets: [
        .executableTarget(
            name: "WildEdgeExamples",
            dependencies: [
                .product(name: "WildEdge", package: "wildedge-swift")
            ]
        ),
        .executableTarget(
            name: "OnnxExample",
            dependencies: [
                .product(name: "WildEdge", package: "wildedge-swift"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ]
        )
    ]
)
