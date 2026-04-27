# WildEdge Swift SDK

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B%20%7C%20macOS%2012%2B-brightgreen.svg)](Package.swift)

On-device ML inference monitoring for Swift (iOS, macOS). Tracks latency, confidence,
drift, and hardware metrics without ever sending raw inputs.

## Repository overview

| Sample | What it shows |
|---|---|
| [Sources](Sources) | SDK source code |
| [iOSAppSample](Examples/iOSAppSample) | iOS app integration using SwiftUI |
| [SPMExamples](Examples/SPMExamples) | Swift Package examples runnable from the terminal or Xcode |
| [OnnxExample](Examples/OnnxExample) | Zero-code ONNX Runtime tracking via auto-interceptor |
| [MLKitExample](Examples/MLKitExample) | Zero-code ML Kit tracking via auto-interceptor |
| [TFLiteExample](Examples/TFLiteExample) | TensorFlow Lite manual inference tracking |
| [TracingExample.swift](Examples/SPMExamples/Sources/WildEdgeExamples/TracingExample.swift) | Multi-step tracing with spans |


## Get a DSN from WildEdge

To run the examples or use the SDK in your application, you need a WildEdge DSN.
A DSN is a single configuration value that contains your Project Key and connection details for the WildEdge API. To get your DSN:

1. Navigate to `https://wildedge.dev/` and sign up or log in.
2. Open the dashboard at `https://app.wildedge.dev/`.
3. Create a project (or open an existing project).
4. Copy the project DSN for later.

## Add the SDK to your project

Add the WildEdge Swift SDK dependency to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/wild-edge/wildedge-swift.git", branch: "main")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "WildEdge", package: "wildedge-swift")
        ]
    )
]
```

#### Alternative to editing Package.swift: add the SDK in Xcode

1. Open your project in Xcode.
2. Go to `File > Add Package Dependencies...`.
3. Add: https://github.com/wild-edge/wildedge-swift.git
4. Select product `WildEdge`.

## Setup

### Auto-init (recommended)

The SDK initializes itself before `main()` runs. Provide the DSN via either:

**Environment variable** (Xcode scheme or process environment):
```
WILDEDGE_DSN=https://<secret>@ingest.wildedge.dev/<key>
```

**Info.plist** (checked as fallback when the env var is absent):
```xml
<key>WILDEDGE_DSN</key>
<string>https://<secret>@ingest.wildedge.dev/<key></string>
```

`WildEdge.shared` is then ready for use anywhere in your app. Set `WILDEDGE_DEBUG=true` (env var) to see verbose auto-init and event logs.

### Manual init

Call `WildEdge.initialize` explicitly when you need programmatic control (e.g. reading the DSN from a config file):

```swift
import WildEdge

let wildEdge: WildEdgeClient = WildEdge.initialize { builder in
    builder.dsn = "https://<secret>@ingest.wildedge.dev/<key>"
    // builder.debug = true
}
```

For iOS, call this at `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. If no DSN is set, `WildEdge.initialize` returns a no-op client.

## Usage

### ONNX Runtime — zero-code integration

The SDK automatically intercepts `ORTSession` creation and `run` calls at the ObjC runtime level — no import or code changes needed. Just run your existing ONNX code and events appear in the dashboard:

```swift
import OnnxRuntimeBindings
// No WildEdge calls required.

let env = try ORTEnv(loggingLevel: .warning)
let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
let outputs = try session.run(withInputs: inputs, outputNames: ["output"], runOptions: nil)
// load, inference, and unload are tracked automatically.
```

### ML Kit — zero-code integration

All built-in ML Kit detectors (Face, Object, Image Labeler, Text Recognizer, Barcode Scanner, Pose) are intercepted automatically. Remote model downloads via `ModelManager` are also tracked:

```swift
import MLKitFaceDetection
import MLKitVision
// No WildEdge calls required.

let detector = FaceDetector.faceDetector(options: options)
// ↑ trackLoad fires automatically

detector.process(VisionImage(image: image)) { faces, error in
    // ↑ trackInference fires automatically
}
```

### TFLite — manual integration

TFLite does not have an ObjC-accessible runtime layer that WildEdge can hook, so use explicit model handles:

```swift
import WildEdge
import TensorFlowLite

let handle = wildEdge.registerModel(
    modelId: "mobilenet_v3_int8_cpu",
    info: ModelInfo(
        modelName: "MobileNet V3",
        modelVersion: "3.0",
        modelSource: "local",
        modelFormat: "tflite",
        quantization: "int8"
    )
)

handle.trackLoad(durationMs: 60, accelerator: .cpu)
let start = Date()
try interpreter.invoke()
_ = handle.trackInference(
    durationMs: Int(Date().timeIntervalSince(start) * 1000),
    inputModality: .image,
    outputModality: .classification
)
```

## Tracing

You can group inferences into a named trace using `wildEdge.trace`:

```swift
wildEdge.trace("user-query") { trace in
    let embedding = trace.span("embed") { _ in
        let start = Date()
        let vector = embedModel.run(input)
        _ = embedHandle.trackInference(durationMs: Int(Date().timeIntervalSince(start) * 1000))
        return vector
    }

    trace.span("classify") { _ in
        let start = Date()
        _ = classifyModel.run(embedding)
        _ = classifyHandle.trackInference(durationMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}
```

- `trace {}` creates a root span.
- `span {}` creates child spans with parent linkage.
- `trackInference()` inside trace/span inherits correlation context.

## Output metadata

```swift
_ = handle.trackInference(
    durationMs: 34,
    outputMeta: DetectionOutputMeta(numPredictions: result.count, avgConfidence: 0.91).toMap()
)
```

Available metadata types: `DetectionOutputMeta`, `GenerationOutputMeta`, `EmbeddingOutputMeta`, `TextInputMeta`.

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `dsn` | `nil` | `https://<secret>@ingest.wildedge.dev/<key>` (or `WILDEDGE_DSN` env var / Info.plist key) |
| `appVersion` | auto-detected | App version attached to every batch |
| `batchSize` | `10` | Events per request |
| `maxQueueSize` | `200` | Max in-memory events |
| `flushIntervalMs` | `60_000` | Background flush interval |
| `maxEventAgeMs` | `900_000` | Old events are dropped |
| `lowConfidenceThreshold` | `0.5` | Sampling threshold |
| `debug` | `false` | Verbose logs (or `WILDEDGE_DEBUG=true`) |

## AI-assisted integration

Paste this prompt into your coding agent:

```text
Integrate the WildEdge Swift SDK into this project.

1. Initialize WildEdge once at app startup:
   - Preferred: set WILDEDGE_DSN env var — the SDK auto-inits before main().
   - Alternative: call WildEdge.initialize { $0.dsn = "YOUR_DSN" } at app launch.

2. ONNX Runtime and ML Kit are intercepted automatically — no code changes needed for those.

3. For all other ML inference code (TensorFlow Lite, Core ML, remote LLM APIs):
   - Register a stable model handle with wildEdge.registerModel(modelId:info:)
   - Add trackLoad()/trackUnload() for model lifecycle when applicable
   - Time inference and call trackInference(...)
   - Add success/failure tracking with errorCode on failures

4. Wrap multi-step pipelines in wildEdge.trace("name") { }.
5. Add lifecycle hooks for flush() and close().
6. Send only metadata (WildEdge.analyzeText(...).toMap(), outputMeta maps), never raw inputs.
```

## Development

#### Build requirements

- Xcode 15+ (recommended)
- Swift 5.9+
- iOS 13+ / macOS 12+

### Run unit tests

```bash
swift test
```

### Run a single test class

```bash
swift test --filter DsnParserTests
```

### Build the library

```bash
swift build -c release
```

### Build/run examples

```bash
cd Examples/SPMExamples
swift run
```

## Runtime dependencies

- `WildEdge` has no required transitive runtime dependencies
- External ML frameworks are integrated by your app (TensorFlow Lite, ONNX Runtime, ML Kit, Core ML)

## Documentation

Full documentation is available at **[docs.wildedge.dev](https://docs.wildedge.dev)**.

## Repo layout

- [Package.swift](Package.swift): Swift SDK package manifest
- [Sources](Sources): SDK source code
- [Tests](Tests): SDK test suite
- [Examples](Examples): iOS app and SwiftPM examples
