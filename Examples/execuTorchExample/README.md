# execuTorchExample

An iOS example app that runs local LLM inference on-device using [ExecuTorch](https://github.com/pytorch/executorch) (branch **swiftpm-1.0.0**), with telemetry via the [WildEdge SDK](https://wildedge.dev).

Models run entirely on-device via the XNNPACK CPU backend. No server, no internet connection required during inference.

## Requirements

- Xcode 15+
- iOS 17+ device or simulator
- A `.pte` model file and its `tokenizer.json` (see below)

---

## 1. Get a model

ExecuTorch uses `.pte` (PyTorch Edge) files exported from PyTorch. You need two files:

| File | Description |
|---|---|
| `model.pte` | The exported + quantized model |
| `tokenizer.json` | HuggingFace JSON tokenizer (required by ExecuTorch's HF tokenizer backend) |

### Option A — Export from PyTorch (recommended for Llama 3.2)

```bash
# Install ExecuTorch export tools
pip install executorch

# Export Llama 3.2 1B with SpinQuant quantization (~1 GB)
python -m extension.llm.export.export_llm \
  --config examples/models/llama/config/llama_spinquant.yaml \
  +base.model_class="llama3_2" \
  +base.checkpoint="${LLAMA_CHECKPOINT}" \
  +base.params="${LLAMA_PARAMS}"
```

See [ExecuTorch LLM on iOS](https://pytorch.org/executorch/stable/llm/run-on-ios.html) for full instructions including acquiring the Llama weights from Meta.

### Option B — Community models on Hugging Face

Search the [ExecuTorch community space](https://huggingface.co/models?search=executorch) on Hugging Face for pre-exported `.pte` files that don't require Meta registration.

### Transfer to device

On the **Simulator**: drag the `.pte` and `tokenizer.json` files into the app's Documents folder in the Simulator's Files app.

On a **physical device**: use AirDrop or Finder (iPhone shown in sidebar) to copy the files to the app's Documents folder.

---

## 2. Setup

```bash
open Examples/execuTorchExample/execuTorchExample.xcodeproj
```

Xcode will resolve the ExecuTorch Swift Package automatically on first open (this downloads ~500 MB of prebuilt xcframeworks). If package resolution fails, use **File → Packages → Reset Package Caches**.

---

## 3. WildEdge DSN

Open `Sources/Info.plist` and replace the placeholder with your project DSN:

```xml
<key>WILDEDGE_DSN</key>
<string>https://<key>@ingest.wildedge.dev/<project-id></string>
```

`WILDEDGE_DEBUG` is set to `true` so events are logged to the Xcode console during development.

---

## 4. Code signing

The project ships with signing disabled. To run on a **physical device**:

1. In Xcode, select the **execuTorchExample** target → **Signing & Capabilities**.
2. Check **Automatically manage signing**.
3. Set **Team** to your Apple Developer account.

> The `increased-memory-limit` entitlement (already in `execuTorchExample.entitlements`) allows the app to use more than the default RAM limit — required for models above ~1.5 GB.

For the **Simulator** no signing is required.

---

## 5. Troubleshooting

### Package resolution errors

**Xcode menu → File → Packages → Reset Package Caches**, then **⌘ + Shift + K** (clean) and **⌘ + B** (build).

### Duplicate symbol linker errors

The project uses `-Wl,-all_load` to force-load ExecuTorch backend registration. If you see duplicate symbol errors, remove that flag from **Build Settings → Other Linker Flags** and re-add only the specific ExecuTorch framework paths instead.

### Model loads but generates nothing

Verify the tokenizer matches the model. The catalog models use `tokenizer.json` (HuggingFace JSON format); using a mismatched tokenizer produces empty output.

---

## 6. Usage

### Using the catalog

1. Tap **Pick Model** to open the model library.
2. Tap **↓ Download** on a catalog model — both the `.pte` file and `tokenizer.json` download automatically. Progress is shown as a combined byte count.
3. When both files are ready the button changes to **Load** — tap it.
4. Wait for the model to initialise (10–30 s for 1B+ models; the main screen shows a spinner).
5. Edit the prompt and tap **Generate** to stream tokens.
6. Tap **Stop** to cancel, or **Unload** (top-right) to free memory before switching models.

### Using your own model files

1. Transfer both files to the device:
   - **Simulator** — drag the `.pte` and `tokenizer.json` into the Simulator's Files app window.
   - **Physical device** — AirDrop the files, or copy them via Finder (iPhone → Files → execuTorchExample).
2. Tap **Pick Model** → scroll to **Or pick from Files**.
3. Tap **Browse** next to *Model (.pte)* and select your `.pte` file.
4. Tap **Browse** next to *Tokenizer (.json / .model / .bin)* and select the matching tokenizer. If a `tokenizer.json` with the expected name already exists in the app's Documents folder it may be auto-detected and pre-filled.
5. Tap **Load Custom Model** (enabled once both files are selected).
6. Wait for the model to initialise, then generate as normal.

---

## How it works

```
Sources/
├── ExecuTorchExampleApp.swift   @main — WildEdge.initialize()
├── LLMRunner.swift              @MainActor ObservableObject
│   ├── loadModel()              TextRunner init + load() on background thread
│   │                            → WildEdge trackLoad (duration, CPU accelerator)
│   ├── generate()               ExecuTorchLLMConfig + r.generate() token callback
│   │                            → WildEdge trackInference (tokens out, TPS, stop reason)
│   └── unload()                 runner.reset() + runner = nil
│                                → WildEdge trackUnload
└── ContentView.swift            File pickers + streaming output UI
```

`TextRunner` (`ExecuTorchLLMTextRunner` in ObjC) is the ExecuTorch Swift-bridged class for text LLM inference. Its `generate(_:_:tokenCallback:)` method is a **blocking** call that streams tokens via a Swift closure — it must run on a background thread (`Task.detached`). UI updates are dispatched back to the main actor per token.

Unlike `llamaExample` (llama.cpp), there is no manual KV-cache management or sampler setup — ExecuTorch's runtime handles that internally.

---

## Differences from llamaExample

| | llamaExample | execuTorchExample |
|---|---|---|
| Runtime | llama.cpp (C API) | ExecuTorch (C++, Swift-bridged) |
| Model format | `.gguf` | `.pte` |
| Extra files | Model only | Model + tokenizer |
| Backends | Metal GPU | XNNPACK CPU |
| In-app download | Yes (catalog) | No (pick from Files) |
| Model management | Manual (KV cache, sampler) | Managed by runtime |
