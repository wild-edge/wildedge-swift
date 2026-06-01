# LeapSDK LFM Audio Benchmark Notes

This note records how `VoiceRecorderSample-Benchmark` runs the LeapSDK LFM audio benchmark and what the reported latency means.

## Model And Flow

- Build scheme: `VoiceRecorderSample-Benchmark`
- Build configuration: `Benchmark`
- Separate LeapSDK app scheme: `VoiceRecorderSample-Benchmark-LeapSDK`
- Separate LeapSDK app configuration: `BenchmarkLeapSDK`
- Separate LeapSDK app bundle ID: `dev.wildedge.sample.voice-leapsdk`
- Current LeapSDK experiment step: `speech_to_tool`
- Current LeapSDK experiment flag: `LEAP_SDK_SPEECH_TO_TOOL_ONLY`
- Model loaded through LeapSDK: `LFM2.5-Audio-1.5B`
- Quantization: `Q4_0`
- Leap KV prompt cache: enabled at `Application Support/leap-kv-cache`
- App-level `llama.framework`: not linked
- Expected LeapSDK bundled backend: `libinference_engine_llamacpp_backend.framework`

The current speech-to-tool experiment flow is:

```text
benchmark .m4a fixture
  -> pre-converted WAV fixture for LeapSDK input
  -> LeapSDK LFM2.5-Audio-1.5B Q4_0
  -> JSON tool-call text
  -> canonical JSON comparison against benchmark_data/<line_id>.json
```

The `VoiceRecorderSample-Benchmark-LeapSDK` build is the dedicated LeapSDK flavor. For the current latency experiment it compiles with `LEAP_SDK_SPEECH_TO_TOOL_ONLY`, installs as a separate app from `dev.wildedge.sample.voice`, and forces the benchmark flow to `speech_to_tool` with the Leap audio model even if the remote SDK config contains a different `benchmark_steps` value. Remote config can still control non-flow benchmark settings such as `delay_seconds`, `number_of_inferences`, `loop`, `recordings_match`, and the prompt override under `model_definitions.leap-lfm2.5-audio-1.5b.inference.system_prompt`.

For direct `speech_to_tool`, the Leap audio engine must use this SDK system prompt:

```text
Perform ASR.
```

The benchmark prompt that defines the expected JSON output and allowed calls is sent as text together with the audio. The remote config field is named `system_prompt` because it is the benchmark's prompt contract, but the app deliberately passes it as the text part of the audio message. Do not replace the SDK system prompt above. Leap's LFM audio engine rejects unsupported SDK system prompts and returns `complete(text:0)` almost immediately, which looks like a 7-10 ms "inference" but is actually a rejected generation request.

## Remote SDK Config

The remote payload should enable the direct flow and the Leap model. To keep the benchmark app simple, define the JSON output contract and possible calls in one remotely scoped prompt string:

```json
{
  "config_version": 1,
  "benchmark_params": {
    "benchmark_steps": ["speech_to_tool"],
    "delay_seconds": 10,
    "number_of_inferences": 10,
    "loop": true,
    "recordings_match": "*.m4a"
  },
  "model_definitions": {
    "leap-lfm2.5-audio-1.5b": {
      "enabled": true,
      "inference": {
        "system_prompt": "Listen to the audio command and return exactly one JSON object. Do not return a transcript or explanation.\n\nOutput shape:\n{\"tool_name\":\"...\",\"arguments\":{...}}\n\nAllowed calls:\n- set_temperature: use for cabin climate, temperature, heat, cold, warmer, cooler, AC, or air conditioning. Arguments: {\"temperature\": number}.\n- change_volume: use for volume, audio loudness, sound level, louder, quieter, mute, or unmute. Arguments: {\"direction\":\"up\"|\"down\"}.\n- navigate: use for navigation, routing, directions, driving, going somewhere, or finding a route. Arguments: {\"destination\": lowercase string}.\n- unknown: use when no allowed call clearly matches. Arguments: {}.\n\nReturn only the JSON object."
      }
    }
  }
}
```

Set `"loop": false` to run one pass over the matched recordings and stop after the last inference. If omitted, the benchmark loops continuously.

Do not include `loader`, `source`, `capabilities`, download policy, security policy, memory policy, or fallback sections in the remote overlay. The local config defines the model and step; the remote payload enables the model and may override the benchmark prompt through `model_definitions.<model>.inference.system_prompt`. In the dedicated LeapSDK app flavor, the direct `speech_to_tool` flow is hardcoded by the build and does not depend on the remote `benchmark_steps` field.

This is plain JSON-text generation, not native Leap function calling. The app does not register benchmark functions with LeapSDK; it passes no `functionCalls` definitions to the SDK request. The model sees the prompt text and audio, then the app parses the returned JSON text and compares it with the expected fixture.

## What We Measure

The app measures Leap speech-to-tool latency manually around the SDK generation call:

```swift
let start = Date()
for try await response in conversation.generateResponse(message: message, generationOptions: options) {
    ...
}
let durationMs = Int(Date().timeIntervalSince(start) * 1000)
```

This means `tool_call_duration_ms` is app-measured wall-clock time for one complete `conversation.generateResponse(...)` call. It includes:

- LeapSDK audio processing inside generation, such as audio slice encoding and audio token decoding.
- Prompt evaluation.
- Text token generation until the final completion event.
- Streaming overhead inside the SDK response loop.

It excludes:

- Model download.
- Model load and initialization.
- Benchmark dataset loading.
- `.m4a` / `.mp3` to `.wav` conversion.
- Reading the prepared audio file into memory.
- Building the chat message before `generateResponse(...)`.
- The configured sleep delay between benchmark items.

Model preparation happens before measured runs in `prepareLeapSpeechToToolBenchmarkModel(...)`. The benchmark iterates over the attached `.m4a` fixtures, then converts each selected fixture to a Leap-compatible WAV before inference. The measured direct inference call receives the prepared `processingAudioURL`; conversion remains outside `tool_call_duration_ms`.

## Expected Timing

On iPhone 16 Pro with `LFM2.5-Audio-1.5B Q4_0`, direct `speech_to_tool` is currently around 2,000 ms per fixture.

On June 1, 2026, the forced Leap `speech_to_text` experiment processed the same audio fixtures in roughly 300-400 ms. That result strongly suggests the slower direct `speech_to_tool` path is not caused by audio file conversion, model preparation, or basic audio ingestion alone. The remaining likely causes are our app-side request shape, prompt length/content, JSON/tool-output constraints, or output parsing/comparison behavior around the direct tool prompt.

The default direct `speech_to_tool` user prompt is much larger than the ASR prompt. In this app, the ASR user instruction is about 118 characters, while the default direct JSON tool prompt is about 4,347 characters because it includes the output contract and examples. Device logs for the long direct prompt showed about 1,046-1,099 prompt tokens and 16-17 generated tokens, so prompt prefill can dominate repeated direct runs.

Leap prompt caching is enabled through `LiquidCacheOptions.enabled(path:)`, passed to `Leap.shared.load(...)` as `LiquidInferenceEngineManifestOptions`. The cache path is `Application Support/leap-kv-cache` in the app container. This should reduce repeated prefill cost for stable prompts, especially the full JSON tool prompt. It will not remove audio encoding/decoding time, model execution for new audio, or generated-token decoding.

Example observed logs:

```text
audio slice encoded in 102-211 ms
audio decoded in 560-686 ms
Prompt Tokens: ~1046-1099
Generated Tokens: ~16-17
Total inference time: ~1.99-2.00 s
tool_call_duration_ms: ~1960-2007
```

So the ~2 second number is expected for this measurement boundary. It is not model load time, not file conversion time, and not the benchmark sleep. It is the end-to-end LeapSDK generation latency for the direct audio-to-tool request.

## Result Semantics

The benchmark compares the generated JSON tool call against the expected JSON fixture after canonicalization.

- A match means the generated output matched the expected fixture.
- A mismatch means the JSON differed, failed parsing, or generation failed.
- The match rate is benchmark-output matching, not model accuracy in a broader statistical sense.

For WildEdge protocol events, the parent span includes fields such as:

- `benchmark_run_id`
- `benchmark_inference_id`
- `tool_call_duration_ms`
- `benchmark_matched_expected`
- `tool_call_exact_match`
- `actual_tool_call_json`
- `expected_tool_call_json`
- `benchmark_tool_call_match_count`
- `benchmark_tool_call_measured_count`
- `benchmark_tool_call_mismatches`

Mismatch metadata is capped for protocol payload size, while the app UI keeps the detailed mismatch list.

## Verification Commands

Build:

```sh
xcodebuild -project Examples/VoiceRecorderSample/VoiceRecorderSample.xcodeproj \
  -scheme VoiceRecorderSample-Benchmark \
  -configuration Benchmark \
  -destination id=00008140-001958220882201C \
  -derivedDataPath /private/tmp/wildedge-voice-benchmark-device-deriveddata \
  build
```

Install:

```sh
xcrun devicectl device install app \
  --device 2819DC7E-216A-5DF6-8368-17DDCB1C176F \
  /private/tmp/wildedge-voice-benchmark-device-deriveddata/Build/Products/Benchmark-iphoneos/VoiceRecorderSample.app
```

Launch without a console timeout for normal benchmark runs:

```sh
xcrun devicectl device process launch \
  --device 2819DC7E-216A-5DF6-8368-17DDCB1C176F \
  --environment-variables '{"LEAP_AUDIO_DEBUG":"1"}' \
  --terminate-existing \
  dev.wildedge.sample.voice
```

Use `--console` only for short debugging sessions. If a `devicectl --timeout ... --console` command times out, CoreDevice can abort the console session while the benchmark is still mid-run, which can look like the app stopped.
