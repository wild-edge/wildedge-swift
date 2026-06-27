# CarScannerExample

An iOS example app ("WE Scan") that uses the device camera or photo library to identify cars in real time using vision-language AI models, with inference telemetry via the [WildEdge SDK](https://wildedge.dev).

Point the camera at any car, tap the shutter, and the app sends the image to a cloud vision model — **Gemini 2.5 Flash** via the Google AI API, via OpenRouter, or both simultaneously — and displays the detected make, model, color, year, and confidence score.

## Requirements

- Xcode 15+
- iOS 16+ device or simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A **Gemini API key** and/or an **OpenRouter API key**

---

## 1. Setup

```bash
cd Examples/CarScannerExample

# Generate the Xcode project
xcodegen generate

open CarScannerExample.xcodeproj
```

---

## 2. API Keys

Open `Sources/Info.plist` and replace the placeholder values:

```xml
<key>GEMINI_API_KEY</key>
<string>YOUR_GEMINI_API_KEY</string>

<key>OPENROUTER_API_KEY</key>
<string>YOUR_OPENROUTER_API_KEY</string>
```

You only need to fill in the key(s) for the provider(s) you intend to use. Get a Gemini key at [aistudio.google.com](https://aistudio.google.com) and an OpenRouter key at [openrouter.ai](https://openrouter.ai).

---

## 3. WildEdge DSN

Open `Sources/Info.plist` and set your project DSN (required for telemetry):

```xml
<key>WILDEDGE_DSN</key>
<string>https://<key>@ingest.wildedge.dev/<project-id></string>
```

`WILDEDGE_DEBUG` can be set to `true` to confirm events are flushed in the Xcode console during development.

---

## 4. Code signing

The project ships with signing disabled for easier getting started. To run on a **physical device**:

1. In Xcode, select the **CarScannerExample** project in the navigator.
2. Select the **CarScannerExample** target → **Signing & Capabilities**.
3. Check **Automatically manage signing**.
4. Set **Team** to your Apple Developer account (free personal teams work).

For the **Simulator** no signing is required.

> **Camera note:** The live camera preview requires a physical device. On the Simulator only the Photos picker flow is available.

---

## 5. Usage

1. Select the recognition provider from the segmented control at the top: **OpenRouter**, **Gemini**, or **Both**.
2. Tap the shutter button to capture a still from the live camera feed, or tap the photo icon to pick an image from your library.
3. The app sends the image to the selected provider and streams back the identified car candidates (brand, model, color, year, confidence).
4. Tap any result card in the scan history grid to see the full detail view, including raw JSON, HTTP stats, and WildEdge inference ID.
5. Use the **settings** icon to adjust the upload image size (256–2048 px) and JPEG compression quality before scanning.

---

## 6. Troubleshooting

### Package resolution errors / stale cache

If Xcode shows errors like *"missing package product"* or *"could not resolve packages"*, reset the package cache:

**Xcode menu → File → Packages → Reset Package Caches**

Then rebuild with **⌘ + Shift + K** (clean) followed by **⌘ + B** (build).

### API key errors

If you see *"Set GEMINI_API_KEY in Info.plist"* or *"Set OPENROUTER_API_KEY in Info.plist"* at runtime, confirm the placeholder in `Info.plist` has been replaced with a real key and that you have selected the matching provider in the UI.
