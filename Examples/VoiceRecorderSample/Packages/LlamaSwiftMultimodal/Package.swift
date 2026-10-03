// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LlamaSwiftMultimodal",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "LlamaSwift",
            targets: ["LlamaSwift"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "llama-cpp-multimodal",
            path: "Artifacts/llama.xcframework"
        ),
        .target(
            name: "LlamaSwift",
            dependencies: ["llama-cpp-multimodal"],
            path: "Sources/LlamaSwift"
        ),
    ]
)
