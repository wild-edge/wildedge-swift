# WildEdge Swift Examples

This directory contains iOS app samples and Swift Package examples demonstrating WildEdge SDK integration.

## DSN Configuration

To run the examples, obtain a DSN from your WildEdge project:

1. Sign up or log in at `https://wildedge.dev/`.
2. Open the dashboard at `https://app.wildedge.dev/`.
3. Create or open a project and copy the DSN.

Set `WILDEDGE_DSN` in each example's `Sources/Info.plist` before running.

---

## llamaExample

An iOS app that runs local LLM inference on-device using **llama.cpp** (release b9305). Download models from the in-app catalog (Qwen2.5, TinyLlama, Liquid AI LFM2 series) or pick any `.gguf` from the Files app, enter a prompt, and stream tokens in real time — no server required.

**Runtime:** llama.cpp · **Backend:** Metal GPU · **Model format:** `.gguf`

**Requirements:** Xcode 15+, iOS 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
cd Examples/llamaExample
bash setup.sh          # downloads llama.cpp xcframework (~700 MB, one-time)
xcodegen generate
open llamaExample.xcodeproj
```

**What gets tracked:**
- `model_load` — load duration, Metal GPU accelerator
- `model_download` — per catalog download: source URL, file size, duration
- `inference` — tokens in/out, TPS, prefill time, stop reason, generation config
- `model_unload` — on explicit unload

---

## execuTorchExample

An iOS app that runs local LLM inference on-device using **ExecuTorch** (swiftpm-1.0.0). Download Llama 3.2 1B models from the in-app catalog or pick any `.pte` + `tokenizer.json` from the Files app.

**Runtime:** ExecuTorch · **Backend:** XNNPACK CPU · **Model format:** `.pte` + `tokenizer.json`

**Requirements:** Xcode 15+, iOS 17+

```bash
open Examples/execuTorchExample/execuTorchExample.xcodeproj
# Xcode resolves the ExecuTorch Swift Package on first open (~500 MB)
```

> Models in the catalog require accepting the Llama 3.2 Community License on HuggingFace before the download will succeed.

**What gets tracked** (zero-code via `ExecuTorchLLMInterceptor`):
- `model_load` — load duration, CPU accelerator
- `model_download` — per catalog download (model + tokenizer, via `ModelDownloader`)
- `inference` — tokens out (exact, counted by wrapping the token callback), TPS, duration
- `model_unload` — on dealloc

---

## CarScannerExample

An iOS camera app that scans cars using OpenRouter and Gemini vision APIs, reporting each inference to WildEdge including the input image as an attachment.

**Requirements:** Xcode 15+, iOS 16+, camera (live capture) or photo library (simulator).

1. Open `CarScannerExample/CarScannerExample.xcodeproj` in Xcode.
2. Fill in `Sources/Info.plist`: `WILDEDGE_DSN`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`.
3. Set your development team under Signing & Capabilities.
4. Run the `CarScannerExample` scheme.

**What gets tracked:**
- `inference` per API call — duration, `inputModality: .multimodal`, `outputModality: .generation`, success/failure
- Resized JPEG input image uploaded as an `InferenceAttachment` (`role: .input`)

---

## VoiceRecorderSample

An iOS app that records audio, runs it through a local ONNX voice-conversion model (T-Pain effect), and tracks the inference with WildEdge including uploading the raw recording as an attachment.

**Requirements:** Xcode 15+, iOS 16+, `OnnxRuntimeBindings` (resolved via SPM).

1. Open `VoiceRecorderSample/VoiceRecorderSample.xcodeproj` in Xcode.
2. Set `WILDEDGE_DSN` in `VoiceRecorderSample/Sources/Info.plist`.
3. Add `TPain.onnx` to the app bundle (drag into Xcode, tick "Add to target"). Without it the app runs in no-model mode.
4. Run the `VoiceRecorderSample` scheme.

**What gets tracked:**
- `model_load` when the ONNX session is initialised
- `inference` per recording — duration, `inputModality: .audio`, `outputModality: .generation`
- `.wav` recording uploaded as an `InferenceAttachment`

---

## TFLiteObjcExample

An iOS app demonstrating **zero-code** TensorFlow Lite tracking via the `TFLInterpreter` auto-interceptor. No manual WildEdge calls needed.

**Requirements:** Xcode 15+, CocoaPods, iOS 15.5+.

```bash
cd Examples/TFLiteObjcExample && pod install
open TFLiteObjcExample.xcworkspace   # not the .xcodeproj
```

Set `WILDEDGE_DSN` in `Sources/TFLiteObjcExample/Info.plist`. The app downloads EfficientNet-Lite0 (~5 MB) on first launch.

**What gets tracked automatically:** `model_load`, `inference` (per `invokeWithError:` call), `model_unload`.

---

## TFLiteExample

An iOS app demonstrating **manual** TensorFlow Lite tracking using the pure-Swift `Interpreter` API.

**Requirements:** Xcode 15+, CocoaPods, iOS 15.5+.

```bash
cd Examples/TFLiteExample && pod install
open TFLiteExample.xcworkspace   # not the .xcodeproj
```

Set `WILDEDGE_DSN` in `Sources/TFLiteExample/Info.plist`.

**What gets tracked:** `model_load` after `allocateTensors()`, `inference` after each `invoke()`.

---

## Benchmarks

An iOS app for benchmarking WildEdge SDK internals — write throughput, compaction strategies, encoding formats, and gzip compression. No DSN needed.

1. Open `Benchmarks/Benchmarks.xcodeproj` in Xcode.
2. Run the `Benchmarks` scheme and tap **Run Benchmarks**.

| Benchmark | What it measures |
|---|---|
| Append throughput | 100 MB across 6 payload sizes, external-lock vs threadSafe BlobStore |
| Compaction | `.inPlace` (memmove) vs `.rename` (atomic swap) on a 100 MB file |
| Dictionary encoding | 1 000 events in `json`, `binary`, `plist`, `compressedJSON` |
| Gzip compression | 1–1 000 event batches: raw size, compressed size, % saved, µs/call |

---

## iOSAppSample

General-purpose iOS integration sample.

1. Open `iOSAppSample/WildEdgeiOSSample.xcodeproj` in Xcode.
2. Set `WILDEDGE_DSN` in `iOSAppSample/Sources/Info.plist`.
3. Run the `WildEdgeiOSSample` scheme on a simulator.

---

## SPMExamples

Swift Package examples runnable from terminal or Xcode.

```bash
cd SPMExamples
export WILDEDGE_DSN="https://<key>@ingest.wildedge.dev/<project-id>"
swift run
```

Or open `SPMExamples/Package.swift` in Xcode and run the `WildEdgeExamples` target. If dependencies don't resolve, use **File → Packages → Reset Package Caches**.
