# llama.cpp + libmtmd Wrapper Runbook

This runbook documents how `VoiceRecorderSample` runs local multimodal audio
input with `llama.cpp` and `libmtmd` on iOS. Use it when adding another
GGUF-based text or audio model, debugging Liquid LFM audio behavior, or moving
the wrapper into a reusable package.

## Current Working Setup

`VoiceRecorderSample` uses a local SwiftPM package at:

```text
Examples/VoiceRecorderSample/Packages/LlamaSwiftMultimodal
```

The package is intentionally shaped like a `llama.swift` replacement:

- Package name: `LlamaSwiftMultimodal`
- Product/module name: `LlamaSwift`
- Binary target: `Artifacts/llama.xcframework`
- Swift shim: re-exports the C module so app code can call `llama_*` and
  `mtmd_*` APIs directly.

The generated `llama.xcframework` is the important part. It combines:

- core `libllama`
- GGML dependencies
- Metal and BLAS backends
- `libmtmd`
- public headers for `llama.h`, `ggml*.h`, `mtmd.h`, and `mtmd-helper.h`

That means the app has one app-owned llama runtime that can run both normal
text-only GGUF models and multimodal audio GGUF models.

## How Multimodal Audio Works

Text-only GGUF inference uses normal `llama.cpp` APIs. Audio input does not.
Direct audio input requires `libmtmd`, because the model needs a multimodal
projector/audio encoder path before the language model can consume the prompt.

The current direct speech-to-tool flow is:

1. Resolve the main model GGUF.
2. Resolve the `mmproj` GGUF.
3. Load the main model with `llama_model_load_from_file`.
4. Get the vocabulary with `llama_model_get_vocab`.
5. Load the multimodal projector with `mtmd_init_from_file`.
6. Verify audio support with `mtmd_support_audio`.
7. Read the target audio sample rate with `mtmd_get_audio_sample_rate`.
8. Decode the input audio file to Float32 PCM at that sample rate.
9. Create an audio bitmap with `mtmd_bitmap_init_from_audio`.
10. Build a chat prompt that includes `mtmd_default_marker()`.
11. Create input chunks with `mtmd_input_chunks_init`.
12. Tokenize text + audio with `mtmd_tokenize`.
13. Evaluate the multimodal chunks with `mtmd_helper_eval_chunks`.
14. Generate text or JSON with the normal llama sampler/decode loop.

The key distinction is that `libmtmd` handles audio ingestion and prompt
evaluation. After that, text generation is still ordinary llama decoding.

## Liquid LFM2.5 Audio Notes

The current Liquid speech-to-tool path uses:

- main GGUF: `LFM2.5-Audio-1.5B-Q4_0.gguf`
- projector GGUF: `mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf`
- provider: `llama_cpp_mtmd`

For our current target, `audio -> JSON command`, tokenizer and vocoder files are
not part of the critical path. We only need audio input and text output.

Tokenizer and vocoder become relevant when we need one of these:

- text-to-speech output
- interleaved audio/text replies
- generated waveform output
- exact compatibility with Liquid's `llama-liquid-audio-cli` runner

If the direct `libmtmd` path loads and generates text, do not add tokenizer or
vocoder just because the official Liquid CLI accepts those files. Add them only
when audio output or exact runner compatibility becomes the goal.

## Recommended Future Approach

Build this once and reuse it as a package named `llama-multimodal`.

Recommended package shape:

```text
Packages/llama-multimodal/
  Package.swift
  Artifacts/llama.xcframework
  Sources/LlamaMultimodal/LlamaMultimodal.swift
  Scripts/build_xcframework.sh
  README.md
```

Recommended public product/module name:

```text
LlamaMultimodal
```

Keep a compatibility product named `LlamaSwift` only if existing code needs a
gradual migration. For new projects, prefer `import LlamaMultimodal` so it is
clear that the runtime includes both core llama.cpp and `libmtmd`.

Future projects should depend on this single reusable package instead of
copying `LlamaSwiftMultimodal` into each app.

## Collision Warning

Do not add a second plain `llama.swift` package beside this wrapper in the same
app target.

SwiftPM package names and module names do not isolate C symbols. The app-owned
`llama.framework` exports broad public symbols such as:

- `_llama_*`
- `_ggml_*`
- `_mtmd_*`

LeapSDK's llama backend can also export overlapping llama/mtmd symbols. Previous
LFM failures strongly suggest that duplicate llama.cpp runtimes in one iOS
process are unsafe unless the symbols are explicitly isolated.

If a second runtime ever becomes unavoidable, treat it as a separate engineering
project. It must prove isolation by:

- renaming or hiding exported C symbols
- using a distinct framework/module name
- inspecting exports with `nm -gU`
- smoke-testing both runtimes in the same app process

Default rule: extend the unified `llama-multimodal` runtime instead of linking
another llama runtime.

## Build And Verification

Build or refresh the current sample-app wrapper:

```sh
Examples/VoiceRecorderSample/Scripts/build_llama_multimodal_xcframework.sh
```

Build the Benchmark app:

```sh
xcodebuild \
  -project Examples/VoiceRecorderSample/VoiceRecorderSample.xcodeproj \
  -scheme VoiceRecorderSample-Benchmark \
  -configuration Benchmark \
  -destination generic/platform=iOS \
  -derivedDataPath /private/tmp/wildedge-lfm25-audio-build \
  build
```

Inspect the built app frameworks:

```sh
find /private/tmp/wildedge-lfm25-audio-build/Build/Products/Benchmark-iphoneos/VoiceRecorderSample.app/Frameworks \
  -maxdepth 2 \
  -type f \
  -perm +111 \
  -print
```

Inspect exported symbols before adding any other llama runtime:

```sh
nm -gU /private/tmp/wildedge-lfm25-audio-build/Build/Products/Benchmark-iphoneos/VoiceRecorderSample.app/Frameworks/llama.framework/llama
```

If another framework also embeds llama.cpp, inspect it too:

```sh
nm -gU /private/tmp/wildedge-lfm25-audio-build/Build/Products/Benchmark-iphoneos/VoiceRecorderSample.app/Frameworks/libinference_engine_llamacpp_backend.framework/libinference_engine_llamacpp_backend
```

Smoke-test these paths after any wrapper change:

- text-only GGUF model
- direct `libmtmd` audio model such as Qwen3-ASR or Ultravox
- Liquid LFM2.5 Audio speech-to-tool
- LeapSDK audio path if LeapSDK remains linked in the app

## Practical Checklist For A New Audio GGUF Model

1. Confirm the model has a main GGUF and an audio-capable `mmproj` GGUF.
2. Add a model preset with provider `llama_cpp_mtmd`.
3. Add download URLs and filenames for both files.
4. Route the model through the `LlamaMultimodalSpeechToToolModel` path.
5. Load main GGUF first, then `mmproj`.
6. Require `mtmd_support_audio` before running inference.
7. Decode audio to `mtmd_get_audio_sample_rate`.
8. Insert `mtmd_default_marker()` in the user prompt.
9. Evaluate with `mtmd_helper_eval_chunks`.
10. Generate text/JSON with the normal llama sampler loop.
11. Run the smoke tests above on device.

Keep the implementation decision simple: one unified app-owned
`llama.cpp + libmtmd` runtime for app GGUF models.
