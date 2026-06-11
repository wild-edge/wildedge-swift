# WildEdge Swift SDK

[![CI](https://github.com/wild-edge/wildedge-swift/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wild-edge/wildedge-swift/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B%20%7C%20macOS%2012%2B-brightgreen.svg)](Package.swift)

On-device ML inference monitoring for Swift (iOS, macOS). Tracks latency, confidence,
drift, and hardware metrics without ever sending raw inputs.

## Getting started

### 1. Get a DSN from WildEdge

To run the examples or use the SDK in your application, you need a WildEdge DSN.
A DSN is a single configuration value that contains your Project Key and connection details for the WildEdge API. To get your DSN:

1. Navigate to `https://wildedge.dev/` and sign up or log in.
2. Open the dashboard at `https://app.wildedge.dev/`.
3. Create a project (or open an existing project).
4. Copy the project DSN for later.

### 2. Add the SDK to your project

#### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wild-edge/wildedge-swift.git", from: "1.0.11")
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

Or add it directly in Xcode via `File > Add Package Dependencies...` using:
```
https://github.com/wild-edge/wildedge-swift.git
```

#### CocoaPods

Add the pod to your `Podfile`:

```ruby
pod 'WildEdge', '1.0.11'
```

Then run:

```bash
pod install
```

### 3. Setup

#### Auto-init (recommended)

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

#### Manual init

Call `WildEdge.initialize` explicitly when you need programmatic control (e.g. reading the DSN from a config file):

```swift
import WildEdge

let wildEdge: WildEdgeClient = WildEdge.initialize { builder in
    builder.dsn = "https://<secret>@ingest.wildedge.dev/<key>"
    // builder.debug = true
    // builder.enableAttachments = true
    // builder.enabledInterceptors = [.ort, .mlKit]  // opt out of specific interceptors
}
```

For iOS, call this at `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. If no DSN is set, `WildEdge.initialize` returns a no-op client.

### 4. Track model load and inferences

```swift
import WildEdge

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

// `interpreter` is your inference runner (e.g. a TFLite Interpreter, Core ML
// model, or any other on-device/remote inference object) — substitute your own.

// Report model load time once, after the model is ready for inference
let loadStart = Date()
try interpreter.allocateTensors()
handle.trackLoad(
    durationMs: Int(Date().timeIntervalSince(loadStart) * 1000),
    accelerator: .cpu
)

// Time and report each inference
let start = Date()
try interpreter.invoke()
_ = handle.trackInference(
    durationMs: Int(Date().timeIntervalSince(start) * 1000),
    inputModality: .image,
    outputModality: .classification
)
```

### 5. Zero-code tracking for supported libraries

Besides the manual steps in step 4, the following libraries are traced automatically via zero-code interceptors — no extra steps needed for those:

#### ONNX Runtime — zero-code integration

The SDK automatically intercepts `ORTSession` creation and `run` calls at the ObjC runtime level — no import or code changes needed. Just run your existing ONNX code and events appear in the dashboard:

```swift
import OnnxRuntimeBindings
// No WildEdge calls required.

let env = try ORTEnv(loggingLevel: .warning)
let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
let outputs = try session.run(withInputs: inputs, outputNames: ["output"], runOptions: nil)
// load, inference, and unload are tracked automatically.
```

#### ML Kit — zero-code integration

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

#### TFLite (`TensorFlowLiteObjC`) — zero-code integration

When your app links `TensorFlowLiteObjC` (i.e. uses `TFLInterpreter`), WildEdge hooks it automatically — no imports or code changes needed:

```objc
// No WildEdge calls required.
#import "TFLInterpreter.h"

TFLInterpreter *interpreter = [[TFLInterpreter alloc] initWithModelPath:modelPath error:nil];
[interpreter allocateTensorsWithError:nil];
// ↑ trackLoad fires automatically

[interpreter invokeWithError:nil];
// ↑ trackInference fires automatically
// dealloc → trackUnload fires automatically
```

> **Note:** The pure-Swift `TensorFlowLite` package (`Interpreter` class) cannot be intercepted — use explicit model handles for that path (see below).

#### ExecuTorch LLM — zero-code integration

When your app links `ExecuTorchLLM` and uses `TextRunner`, WildEdge intercepts load, generate, and dealloc automatically:

```swift
import ExecuTorchLLM
// No WildEdge calls required.

let runner = TextRunner(modelPath: modelPath, tokenizerPath: tokenizerPath)
try runner.load()
// ↑ trackLoad fires automatically (duration, CPU accelerator)

try runner.generate(prompt, config) { token in
    // ↑ token callback is wrapped — exact output token count is measured
    print(token)
}
// ↑ trackInference fires automatically after generate returns
//   (tokensOut, TPS, duration, success/error)

// runner dealloc → trackUnload fires automatically
```

Token counting is done by wrapping the caller's callback block at the ObjC runtime level — no changes to the callback needed. `ModelHandle` is stored as an associated object on the runner instance so it survives background threads and arbitrary lifetimes.

#### TFLite (pure Swift) — manual integration

The Swift `Interpreter` class has no ObjC runtime exposure, so use explicit model handles:

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

## Selectively disabling zero-code interceptors

All auto-interceptors are enabled by default. Use `enabledInterceptors` to opt out of individual ones:

```swift
WildEdge.initialize { builder in
    builder.dsn = "..."

    // Disable all zero-code interceptors
    builder.enabledInterceptors = []

    // Enable only specific ones
    builder.enabledInterceptors = [.ort, .mlKit]   // ONNX + both ML Kit interceptors
    builder.enabledInterceptors = [.ort, .tfl]     // ONNX + TFLite only
}
```

Available members of `Interceptors`:

| Member | Description |
|---|---|
| `.ort` | ONNX Runtime (`ORTSession` init / run / dealloc) |
| `.mlKitDetector` | ML Kit detector classes (FaceDetector, ObjectDetector, etc.) |
| `.mlKitModelManager` | ML Kit `ModelManager` remote model downloads |
| `.tfl` | TensorFlow Lite `TFLInterpreter` |
| `.execuTorchLLM` | ExecuTorch `ExecuTorchLLMTextRunner` (load, generate with token counting, dealloc) |
| `.mlKit` | Convenience: `.mlKitDetector` + `.mlKitModelManager` combined |
| `.all` | All interceptors enabled (default) |

## Examples

> **Tip:** Want to see WildEdge in action? Check out the example apps below.

| Example | Runtime | What it shows |
|---|---|---|
| [llamaExample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/llamaExample) | llama.cpp · Metal GPU | On-device LLM — in-app GGUF catalog (Qwen2.5, TinyLlama, Liquid AI LFM2), streaming token output, Metal warmup, perf telemetry via `llama_perf_context` |
| [execuTorchExample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/execuTorchExample) | ExecuTorch · XNNPACK CPU | On-device LLM — Llama 3.2 1B catalog (.pte + tokenizer.json), zero-code telemetry via `ExecuTorchLLMInterceptor` (`.execuTorchLLM`), RE2 tokenizer patching, `kernels_quantized` / `kernels_torchao` for INT4 models |
| [CarScannerExample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/CarScannerExample) | OpenRouter / Gemini API | iOS camera app — scans cars with remote vision APIs, tracks each inference and uploads the input image as an attachment |
| [VoiceRecorderSample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/VoiceRecorderSample) | ONNX Runtime | Records audio, runs a local ONNX voice-conversion model, tracks inference + uploads the recording as an attachment |
| [OnnxExample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/OnnxExample) | ONNX Runtime | Zero-code tracking via auto-interceptor |
| [MLKitExample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/MLKitExample) | ML Kit | Zero-code tracking via auto-interceptor |
| [TFLiteObjcExample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/TFLiteObjcExample) | TensorFlow Lite (ObjC) | Zero-code tracking via `TFLInterpreter` auto-interceptor |
| [TFLiteExample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/TFLiteExample) | TensorFlow Lite (Swift) | Manual tracking using the pure-Swift `Interpreter` |
| [Benchmarks](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/Benchmarks) | — | Interactive benchmarks for BlobStore throughput, compaction, encoding formats, and gzip compression |
| [iOSAppSample](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/iOSAppSample) | — | General-purpose iOS integration sample |
| [SPMExamples](https://github.com/wild-edge/wildedge-swift/tree/main/Examples/SPMExamples) | — | Swift Package examples runnable from the terminal or Xcode, including multi-step tracing |

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

## Attachments

Attach binary payloads (images, audio, embeddings) to an inference event. Attachments are uploaded asynchronously to S3 via a presign endpoint — the inference event is never blocked.

Enable the pipeline in the builder (`enableAttachments = true` is required) and pass attachments to `trackInference`:

```swift
WildEdge.initialize { builder in
    builder.dsn = "https://<secret>@ingest.wildedge.dev/<key>"
    builder.enableAttachments = true
}

// In-memory data
_ = handle.trackInference(
    durationMs: 42,
    attachments: [
        InferenceAttachment(name: "input.jpg", role: .input,
                            payload: .data(jpegData, mimeType: "image/jpeg")),
        InferenceAttachment(name: "mask.png", role: .output,
                            payload: .data(maskData, mimeType: "image/png")),
    ]
)

// File on disk (streamed directly without loading into RAM)
_ = handle.trackInference(
    durationMs: 150,
    attachments: [
        InferenceAttachment(name: "recording.wav", role: .input,
                            payload: .file(wavURL, mimeType: "audio/wav")),
    ]
)
```

Attachment files are managed under `Application Support/wildedge/attachments/` (excluded from iCloud backup) and deleted automatically after a successful upload or after `maxAttachmentAgeMs`.

## Output metadata

```swift
_ = handle.trackInference(
    durationMs: 34,
    outputMeta: DetectionOutputMeta(numPredictions: result.count, avgConfidence: 0.91).toMap()
)
```

Available metadata types: `DetectionOutputMeta`, `GenerationOutputMeta`, `EmbeddingOutputMeta`, `TextInputMeta`, `GenerationConfig`.

For API-hosted models, pass `ApiMeta` to surface which model checkpoint was actually used and detect silent backend updates:

```swift
_ = handle.trackInference(
    durationMs: elapsed,
    outputMeta: GenerationOutputMeta(tokensIn: 128, tokensOut: 256).toMap(),
    apiMeta: ApiMeta(
        resolvedModelId: response.model,         // e.g. "gpt-4o-2024-11-20"
        systemFingerprint: response.fingerprint, // opaque backend version string
        serviceTier: "default"
    )
)
```

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `dsn` | `nil` | `https://<secret>@ingest.wildedge.dev/<key>` (or `WILDEDGE_DSN` env var / Info.plist key) |
| `appVersion` | auto-detected | App version attached to every batch |
| `batchSize` | `10` | Events per ingest request |
| `maxQueueSize` | `200` | Maximum events buffered on disk before oldest are evicted |
| `flushIntervalMs` | `60_000` | Background flush interval (ms) |
| `maxEventAgeMs` | `900_000` | Events older than this are dropped before sending (ms) |
| `lowConfidenceThreshold` | `0.5` | Predictions below this are flagged low-confidence |
| `debug` | `false` | Verbose console logs (or `WILDEDGE_DEBUG=true`) |
| `enabledInterceptors` | `.all` | Zero-code interceptors to install — use an `Interceptors` set literal such as `[.ort, .mlKit]` to enable only specific ones, or `[]` to disable all |
| `enableAttachments` | `false` | Opt in to the attachment upload pipeline |
| `maxAttachmentsPerInference` | `10` | Attachment cap per `trackInference` call |
| `maxAttachmentSizeBytes` | `10 MB` | Attachments larger than this are dropped |
| `maxAttachmentAgeMs` | `300` s | Attachments not uploaded within this window are evicted |
| `attachmentFlushIntervalMs` | `5_000` | How often the attachment consumer checks for pending uploads (ms) |
| `attachmentTransmitTimeoutMs` | `10_000` | Network timeout for presign and S3 upload requests (ms) |
| `attachmentFilter` | `nil` | Optional closure to filter or reorder attachments before they are queued |
| `enableCompression` | `true` | Compress batch payloads with gzip before sending (`Content-Encoding: gzip`) |

## Diagnostics

Call `diagnostics()` on any `WildEdgeClient` to inspect the SDK's internal state at runtime:

```swift
let diag = wildEdge.diagnostics()
print(diag.processMemoryBytes)         // physical memory footprint of the process (bytes)
print(diag.systemAvailableMemoryBytes) // system-wide free memory, nil if unavailable
print(diag.eventQueueCount)            // events buffered and waiting to flush
print(diag.attachmentQueueCount)       // attachments queued for upload
print(diag.attachmentUploadedCount)    // cumulative successful uploads
print(diag.attachmentDropCount)        // cumulative drops (age eviction + permanent failures)
print(diag.attachmentPermanentFailureCount) // drops due to 400/401 responses
```

| Field | Description |
|---|---|
| `processMemoryBytes` | Physical memory footprint of the current process (`phys_footprint` via `task_vm_info`) |
| `systemAvailableMemoryBytes` | System-wide available memory (free + inactive VM pages); `nil` if the kernel call fails |
| `eventQueueCount` | Number of events currently buffered on disk and waiting to be flushed |
| `attachmentQueueCount` | Number of attachments currently in the upload queue |
| `attachmentUploadedCount` | Cumulative count of attachments successfully uploaded |
| `attachmentDropCount` | Cumulative count of attachments dropped (age eviction + permanent failures) |
| `attachmentPermanentFailureCount` | Attachments dropped due to a permanent transmit failure (400/401) |

## AI-assisted integration

Paste this prompt into your coding agent:

```text
Integrate the WildEdge Swift SDK into this project.

1. Initialize WildEdge once at app startup:
   - Preferred: set WILDEDGE_DSN env var — the SDK auto-inits before main().
   - Alternative: call WildEdge.initialize { $0.dsn = "YOUR_DSN" } at app launch.

2. ONNX Runtime, ML Kit, and TensorFlow Lite (`TFLInterpreter`) are intercepted automatically — no code changes needed for those.

3. For all other ML inference code (TensorFlow Lite pure-Swift `Interpreter`, Core ML, remote LLM APIs):
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

## Binary size impact

Measured on minimal apps compiled with `-Osize` and stripped, targeting `arm64-apple-ios14.0` and `arm64-apple-macos12.0`.

| | iOS install | iOS `.ipa` | macOS install | macOS `.zip` |
|---|---|---|---|---|
| Without SDK | 90 KB | 14 KB | 53 KB | 9 KB |
| With SDK | 315 KB | 122 KB | 299 KB | 118 KB |
| **Delta** | **+225 KB** | **+107 KB** | **+246 KB** | **+109 KB** |

**Segment breakdown (release, `-Osize`)**

| Segment | Size | What it is |
|---|---|---|
| `__TEXT` (code) | 176 KB | Executable machine instructions |
| `__DATA` | 21 KB | Globals, vtables, ObjC metadata |

Download size is the zipped `.app`/`.ipa` binary delta. Apple's App Store LZFSE compressor achieves similar ratios, so real-world download overhead is around **~100 KB** on both platforms.

## Runtime dependencies

- `WildEdge` has no required transitive runtime dependencies
- External ML frameworks are integrated by your app (TensorFlow Lite, ONNX Runtime, ML Kit, Core ML)

## Documentation

Full documentation is available at **[docs.wildedge.dev](https://docs.wildedge.dev)**.

## Repository overview

- [Package.swift](https://github.com/wild-edge/wildedge-swift/blob/main/Package.swift): Swift SDK package manifest
- [Sources](https://github.com/wild-edge/wildedge-swift/tree/main/Sources): SDK source code
- [Tests](https://github.com/wild-edge/wildedge-swift/tree/main/Tests): SDK test suite
- [Examples](https://github.com/wild-edge/wildedge-swift/tree/main/Examples): iOS app and SwiftPM examples
