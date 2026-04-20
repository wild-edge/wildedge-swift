# WildEdge

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B%20%7C%20macOS%2012%2B-brightgreen.svg)](WildEdge/Package.swift)

On-device ML inference monitoring for iOS. Tracks latency, confidence,
drift, and hardware metrics without ever sending raw inputs.

> **Pre-release:** API is unstable until v1.0.

## Samples

| Sample | What it shows |
|---|---|
| [iOSAppSample](WildEdgeExamples/iOSAppSample) | iOS app integration using SwiftUI |
| [SPMExamples](WildEdgeExamples/SPMExamples) | Swift Package examples runnable from terminal/Xcode |
| [TFLiteExample.swift](WildEdgeExamples/SPMExamples/Sources/WildEdgeExamples/TFLiteExample.swift) | TensorFlow Lite inference tracking |
| [OnnxExample.swift](WildEdgeExamples/SPMExamples/Sources/WildEdgeExamples/OnnxExample.swift) | ONNX Runtime inference tracking |
| [MLKitExample.swift](WildEdgeExamples/SPMExamples/Sources/WildEdgeExamples/MLKitExample.swift) | ML Kit-style detection instrumentation |
| [TracingExample.swift](WildEdgeExamples/SPMExamples/Sources/WildEdgeExamples/TracingExample.swift) | Multi-step tracing with spans |

To run package samples:

```bash
cd WildEdgeExamples/SPMExamples
export WILDEDGE_DSN="https://<secret>@ingest.wildedge.dev/<key>"
swift run
```

Without a DSN the SDK runs in noop mode: all tracking calls work, events are discarded locally.

## Install

Add WildEdge with Swift Package Manager.

### Xcode

1. Open your app in Xcode.
2. Go to `File > Add Package Dependencies...`.
3. Add:

```text
https://github.com/wild-edge/wildedge-swift.git
```

4. Select product `WildEdge`.

### Package.swift

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

## Setup

```swift
import WildEdge

let wildEdge: WildEdgeClient = WildEdge.initialize { builder in
    builder.dsn = "https://<secret>@ingest.wildedge.dev/<key>" // or WILDEDGE_DSN env var
    // builder.appVersion = "1.2.3" // optional
    // builder.debug = true          // verbose logs
}
```

If no DSN is set, `WildEdge.initialize` returns a no-op client.

## Integrations

The Swift SDK uses explicit model handles (`registerModel` + `trackInference`) as the primary integration pattern.

### TFLite

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

### ONNX Runtime

```swift
import WildEdge

let handle = wildEdge.registerModel(
    modelId: "face_detector_int8",
    info: ModelInfo(
        modelName: "Face Detector",
        modelVersion: "1.0",
        modelSource: "local",
        modelFormat: "onnx",
        quantization: "int8"
    )
)

let start = Date()
let outputs = try session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
_ = handle.trackInference(
    durationMs: Int(Date().timeIntervalSince(start) * 1000),
    inputModality: .image,
    outputModality: .detection,
    outputMeta: DetectionOutputMeta(numPredictions: outputs.count).toMap()
)
```

### ML Kit

```swift
import WildEdge

let handle = wildEdge.registerModel(
    modelId: "face-detector",
    info: ModelInfo(
        modelName: "Face Detector",
        modelVersion: "16.1",
        modelSource: "local",
        modelFormat: "mlkit"
    )
)

let start = Date()
faceDetector.process(visionImage) { faces, error in
    let durationMs = Int(Date().timeIntervalSince(start) * 1000)

    if error != nil {
        _ = handle.trackInference(
            durationMs: durationMs,
            inputModality: .image,
            outputModality: .detection,
            success: false,
            errorCode: "mlkit_face_detection_error"
        )
        return
    }

    _ = handle.trackInference(
        durationMs: durationMs,
        inputModality: .image,
        outputModality: .detection,
        outputMeta: DetectionOutputMeta(numPredictions: (faces ?? []).count).toMap()
    )
}
```

### Remote models

For direct remote LLM/API calls, use `modelSource = "api"` and `modelFormat = "remote"`:

```swift
let handle = wildEdge.registerModel("gpt-4o-mini", info: ModelInfo(
    modelName: "GPT-4o mini",
    modelVersion: "2024-07-18",
    modelSource: "api",
    modelFormat: "remote"
))

let inputMeta = WildEdge.analyzeText(prompt).toMap()
let start = Date()
let response = try await callRemoteApi(prompt)

_ = handle.trackInference(
    durationMs: Int(Date().timeIntervalSince(start) * 1000),
    inputModality: .text,
    outputModality: .generation,
    inputMeta: inputMeta,
    outputMeta: GenerationOutputMeta(
        tokensIn: response.usage.promptTokens,
        tokensOut: response.usage.completionTokens
    ).toMap()
)
```

### Manual tracking

```swift
let handle = wildEdge.registerModel("my-model", info: ModelInfo(
    modelName: "MobileNet",
    modelVersion: "v3",
    modelSource: "local",
    modelFormat: "custom"
))

handle.trackLoad(durationMs: 120, accelerator: .cpu, coldStart: true)

let start = Date()
let output = model.run(input)
_ = output

let inferenceId = handle.trackInference(
    durationMs: Int(Date().timeIntervalSince(start) * 1000),
    inputModality: .image,
    outputModality: .detection
)

handle.trackFeedback(.thumbsUp, relatedInferenceId: inferenceId)
handle.trackUnload()
```

## Feedback types

`FeedbackType` has built-in values and custom signals.

| Value | Meaning |
|---|---|
| `.thumbsUp` | User explicitly approved the result |
| `.thumbsDown` | User explicitly rejected the result |
| `.accepted` | User accepted/used result without editing |
| `.edited` | User accepted but modified the result |
| `.rejected` | User dismissed or ignored the result |
| `.custom("...")` | Domain-specific signal |

`trackFeedback` links to the latest inference automatically. For earlier inferences, pass `relatedInferenceId`:

```swift
let inferenceId = handle.trackInference(durationMs: 42)
handle.trackFeedback(.edited, relatedInferenceId: inferenceId, editDistance: 5)
```

## Tracing

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
| `dsn` | `nil` | `https://<secret>@ingest.wildedge.dev/<key>` (or `WILDEDGE_DSN`) |
| `appVersion` | auto-detected | App version attached to every batch |
| `batchSize` | `10` | Events per request |
| `maxQueueSize` | `200` | Max in-memory events |
| `flushIntervalMs` | `60_000` | Background flush interval |
| `maxEventAgeMs` | `900_000` | Old events are dropped |
| `lowConfidenceThreshold` | `0.5` | Sampling threshold |
| `debug` | `false` | Verbose logs (or `WILDEDGE_DEBUG=true`) |

## Testing

`WildEdge.initialize()` returns `WildEdgeClient`; depend on this protocol and inject noop in tests:

```swift
let prodClient: WildEdgeClient = WildEdge.initialize { $0.dsn = "..." }
let testClient: WildEdgeClient = NoopWildEdgeClient()
```

Noop client executes `trace`/`span` blocks and drops events.

## Lifecycle

```swift
wildEdge.flush() // default timeout 5s
wildEdge.close() // stops consumer and attempts final flush
```

## AI-assisted integration

Paste this prompt into your coding agent:

```text
Integrate the WildEdge Swift SDK into this project.

1. Find all ML inference code (TensorFlow Lite, ONNX Runtime, ML Kit, Core ML, remote LLM APIs).
2. For each inference site:
   - Register a stable model handle with wildEdge.registerModel(modelId:info:)
   - Add trackLoad()/trackUnload() for model lifecycle when applicable
   - Time inference and call trackInference(...)
   - Add success/failure tracking with errorCode on failures
3. Initialize WildEdge once at app startup using WildEdge.initialize { $0.dsn = "YOUR_DSN" }.
4. Wrap multi-step pipelines in wildEdge.trace("name") { }.
5. Add lifecycle hooks for flush() and close().
6. Send only metadata (WildEdge.analyzeText(...).toMap(), outputMeta maps), never raw inputs.
```

## Development

### Requirements

- Xcode 15+ (recommended)
- Swift 5.9+
- iOS 13+ / macOS 12+

### Run unit tests

```bash
cd WildEdge
swift test
```

### Run a single test class

```bash
cd WildEdge
swift test --filter DsnParserTests
```

### Build the library

```bash
cd WildEdge
swift build -c release
```

### Build/run examples

```bash
cd WildEdgeExamples/SPMExamples
swift run
```

## Requirements

- No required transitive runtime dependencies in `WildEdge`
- External ML frameworks are integrated by your app (TensorFlow Lite, ONNX Runtime, ML Kit, Core ML)

## Repo layout

- [WildEdge](WildEdge): Swift SDK package
- [WildEdgeExamples](WildEdgeExamples): iOS app + SwiftPM examples
