// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnnxExample",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2")
    ],
    targets: [
        .executableTarget(
            name: "OnnxExample",
            dependencies: [
                .product(name: "WildEdge", package: "wildedge-swift"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            resources: [
                .copy("add_mul_add.onnx")
            ]
        )
    ]
)
