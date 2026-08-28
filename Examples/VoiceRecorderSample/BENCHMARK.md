# VoiceRecorderSample Benchmark

## Overview

Benchmark mode is available only in `BENCHMARK_BUILD`. When `benchmark_enabled` is true, the app runs bundled benchmark WAV, MP3, or M4A files in a loop, waits 10 seconds between benchmark runs, and reports WildEdge inference events for each measured model step.

The benchmark input set and step sequence are controlled by the SDK config payload. The app uses the currently effective STT model/settings from the same payload or local settings when a run includes `speech_to_text`.

## Dataset Layout

Benchmark files live in:

`Examples/VoiceRecorderSample/benchmark_data/`

Each recording uses this identifier:

`<line_id>-<variant_id>-<speaker_id>`

Example:

`001-001-A.wav`

This means:

- `001`: benchmark line ID
- `001`: phrase variant ID
- `A`: speaker ID

Expected files are shared where possible:

- `001-001-A.wav`, `001-001-A.mp3`, or `001-001-A.m4a`: input recording for line 001, variant 001, speaker A
- `001-001-A.wav`: optional preprocessed WAV sidecar used for inference when the source input is `001-001-A.m4a` or `001-001-A.mp3`
- `001-001.txt`: expected exact transcript for line 001, variant 001, shared by speakers
- `001.json`: expected exact tool call for line 001, shared by variants and speakers

```mermaid
flowchart TD
  root["benchmark_data/"]

  root --> audio["Audio Input"]
  root --> transcript["Expected Transcript"]
  root --> tool["Expected Tool call"]

  audio --> wavA["001-001-A.m4a"]
  audio --> wavB["001-001-B.wav"]
  audio --> wavC["001-001-C.mp3"]

  transcript --> sharedTranscript["001-001.txt"]
  tool --> sharedTool["001.json"]
```

The file tree for that same example is:

```text
benchmark_data/
├── 001-001-A.m4a      # speaker A audio input
├── 001-001-A.wav      # optional preprocessed inference input
├── 001-001-B.wav      # speaker B audio input
├── 001-001-C.mp3      # speaker C audio input
├── 001-001.txt        # expected transcript for line 001, variant 001
└── 001.json           # expected tool call for line 001
```

## Dataset Assumptions

Plain Markdown tables cannot merge cells. This table uses raw HTML so the line-level expected tool call can be shown once with `rowspan`.

<table>
  <thead>
    <tr>
      <th>Category</th>
      <th>Line ID</th>
      <th>Variant ID</th>
      <th>Phrase</th>
      <th>Expected Tool Call</th>
      <th>Recording IDs</th>
      <th>Expected Transcript</th>
      <th>Expected Tool Call File</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td rowspan="3">climate</td>
      <td rowspan="3"><code>001</code></td>
      <td><code>001</code></td>
      <td>set the temperature to 21 degrees</td>
      <td rowspan="3">
        <pre><code>{
  "tool_name": "set_temperature",
  "arguments": {
    "temperature": 21
  }
}</code></pre>
      </td>
      <td><code>001-001-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>001-001.txt</code></td>
      <td rowspan="3"><code>001.json</code></td>
    </tr>
    <tr>
      <td><code>002</code></td>
      <td>set the temperature to 21 degrees, please</td>
      <td><code>001-002-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>001-002.txt</code></td>
    </tr>
    <tr>
      <td><code>003</code></td>
      <td>temperature 21 degrees</td>
      <td><code>001-003-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>001-003.txt</code></td>
    </tr>
    <tr>
      <td rowspan="3">radio</td>
      <td rowspan="3"><code>002</code></td>
      <td><code>001</code></td>
      <td>volume down</td>
      <td rowspan="3">
        <pre><code>{
  "tool_name": "change_volume",
  "arguments": {
    "direction": "down"
  }
}</code></pre>
      </td>
      <td><code>002-001-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>002-001.txt</code></td>
      <td rowspan="3"><code>002.json</code></td>
    </tr>
    <tr>
      <td><code>002</code></td>
      <td>hey, volume down</td>
      <td><code>002-002-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>002-002.txt</code></td>
    </tr>
    <tr>
      <td><code>003</code></td>
      <td>its too loud, volume down</td>
      <td><code>002-003-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>002-003.txt</code></td>
    </tr>
    <tr>
      <td rowspan="3">nav</td>
      <td rowspan="3"><code>003</code></td>
      <td><code>001</code></td>
      <td>navigate home, please</td>
      <td rowspan="3">
        <pre><code>{
  "tool_name": "navigate",
  "arguments": {
    "destination": "home"
  }
}</code></pre>
      </td>
      <td><code>003-001-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>003-001.txt</code></td>
      <td rowspan="3"><code>003.json</code></td>
    </tr>
    <tr>
      <td><code>002</code></td>
      <td>navigate home, now</td>
      <td><code>003-002-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>003-002.txt</code></td>
    </tr>
    <tr>
      <td><code>003</code></td>
      <td>let's go home</td>
      <td><code>003-003-A/B/C.wav/.mp3/.m4a</code></td>
      <td><code>003-003.txt</code></td>
    </tr>
  </tbody>
</table>

## SDK Config Selection

The SDK payload is a strict overlay on top of the local app benchmark config. The app decodes JSON into typed Swift config models, merges only allowed remote sections, validates the effective config, resolves active steps to models, estimates memory use, and then starts the benchmark.

Remote payloads may contain only:

- `config_version`
- `benchmark_params`
- `step_definitions`
- `model_definitions`

Remote payloads may not override local capabilities, download policy, security policy, memory policy, fallback behavior, app settings, or SDK refresh settings. A payload with forbidden or unknown top-level keys is rejected and the local benchmark config is used.

Minimal flow-only payload:

```json
{
  "config_version": 1,
  "benchmark_params": {
    "benchmark_steps": ["speech_to_text", "text_to_tool"],
    "delay_seconds": 10,
    "number_of_inferences": 10,
    "recordings_match": "*"
  }
}
```

One-step speech-to-tool can run Liquid LFM2.5 Audio fully on-device through the local
`llama.cpp` multimodal runtime. The app uses a `LlamaSwiftMultimodal` package
whose generated `llama.xcframework` includes `libmtmd`, `mtmd.h`, and
`mtmd-helper.h`; plain `llama.swift`/`libllama` text inference is not enough for
audio input.

Build or refresh the multimodal XCFramework with:

```sh
Examples/VoiceRecorderSample/Scripts/build_llama_multimodal_xcframework.sh
```

Then select the model in the SDK payload. The preset downloads both the
Q4_0 GGUF and the Q4_0 `mmproj` projector from Hugging Face:

```json
{
  "config_version": 1,
  "benchmark_params": {
    "benchmark_steps": ["speech_to_tool"],
    "speech_to_tool_model": {
      "preset": "liquid-lfm2.5-audio-1.5b-gguf",
      "provider": "llama_cpp_mtmd"
    }
  }
}
```

The old `llama-server` path can still be used explicitly with
`"provider": "llama_server"` and a `server_url`, but it is not the default
offline path.

Step definitions are reusable and describe only pipeline shape:

```json
{
  "config_version": 1,
  "step_definitions": {
    "text_to_tool": {
      "input_type": "text",
      "output_type": "json",
      "model_name": "qwen3-4b-4bit-remote"
    }
  }
}
```

Model definitions describe how to find and load the model. Remote `memory_estimate_mb` is allowed as a hint, but the app still enforces the local `memory_policy`.

```json
{
  "config_version": 1,
  "model_definitions": {
    "qwen3-4b-4bit-remote": {
      "enabled": true,
      "source": "hf://REAL_OWNER/REAL_REPO_NAME/model.gguf@0123456789abcdef",
      "loader": "llama.cpp",
      "memory_estimate_mb": 3500,
      "inference": {
        "temperature": 0,
        "max_tokens": 512
      }
    }
  }
}
```

Complete remote model suggestion:

```json
{
  "config_version": 1,
  "benchmark_params": {
    "benchmark_steps": ["speech_to_text", "text_to_tool"]
  },
  "step_definitions": {
    "text_to_tool": {
      "input_type": "text",
      "output_type": "json",
      "model_name": "qwen3-4b-4bit-remote"
    }
  },
  "model_definitions": {
    "qwen3-4b-4bit-remote": {
      "enabled": true,
      "source": "hf://REAL_OWNER/REAL_REPO_NAME/model.gguf@0123456789abcdef",
      "loader": "llama.cpp",
      "memory_estimate_mb": 3500,
      "inference": {
        "temperature": 0,
        "max_tokens": 512
      }
    }
  }
}
```

Disable a model remotely:

```json
{
  "config_version": 1,
  "model_definitions": {
    "leap-lfm2.5-audio-1.5b": {
      "enabled": false
    }
  }
}
```

To focus on particular input audio files, set `recordings_match` to recording ID patterns:

```json
{
  "config_version": 1,
  "benchmark_params": {
    "delay_seconds": 10,
    "number_of_inferences": 10,
    "benchmark_steps": ["speech_to_text", "text_to_tool"],
    "recordings_match": [
      "001*",
      "^003-003-[AC]$"
    ]
  }
}
```

This runs matching bundled audio files one by one, for example:

- `benchmark_data/001-001-A.wav`
- `benchmark_data/001-001-B.wav`
- `benchmark_data/001-001-C.m4a`
- `benchmark_data/001-002-A.wav`
- `benchmark_data/003-003-A.wav`
- `benchmark_data/003-003-C.wav`

Selection rules:

- Benchmark mode is still controlled locally by the Benchmark build UI. Remote config changes the benchmark flow and model selection; it does not start or stop benchmark mode.
- `benchmark_params.benchmark_steps` selects benchmark behavior.
- Each active step must exist in `step_definitions`, each step must reference a model in `model_definitions`, and each active model must be enabled.
- Step input/output types are validated as a chain. `speech_to_text` is `audio -> text`; `text_to_tool` is `text -> json`; therefore `["speech_to_text", "text_to_tool"]` is valid as `audio -> text -> json`.
- `["speech_to_tool"]` runs the selected direct audio-to-tool model. Leap uses LeapSDK audio; Liquid LFM2.5 Audio and Qwen3-ASR use local llama.cpp `libmtmd`.
- `benchmark_params.recordings_match: "*"` runs all available WAV, MP3, and M4A files.
- `benchmark_params.recordings_match` filters by recording ID, filename, or bundle path.
- `recordings_match` supports wildcard patterns such as `001*`; explicit regular expressions such as `^003-003-[AC]$` are also supported.
- `benchmark_params.delay_seconds` controls the wait between runs and defaults to 10.
- `benchmark_params.number_of_inferences` controls how many measured benchmark runs execute for each selected audio file before advancing to the next file. It defaults to 1.
- Sources must use supported local schemes, currently `bundle` or `hf`.
- Remote `hf://` model sources must pin a revision with `@<commit>`.
- Loader/source compatibility is validated. `.gguf` requires `llama.cpp`, `.mlpackage` requires `coreml`, and `.onnx` requires `onnx`.
- The memory estimator accounts for model file size, KV cache, loader overhead, temporary buffers, current available memory, and a local safety margin. `memory_estimate_mb` can only raise the estimate; it cannot bypass local policy.
- Missing audio files are skipped.

If a downloaded SDK config is invalid, the app rejects that overlay and uses the local benchmark config. The SDK payload status explains the validation failure.

## Run Behavior

For each selected WAV, MP3, or M4A file, the app:

1. Injects the bundled audio file URL into the current speech-to-text processing flow.
2. Prepares the processing audio file before measurement, converting M4A to a temporary WAV when possible.
3. Runs `benchmark_params.number_of_inferences` measured benchmark runs for that processing file.
4. Records the benchmark file ID and run index in WildEdge metadata.
5. Loads the expected transcript from `<line_id>-<variant_id>.txt`.
6. Loads the expected tool-call JSON from `<line_id>.json`.
7. Executes the selected `benchmark_steps`.
8. Emits transcript comparison metadata for STT-including runs, including normalized exact match and WER.
9. Emits tool-call comparison metadata for tool-call runs, using canonical JSON equality so whitespace and key order do not matter.
10. Waits `benchmark_params.delay_seconds`, defaulting to 10 seconds, between measured benchmark runs.
11. Continues with the next selected file until benchmark mode is disabled.

`["speech_to_text"]` runs the existing STT-only benchmark and compares the produced transcript with the expected transcript fixture.

`["speech_to_text", "text_to_tool"]` first runs the selected STT model, then sends the actual transcript to the selected text-to-tool model with a strict text-to-tool prompt. Apple Foundation Models runs through its native SDK. FunctionGemma, TinyLlama, and Qwen presets run through llama.cpp with GGUF weights downloaded from Hugging Face. It compares the resulting JSON object with the expected `<line_id>.json` fixture.

`["speech_to_tool"]` sends audio directly to the selected audio-to-tool model.
Leap uses the LeapSDK audio adapter. Liquid LFM2.5 Audio and Qwen3-ASR use local
llama.cpp `libmtmd`, load the main GGUF plus `mmproj`, convert the input audio
to float PCM, and evaluate an audio marker in the multimodal prompt before
generating the tool JSON.

Benchmark runs do not upload benchmark WAV/MP3/M4A files, transcript `.txt` files, or tool-call `.json` files as attachments. The event metadata refers to the bundled dataset files by name instead.

The benchmark status panel shows the selected steps, current input file, preprocessing file, run index, latest latency/result, expected and actual transcript for STT-including runs, expected and actual tool-call JSON for tool-call runs, transcript match, tool-call match, and a live countdown during the configured sleep before the next benchmark run.

WAV files are passed to the selected benchmark backend directly. MP3 and M4A files are converted on-device to temporary WAV files before inference when a selected backend requires WAV input. Conversion time is a preparation step and is not included in the measured inference duration.

## WildEdge Metadata

Each benchmark inference should include enough metadata to identify the run without uploading the source dataset file.

Input metadata should include:

- `benchmark_enabled`
- `benchmark_steps`
- `source`
- `benchmark_file`
- `benchmark_recording_id`
- `input_data_name`
- `input_data_file`
- `recording_duration_seconds`
- `input_audio_duration_seconds`
- `preprocessing_file`
- `processing_audio_extension`
- `processing_audio_duration_seconds`
- `converted_to_wav_before_inference`
- `benchmark_line_id`
- `benchmark_variant_id`
- `benchmark_speaker_id`
- `benchmark_delay_seconds`
- `benchmark_number_of_inferences`
- `benchmark_recordings_match`
- `benchmark_audio_extension`
- `expected_transcript_file`
- `expected_tool_call`
- `expected_tool_call_file`
- `expected_tool_call_json`
- `benchmark_iteration`
- `benchmark_inference_index`
- `benchmark_inference_count`
- selected STT model/settings

Output metadata should include:

- `transcript`
- `expected_transcript`
- `normalized_transcript`
- `normalized_expected_transcript`
- `normalized_exact_match`
- `wer`
- `expected_tool_call`
- `expected_tool_call_json`
- `actual_tool_call`
- `actual_tool_call_json`
- `actual_tool_call_parse_error`
- `tool_call_exact_match`
- `tool_call_step`
- `tool_call_duration_ms`
- `benchmark_total_duration_ms`
- duration fields reported by the processing flow

Each benchmark run is tracked inside a WildEdge span named after the input audio file, for example `001-001-A.wav`. Two-step runs record separate logical model handles for the STT step and the text-to-tool step; direct runs record the speech-to-tool logical model handle.

## Supported Tool Calls

Tool-call benchmarks expect one strict JSON object:

```json
{
  "tool_name": "set_temperature",
  "arguments": {
    "temperature": 21
  }
}
```

The v1 supported tools are:

- `set_temperature` with numeric `temperature`
- `change_volume` with string `direction`
- `navigate` with string `destination`

Expected and actual tool calls are compared by parsed canonical JSON equality. Model output may contain surrounding text or code fences; the benchmark extracts the first JSON object before parsing. The parsed object must use one supported `tool_name`, contain only `tool_name` and `arguments`, and use the expected argument key and value type for that tool.
