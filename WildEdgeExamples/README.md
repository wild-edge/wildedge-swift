# WildEdge Swift Examples

This directory contains two Swift SDK example tracks: a full iOS app sample (`iOSAppSample`) and Swift Package examples (`SPMExamples`).

## DSN Configuration

To use the Swift SDK, you need to obtain a DSN (configuration parameter).

1. Navigate to `https://wildedge.dev/` and sign up or log in.
2. Open the dashboard at `https://app.wildedge.dev/`.
3. Create a project (or open an existing project).
4. Copy the project DSN for later.

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

Run from terminal:

```bash
cd SPMExamples
# Get your DSN:
# 1) sign up/login at https://wildedge.dev/
# 2) open https://app.wildedge.dev/
# 3) create a project and copy DSN from project settings
export WILDEDGE_DSN="https://<secret>@ingest.wildedge.dev/<key>"
swift run
```

If the `WildEdge` dependency does not resolve after opening in Xcode, go to `File > Packages` and click `Reset Package Caches`, then `Resolve Package Versions`.

Example files included in the SPM package:

- `SPMExamples/Sources/WildEdgeExamples/CoroutinesExample.swift` - async/await and AsyncStream-based tracking examples
- `SPMExamples/Sources/WildEdgeExamples/GalleryExample.swift` - gallery and token-streaming equivalent
- `SPMExamples/Sources/WildEdgeExamples/MLKitExample.swift` - detection equivalent using Google ML Kit Face Detection
- `SPMExamples/Sources/WildEdgeExamples/OnnxExample.swift` - ONNX session equivalent using ONNX Runtime (onnxruntime.ai)
- `SPMExamples/Sources/WildEdgeExamples/TFLiteExample.swift` - TFLite classification equivalent using TensorFlow Lite
- `SPMExamples/Sources/WildEdgeExamples/TracingExample.swift` - trace/span equivalent for a pipeline

## ML Kit In Swift

`MLKitExample.swift` uses native Google ML Kit classes in Swift:

- `MLKitFaceDetection.FaceDetector`
- `MLKitVision.VisionImage`

To run it in Xcode, add Google ML Kit (FaceDetection + Vision) to your project, for example via CocoaPods or manual framework linking.

If ML Kit libraries are not linked, the file compiles a fallback path (without ML Kit imports) so the full package still builds correctly.

## ONNX Runtime In Swift

`OnnxExample.swift` uses native ONNX Runtime classes in Swift:

- `ORTEnv`
- `ORTSession`
- `ORTValue`

To run it in Xcode, add ONNX Runtime (onnxruntime.ai), for example via CocoaPods or manual framework linking.

If ONNX Runtime is not linked, the file compiles a fallback path (without ORT imports) so the full package still builds correctly.

## TensorFlow Lite In Swift

`TFLiteExample.swift` uses real TensorFlow Lite in Swift:

- `TensorFlowLite.Interpreter`
- `allocateTensors()`, `copy(...)`, `invoke()`, `output(at:)`

To run it in Xcode, add TensorFlow Lite (tensorflow.org/lite), for example via CocoaPods (`TensorFlowLiteSwift`) or manual framework linking.

If TensorFlow Lite is not linked, the file compiles a fallback path (without TensorFlowLite imports) so the full package still builds correctly.

## Podfile (ML Kit + ONNX Runtime)

The examples directory includes a ready `Podfile` with:

- `GoogleMLKit/FaceDetection`
- `GoogleMLKit/Vision`
- `onnxruntime-objc`
- `TensorFlowLiteSwift`

Steps:

1. Open `Podfile` and change the target name from `WildEdgeExamplesApp` to your app target name.
2. Run `pod install` in `SPMExamples`.
3. Open the `.xcworkspace` instead of `.xcodeproj`.
