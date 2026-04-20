# WildEdge Swift Examples

This directory contains two Swift SDK example tracks: a full iOS app sample (`iOSAppSample`) and Swift Package examples (`SPMExamples`).

## DSN Configuration

To run the examples, you need to obtain a DSN (configuration parameter).

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

or run from terminal:

```bash
cd SPMExamples
export WILDEDGE_DSN="https://<secret>@ingest.wildedge.dev/<key>"
swift run
```

If the `WildEdge` dependency does not resolve after opening in Xcode, go to `File > Packages` and click `Reset Package Caches`, then `Resolve Package Versions`.
