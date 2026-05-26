// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlamaPackage",
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [
        // Run setup.sh once before opening Xcode to populate this path.
        .binaryTarget(
            name: "llama",
            path: "Frameworks/llama.xcframework"
        )
    ]
)
