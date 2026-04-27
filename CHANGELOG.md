# Changelog

## 1.0.0 — April 2026

First stable release. Supports iOS 13+ and macOS 12+. Available via Swift Package Manager and CocoaPods.

### Zero-code auto-interceptors

Three frameworks are now instrumented automatically at the ObjC runtime level — no `import WildEdge` or code changes required in inference call sites.

**ONNX Runtime** — `ORTSession` creation, `run`, and dealloc are intercepted. Load duration, inference duration, tensor counts, and error codes are captured automatically.

**ML Kit detectors** — All built-in detectors (Face, Object, Image Labeler, Text Recognizer, Barcode Scanner, Pose) are intercepted via factory method and `processImage:completion:` / `resultsInImage:error:` swizzling. Result counts are reported as output metadata.

**ML Kit remote model downloads** — `ModelManager.downloadModel:conditions:` and the `MLKModelDownloadDidSucceed` / `MLKModelDownloadDidFail` notifications are observed to track download duration and success.

### Auto-init before `main()`

The SDK initialises itself via an ObjC `+load` hook before `main()` runs. Set `WILDEDGE_DSN` in the Xcode scheme environment or in `Info.plist` and `WildEdge.shared` is ready without a single line of setup code.

### Manual integration API

For frameworks without an ObjC runtime layer (TensorFlow Lite, Core ML, remote LLM APIs), the explicit handle API is available:

- `registerModel(modelId:info:)` — declares a model and returns a `ModelHandle`
- `trackLoad(durationMs:accelerator:)` — records model initialisation; defaults to `.cpu` when accelerator is unspecified
- `trackInference(durationMs:inputModality:outputModality:success:errorCode:inputMeta:outputMeta:)` — records a single inference
- `trackUnload(reason:)` / `trackDownload(...)` / `trackFeedback(_:)` / `trackError(...)`

### Distributed tracing

`wildEdge.trace("name") { }` creates a root span. `trace.span("child") { }` creates child spans with automatic parent linkage. `trackInference` calls inside a span inherit the trace and span IDs automatically.

### Output and input metadata

Structured metadata types for common tasks:

- `DetectionOutputMeta` — prediction count, top-K labels with confidence
- `GenerationOutputMeta` — token counts, time-to-first-token, tokens/s, stop reason, safety flag
- `EmbeddingOutputMeta` — embedding dimensions
- `TextInputMeta` — char/word/token counts, language, code detection
- `HardwareContext` — thermal state, battery, available memory, CPU frequency, actual accelerator

### Bug fixes

- `model_load` events always include the `accelerator` field; previously the field was omitted when not explicitly passed, causing backend validation errors.

### Examples

| Example | Integration style |
|---|---|
| `OnnxExample` | Zero-code — ONNX auto-interceptor |
| `MLKitExample` | Zero-code — ML Kit auto-interceptor |
| `TFLiteExample` | Manual handles — TFLite iOS CocoaPods app |
| `SPMExamples` | Manual handles — tracing and coroutines |
