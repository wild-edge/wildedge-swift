# WildEdge iOS Sample App

This app is a SwiftUI usage example of the WildEdge SDK with an end-to-end event flow:

- initialize client
- show status (reporting enabled vs noop)
- register model
- download model file and track `model_download`
- run a traced batch with 10 inference events
- track feedback
- flush and show pending counts

## Requirements

- Xcode 15+
- iOS 14+

## Open and Run

1. Open `WildEdgeExamples/iOSAppSample/WildEdgeiOSSample.xcodeproj`.
2. Select an iOS Simulator.
3. Run the `WildEdgeiOSSample` scheme.

## Configure DSN

By default, the app runs in noop mode.

To enable reporting, set `WILDEDGE_DSN` in Build Settings for the app target:

- Build Settings -> User-Defined -> `WILDEDGE_DSN`
- Example value: `https://<secret>@ingest.wildedge.dev/<key>`

## Notes

- The sample tracks synthetic inference payloads to keep dependencies minimal.
- Download URL points to a MobileNet `.tflite` file used only to demonstrate tracked download flow.
