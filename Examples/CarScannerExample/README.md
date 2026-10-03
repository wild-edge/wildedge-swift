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

# Fetch the on-device models first, if you have access (see section 6)

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

While the camera is live, an on-device detector draws a box around any car, truck, bus or motorcycle in frame. It runs locally at ~4 fps, costs nothing, and is independent of the cloud scan — the shutter still sends the whole frame to the selected provider.

---

## 6. On-device models

The detector and the brand classifier are **not in this repository**: `*.mlpackage/` is gitignored, so a fresh checkout has neither. The app still builds and runs without them. With no detector there are no live boxes and no crop, and with no classifier there is no brand hint.

**To get the models, contact [WildEdge](https://wildedge.dev).** Both live in private Hugging Face repositories. The classifier was trained on research-only datasets (VMMRdb, Stanford Cars, DVM-CAR), so its weights must not be redistributed or shipped in a commercial product.

Once you have access, fetch them **before** `xcodegen generate`, since the project only picks up files that exist:

```bash
hf download WildEdgeDev/we-scan-detector-coreml \
  --include "coreml/model_fp16.mlpackage/*" "coreml/model_int8.mlpackage/*" \
  --local-dir /tmp/detector
cp -R /tmp/detector/coreml/model_fp16.mlpackage Sources/VehicleDetectorModel.mlpackage
cp -R /tmp/detector/coreml/model_int8.mlpackage Sources/VehicleDetectorModelInt8.mlpackage

hf download WildEdgeDev/we-scan-brand-classifier \
  --include "coreml/model_fp16.mlpackage/*" --local-dir /tmp/brand
cp -R /tmp/brand/coreml/model_fp16.mlpackage Sources/BrandClassifierModel.mlpackage

xcodegen generate
```

---

## 7. On-device vehicle detector

While the camera is live, **RT-DETR r18vd** (Core ML, fp16 or int8) draws a box around any car, truck, bus or motorcycle in frame. `VehicleDetector.swift` runs it through Vision with `.computeUnits = .all`, and the app skips the local loop if the model is missing. RT-DETR needs no NMS: the app keeps any of the 300 queries whose sigmoid score for a vehicle class is at least **0.5**. The 80-class output uses the contiguous COCO map, so the vehicle ids are **2, 3, 5 and 7**, not the 91-class ids listed on the model card. **Settings → On-Device Detector** switches builds at runtime, and fp16 is the default. Both builds take about 30 ms on an iPhone 13 and an iPhone 17 alike, so int8 saves 19 MB but buys no speed and its boxes are less accurate. Live preview frames are not reported to WildEdge; only the detection on each scanned still is.

---

## 8. On-device brand classifier

Before a scan reaches the cloud provider, the app names the manufacturer locally and adds that guess to the prompt. It pads the detector's largest vehicle box by 12% a side and squashes the crop to 224x224, matching how the classifier was trained. The model ranks 43 mostly-European brands, and if the top one clears **0.35** the prompt gets a hint such as "Tesla 78%, Rolls-Royce 1%, Mitsubishi 1%", framed as a prior rather than evidence. Despite being a Core ML classifier, it outputs **raw logits**, so `BrandClassifier.softmax` normalizes them before use. It has no "not a car" class, which is what the threshold guards against. Any failure (missing model, no vehicle, a flat ranking) sends the prompt unchanged. Tapping a scan shows the classifier's brand, confidence, runners-up, latency and whether the hint reached the provider.

## 9. Troubleshooting

### Package resolution errors / stale cache

If Xcode shows errors like *"missing package product"* or *"could not resolve packages"*, reset the package cache:

**Xcode menu → File → Packages → Reset Package Caches**

Then rebuild with **⌘ + Shift + K** (clean) followed by **⌘ + B** (build).

### API key errors

If you see *"Set GEMINI_API_KEY in Info.plist"* or *"Set OPENROUTER_API_KEY in Info.plist"* at runtime, confirm the placeholder in `Info.plist` has been replaced with a real key and that you have selected the matching provider in the UI.
