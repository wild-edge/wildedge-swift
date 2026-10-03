# LFM Crash Investigation

Date: 2026-05-27

Device: iPhone 16 Pro, iOS 26.3.1 (23D771330a)

App: `dev.wildedge.sample.voice`, benchmark build

LeapSDK: 0.10.7

## Conclusion

The LFM audio crash was caused by conflicting llama.cpp runtimes in the same iOS app process.

The broken build embedded app-level `llama.framework` through `llama.swift` while LeapSDK also embedded and used its own `libinference_engine_llamacpp_backend.framework`. Removing `llama.swift` from the app target restores LeapSDK's LFM2.5 audio path on LeapSDK 0.10.7.

Practical rule for this app: do not link a second upstream llama.cpp runtime into the same target that uses LeapSDK audio models, unless that runtime is fully symbol-isolated from LeapSDK's backend.

## Finding

The current LFM crash was reproduced only in builds that also linked the app-level `llama.swift` package. Removing `llama.swift` from the app target and relying only on LeapSDK's bundled llama.cpp backend makes `LFM2.5-Audio-1.5B Q4_0` load and transcribe successfully again.

The suspected breaking commit is `cc21ba519bda9b7dd3e5c0d894609a246abd60fd` (`supporting more models`), which added:

- `llama.swift` as a SwiftPM dependency.
- `LlamaSwift` as an app framework dependency.
- App-side llama.cpp text-to-tool loading code.

The known working TestFlight commit is `a860724f23c718a99bdeb24791a83b71346dc190` (`released to testflight`), which did not link `llama.swift`.

## Crash Evidence

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

At the time of this crash, the app bundle also embedded `llama.framework` from `llama.swift`. Both that framework and LeapSDK's `libinference_engine_llamacpp_backend.framework` export public `_llama_*` symbols. That makes symbol interposition or backend state collision the most likely explanation for why LeapSDK's own loader behaved differently in the app than it does in isolation.

## Direct llama.cpp Probe

Date: 2026-05-28

Build: `VoiceRecorderSample-Benchmark`, LeapSDK 0.10.7, `llama.swift` 2.9357.0. Xcode reported the device OS as iOS 26.5 for this run.

Launch:

```sh
xcrun devicectl device process launch \
  --device 2819DC7E-216A-5DF6-8368-17DDCB1C176F \
  --terminate-existing \
  --console \
  --timeout 180 \
  --environment-variables '{"LLAMA_LFM_DEBUG":"1"}' \
  dev.wildedge.sample.voice
```

Result: the same cached Leap-managed GGUF loads successfully through direct `llama.cpp` calls.

Relevant console output:

```text
[LlamaLfmDebug] gguf=.../Documents/leap_models/LFM2.5-Audio-1.5B-Q4_0/LFM2.5-Audio-1.5B-Q4_0.gguf
[LlamaLfmDebug] size=695750880
general.architecture = lfm2
lfm2.context_length = 128000
print_info: arch = lfm2
print_info: n_ctx_train = 128000
load_tensors: offloaded 17/17 layers to GPU
[LlamaLfmDebug] model loaded
llama_context: n_ctx = 128000
llama_kv_cache: MTL0 KV buffer size = 1500.00 MiB
sched_reserve: MTL0 compute buffer size = 395.03 MiB
sched_reserve: CPU compute buffer size = 258.01 MiB
[LlamaLfmDebug] context loaded n_ctx=128000
[LlamaLfmDebug] direct llama.cpp load succeeded
```

Conclusion: the cached `LFM2.5-Audio-1.5B-Q4_0.gguf` is not intrinsically invalid. A current direct llama.cpp path recognizes `general.architecture = lfm2`, reads `lfm2.context_length`, loads tensors, and creates a resident 128000-token context. The LeapSDK failing path is therefore likely using a different bundled inference backend or architecture dispatch that incorrectly resolves this model as `gpt-oss` and asks for `gpt-oss.context_length`.

This probe only validates model/context loading. It does not yet implement audio transcription because raw llama.cpp inference still needs the LFM audio frontend: audio decoding, feature extraction/audio tokenization, chat-template construction for audio parts, decode loop, and output parsing. LeapSDK was previously providing that higher-level audio adapter.

## No-llama.swift Verification

Date: 2026-05-28

Build: latest local code, LeapSDK 0.10.7, with `llama.swift` removed from `project.yml`, `Package.resolved`, and the Xcode target dependencies.

Bundle inspection:

```text
VoiceRecorderSample.app/Frameworks/LeapSDK.framework
VoiceRecorderSample.app/Frameworks/libinference_engine.framework
VoiceRecorderSample.app/Frameworks/libinference_engine_llamacpp_backend.framework
```

There is no `VoiceRecorderSample.app/Frameworks/llama.framework`, and `VoiceRecorderSample.debug.dylib` no longer links `@rpath/llama.framework/llama`.

Launch:

```sh
xcrun devicectl device process launch \
  --device 2819DC7E-216A-5DF6-8368-17DDCB1C176F \
  --environment-variables '{"LEAP_AUDIO_DEBUG":"1"}' \
  --console \
  dev.wildedge.sample.voice
```

Result: LeapSDK loaded the audio model and completed transcription.

Relevant console output:

```text
LeapSDK load started: LFM2.5-Audio-1.5B Q4_0
Using lfm2 audio engine
general.architecture = lfm2
lfm2.context_length = 128000
print_info: arch = lfm2
print_info: n_ctx_train = 128000
llama_context: n_ctx = 8192
loaded .../mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf
loaded .../vocoder-LFM2.5-Audio-1.5B-Q4_0.gguf
mtmd_context: audio decoder initialized
LeapSDK load completed
Leap ASR chunk: Set
Leap ASR chunk:  the
Leap ASR chunk:  temperature
Leap ASR chunk:  to
Leap ASR chunk:  twenty
Leap ASR chunk: -one
Leap ASR chunk:  degrees
Leap ASR chunk: .
[LeapFixtureDebug] transcript=Set the temperature to twenty-one degrees.
```

Conclusion: LeapSDK 0.10.7 can load and run this LFM audio model when the app does not also link `llama.swift`. The remote artifact and LeapSDK 0.10.7 are not sufficient to explain the crash.

## Current Mitigation

The current mitigation is to not link app-level `llama.swift` into VoiceRecorderSample. `LeapSpeechTranscriber.isLoadTemporarilyDisabled` is now false again, so LeapSDK is the only LFM audio loading path.

The app still contains conditional source for local GGUF text-to-tool models, but with `llama.swift` absent `canImport(LlamaSwift)` is false and that code falls back to controlled "not linked" errors.

## Ranked Theses

1. Confirmed: adding `llama.swift` to the app target breaks LeapSDK's LFM audio loading.

Evidence: the same app, same LeapSDK 0.10.7, same cached Leap model folder, and same fixture succeeds after removing `llama.swift`. The built app no longer embeds `llama.framework`; LeapSDK loads the main GGUF, mmproj, and vocoder, then transcribes audio.

Likely mechanism: duplicate exported llama.cpp C symbols or global backend state collision between app-level `llama.framework` and LeapSDK's bundled `libinference_engine_llamacpp_backend.framework`.

Test to clear: re-add `llama.swift` without calling any app-side llama code and run the same `LEAP_AUDIO_DEBUG=1` path. If it fails again, linking/embedding alone is enough to trigger the collision.

2. Reclassified: LeapSDK 0.10.7 metadata/backend mismatch for `LFM2.5-Audio-1.5B Q4_0` is a symptom in the conflicted build, not an intrinsic SDK/model failure.

Evidence: the loaded GGUF metadata exposes `lfm2.context_length`, but the backend asks for `gpt-oss.context_length`. The crash happens inside LeapSDK model loading before generation starts.

Evidence against it being intrinsic: the no-`llama.swift` build loads the same model through LeapSDK and completes ASR.

Test to clear: keep `llama.swift` removed and run the full remote benchmark config repeatedly, including after uninstall/reinstall.

3. Possible: the same symbol/backend collision explains the text-only LFM failures.

Evidence: `lfm2.5-350m` and `lfm2.5-1.2b-instruct` previously failed at load with the same missing `gpt-oss.context_length` metadata family. Those models are already disabled for `text_to_tool`.

Test to clear: launch a small isolated app path that only calls `Leap.shared.load` for `LFM2.5-350M Q4_K_M` after the SDK/model update.

4. Likely not a memory jetsam.

Evidence: the device reports `EXC_CRASH`, `SIGABRT`, `Abort trap: 6`, and a LeapSDK/Kotlin unhandled exception. The console shows around 5460 MiB free on the Apple A18 Pro GPU before load. This is a backend abort, not an iOS memory kill.

Test to clear: check for a matching `JetsamEvent` at the same timestamp. The copied VoiceRecorderSample reports are not jetsam reports.

5. Possible but not primary: stale app container cache.

Evidence: the GGUF path is in the app container under `Documents/leap_models`. Reinstalling the app does not necessarily clear this directory. A corrupt or outdated cached model could make repeat failures deterministic.

Evidence against: the backend successfully reads a coherent GGUF V3 header and metadata, then fails on a specific missing metadata key. That points more to an SDK/model compatibility issue than a partial download.

Test to clear: uninstall the app, reinstall, let LeapSDK redownload the model, and confirm whether the same metadata error appears. This test is useful but should not be expected to fix the key mismatch.

6. Separate issue: app-side llama.cpp text-to-tool can also abort.

Evidence: `VoiceRecorderSample-2026-05-27-203432.ips` is a different crash family. It aborts in `ggml_abort`, `llama_decode`, and `LlamaCppBenchmarkTextToToolModel.decode`, not in LeapSDK. That report belongs to the TinyLlama/Qwen/FunctionGemma llama.cpp path, not the Leap LFM path.

Test to clear: reproduce with a fixed text-only config and capture the llama.cpp log around `llama_decode`.

7. Unlikely: prompt or audio fixture content.

Evidence: the confirmed LFM crash happens in `loadModel` before `createConversation`, before the prompt, and before the audio file is sent to generation.

Test to clear: call `prepareModel()` without any audio input. The current console run already failed during model preparation. The separate direct llama.cpp probe also loads the model without any audio input.

8. Unlikely: our recent switch back to `options: nil`.

Evidence: older commits used the same direct `Leap.shared.load(... options: nil ...)` shape for `LeapSpeechTranscriber`, and `project.yml` pinned LeapSDK 0.10.6 in the compared commits. The latest console failure is not caused by explicit manifest options.

Test to clear: compare against a build with an older LeapSDK or a known-working Leap-managed model manifest rather than only comparing app code.

## Next Decisive Actions

1. Keep `llama.swift` out of the app target while using LeapSDK audio models.
2. Run the original remote benchmark config again on device with this no-`llama.swift` build.
3. If local llama.cpp text-to-tool models are still needed, isolate them from the app process. Options include a separate test target/app, a differently named/private llama build that does not export `_llama_*`, or using LeapSDK/MLX paths instead of linking a second llama runtime.
4. Reproduce by re-adding only the `llama.swift` dependency, without calling app-side llama code. That will prove whether link-time embedding alone is the trigger.
5. If we need to discuss this with Liquid, frame it as a symbol/runtime collision between a second app-linked llama.cpp XCFramework and LeapSDK's bundled llama.cpp backend.
