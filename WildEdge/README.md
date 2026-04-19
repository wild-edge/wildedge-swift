# WildEdge iOS SDK (Swift)

Swift Package for monitoring on-device ML inference.

## Installation (SPM)

In Xcode, add a local package:
- Folder: `WildEdge`

Or via `Package.swift`:

```swift
.package(path: "WildEdge")
```

## Usage

```swift
import WildEdge

let wildEdge = WildEdge.initialize { builder in
    builder.dsn = "https://<secret>@ingest.wildedge.dev/<key>"
    builder.debug = true
}

let handle = wildEdge.registerModel(
    modelId: "mobilenet_v1",
    info: ModelInfo(
        modelName: "MobileNet",
        modelVersion: "1.0",
        modelSource: "local",
        modelFormat: "coreml"
    )
)

handle.trackLoad(durationMs: 120, accelerator: .cpu)
let inferenceId = handle.trackInference(
    durationMs: 34,
    inputModality: .image,
    outputModality: .classification,
    outputMeta: DetectionOutputMeta(numPredictions: 3, avgConfidence: 0.91).toMap()
)
handle.trackFeedback(.thumbsUp, relatedInferenceId: inferenceId)

wildEdge.flush()
```

## Trace/span

```swift
wildEdge.trace("user-query") { trace in
    trace.span("embed") { _ in
        // inference 1
    }
    trace.span("classify") { _ in
        // inference 2
    }
}
```

