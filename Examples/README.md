# WildEdge Swift Examples

This directory contains iOS app samples and Swift Package examples demonstrating WildEdge SDK integration.

## DSN Configuration

To run the examples, you need to obtain a DSN (configuration parameter).

1. Navigate to `https://wildedge.dev/` and sign up or log in.
2. Open the dashboard at `https://app.wildedge.dev/`.
3. Create a project (or open an existing project).
4. Copy the project DSN for later.

## VoiceRecorderSample Instructions

An iOS app that records audio, runs it through a local ONNX voice-conversion model (T-Pain effect), and tracks the inference with WildEdge — including uploading the raw recording as an attachment.

**Requirements:** Xcode 15+, iOS 16+ device or simulator, `OnnxRuntimeBindings` package (resolved automatically via SPM).

1. Open `VoiceRecorderSample/VoiceRecorderSample.xcodeproj` in Xcode (SPM dependencies resolve automatically).
2. Set `WILDEDGE_DSN` in `VoiceRecorderSample/Sources/Info.plist` or via Edit Scheme → Run → Environment Variables.
3. Add `TPain.onnx` to the app bundle (drag into Xcode, tick "Add to target"). Without it the app runs in no-model mode and skips local inference.
4. Select an iOS Simulator or device as the run destination.
5. Run the `VoiceRecorderSample` scheme.

Attachment uploads (`enableAttachments = true`) are already enabled in `RecorderViewModel.swift` — they activate automatically once a valid DSN is set.

**What gets tracked:**
- `model_load` event when the ONNX session is initialised
- `inference` event per recording, including duration, input modality (`audio`), and output modality (`generation`)
- The `.wav` recording uploaded as an `InferenceAttachment` (requires `enableAttachments = true`)

## CarScannerExample Instructions

An iOS camera app that scans cars using OpenRouter and Gemini vision APIs and reports each inference to WildEdge — including uploading the input image as an attachment. Built with SwiftUI and XcodeGen.

**Requirements:** Xcode 15+, iOS 16+ device (camera required for live capture; photo library works on simulator), XcodeGen.

1. Generate the Xcode project:
   ```bash
   cd Examples/CarScannerExample
   xcodegen generate
   ```
2. Open `CarScannerExample.xcodeproj` in Xcode.
3. Fill in your credentials in `Sources/Info.plist`:
   - `WILDEDGE_DSN` — your WildEdge project DSN
   - `OPENROUTER_API_KEY` — your OpenRouter API key
   - `GEMINI_API_KEY` — your Google Gemini API key
4. Set your development team in Xcode's project settings (Signing & Capabilities).
5. Run the `CarScannerExample` scheme on a device or simulator.

**What gets tracked:**
- `inference` event per API call via a per-provider `ModelHandle`, including duration, `inputModality: .multimodal`, `outputModality: .generation`, and HTTP success/failure
- The resized JPEG input image uploaded as an `InferenceAttachment` (`role: .input`)

## BlobStoreBenchmark Instructions

An iOS app that runs interactive performance benchmarks for the WildEdge SDK's internal BlobStore storage layer. Useful for comparing write throughput, compaction strategies, and dictionary encoding formats on real devices.

**Requirements:** Xcode 15+, iOS 16+ device or simulator. No DSN needed — the app has no network calls.

1. Open `BlobStoreBenchmark/BlobStoreBenchmark.xcodeproj` in Xcode.
2. Select an iOS Simulator or device as the run destination.
3. Run the `BlobStoreBenchmark` scheme and tap **Run Benchmarks**.

**What it measures:**

| Benchmark | Description |
|---|---|
| Append throughput | Write 100 MB across 6 payload sizes (100 B → 100 MB), comparing external-lock vs threadSafe BlobStore |
| Compaction | Drop the first 50 MB from a 100 MB file, comparing `.inPlace` (memmove) vs `.rename` (atomic temp+swap) |
| Dictionary encoding | Encode and decode 1 000 inference events in all four formats: `json`, `binary`, `plist`, `compressedJSON` |

Results are displayed in a live table and printed to the console log.

## TFLiteObjcExample Instructions

An iOS app demonstrating zero-code TensorFlow Lite tracking via the `TFLInterpreter` auto-interceptor. No WildEdge calls are required — `trackLoad`, `trackInference`, and `trackUnload` fire automatically whenever `TFLInterpreter` is used.

**Requirements:** Xcode 15+, CocoaPods, iOS 15.5+ simulator or device.

1. Install CocoaPods dependencies:
   ```bash
   cd Examples/TFLiteObjcExample
   pod install
   ```
2. Open **`TFLiteObjcExample.xcworkspace`** in Xcode (not the `.xcodeproj`).
3. Set `WILDEDGE_DSN` in `Sources/TFLiteObjcExample/Info.plist` or via Edit Scheme → Run → Environment Variables.
4. Run the `TFLiteObjcExample` scheme.

The app downloads a sample EfficientNet-Lite0 model (~5 MB) automatically on first launch if no bundled `model.tflite` is present. To use your own model instead, drag a `.tflite` file into Xcode and tick "Add to target".

**What gets tracked automatically:**
- `model_load` when `TFLInterpreter` is initialised
- `inference` on each `invokeWithError:` call, with duration and success/error
- `model_unload` when the interpreter is deallocated

## TFLiteExample Instructions

An iOS app demonstrating manual TensorFlow Lite tracking using the pure-Swift `Interpreter` API. Because `Interpreter` has no ObjC runtime exposure, model lifecycle events are tracked explicitly via `ModelHandle`.

**Requirements:** Xcode 15+, CocoaPods, iOS 15.5+ simulator or device.

1. Install CocoaPods dependencies:
   ```bash
   cd Examples/TFLiteExample
   pod install
   ```
2. Open **`TFLiteExample.xcworkspace`** in Xcode (not the `.xcodeproj`).
3. Set `WILDEDGE_DSN` in `Sources/TFLiteExample/Info.plist` or via Edit Scheme → Run → Environment Variables.
4. Run the `TFLiteExample` scheme.

The app downloads a sample EfficientNet-Lite0 model (~5 MB) automatically on first launch if no bundled `model.tflite` is present.

**What gets tracked:**
- `model_load` after `interpreter.allocateTensors()` succeeds
- `inference` after each `interpreter.invoke()`, with duration and output shape
- `model_unload` is not tracked automatically (pure-Swift, no dealloc hook)

## iOSAppSample Instructions

1. Open `iOSAppSample/WildEdgeiOSSample.xcodeproj` in Xcode.
2. The application reads DSN from the `WILDEDGE_DSN` key in `Info.plist`; if required, update the value in `iOSAppSample/Sources/Info.plist`.
3. Select an iOS Simulator as the run destination.
4. Run the `WildEdgeiOSSample` scheme.

## SPMExamples Instructions

Open in Xcode:

1. Open `SPMExamples/Package.swift` in Xcode.
2. Xcode will load the Swift Package as a workspace.
3. Run the `WildEdgeExamples` target.

or run from terminal:

```bash
cd SPMExamples
export WILDEDGE_DSN="https://<secret>@ingest.wildedge.dev/<key>"
swift run
```

If the `WildEdge` dependency does not resolve after opening in Xcode, go to `File > Packages` and click `Reset Package Caches`, then `Resolve Package Versions`.
