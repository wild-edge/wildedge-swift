# llamaExample

An iOS example app that runs local LLM inference on-device using [llama.cpp](https://github.com/ggml-org/llama.cpp) (release **b9305**), with inference telemetry via the [WildEdge SDK](https://wildedge.dev).

The app lets you download models directly in-app or pick any GGUF file from the Files app, enter a prompt, and stream tokens in real time — no server required.

## Requirements

- Xcode 15+
- iOS 16+ device or simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

---

## 1. Setup

```bash
cd Examples/llamaExample

# Download and unpack the llama.cpp xcframework (one-time, ~700 MB)
bash setup.sh

# Generate the Xcode project
xcodegen generate

open llamaExample.xcodeproj
```

> **Why setup.sh?** The official GitHub release zip nests the xcframework under `build-apple/`, which SPM's remote binary target resolver rejects as an invalid archive. `setup.sh` extracts it to the correct flat path (`LlamaPackage/Frameworks/llama.xcframework`) that Xcode and SPM accept. The directory is git-ignored.

---

## 2. WildEdge DSN

Open `Sources/Info.plist` and set your project DSN:

```xml
<key>WILDEDGE_DSN</key>
<string>https://<key>@ingest.wildedge.dev/<project-id></string>
```

`WILDEDGE_DEBUG` is already set to `true` so you can confirm events are flushed in the Xcode console during development.

---

## 3. Code signing

The project ships with signing disabled for easier getting started. To run on a **physical device** you need to assign a team:

1. In Xcode, select the **llamaExample** project in the navigator.
2. Select the **llamaExample** target → **Signing & Capabilities**.
3. Check **Automatically manage signing**.
4. Set **Team** to your Apple Developer account (free personal teams work).
5. Xcode will generate a provisioning profile automatically.

For the **Simulator** no signing is required — just select any iPhone simulator and hit **Run**.

---

## 4. Troubleshooting

### Package resolution errors / stale cache

If Xcode shows errors like *"missing package product"*, *"invalid checksum"*, or *"could not resolve packages"* after changing `Package.swift`, reset the package cache:

**Xcode menu → File → Packages → Reset Package Caches**

Then rebuild with **⌘ + Shift + K** (clean) followed by **⌘ + B** (build).

Alternatively from the terminal:

```bash
# Remove Xcode's derived data for this project
rm -rf ~/Library/Developer/Xcode/DerivedData/llamaExample-*

# Remove the SPM global cache (re-downloads all packages)
rm -rf ~/Library/Caches/org.swift.swiftpm
```

### xcframework missing

If you see *"binary target 'llama' is missing"* it means `setup.sh` hasn't been run yet:

```bash
bash setup.sh
```

---

## 5. Usage

1. Tap **Pick Model** to open the model library.
2. Download one of the built-in models (Qwen2.5 0.5B or TinyLlama 1.1B), or tap **Pick from Files** to load any `.gguf` from the Files app.
3. After the model loads, edit the prompt in the text field.
4. Tap **Generate** to stream tokens in real time.
5. Tap **Stop** at any time to cancel generation.
6. Tap **Unload** (top-right) to free memory before switching models.

---

## How it works

```
LlamaPackage/Package.swift
└── binaryTarget(path:) → LlamaPackage/Frameworks/llama.xcframework

Sources/
├── LlamaExampleApp.swift     @main entry — WildEdge.initialize()
├── LlamaRunner.swift         @MainActor ObservableObject wrapping the C API
│   ├── loadModel()           llama_model_load_from_file + llama_init_from_model
│   │                         → WildEdge trackLoad (duration, GPU accelerator)
│   ├── generate()            tokenize → prefill batch → autoregressive decode loop
│   │                         → WildEdge trackInference (tokens in/out, TPS, stop reason)
│   └── freeAll()             frees C resources → WildEdge trackUnload
├── ModelDownloader.swift     URLSession download manager for the in-app catalog
│                             → WildEdge trackDownload on completion
├── ModelLibraryView.swift    Sheet with catalog rows + "Pick from Files" option
└── ContentView.swift         Main screen — prompt input + streaming output
```

`LlamaRunner` calls the llama.cpp C API directly from Swift. The xcframework bundles a `module.modulemap` that makes `import llama` work — no bridging header needed.

WildEdge cannot zero-code-intercept C libraries, so telemetry is wired manually at each lifecycle point: `trackLoad`, `trackInference`, `trackDownload`, and `trackUnload`.

---

## Updating to a newer llama.cpp release

1. Edit `RELEASE` in [`setup.sh`](setup.sh) to the new tag (e.g. `b9309`).
2. Delete the old xcframework: `rm -rf LlamaPackage/Frameworks/`
3. Re-run `bash setup.sh`.
4. In Xcode: **File → Packages → Reset Package Caches**, then rebuild.
