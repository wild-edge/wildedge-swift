# LFM Crash Investigation

Date: 2026-05-27

Device: iPhone 16 Pro, iOS 26.3.1 (23D771330a)

App: `dev.wildedge.sample.voice`, benchmark build

LeapSDK: 0.10.6

## Finding

The current LFM crash is caused by LeapSDK aborting while loading `LFM2.5-Audio-1.5B` with `Q4_0`.

Captured console output from the device:

```text
LeapSDK load started: LFM2.5-Audio-1.5B Q4_0
Using lfm2 audio engine
loaded meta data ... LFM2.5-Audio-1.5B-Q4_0.gguf
general.architecture = lfm2
lfm2.context_length = 128000
llama_model_load: error loading model: error loading model hyperparameters: key not found in model: gpt-oss.context_length
LeapModelLoadingException: Failed to load model: 5
Uncaught Kotlin exception
App terminated due to signal 6.
```

The crash reports match this:

- `VoiceRecorderSample-2026-05-27-202205.ips`: `EXC_CRASH`, `SIGABRT`, `InferenceEngineModelRunner.Companion#loadModel`
- `VoiceRecorderSample-2026-05-27-204247.ips`: `EXC_CRASH`, `SIGABRT`, `InferenceEngineModelRunner.Companion#loadModel`
- `VoiceRecorderSample-2026-05-27-204640.ips`: `EXC_CRASH`, `SIGABRT`, `InferenceEngineModelRunner.Companion#loadModel`

This is not a Swift error path. The SDK throws an uncaught Kotlin exception after the backend load failure, so a normal Swift `do/catch` around `Leap.shared.load` is not enough to keep the app alive.

## Current Mitigation

The app now blocks the known-bad load before calling LeapSDK:

- `LeapSpeechTranscriber.prepareModel()` returns a controlled error while `LeapSpeechTranscriber.isLoadTemporarilyDisabled` is true.
- Benchmark remote config validation marks direct `speech_to_tool` as unsupported while this SDK/model combination is blocked.
- Benchmark remote config validation also rejects Leap audio for `speech_to_text` while this SDK/model combination is blocked.

This keeps the app from repeatedly crashing when the fetched config asks for Leap audio.

## Ranked Theses

1. Confirmed: LeapSDK 0.10.6 has a metadata/backend mismatch for `LFM2.5-Audio-1.5B Q4_0`.

Evidence: the loaded GGUF metadata exposes `lfm2.context_length`, but the backend asks for `gpt-oss.context_length`. The crash happens inside LeapSDK model loading before generation starts.

Test to clear: update LeapSDK or the Leap-managed model package and verify the same direct `Leap.shared.load(model: "LFM2.5-Audio-1.5B", quantization: "Q4_0", options: nil)` no longer asks for `gpt-oss.context_length`.

2. Very likely: the same LeapSDK metadata issue explains the text-only LFM failures.

Evidence: `lfm2.5-350m` and `lfm2.5-1.2b-instruct` previously failed at load with the same missing `gpt-oss.context_length` metadata family. Those models are already disabled for `text_to_tool`.

Test to clear: launch a small isolated app path that only calls `Leap.shared.load` for `LFM2.5-350M Q4_K_M` after the SDK/model update.

3. Likely not a memory jetsam.

Evidence: the device reports `EXC_CRASH`, `SIGABRT`, `Abort trap: 6`, and a LeapSDK/Kotlin unhandled exception. The console shows around 5460 MiB free on the Apple A18 Pro GPU before load. This is a backend abort, not an iOS memory kill.

Test to clear: check for a matching `JetsamEvent` at the same timestamp. The copied VoiceRecorderSample reports are not jetsam reports.

4. Possible but not primary: stale app container cache.

Evidence: the GGUF path is in the app container under `Documents/leap_models`. Reinstalling the app does not necessarily clear this directory. A corrupt or outdated cached model could make repeat failures deterministic.

Evidence against: the backend successfully reads a coherent GGUF V3 header and metadata, then fails on a specific missing metadata key. That points more to an SDK/model compatibility issue than a partial download.

Test to clear: uninstall the app, reinstall, let LeapSDK redownload the model, and confirm whether the same metadata error appears. This test is useful but should not be expected to fix the key mismatch.

5. Separate issue: llama.cpp text-to-tool can also abort.

Evidence: `VoiceRecorderSample-2026-05-27-203432.ips` is a different crash family. It aborts in `ggml_abort`, `llama_decode`, and `LlamaCppBenchmarkTextToToolModel.decode`, not in LeapSDK. That report belongs to the TinyLlama/Qwen/FunctionGemma llama.cpp path, not the Leap LFM path.

Test to clear: reproduce with a fixed text-only config and capture the llama.cpp log around `llama_decode`.

6. Unlikely: prompt or audio fixture content.

Evidence: the confirmed LFM crash happens in `loadModel` before `createConversation`, before the prompt, and before the audio file is sent to generation.

Test to clear: call `prepareModel()` without any audio input. The current console run already failed during model preparation.

7. Unlikely: our recent switch back to `options: nil`.

Evidence: older commits used the same direct `Leap.shared.load(... options: nil ...)` shape for `LeapSpeechTranscriber`, and `project.yml` pinned LeapSDK 0.10.6 in the compared commits. The latest console failure is not caused by explicit manifest options.

Test to clear: compare against a build with an older LeapSDK or a known-working Leap-managed model manifest rather than only comparing app code.

## Next Decisive Actions

1. Ask Liquid/LeapSDK for the SDK version or model package that supports LFM2 GGUF metadata using `lfm2.context_length`.
2. After upgrading SDK/model package, temporarily set `LeapSpeechTranscriber.isLoadTemporarilyDisabled` to false and run only `prepareModel()` with the device console attached.
3. If the SDK still fails, uninstall the app to clear `Documents/leap_models`, reinstall, and repeat the same single-load test.
4. Only after `prepareModel()` succeeds should `speech_to_tool` benchmark runs be re-enabled.
