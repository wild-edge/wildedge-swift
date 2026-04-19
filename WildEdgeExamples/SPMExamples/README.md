# WildEdge iOS Examples

This directory contains iOS SDK usage scenarios.

## How To Open In Xcode

Recommended:

1. Open `WildEdgeExamples/SPMExamples/Package.swift` in Xcode.
2. Xcode will load the Swift Package as a workspace.
3. Run the `WildEdgeExamples` target.

If the `WildEdge` dependency does not resolve after opening, go to `File > Packages` and click `Reset Package Caches`, then `Resolve Package Versions`.

## DSN Configuration

The SDK reads DSN from the `WILDEDGE_DSN` environment variable.

Example terminal run:

```bash
cd WildEdgeExamples/SPMExamples
export WILDEDGE_DSN="https://<secret>@ingest.wildedge.dev/<key>"
swift run
```

## Contents

- `../iOSAppSample/` - full SwiftUI iOS app that demonstrates an end-to-end SDK flow
- `CoroutinesExample.swift` - async/await and AsyncStream-based tracking examples
- `GalleryExample.swift` - gallery and token-streaming equivalent
- `MLKitExample.swift` - detection equivalent using Google ML Kit Face Detection
- `OnnxExample.swift` - ONNX session equivalent using ONNX Runtime (onnxruntime.ai)
- `TFLiteExample.swift` - TFLite classification equivalent using TensorFlow Lite
- `TracingExample.swift` - trace/span equivalent for a pipeline

## ML Kit On iOS

`MLKitExample.swift` uses native Google ML Kit classes on iOS:

- `MLKitFaceDetection.FaceDetector`
- `MLKitVision.VisionImage`

To run it in Xcode, add Google ML Kit (FaceDetection + Vision) to your project, for example via CocoaPods or manual framework linking.

If ML Kit libraries are not linked, the file compiles a fallback path (without ML Kit imports) so the full package still builds correctly.

## ONNX Runtime On iOS

`OnnxExample.swift` uses native ONNX Runtime classes for iOS:

- `ORTEnv`
- `ORTSession`
- `ORTValue`

To run it in Xcode, add ONNX Runtime iOS (onnxruntime.ai), for example via CocoaPods or manual framework linking.

If ONNX Runtime is not linked, the file compiles a fallback path (without ORT imports) so the full package still builds correctly.

## TensorFlow Lite On iOS

`TFLiteExample.swift` uses real TensorFlow Lite on iOS:

- `TensorFlowLite.Interpreter`
- `allocateTensors()`, `copy(...)`, `invoke()`, `output(at:)`

To run it in Xcode, add TensorFlow Lite iOS (tensorflow.org/lite), for example via CocoaPods (`TensorFlowLiteSwift`) or manual framework linking.

If TensorFlow Lite is not linked, the file compiles a fallback path (without TensorFlowLite imports) so the full package still builds correctly.

## Podfile (ML Kit + ONNX Runtime)

The examples directory includes a ready `Podfile` with:

- `GoogleMLKit/FaceDetection`
- `GoogleMLKit/Vision`
- `onnxruntime-objc`
- `TensorFlowLiteSwift`

Steps:

1. Open `Podfile` and change the target name from `WildEdgeExamplesApp` to your app target name.
2. Run `pod install` in `WildEdgeExamples/SPMExamples`.
3. Open the `.xcworkspace` instead of `.xcodeproj`.
