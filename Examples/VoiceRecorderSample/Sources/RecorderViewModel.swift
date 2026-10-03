import AVFoundation
import OnnxRuntimeBindings
import Speech
import UIKit
import WildEdge

struct RecordingResult {
    let duration: TimeInterval
    let fileURL: URL
    let fileSizeBytes: Int64
    let inferenceId: String
    let speechInferenceId: String?
    let transcript: String?
    let transcriptionDurationMs: Int?
    let transcriptionModelName: String?
    let toolCall: String?
    let toolRawText: String?
    let toolCallDurationMs: Int?
    let toolCallModelName: String?
    let spectrogramURL: URL?

    var formattedDuration: String {
        let total = Int(duration)
        return String(format: "%02d:%02d.%d", total / 60, total % 60, Int(duration * 10) % 10)
    }

    var formattedFileSize: String {
        let kb = Double(fileSizeBytes) / 1024
        return kb >= 1024
            ? String(format: "%.1f MB", kb / 1024)
            : String(format: "%.1f KB", kb)
    }
}

private struct RecordingInputAttachments {
    let attachments: [InferenceAttachment]
    let spectrogramURL: URL?
}

@MainActor
final class RecorderViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isRecording = false
    @Published var isFinishing = false
    @Published var isProcessing = false
    @Published var isPlayingProcessedAudio = false
    @Published var duration: TimeInterval = 0
    @Published var barLevels: [Float] = Array(repeating: 0, count: 30)
    @Published var lastRecording: RecordingResult?
    @Published var processingMessage = ""
    @Published var processingProgress: Double?
    @Published var processedAudioURL: URL?
    #if BENCHMARK_BUILD
    @Published var isBenchmarking = false
    @Published var benchmarkStatus = ""
    @Published var benchmarkCurrentInput = ""
    @Published var benchmarkPreprocessingFile = ""
    @Published var benchmarkRunProgress = ""
    @Published var benchmarkSleepCountdown = ""
    @Published var benchmarkTranscript = ""
    @Published var benchmarkExpectedTranscript = ""
    @Published var benchmarkStepsText = ""
    @Published var benchmarkExpectedToolCall = ""
    @Published var benchmarkActualToolCall = ""
    @Published var benchmarkRawModelText = ""
    @Published var benchmarkLatencyText = ""
    @Published var benchmarkTranscriptMatchText = ""
    @Published var benchmarkToolCallMatchText = ""
    @Published var benchmarkToolCallMatchSummary = ""
    @Published var benchmarkToolCallMismatchDetails: [String] = []
    #endif

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingURL: URL?
    private let modelHandle: ModelHandle
    private let appleSpeechModelHandle: ModelHandle
    private let whisperTinySpeechModelHandle: ModelHandle
    private let whisperBaseSpeechModelHandle: ModelHandle
    private let leapSpeechModelHandle: ModelHandle
    private let leapAudioTextToolModelHandle: ModelHandle
    private let leapSmallTextToolModelHandle: ModelHandle
    private let leapInstructTextToolModelHandle: ModelHandle
    private let functionGemmaTextToolModelHandle: ModelHandle
    private let functionGemmaMLXTextToolModelHandle: ModelHandle
    private let qwen35SmallMLXTextToolModelHandle: ModelHandle
    private let tinyLlamaTextToolModelHandle: ModelHandle
    private let qwen2SmallTextToolModelHandle: ModelHandle
    private let qwen25TextToolModelHandle: ModelHandle
    private let qwen3SmallTextToolModelHandle: ModelHandle
    private let qwen3TextToolModelHandle: ModelHandle
    private let onnxTextToolModelHandle: ModelHandle
    private let appleFoundationTextToolModelHandle: ModelHandle
    private let customTextToolModelHandle: ModelHandle
    private let leapSpeechToolModelHandle: ModelHandle
    private let localMultimodalSpeechToolModelHandle: ModelHandle
    private let ultravoxSpeechToolModelHandle: ModelHandle
    private let qwen3ASRSpeechToolModelHandle: ModelHandle
    private let localOnnxProcessor: LocalOnnxVoiceProcessingClient?
    #if BENCHMARK_BUILD
    private var benchmarkTask: Task<Void, Never>?
    private var benchmarkSettings: VoiceRecorderEffectiveSettings?
    private var benchmarkRequested = false
    #endif

    override init() {
        let dsn = (Bundle.main.object(forInfoDictionaryKey: "WILDEDGE_DSN") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
            builder.batchSize = 1
            builder.flushIntervalMs = 1_000
            builder.enableAttachments = true
            builder.maxAttachmentsPerInference = 4
            builder.attachmentFlushIntervalMs = 1_000
            builder.maxAttachmentSizeBytes = 20 * 1024 * 1024  // 20 MB — generous for long takes
        }

        modelHandle = WildEdge.shared.registerModel(
            modelId: "tpain-voice-converter",
            info: ModelInfo(
                modelName: "T-Pain Voice Converter",
                modelSource: "local-bundle",
                modelFormat: "onnx",
                modelFamily: "voice-conversion"
            )
        )
        appleSpeechModelHandle = WildEdge.shared.registerModel(
            modelId: "apple-speech-recognizer",
            info: ModelInfo(
                modelName: "Apple Speech Recognizer",
                modelSource: "apple-speech",
                modelFormat: "framework",
                modelFamily: "speech-to-text"
            )
        )
        whisperTinySpeechModelHandle = WildEdge.shared.registerModel(
            modelId: WhisperModelSize.tiny.wildEdgeModelId,
            info: ModelInfo(
                modelName: "OpenAI Whisper Tiny",
                modelSource: "whisperkit-coreml",
                modelFormat: "coreml",
                modelFamily: "speech-to-text"
            )
        )
        whisperBaseSpeechModelHandle = WildEdge.shared.registerModel(
            modelId: WhisperModelSize.base.wildEdgeModelId,
            info: ModelInfo(
                modelName: "OpenAI Whisper Base",
                modelSource: "whisperkit-coreml",
                modelFormat: "coreml",
                modelFamily: "speech-to-text"
            )
        )
        leapSpeechModelHandle = WildEdge.shared.registerModel(
            modelId: "leap-lfm2.5-audio-1.5b",
            info: ModelInfo(
                modelName: "Leap LFM2.5 Audio 1.5B",
                modelSource: "leap-sdk",
                modelFormat: "gguf",
                modelFamily: "speech-to-text"
            )
        )
        leapAudioTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.leapLFM25Audio.logicalModelId,
            info: ModelInfo(
                modelName: "Leap LFM2.5 Audio 1.5B Text To Tool",
                modelSource: "leap-sdk",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
	        leapSmallTextToolModelHandle = WildEdge.shared.registerModel(
	            modelId: BenchmarkTextToToolModel.leapLFM25350M.logicalModelId,
	            info: ModelInfo(
	                modelName: "LFM2 350M Text To Tool",
	                modelSource: "huggingface",
	                modelFormat: "gguf",
	                modelFamily: "tool-calling"
	            )
        )
	        leapInstructTextToolModelHandle = WildEdge.shared.registerModel(
	            modelId: BenchmarkTextToToolModel.leapLFM2512BInstruct.logicalModelId,
	            info: ModelInfo(
	                modelName: "LFM2 1.2B Instruct Text To Tool",
	                modelSource: "huggingface",
	                modelFormat: "gguf",
	                modelFamily: "tool-calling"
	            )
        )
        functionGemmaTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.functionGemma.logicalModelId,
            info: ModelInfo(
                modelName: "FunctionGemma Text To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        functionGemmaMLXTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.functionGemmaMLX.logicalModelId,
            info: ModelInfo(
                modelName: "FunctionGemma MLX 4-bit Text To Tool",
                modelSource: "huggingface",
                modelFormat: "safetensors",
                modelFamily: "tool-calling"
            )
        )
        qwen35SmallMLXTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.qwen35ZeroPointEightBOptiQMLX.logicalModelId,
            info: ModelInfo(
                modelName: "Qwen3.5 0.8B OptiQ MLX 4-bit Text To Tool",
                modelSource: "huggingface",
                modelFormat: "safetensors",
                modelFamily: "tool-calling"
            )
        )
        tinyLlamaTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.tinyLlamaOnePointOneB.logicalModelId,
            info: ModelInfo(
                modelName: "TinyLlama 1.1B 4-bit GGUF Text To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        qwen2SmallTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.qwen2ZeroPointFiveBInstruct.logicalModelId,
            info: ModelInfo(
                modelName: "Qwen2 0.5B Instruct 4-bit Text To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        qwen25TextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.qwen25OnePointFiveBInstruct.logicalModelId,
            info: ModelInfo(
                modelName: "Qwen2.5 1.5B Instruct Text To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        qwen3SmallTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.qwen3ZeroPointSixB4Bit.logicalModelId,
            info: ModelInfo(
                modelName: "Qwen3 0.6B 4-bit Text To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        qwen3TextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.qwen3FourB4Bit.logicalModelId,
            info: ModelInfo(
                modelName: "Qwen3-4B 4-bit Text To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        onnxTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.onnxRuntime.logicalModelId,
            info: ModelInfo(
                modelName: "ONNX Text To Tool",
                modelSource: "remote",
                modelFormat: "onnx",
                modelFamily: "tool-calling"
            )
        )
        appleFoundationTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.appleFoundationModels.logicalModelId,
            info: ModelInfo(
                modelName: "Apple Foundation Models Text To Tool",
                modelSource: "apple",
                modelFormat: "foundationmodels",
                modelFamily: "tool-calling"
            )
        )
        customTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: "custom-text-to-tool",
            info: ModelInfo(
                modelName: "Custom Text To Tool",
                modelSource: "remote",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        leapSpeechToolModelHandle = WildEdge.shared.registerModel(
            modelId: "leap-lfm2.5-audio-1.5b-speech-to-tool",
            info: ModelInfo(
                modelName: "Leap LFM2.5 Audio 1.5B Speech To Tool",
                modelSource: "leap-sdk",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        localMultimodalSpeechToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.liquidLFM25AudioOnePointFiveB.modelId,
            info: ModelInfo(
                modelName: "\(BenchmarkTextToToolModel.liquidLFM25AudioOnePointFiveB.displayName) Speech To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        ultravoxSpeechToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.ultravoxLlama32OneB.modelId,
            info: ModelInfo(
                modelName: "\(BenchmarkTextToToolModel.ultravoxLlama32OneB.displayName) Speech To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )
        ultravoxSpeechToolModelHandle.acceleratorActual = .gpu
        qwen3ASRSpeechToolModelHandle = WildEdge.shared.registerModel(
            modelId: BenchmarkTextToToolModel.qwen3ASRZeroPointSixB.modelId,
            info: ModelInfo(
                modelName: "\(BenchmarkTextToToolModel.qwen3ASRZeroPointSixB.displayName) Speech To Tool",
                modelSource: "huggingface",
                modelFormat: "gguf",
                modelFamily: "tool-calling"
            )
        )

        if let modelURL = Bundle.main.url(forResource: "TPain", withExtension: "onnx") {
            do {
                localOnnxProcessor = try LocalOnnxVoiceProcessingClient(modelURL: modelURL)
                processingMessage = "TPain.onnx loaded. Ready for local ONNX inference."
            } catch {
                localOnnxProcessor = nil
                processingMessage = "Could not initialize local ONNX model: \(error.localizedDescription)"
            }
        } else {
            localOnnxProcessor = nil
            processingMessage = "TPain.onnx is missing in app bundle."
        }

        super.init()
    }

    #if BENCHMARK_BUILD
    func syncBenchmark(settings: VoiceRecorderEffectiveSettings) {
        benchmarkSettings = settings
        benchmarkRequested = settings.benchmarkEnabled
        print(
            "Benchmark effective settings: enabled=\(settings.benchmarkEnabled), steps=\(settings.benchmarkSteps.map(\.rawValue).joined(separator: ",")), voice_to_text=\(settings.voiceToTextMode.rawValue), audio_to_tool=\(settings.audioToToolArchitecture.rawValue), speech_to_tool_model=\(settings.benchmarkSpeechToToolModel.modelId)"
        )

        if settings.benchmarkEnabled {
            startBenchmarkLoopIfNeeded()
        } else if benchmarkTask != nil {
            benchmarkStatus = "Benchmark stopping..."
        } else {
            isBenchmarking = false
            Self.setBenchmarkIdleTimerDisabled(false)
            benchmarkStatus = ""
            benchmarkCurrentInput = ""
            benchmarkPreprocessingFile = ""
            benchmarkRunProgress = ""
            benchmarkSleepCountdown = ""
            benchmarkTranscript = ""
            benchmarkExpectedTranscript = ""
            benchmarkStepsText = ""
            benchmarkExpectedToolCall = ""
            benchmarkActualToolCall = ""
            benchmarkRawModelText = ""
            benchmarkLatencyText = ""
            benchmarkTranscriptMatchText = ""
            benchmarkToolCallMatchText = ""
            benchmarkToolCallMatchSummary = ""
            benchmarkToolCallMismatchDetails = []
        }
    }

    private func startBenchmarkLoopIfNeeded() {
        guard benchmarkTask == nil else { return }

        let runId = "voice-recorder-benchmark-\(UUID().uuidString)"
        isBenchmarking = true
        Self.setBenchmarkIdleTimerDisabled(true)
        benchmarkStatus = "Benchmark starting..."
        benchmarkCurrentInput = ""
        benchmarkPreprocessingFile = ""
        benchmarkRunProgress = ""
        benchmarkSleepCountdown = ""
        benchmarkTranscript = ""
        benchmarkExpectedTranscript = ""
        benchmarkStepsText = ""
        benchmarkExpectedToolCall = ""
        benchmarkActualToolCall = ""
        benchmarkRawModelText = ""
        benchmarkLatencyText = ""
        benchmarkTranscriptMatchText = ""
        benchmarkToolCallMatchText = ""
        benchmarkToolCallMatchSummary = ""
        benchmarkToolCallMismatchDetails = []

        benchmarkTask = Task.detached(priority: .utility) { [
            weak self,
            appleSpeechModelHandle = self.appleSpeechModelHandle,
            whisperTinySpeechModelHandle = self.whisperTinySpeechModelHandle,
            whisperBaseSpeechModelHandle = self.whisperBaseSpeechModelHandle,
            leapSpeechModelHandle = self.leapSpeechModelHandle,
            leapAudioTextToolModelHandle = self.leapAudioTextToolModelHandle,
            leapSmallTextToolModelHandle = self.leapSmallTextToolModelHandle,
            leapInstructTextToolModelHandle = self.leapInstructTextToolModelHandle,
            functionGemmaTextToolModelHandle = self.functionGemmaTextToolModelHandle,
            functionGemmaMLXTextToolModelHandle = self.functionGemmaMLXTextToolModelHandle,
            qwen35SmallMLXTextToolModelHandle = self.qwen35SmallMLXTextToolModelHandle,
            tinyLlamaTextToolModelHandle = self.tinyLlamaTextToolModelHandle,
            qwen2SmallTextToolModelHandle = self.qwen2SmallTextToolModelHandle,
            qwen25TextToolModelHandle = self.qwen25TextToolModelHandle,
            qwen3SmallTextToolModelHandle = self.qwen3SmallTextToolModelHandle,
            qwen3TextToolModelHandle = self.qwen3TextToolModelHandle,
            onnxTextToolModelHandle = self.onnxTextToolModelHandle,
            appleFoundationTextToolModelHandle = self.appleFoundationTextToolModelHandle,
            customTextToolModelHandle = self.customTextToolModelHandle,
            leapSpeechToolModelHandle = self.leapSpeechToolModelHandle,
            localMultimodalSpeechToolModelHandle = self.localMultimodalSpeechToolModelHandle,
            ultravoxSpeechToolModelHandle = self.ultravoxSpeechToolModelHandle,
            qwen3ASRSpeechToolModelHandle = self.qwen3ASRSpeechToolModelHandle
        ] in
            await Self.runBenchmarkLoop(
                viewModel: self,
                runId: runId,
                appleSpeechModelHandle: appleSpeechModelHandle,
                whisperTinySpeechModelHandle: whisperTinySpeechModelHandle,
                whisperBaseSpeechModelHandle: whisperBaseSpeechModelHandle,
                leapSpeechModelHandle: leapSpeechModelHandle,
                leapAudioTextToolModelHandle: leapAudioTextToolModelHandle,
                leapSmallTextToolModelHandle: leapSmallTextToolModelHandle,
                leapInstructTextToolModelHandle: leapInstructTextToolModelHandle,
                functionGemmaTextToolModelHandle: functionGemmaTextToolModelHandle,
                functionGemmaMLXTextToolModelHandle: functionGemmaMLXTextToolModelHandle,
                qwen35SmallMLXTextToolModelHandle: qwen35SmallMLXTextToolModelHandle,
                tinyLlamaTextToolModelHandle: tinyLlamaTextToolModelHandle,
                qwen2SmallTextToolModelHandle: qwen2SmallTextToolModelHandle,
                qwen25TextToolModelHandle: qwen25TextToolModelHandle,
                qwen3SmallTextToolModelHandle: qwen3SmallTextToolModelHandle,
                qwen3TextToolModelHandle: qwen3TextToolModelHandle,
                onnxTextToolModelHandle: onnxTextToolModelHandle,
                appleFoundationTextToolModelHandle: appleFoundationTextToolModelHandle,
                customTextToolModelHandle: customTextToolModelHandle,
                leapSpeechToolModelHandle: leapSpeechToolModelHandle,
                localMultimodalSpeechToolModelHandle: localMultimodalSpeechToolModelHandle,
                ultravoxSpeechToolModelHandle: ultravoxSpeechToolModelHandle,
                qwen3ASRSpeechToolModelHandle: qwen3ASRSpeechToolModelHandle
            )
        }
    }
    #endif

    func toggleRecording(
        voiceToTextMode: VoiceToTextMode,
        whisperModelSize: WhisperModelSize,
        audioToToolArchitecture: AudioToToolArchitecture,
        includeSpectrogramAttachment: Bool,
        includeWAVAttachment: Bool
    ) async {
        if isRecording {
            stopRecording(
                voiceToTextMode: voiceToTextMode,
                whisperModelSize: whisperModelSize,
                audioToToolArchitecture: audioToToolArchitecture,
                includeSpectrogramAttachment: includeSpectrogramAttachment,
                includeWAVAttachment: includeWAVAttachment
            )
        } else {
            await startRecording(voiceToTextMode: voiceToTextMode)
        }
    }

    private func startRecording(voiceToTextMode: VoiceToTextMode) async {
        guard await requestMicrophonePermission() else { return }
        if voiceToTextMode == .apple {
            guard await requestSpeechRecognitionPermission() else {
                processingMessage = "Speech recognition permission is required for Apple voice to text."
                return
            }
        }

        stopPlayback()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wildedge_voice_recording.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        // Flip UI immediately so button/bar animations start without waiting
        // for AVAudioSession (which can take 50–200 ms on first activation).
        isRecording = true
        duration = 0
        barLevels = Array(repeating: 0, count: barLevels.count)
        lastRecording = nil
        processedAudioURL = nil
        processingProgress = nil
        processingMessage = localOnnxProcessor == nil
            ? "TPain.onnx is missing in app bundle."
            : ""
        recordingStartTime = Date()

        let recorder = await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.record, mode: .default)
            try? session.setActive(true)
            return try? AVAudioRecorder(url: url, settings: settings)
        }.value

        guard let recorder else {
            isRecording = false
            return
        }

        recorder.isMeteringEnabled = true
        recorder.record()
        audioRecorder = recorder
        recordingURL = url

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopRecording(
        voiceToTextMode: VoiceToTextMode,
        whisperModelSize: WhisperModelSize,
        audioToToolArchitecture: AudioToToolArchitecture,
        includeSpectrogramAttachment: Bool,
        includeWAVAttachment: Bool
    ) {
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        audioRecorder = nil

        let finalDuration = duration
        let url = recordingURL

        // Reset UI immediately so animations aren't blocked
        isRecording = false
        duration = 0
        barLevels = Array(repeating: 0, count: barLevels.count)
        isFinishing = true
        isProcessing = true
        processingProgress = nil
        processingMessage = voiceToTextMode == .apple
            ? "Transcribing with Apple Speech..."
            : voiceToTextMode == .whisper
            ? "Transcribing with Whisper \(whisperModelSize.displayName)..."
            : voiceToTextMode == .leap
            ? "Transcribing with Leap LFM2.5 Audio..."
            : audioToToolArchitecture == .oneStep
            ? "Generating tool call with \(BenchmarkTextToToolModel.liquidLFM25AudioOnePointFiveB.displayName)..."
            : localOnnxProcessor == nil
            ? "TPain.onnx is missing in app bundle."
            : "Running local ONNX inference..."

        // File I/O, session teardown, and inference tracking on a background thread
        Task.detached { [
            weak self,
            modelHandle = self.modelHandle,
            appleSpeechModelHandle = self.appleSpeechModelHandle,
            whisperTinySpeechModelHandle = self.whisperTinySpeechModelHandle,
            whisperBaseSpeechModelHandle = self.whisperBaseSpeechModelHandle,
            leapSpeechModelHandle = self.leapSpeechModelHandle,
            localMultimodalSpeechToolModelHandle = self.localMultimodalSpeechToolModelHandle,
            localOnnxProcessor = self.localOnnxProcessor
        ] in
            try? AVAudioSession.sharedInstance().setActive(false)
            guard let url else {
                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
                    self?.processingProgress = nil
                }
                return
            }

            let attachment = InferenceAttachment(
                name: url.lastPathComponent,
                role: .input,
                payload: .file(url, mimeType: "audio/wav")
            )
            let inputAttachmentBundle = Self.makeInputAttachments(
                audioAttachment: attachment,
                audioURL: url,
                includeSpectrogramAttachment: includeSpectrogramAttachment,
                includeWAVAttachment: includeWAVAttachment
            )
            let transcription = await Self.transcribeIfNeeded(
                url: url,
                voiceToTextMode: voiceToTextMode,
                whisperModelSize: whisperModelSize,
                progressHandler: { progress, speed in
                    guard voiceToTextMode == .leap else { return }
                    Task { @MainActor [weak self] in
                        self?.processingProgress = progress
                        self?.processingMessage = Self.leapDownloadMessage(progress: progress, speed: speed)
                    }
                }
            )
            await MainActor.run {
                self?.processingProgress = nil
            }
            let speechInferenceId = Self.trackSpeechInferenceIfNeeded(
                transcription: transcription,
                audioToToolArchitecture: audioToToolArchitecture,
                appleSpeechModelHandle: appleSpeechModelHandle,
                whisperTinySpeechModelHandle: whisperTinySpeechModelHandle,
                whisperBaseSpeechModelHandle: whisperBaseSpeechModelHandle,
                leapSpeechModelHandle: leapSpeechModelHandle,
                recordingDurationSeconds: finalDuration,
                attachments: inputAttachmentBundle.attachments
            )
            if speechInferenceId != nil {
                WildEdge.shared.flush(timeoutMs: 5_000)
            }

            if audioToToolArchitecture == .oneStep {
                await MainActor.run {
                    self?.processingProgress = nil
                    self?.processingMessage = "Generating tool call with \(BenchmarkTextToToolModel.liquidLFM25AudioOnePointFiveB.displayName)..."
                }
                let toolCall = await Self.generateManualSpeechToolCall(
                    url: url,
                    progressHandler: { progress, speed in
                        Task { @MainActor [weak self] in
                            self?.processingProgress = progress
                            self?.processingMessage = Self.modelDownloadMessage(
                                modelName: BenchmarkTextToToolModel.liquidLFM25AudioOnePointFiveB.displayName,
                                progress: progress,
                                speed: speed
                            )
                        }
                    }
                )
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                let inferenceId = localMultimodalSpeechToolModelHandle.trackInference(
                    durationMs: toolCall.durationMs,
                    inputModality: .audio,
                    outputModality: .generation,
                    success: toolCall.parsedSuccessfully,
                    errorCode: toolCall.errorDescription,
                    inputMeta: [
                        "source": "VoiceRecorderSample",
                        "model_id": toolCall.modelId,
                        "recording_duration_seconds": finalDuration,
                        "input_audio_duration_seconds": finalDuration,
                        "voice_to_text_mode": voiceToTextMode.rawValue,
                        "audio_to_tool_architecture": audioToToolArchitecture.rawValue
                    ],
                    outputMeta: [
                        "provider": toolCall.provider,
                        "model_id": toolCall.modelId,
                        "model_name": toolCall.modelName,
                        "model_source": toolCall.modelSource,
                        "model_format": toolCall.modelFormat,
                        "quantization": toolCall.quantization,
                        "raw_output": toolCall.rawOutput,
                        "raw_model_text": toolCall.rawText,
                        "tool_call_json": toolCall.canonicalJSON ?? "",
                        "tool_call_parse_error": toolCall.errorDescription ?? ""
                    ],
                    attachments: inputAttachmentBundle.attachments
                )
                WildEdge.shared.flush(timeoutMs: 5_000)

                let recording = RecordingResult(
                    duration: finalDuration,
                    fileURL: url,
                    fileSizeBytes: fileSize,
                    inferenceId: inferenceId,
                    speechInferenceId: speechInferenceId,
                    transcript: transcription?.transcript,
                    transcriptionDurationMs: transcription?.durationMs,
                    transcriptionModelName: transcription?.modelName,
                    toolCall: toolCall.canonicalJSON ?? toolCall.rawOutput,
                    toolRawText: toolCall.rawText,
                    toolCallDurationMs: toolCall.durationMs,
                    toolCallModelName: toolCall.modelName,
                    spectrogramURL: inputAttachmentBundle.spectrogramURL
                )

                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
                    self?.processingProgress = nil
                    self?.processingMessage = toolCall.parsedSuccessfully
                        ? "Tool call generated in \(toolCall.durationMs) ms."
                        : toolCall.errorDescription ?? "Tool call generation failed."
                    self?.lastRecording = recording
                }
                return
            }

            guard let localOnnxProcessor else {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                let inferenceId: String
                if let speechInferenceId {
                    inferenceId = speechInferenceId
                } else {
                    inferenceId = modelHandle.trackInference(
                        durationMs: Int(finalDuration * 1000),
                        inputModality: .audio,
                        outputModality: .generation,
                        success: false,
                        errorCode: "local_onnx_model_not_available",
                        inputMeta: [
                            "source": "VoiceRecorderSample",
                            "model_id": "TPain.onnx",
                            "recording_duration_seconds": finalDuration,
                            "input_audio_duration_seconds": finalDuration,
                            "voice_to_text_mode": voiceToTextMode.rawValue,
                            "audio_to_tool_architecture": audioToToolArchitecture.rawValue,
                            "speech_to_text_model": transcription?.modelId ?? "",
                            "speech_to_text_duration_ms": transcription?.durationMs ?? 0,
                            "transcript": transcription?.transcript ?? ""
                        ],
                        attachments: inputAttachmentBundle.attachments
                    )
                    WildEdge.shared.flush(timeoutMs: 5_000)
                }

                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
                    self?.processingProgress = nil
                    self?.processingMessage = transcription == nil
                        ? "TPain.onnx is missing in app bundle."
                        : transcription?.errorDescription ?? "\(transcription?.modelName ?? "Voice to text") completed."
                    self?.lastRecording = RecordingResult(
                        duration: finalDuration,
                        fileURL: url,
                        fileSizeBytes: fileSize,
                        inferenceId: inferenceId,
                        speechInferenceId: speechInferenceId,
                        transcript: transcription?.transcript,
                        transcriptionDurationMs: transcription?.durationMs,
                        transcriptionModelName: transcription?.modelName,
                        toolCall: nil,
                        toolRawText: nil,
                        toolCallDurationMs: nil,
                        toolCallModelName: nil,
                        spectrogramURL: inputAttachmentBundle.spectrogramURL
                    )
                }
                return
            }

            let processStart = Date()

            do {
                let result = try localOnnxProcessor.process(inputAudioURL: url)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                let outputAttachment = InferenceAttachment(
                    name: result.outputURL.lastPathComponent,
                    role: .output,
                    payload: .file(result.outputURL, mimeType: "audio/wav")
                )
                let inferenceId = modelHandle.trackInference(
                    durationMs: Int(Date().timeIntervalSince(processStart) * 1000),
                    inputModality: .audio,
                    outputModality: .generation,
                    success: true,
                    inputMeta: [
                        "source": "VoiceRecorderSample",
                        "model_id": "TPain.onnx",
                        "recording_duration_seconds": finalDuration,
                        "input_audio_duration_seconds": finalDuration,
                        "voice_to_text_mode": voiceToTextMode.rawValue,
                        "audio_to_tool_architecture": audioToToolArchitecture.rawValue
                    ],
                    outputMeta: [
                        "provider": "onnxruntime",
                        "model_id": "TPain.onnx",
                        "response_summary": result.responseSummary,
                        "response_bytes": result.responseBytes,
                        "output_names": result.outputNames.joined(separator: ","),
                        "voice_to_text_mode": voiceToTextMode.rawValue,
                        "audio_to_tool_architecture": audioToToolArchitecture.rawValue,
                        "speech_to_text_inference_id": speechInferenceId ?? "",
                        "speech_to_text_model": transcription?.modelId ?? "",
                        "speech_to_text_duration_ms": transcription?.durationMs ?? 0,
                        "transcript": transcription?.transcript ?? ""
                    ],
                    attachments: speechInferenceId == nil
                        ? inputAttachmentBundle.attachments + [outputAttachment]
                        : [outputAttachment]
                )
                WildEdge.shared.flush(timeoutMs: 5_000)

                let recording = RecordingResult(
                    duration: finalDuration,
                    fileURL: url,
                    fileSizeBytes: fileSize,
                    inferenceId: inferenceId,
                    speechInferenceId: speechInferenceId,
                    transcript: transcription?.transcript,
                    transcriptionDurationMs: transcription?.durationMs,
                    transcriptionModelName: transcription?.modelName,
                    toolCall: nil,
                    toolRawText: nil,
                    toolCallDurationMs: nil,
                    toolCallModelName: nil,
                    spectrogramURL: inputAttachmentBundle.spectrogramURL
                )

                print("""
                --- TPain local ONNX inference finished ---
                Input     : \(url.path)
                Output    : \(result.outputURL.path)
                Summary   : \(result.responseSummary)
                Inference : \(inferenceId)
                -------------------------------
                """)

                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
                    self?.processingProgress = nil
                    self?.processingMessage = "Processed in \(Int(Date().timeIntervalSince(processStart) * 1000)) ms."
                    self?.processedAudioURL = result.outputURL
                    self?.lastRecording = recording
                }
            } catch {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                let inferenceId = modelHandle.trackInference(
                    durationMs: Int(Date().timeIntervalSince(processStart) * 1000),
                    inputModality: .audio,
                    outputModality: .generation,
                    success: false,
                    errorCode: String(describing: type(of: error)),
                    inputMeta: [
                        "source": "VoiceRecorderSample",
                        "model_id": "TPain.onnx",
                        "recording_duration_seconds": finalDuration,
                        "input_audio_duration_seconds": finalDuration,
                        "voice_to_text_mode": voiceToTextMode.rawValue,
                        "audio_to_tool_architecture": audioToToolArchitecture.rawValue,
                        "speech_to_text_inference_id": speechInferenceId ?? "",
                        "speech_to_text_model": transcription?.modelId ?? "",
                        "speech_to_text_duration_ms": transcription?.durationMs ?? 0,
                        "transcript": transcription?.transcript ?? ""
                    ],
                    attachments: speechInferenceId == nil ? inputAttachmentBundle.attachments : []
                )
                WildEdge.shared.flush(timeoutMs: 5_000)

                let recording = RecordingResult(
                    duration: finalDuration,
                    fileURL: url,
                    fileSizeBytes: fileSize,
                    inferenceId: inferenceId,
                    speechInferenceId: speechInferenceId,
                    transcript: transcription?.transcript,
                    transcriptionDurationMs: transcription?.durationMs,
                    transcriptionModelName: transcription?.modelName,
                    toolCall: nil,
                    toolRawText: nil,
                    toolCallDurationMs: nil,
                    toolCallModelName: nil,
                    spectrogramURL: inputAttachmentBundle.spectrogramURL
                )

                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
                    self?.processingProgress = nil
                    self?.processingMessage = error.localizedDescription
                    self?.lastRecording = recording
                }
            }
        }
    }

    private func tick() {
        guard let start = recordingStartTime else { return }
        duration = Date().timeIntervalSince(start)
        audioRecorder?.updateMeters()
        shiftInNewLevel()
    }

    private func shiftInNewLevel() {
        guard let recorder = audioRecorder else { return }
        let power = recorder.averagePower(forChannel: 0)
        let minDb: Float = -50
        let newLevel = max(0, min(1, (power - minDb) / abs(minDb)))
        var updated = barLevels
        updated.removeFirst()
        updated.append(newLevel)
        barLevels = updated
    }

    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied:  return false
            default:       return await AVAudioApplication.requestRecordPermission()
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return true
            case .denied:  return false
            default:
                return await withCheckedContinuation { continuation in
                    AVAudioSession.sharedInstance().requestRecordPermission {
                        continuation.resume(returning: $0)
                    }
                }
            }
        }
    }

    private func requestSpeechRecognitionPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    private nonisolated static func transcribeIfNeeded(
        url: URL,
        voiceToTextMode: VoiceToTextMode,
        whisperModelSize: WhisperModelSize,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async -> SpeechTranscriptionResult? {
        guard voiceToTextMode != .disabled else { return nil }

        let start = Date()

        switch voiceToTextMode {
        case .apple:
            do {
                let transcript = try await AppleSpeechTranscriber().transcribe(url: url)
                return SpeechTranscriptionResult(
                    transcript: transcript,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    errorDescription: nil,
                    provider: "apple_speech",
                    modelId: "apple-speech-recognizer",
                    modelName: "Apple Speech",
                    requiresOnDeviceRecognition: true,
                    whisperModelSize: nil
                )
            } catch {
                print("Apple Speech transcription failed: \(error.localizedDescription)")
                return SpeechTranscriptionResult(
                    transcript: nil,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    errorDescription: error.localizedDescription,
                    provider: "apple_speech",
                    modelId: "apple-speech-recognizer",
                    modelName: "Apple Speech",
                    requiresOnDeviceRecognition: true,
                    whisperModelSize: nil
                )
            }
        case .whisper:
            do {
                let transcript = try await WhisperSpeechTranscriber.shared.transcribe(
                    url: url,
                    model: whisperModelSize
                )
                return SpeechTranscriptionResult(
                    transcript: transcript,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    errorDescription: nil,
                    provider: "whisperkit",
                    modelId: whisperModelSize.wildEdgeModelId,
                    modelName: "Whisper \(whisperModelSize.displayName)",
                    requiresOnDeviceRecognition: true,
                    whisperModelSize: whisperModelSize
                )
            } catch {
                print("Whisper transcription failed: \(error.localizedDescription)")
                return SpeechTranscriptionResult(
                    transcript: nil,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    errorDescription: error.localizedDescription,
                    provider: "whisperkit",
                    modelId: whisperModelSize.wildEdgeModelId,
                    modelName: "Whisper \(whisperModelSize.displayName)",
                    requiresOnDeviceRecognition: true,
                    whisperModelSize: whisperModelSize
                )
            }
        case .leap:
            do {
                let transcriber = await LeapSpeechTranscriber.shared()
                let transcript = try await transcriber.transcribe(
                    url: url,
                    progressHandler: progressHandler
                )
                return SpeechTranscriptionResult(
                    transcript: transcript,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    errorDescription: nil,
                    provider: "leap_sdk",
                    modelId: "\(LeapSpeechTranscriber.modelName)-\(LeapSpeechTranscriber.quantization)",
                    modelName: "Leap LFM2.5 Audio",
                    requiresOnDeviceRecognition: true,
                    whisperModelSize: nil
                )
            } catch {
                print("Leap transcription failed: \(error.localizedDescription)")
                return SpeechTranscriptionResult(
                    transcript: nil,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    errorDescription: error.localizedDescription,
                    provider: "leap_sdk",
                    modelId: "\(LeapSpeechTranscriber.modelName)-\(LeapSpeechTranscriber.quantization)",
                    modelName: "Leap LFM2.5 Audio",
                    requiresOnDeviceRecognition: true,
                    whisperModelSize: nil
                )
            }
        case .disabled:
            return nil
        }
    }

    private nonisolated static func generateManualSpeechToolCall(
        url: URL,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async -> BenchmarkToolCallGenerationResult {
        print("Manual speech_to_tool starting: model=\(BenchmarkTextToToolModel.liquidLFM25AudioOnePointFiveB.modelId), file=\(url.lastPathComponent)")
        return await LeapBenchmarkToolCallModel.shared.generate(
            input: .audio(url),
            speechToToolModel: .liquidLFM25AudioOnePointFiveB,
            progressHandler: progressHandler
        )
    }

    #if BENCHMARK_BUILD
    private struct BenchmarkToolCallResult {
        let step: BenchmarkStep
        let rawOutput: String
        let rawText: String
        let durationMs: Int
        let parsedJSON: ToolCallJSONValue?
        let canonicalJSON: String?
        let errorDescription: String?
        let provider: String
        let modelId: String
        let modelName: String
        let modelSource: String
        let modelFormat: String
        let quantization: String

        var parsedSuccessfully: Bool {
            parsedJSON != nil && errorDescription == nil
        }
    }

    private struct BenchmarkWarmupResult {
        let completed: Bool
        let runtimeStopStatus: String?
    }

    private struct BenchmarkDatasetItem {
        let audioURL: URL
        let processingAudioURL: URL
        let audioDurationSeconds: Double?
        let processingAudioDurationSeconds: Double?
        let expectedTranscriptURL: URL?
        let expectedToolCallURL: URL?
        let expectedTranscript: String?
        let expectedToolCall: String?
        let expectedToolCallJSON: ToolCallJSONValue?
        let expectedToolCallCanonicalJSON: String?
        let expectedToolCallParseError: String?

        var baseName: String {
            audioURL.deletingPathExtension().lastPathComponent
        }

        var recordingID: String {
            baseName
        }

        var lineID: String? {
            identifierParts.indices.contains(0) ? identifierParts[0] : nil
        }

        var variantID: String? {
            identifierParts.indices.contains(1) ? identifierParts[1] : nil
        }

        var speakerID: String? {
            identifierParts.indices.contains(2) ? identifierParts[2] : nil
        }

        private var identifierParts: [String] {
            baseName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        }

        var audioBundlePath: String {
            "benchmark_data/\(audioURL.lastPathComponent)"
        }

        var wasConvertedForProcessing: Bool {
            processingAudioURL != audioURL
        }

        var expectedTranscriptBundlePath: String? {
            expectedTranscriptURL.map { "benchmark_data/\($0.lastPathComponent)" }
        }

        var expectedToolCallBundlePath: String? {
            expectedToolCallURL.map { "benchmark_data/\($0.lastPathComponent)" }
        }

        func preparedForProcessing(at url: URL) -> BenchmarkDatasetItem {
            BenchmarkDatasetItem(
                audioURL: audioURL,
                processingAudioURL: url,
                audioDurationSeconds: audioDurationSeconds,
                processingAudioDurationSeconds: RecorderViewModel.benchmarkAudioDurationSeconds(for: url),
                expectedTranscriptURL: expectedTranscriptURL,
                expectedToolCallURL: expectedToolCallURL,
                expectedTranscript: expectedTranscript,
                expectedToolCall: expectedToolCall,
                expectedToolCallJSON: expectedToolCallJSON,
                expectedToolCallCanonicalJSON: expectedToolCallCanonicalJSON,
                expectedToolCallParseError: expectedToolCallParseError
            )
        }
    }

    private nonisolated static func runBenchmarkLoop(
        viewModel: RecorderViewModel?,
        runId: String,
        appleSpeechModelHandle: ModelHandle,
        whisperTinySpeechModelHandle: ModelHandle,
        whisperBaseSpeechModelHandle: ModelHandle,
        leapSpeechModelHandle: ModelHandle,
        leapAudioTextToolModelHandle: ModelHandle,
        leapSmallTextToolModelHandle: ModelHandle,
        leapInstructTextToolModelHandle: ModelHandle,
        functionGemmaTextToolModelHandle: ModelHandle,
        functionGemmaMLXTextToolModelHandle: ModelHandle,
        qwen35SmallMLXTextToolModelHandle: ModelHandle,
        tinyLlamaTextToolModelHandle: ModelHandle,
        qwen2SmallTextToolModelHandle: ModelHandle,
        qwen25TextToolModelHandle: ModelHandle,
        qwen3SmallTextToolModelHandle: ModelHandle,
        qwen3TextToolModelHandle: ModelHandle,
        onnxTextToolModelHandle: ModelHandle,
        appleFoundationTextToolModelHandle: ModelHandle,
        customTextToolModelHandle: ModelHandle,
        leapSpeechToolModelHandle: ModelHandle,
        localMultimodalSpeechToolModelHandle: ModelHandle,
        ultravoxSpeechToolModelHandle: ModelHandle,
        qwen3ASRSpeechToolModelHandle: ModelHandle
    ) async {
        while !Task.isCancelled {
            guard await isBenchmarkRequested(viewModel),
                  let settings = await benchmarkSettings(from: viewModel)
            else {
                await finishBenchmarkLoop(viewModel: viewModel, status: "Benchmark disabled.")
                return
            }
            guard let remoteConfigWarning = settings.remoteConfigWarning else {
                break
            }
            await displayUnsupportedBenchmarkConfig(
                settings: settings,
                warning: remoteConfigWarning,
                viewModel: viewModel
            )
            guard await sleepBenchmarkDelay(
                seconds: unsupportedBenchmarkConfigSleepSeconds(for: settings),
                viewModel: viewModel,
                statusText: remoteConfigWarning
            ) else {
                await finishBenchmarkLoop(viewModel: viewModel, status: "Benchmark disabled.")
                return
            }
        }

        guard !Task.isCancelled else {
            await finishBenchmarkLoop(viewModel: viewModel, status: "Benchmark disabled.")
            return
        }

        let loadedItems = loadBenchmarkDataset()
        guard !loadedItems.isEmpty else {
            await MainActor.run {
                viewModel?.isBenchmarking = false
                Self.setBenchmarkIdleTimerDisabled(false)
                viewModel?.benchmarkRequested = false
                viewModel?.benchmarkTask = nil
                viewModel?.benchmarkStatus = "No benchmark data found."
                viewModel?.benchmarkCurrentInput = ""
                viewModel?.benchmarkPreprocessingFile = ""
                viewModel?.benchmarkRunProgress = ""
                viewModel?.benchmarkSleepCountdown = ""
                viewModel?.benchmarkTranscript = ""
                viewModel?.benchmarkExpectedTranscript = ""
                viewModel?.benchmarkStepsText = ""
                viewModel?.benchmarkExpectedToolCall = ""
                viewModel?.benchmarkActualToolCall = ""
                viewModel?.benchmarkRawModelText = ""
                viewModel?.benchmarkLatencyText = ""
                viewModel?.benchmarkTranscriptMatchText = ""
                viewModel?.benchmarkToolCallMatchText = ""
                viewModel?.benchmarkToolCallMatchSummary = ""
                viewModel?.benchmarkToolCallMismatchDetails = []
            }
            return
        }
        await MainActor.run {
            viewModel?.isBenchmarking = true
            viewModel?.benchmarkStatus = "Preparing benchmark data..."
            viewModel?.benchmarkCurrentInput = "\(loadedItems.count) bundled files"
            viewModel?.benchmarkPreprocessingFile = ""
            viewModel?.benchmarkRunProgress = ""
            viewModel?.benchmarkSleepCountdown = ""
            viewModel?.benchmarkTranscript = ""
            viewModel?.benchmarkExpectedTranscript = ""
            viewModel?.benchmarkStepsText = ""
            viewModel?.benchmarkExpectedToolCall = ""
            viewModel?.benchmarkActualToolCall = ""
            viewModel?.benchmarkRawModelText = ""
            viewModel?.benchmarkLatencyText = ""
            viewModel?.benchmarkTranscriptMatchText = ""
            viewModel?.benchmarkToolCallMatchText = ""
            viewModel?.benchmarkToolCallMatchSummary = ""
            viewModel?.benchmarkToolCallMismatchDetails = []
        }
        let allItems = await prepareBenchmarkDataset(loadedItems, viewModel: viewModel)
        guard !allItems.isEmpty else {
            await MainActor.run {
                viewModel?.isBenchmarking = false
                Self.setBenchmarkIdleTimerDisabled(false)
                viewModel?.benchmarkRequested = false
                viewModel?.benchmarkTask = nil
                viewModel?.benchmarkStatus = "No benchmark data could be prepared."
                viewModel?.benchmarkCurrentInput = ""
                viewModel?.benchmarkPreprocessingFile = ""
                viewModel?.benchmarkRunProgress = ""
                viewModel?.benchmarkSleepCountdown = ""
                viewModel?.benchmarkTranscript = ""
                viewModel?.benchmarkExpectedTranscript = ""
                viewModel?.benchmarkStepsText = ""
                viewModel?.benchmarkExpectedToolCall = ""
                viewModel?.benchmarkActualToolCall = ""
                viewModel?.benchmarkRawModelText = ""
                viewModel?.benchmarkLatencyText = ""
                viewModel?.benchmarkTranscriptMatchText = ""
                viewModel?.benchmarkToolCallMatchText = ""
                viewModel?.benchmarkToolCallMatchSummary = ""
                viewModel?.benchmarkToolCallMismatchDetails = []
            }
            return
        }

        var finishStatus = "Benchmark disabled."
        var iteration = 1
        var preparedWhisperModels = Set<WhisperModelSize>()
        var preparedTextToToolModels = Set<BenchmarkTextToToolModel>()
        var warmedBenchmarkKeys = Set<String>()
        var toolCallMatchCount = 0
        var toolCallMeasuredCount = 0
        var toolCallExpectedCount = 0
        var toolCallMismatchDetailsByKey: [String: String] = [:]
        benchmarkLoop: while !Task.isCancelled {
            guard await isBenchmarkRequested(viewModel) else { break }
            guard let passSettings = await benchmarkSettings(from: viewModel) else { break }
            print(
                "Benchmark pass settings: steps=\(passSettings.benchmarkSteps.map(\.rawValue).joined(separator: ",")), voice_to_text=\(passSettings.voiceToTextMode.rawValue), audio_to_tool=\(passSettings.audioToToolArchitecture.rawValue), speech_to_tool_model=\(passSettings.benchmarkSpeechToToolModel.modelId)"
            )
            if let remoteConfigWarning = passSettings.remoteConfigWarning {
                await displayUnsupportedBenchmarkConfig(
                    settings: passSettings,
                    warning: remoteConfigWarning,
                    viewModel: viewModel
                )
                guard await sleepBenchmarkDelay(
                    seconds: unsupportedBenchmarkConfigSleepSeconds(for: passSettings),
                    viewModel: viewModel,
                    statusText: remoteConfigWarning
                ) else {
                    break
                }
                continue
            }
            await MainActor.run {
                viewModel?.isBenchmarking = true
                Self.setBenchmarkIdleTimerDisabled(true)
            }
            if let benchmarkStepsError = passSettings.benchmarkStepsError {
                await MainActor.run {
                    viewModel?.isBenchmarking = true
                    viewModel?.benchmarkStatus = benchmarkStepsError
                    viewModel?.benchmarkCurrentInput = passSettings.benchmarkRecordingsMatch.joined(separator: ", ")
                    viewModel?.benchmarkPreprocessingFile = ""
                    viewModel?.benchmarkRunProgress = ""
                    viewModel?.benchmarkSleepCountdown = ""
                    viewModel?.benchmarkTranscript = ""
                    viewModel?.benchmarkExpectedTranscript = ""
                    viewModel?.benchmarkStepsText = benchmarkStepsDescription(
                        passSettings.benchmarkSteps,
                        textToToolModel: passSettings.benchmarkTextToToolModel,
                        speechToToolModel: passSettings.benchmarkSpeechToToolModel
                    )
                    viewModel?.benchmarkExpectedToolCall = ""
                    viewModel?.benchmarkActualToolCall = ""
                    viewModel?.benchmarkRawModelText = ""
                    viewModel?.benchmarkLatencyText = ""
                    viewModel?.benchmarkTranscriptMatchText = ""
                    viewModel?.benchmarkToolCallMatchText = ""
                    viewModel?.benchmarkToolCallMatchSummary = ""
                    viewModel?.benchmarkToolCallMismatchDetails = []
                }
                guard await sleepBenchmarkDelay(seconds: passSettings.benchmarkDelaySeconds, viewModel: viewModel) else {
                    break
                }
                continue
            }
            let items = selectedBenchmarkItems(from: allItems, settings: passSettings)
            guard !items.isEmpty else {
                await MainActor.run {
                    viewModel?.isBenchmarking = true
                    viewModel?.benchmarkStatus = "No benchmark data matched SDK config."
                    viewModel?.benchmarkCurrentInput = passSettings.benchmarkRecordingsMatch.joined(separator: ", ")
                    viewModel?.benchmarkPreprocessingFile = ""
                    viewModel?.benchmarkRunProgress = ""
                    viewModel?.benchmarkSleepCountdown = ""
                    viewModel?.benchmarkTranscript = ""
                    viewModel?.benchmarkExpectedTranscript = ""
                    viewModel?.benchmarkStepsText = benchmarkStepsDescription(
                        passSettings.benchmarkSteps,
                        textToToolModel: passSettings.benchmarkTextToToolModel,
                        speechToToolModel: passSettings.benchmarkSpeechToToolModel
                    )
                    viewModel?.benchmarkExpectedToolCall = ""
                    viewModel?.benchmarkActualToolCall = ""
                    viewModel?.benchmarkRawModelText = ""
                    viewModel?.benchmarkLatencyText = ""
                    viewModel?.benchmarkTranscriptMatchText = ""
                    viewModel?.benchmarkToolCallMatchText = ""
                    viewModel?.benchmarkToolCallMatchSummary = ""
                    viewModel?.benchmarkToolCallMismatchDetails = []
                }
                guard await sleepBenchmarkDelay(seconds: passSettings.benchmarkDelaySeconds, viewModel: viewModel) else {
                    break
                }
                continue
            }

            let passInferenceCount = max(1, passSettings.benchmarkNumberOfInferences)
            let passHasToolStep = passSettings.benchmarkSteps.contains(.textToTool)
                || passSettings.benchmarkSteps.contains(.speechToTool)
            toolCallMatchCount = 0
            toolCallMeasuredCount = 0
            toolCallExpectedCount = passHasToolStep ? items.count * passInferenceCount : 0
            toolCallMismatchDetailsByKey = [:]
            await MainActor.run {
                viewModel?.benchmarkToolCallMatchSummary = passHasToolStep
                    ? benchmarkToolCallMatchProgressText(
                        matched: toolCallMatchCount,
                        measured: toolCallMeasuredCount,
                        total: toolCallExpectedCount
                    )
                    : ""
                viewModel?.benchmarkToolCallMismatchDetails = passHasToolStep
                    ? benchmarkMismatchDetails(from: toolCallMismatchDetailsByKey)
                    : []
            }

            let warmupKey = benchmarkWarmupKey(settings: passSettings, item: items[0])
            if warmedBenchmarkKeys.contains(warmupKey) == false {
                let warmup = await runBenchmarkWarmup(
                    item: items[0],
                    settings: passSettings,
                    viewModel: viewModel
                )
                if let runtimeStopStatus = warmup.runtimeStopStatus {
                    finishStatus = runtimeStopStatus
                    await MainActor.run {
                        viewModel?.benchmarkRequested = false
                        viewModel?.benchmarkRunProgress = "Stopped"
                    }
                    break benchmarkLoop
                }
                if warmup.completed {
                    warmedBenchmarkKeys.insert(warmupKey)
                    if passSettings.benchmarkSteps.contains(.speechToText),
                       passSettings.voiceToTextMode == .whisper {
                        preparedWhisperModels.insert(passSettings.whisperModelSize)
                    }
                    if passSettings.benchmarkSteps.contains(.textToTool),
                       Self.needsLocalTextToToolPreparation(passSettings.benchmarkTextToToolModel) {
                        preparedTextToToolModels.insert(passSettings.benchmarkTextToToolModel)
                    }
                }
                guard await isBenchmarkRequested(viewModel) else { break }
                guard !Task.isCancelled else { break }
            }

            for (offset, item) in items.enumerated() {
                guard !Task.isCancelled else { break }
                guard await isBenchmarkRequested(viewModel) else { break }
                guard let settings = await benchmarkSettings(from: viewModel) else { break }

                let needsSpeechToText = settings.benchmarkSteps.contains(.speechToText)
                let needsTextToTool = settings.benchmarkSteps.contains(.textToTool)
                if needsSpeechToText,
                   settings.voiceToTextMode == .whisper,
                   !preparedWhisperModels.contains(settings.whisperModelSize) {
                    let didPrepare = await prepareWhisperBenchmarkModel(
                        settings.whisperModelSize,
                        viewModel: viewModel
                    )
                    guard didPrepare else {
                        guard await sleepBenchmarkDelay(seconds: settings.benchmarkDelaySeconds, viewModel: viewModel) else {
                            break
                        }
                        continue
                    }
                    preparedWhisperModels.insert(settings.whisperModelSize)
                }

                if needsTextToTool,
                   Self.needsLocalTextToToolPreparation(settings.benchmarkTextToToolModel),
                   !preparedTextToToolModels.contains(settings.benchmarkTextToToolModel) {
                    let didPrepare = await prepareTextToToolBenchmarkModel(
                        settings.benchmarkTextToToolModel,
                        viewModel: viewModel
                    )
                    guard didPrepare else {
                        guard await sleepBenchmarkDelay(seconds: settings.benchmarkDelaySeconds, viewModel: viewModel) else {
                            break
                        }
                        continue
                    }
                    preparedTextToToolModels.insert(settings.benchmarkTextToToolModel)
                }

                guard needsSpeechToText == false || settings.voiceToTextMode != .disabled else {
                    await MainActor.run {
                        viewModel?.benchmarkStatus = "Benchmark requires voice to text."
                        viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                        viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
                        viewModel?.benchmarkRunProgress = ""
                        viewModel?.benchmarkSleepCountdown = ""
                        viewModel?.benchmarkTranscript = ""
                        viewModel?.benchmarkExpectedTranscript = item.expectedTranscript ?? ""
                        viewModel?.benchmarkStepsText = benchmarkStepsDescription(
                            settings.benchmarkSteps,
                            textToToolModel: settings.benchmarkTextToToolModel,
                            speechToToolModel: settings.benchmarkSpeechToToolModel
                        )
                        viewModel?.benchmarkExpectedToolCall = ""
                        viewModel?.benchmarkActualToolCall = ""
                        viewModel?.benchmarkRawModelText = ""
                        viewModel?.benchmarkLatencyText = ""
                        viewModel?.benchmarkTranscriptMatchText = ""
                        viewModel?.benchmarkToolCallMatchText = ""
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                let inferenceCount = max(1, settings.benchmarkNumberOfInferences)
                for inferenceIndex in 1...inferenceCount {
                    guard !Task.isCancelled else { break }
                    guard await isBenchmarkRequested(viewModel) else { break }
                    guard let settings = await benchmarkSettings(from: viewModel) else { break }
                    let needsSpeechToText = settings.benchmarkSteps.contains(.speechToText)
                    let needsTextToTool = settings.benchmarkSteps.contains(.textToTool)
                    let needsSpeechToTool = settings.benchmarkSteps.contains(.speechToTool)
                    let hasToolStep = needsTextToTool || needsSpeechToTool

                    await MainActor.run {
                        viewModel?.isBenchmarking = true
                        viewModel?.benchmarkStatus = "Measuring \(benchmarkStepsDescription(settings.benchmarkSteps, textToToolModel: settings.benchmarkTextToToolModel, speechToToolModel: settings.benchmarkSpeechToToolModel))..."
                        viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                        viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
                        viewModel?.benchmarkRunProgress = "Run \(inferenceIndex)/\(inferenceCount)"
                        viewModel?.benchmarkSleepCountdown = ""
                        viewModel?.benchmarkTranscript = ""
                        viewModel?.benchmarkExpectedTranscript = needsSpeechToText ? item.expectedTranscript ?? "" : ""
                        viewModel?.benchmarkStepsText = benchmarkStepsDescription(
                            settings.benchmarkSteps,
                            textToToolModel: settings.benchmarkTextToToolModel,
                            speechToToolModel: settings.benchmarkSpeechToToolModel
                        )
                        viewModel?.benchmarkExpectedToolCall = hasToolStep ? expectedToolCallDisplay(for: item) : ""
                        viewModel?.benchmarkActualToolCall = ""
                        viewModel?.benchmarkRawModelText = ""
                        viewModel?.benchmarkLatencyText = ""
                        viewModel?.benchmarkTranscriptMatchText = ""
                        viewModel?.benchmarkToolCallMatchText = ""
                    }

                    let inputMeta = benchmarkInputMeta(
                        item: item,
                        settings: settings,
                        iteration: iteration,
                        itemIndex: offset + 1,
                        itemCount: items.count,
                        inferenceIndex: inferenceIndex,
                        inferenceCount: inferenceCount
                    )

                    var transcription: SpeechTranscriptionResult?
                    var comparison: [String: Any] = [:]
                    var toolResult: BenchmarkToolCallResult?
                    var toolComparison: [String: Any] = [:]
                    var totalDurationMs = 0
                    var speechInferenceId: String?
                    var toolInferenceId: String?
                    let inferenceId = await WildEdge.shared.trace(
                        item.audioURL.lastPathComponent,
                        kind: .eval,
                        attributes: inputMeta
                    ) { span in
                        let totalStart = Date()
                        if needsSpeechToText {
                            var speechStepAttributes = inputMeta
                            speechStepAttributes["benchmark_step"] = BenchmarkStep.speechToText.rawValue
                            await span.span(
                                BenchmarkStep.speechToText.rawValue,
                                kind: .agentStep,
                                attributes: speechStepAttributes
                            ) { speechSpan in
                                transcription = await transcribeIfNeeded(
                                    url: item.processingAudioURL,
                                    voiceToTextMode: settings.voiceToTextMode,
                                    whisperModelSize: settings.whisperModelSize,
                                    progressHandler: { progress, speed in
                                        guard settings.voiceToTextMode == .leap else { return }
                                        Task { @MainActor [weak viewModel] in
                                            guard viewModel?.benchmarkRequested == true else { return }
                                            viewModel?.benchmarkStatus = leapDownloadMessage(progress: progress, speed: speed)
                                        }
                                    }
                                )
                                comparison = benchmarkComparisonMeta(
                                    actualTranscript: transcription?.transcript,
                                    expectedTranscript: item.expectedTranscript
                                )
                                speechSpan.setAttributes([
                                    "benchmark_step": BenchmarkStep.speechToText.rawValue,
                                    "speech_to_text_model": transcription?.modelId ?? "",
                                    "speech_to_text_duration_ms": transcription?.durationMs ?? 0,
                                    "transcript_exact_match": comparison["normalized_exact_match"] as? Bool ?? false,
                                    "transcript_match_evaluated": comparison["normalized_exact_match"] != nil
                                ])
                                speechInferenceId = trackSpeechInferenceIfNeeded(
                                    transcription: transcription,
                                    audioToToolArchitecture: settings.audioToToolArchitecture,
                                    appleSpeechModelHandle: appleSpeechModelHandle,
                                    whisperTinySpeechModelHandle: whisperTinySpeechModelHandle,
                                    whisperBaseSpeechModelHandle: whisperBaseSpeechModelHandle,
                                    leapSpeechModelHandle: leapSpeechModelHandle,
                                    attachments: [],
                                    additionalInputMeta: inputMeta,
                                    additionalOutputMeta: comparison,
                                    runId: runId,
                                    traceId: speechSpan.traceId,
                                    parentSpanId: speechSpan.spanId
                                )
                            }
                        } else {
                            comparison = benchmarkComparisonMeta(
                                actualTranscript: nil,
                                expectedTranscript: nil
                            )
                        }

                        if hasToolStep {
                            let toolStep: BenchmarkStep = needsTextToTool ? .textToTool : .speechToTool
                            var toolStepAttributes = inputMeta
                            toolStepAttributes["benchmark_step"] = toolStep.rawValue
                            await span.span(
                                toolStep.rawValue,
                                kind: .agentStep,
                                attributes: toolStepAttributes
                            ) { toolSpan in
                                if needsTextToTool {
                                    toolResult = await generateTextToolCall(
                                        transcript: transcription?.transcript,
                                        model: settings.benchmarkTextToToolModel,
                                        viewModel: viewModel
                                    )
                                } else {
                                    toolResult = await generateSpeechToolCall(
                                        url: item.processingAudioURL,
                                        model: settings.benchmarkSpeechToToolModel,
                                        viewModel: viewModel
                                    )
                                }

                                toolComparison = benchmarkToolCallComparisonMeta(
                                    actualToolCall: toolResult,
                                    expectedItem: item
                                )
                                let toolMatched = toolComparison["tool_call_exact_match"] as? Bool
                                toolCallMeasuredCount += 1
                                if toolMatched == true {
                                    toolCallMatchCount += 1
                                } else {
                                    print(
                                        """
                                        Benchmark tool-call mismatch: file=\(item.audioURL.lastPathComponent); expected=\(toolComparison["expected_tool_call_json"] as? String ?? ""); actual=\(toolComparison["actual_tool_call_json"] as? String ?? ""); actual_parse_error=\(toolComparison["actual_tool_call_parse_error"] as? String ?? ""); expected_parse_error=\(toolComparison["expected_tool_call_parse_error"] as? String ?? ""); raw=\(toolComparison["actual_tool_call"] as? String ?? "")
                                        """
                                    )
                                    let mismatchKey = benchmarkToolCallMismatchKey(
                                        item: item,
                                        settings: settings,
                                        inferenceIndex: inferenceIndex,
                                        inferenceCount: inferenceCount
                                    )
                                    toolCallMismatchDetailsByKey[mismatchKey] = benchmarkToolCallMismatchDetail(
                                        item: item,
                                        inferenceIndex: inferenceIndex,
                                        inferenceCount: inferenceCount,
                                        toolCall: toolResult
                                    )
                                }
                                toolComparison["benchmark_tool_call_match_count"] = toolCallMatchCount
                                toolComparison["benchmark_tool_call_measured_count"] = toolCallMeasuredCount
                                toolComparison["benchmark_tool_call_expected_count"] = toolCallExpectedCount
                                toolComparison["benchmark_tool_call_match_rate"] = toolCallMeasuredCount > 0
                                    ? Double(toolCallMatchCount) / Double(toolCallMeasuredCount)
                                    : 0
                                toolComparison["benchmark_tool_call_progress_rate"] = toolCallExpectedCount > 0
                                    ? Double(toolCallMeasuredCount) / Double(toolCallExpectedCount)
                                    : 0
                                toolComparison["benchmark_tool_call_mismatches"] = benchmarkMismatchSummary(
                                    benchmarkMismatchDetails(from: toolCallMismatchDetailsByKey)
                                )

                                toolSpan.setAttributes([
                                    "benchmark_step": toolStep.rawValue,
                                    "tool_call_model": toolResult?.modelId ?? "",
                                    "tool_call_duration_ms": toolResult?.durationMs ?? 0,
                                    "tool_call_exact_match": toolMatched ?? false,
                                    "tool_call_match_evaluated": toolMatched != nil
                                ])

                                if let toolResult {
                                    let toolHandle = toolResult.step == .textToTool
                                        ? textToToolModelHandle(
                                            for: settings.benchmarkTextToToolModel,
                                            leapAudioTextToolModelHandle: leapAudioTextToolModelHandle,
                                            leapSmallTextToolModelHandle: leapSmallTextToolModelHandle,
                                            leapInstructTextToolModelHandle: leapInstructTextToolModelHandle,
                                            functionGemmaTextToolModelHandle: functionGemmaTextToolModelHandle,
                                            functionGemmaMLXTextToolModelHandle: functionGemmaMLXTextToolModelHandle,
                                            qwen35SmallMLXTextToolModelHandle: qwen35SmallMLXTextToolModelHandle,
                                            tinyLlamaTextToolModelHandle: tinyLlamaTextToolModelHandle,
                                            qwen2SmallTextToolModelHandle: qwen2SmallTextToolModelHandle,
                                            qwen25TextToolModelHandle: qwen25TextToolModelHandle,
                                            qwen3SmallTextToolModelHandle: qwen3SmallTextToolModelHandle,
                                            qwen3TextToolModelHandle: qwen3TextToolModelHandle,
                                            onnxTextToolModelHandle: onnxTextToolModelHandle,
                                            appleFoundationTextToolModelHandle: appleFoundationTextToolModelHandle,
                                            customTextToolModelHandle: customTextToolModelHandle
                                        )
                                        : speechToToolModelHandle(
                                            for: settings.benchmarkSpeechToToolModel,
                                            leapSpeechToolModelHandle: leapSpeechToolModelHandle,
                                            localMultimodalSpeechToolModelHandle: localMultimodalSpeechToolModelHandle,
                                            ultravoxSpeechToolModelHandle: ultravoxSpeechToolModelHandle,
                                            qwen3ASRSpeechToolModelHandle: qwen3ASRSpeechToolModelHandle
                                        )
                                    toolInferenceId = trackToolCallInference(
                                        toolCall: toolResult,
                                        modelHandle: toolHandle,
                                        inputModality: toolResult.step == .textToTool ? .text : .audio,
                                        additionalInputMeta: inputMeta,
                                        additionalOutputMeta: toolComparison,
                                        runId: runId,
                                        inputText: toolResult.step == .textToTool ? transcription?.transcript : nil,
                                        traceId: toolSpan.traceId,
                                        parentSpanId: toolSpan.spanId
                                    )
                                }
                            }
                        }
                        let toolCallMismatchDetails = hasToolStep
                            ? benchmarkMismatchDetails(from: toolCallMismatchDetailsByKey)
                            : []
                        totalDurationMs = Int(Date().timeIntervalSince(totalStart) * 1000)
                        span.setAttributes(
                            benchmarkSpanAttributes(
                                item: item,
                                transcription: transcription,
                                toolCall: toolResult,
                                settings: settings,
                                inferenceIndex: inferenceIndex,
                                inferenceCount: inferenceCount,
                                totalDurationMs: totalDurationMs,
                                transcriptMatched: comparison["normalized_exact_match"] as? Bool,
                                toolCallMatched: toolComparison["tool_call_exact_match"] as? Bool,
                                toolCallMatchCount: toolCallMatchCount,
                                toolCallMeasuredCount: toolCallMeasuredCount,
                                toolCallExpectedCount: toolCallExpectedCount,
                                toolCallMismatchDetails: toolCallMismatchDetails
                            )
                        )
                        return toolInferenceId ?? speechInferenceId
                    }
                    if inferenceId != nil {
                        WildEdge.shared.flush(timeoutMs: 5_000)
                    }

                    await MainActor.run {
                        let transcriptMatched = comparison["normalized_exact_match"] as? Bool
                        let toolMatched = toolComparison["tool_call_exact_match"] as? Bool
                        let toolCallMismatchDetails = benchmarkMismatchDetails(from: toolCallMismatchDetailsByKey)
                        let transcriptText = benchmarkTranscriptText(from: transcription)
                        let result = benchmarkResultText(
                            needsSpeechToText: needsSpeechToText,
                            transcription: transcription,
                            transcriptMatched: transcriptMatched,
                            toolCall: toolResult,
                            toolMatched: toolMatched
                        )
                        viewModel?.benchmarkStatus = "Benchmark \(item.audioBundlePath) \(result)."
                        viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                        viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
                        viewModel?.benchmarkRunProgress = "Run \(inferenceIndex)/\(inferenceCount)"
                        viewModel?.benchmarkSleepCountdown = ""
                        viewModel?.benchmarkTranscript = needsSpeechToText ? transcriptText : ""
                        viewModel?.benchmarkExpectedTranscript = needsSpeechToText ? item.expectedTranscript ?? "" : ""
                        viewModel?.benchmarkStepsText = benchmarkStepsDescription(
                            settings.benchmarkSteps,
                            textToToolModel: settings.benchmarkTextToToolModel,
                            speechToToolModel: settings.benchmarkSpeechToToolModel
                        )
                        viewModel?.benchmarkExpectedToolCall = hasToolStep ? expectedToolCallDisplay(for: item) : ""
                        viewModel?.benchmarkActualToolCall = hasToolStep ? actualToolCallDisplay(for: toolResult) : ""
                        viewModel?.benchmarkRawModelText = hasToolStep ? rawModelTextDisplay(for: toolResult) : ""
                        viewModel?.benchmarkLatencyText = benchmarkLatencyText(
                            transcription: transcription,
                            toolCall: toolResult,
                            totalDurationMs: totalDurationMs
                        )
                        viewModel?.benchmarkTranscriptMatchText = needsSpeechToText
                            ? transcriptResultText(transcription: transcription, matched: transcriptMatched)
                            : ""
                        viewModel?.benchmarkToolCallMatchText = hasToolStep
                            ? toolCallResultText(toolCall: toolResult, matched: toolMatched)
                            : ""
                        viewModel?.benchmarkToolCallMatchSummary = hasToolStep
                            ? benchmarkToolCallMatchProgressText(
                                matched: toolCallMatchCount,
                                measured: toolCallMeasuredCount,
                                total: toolCallExpectedCount
                            )
                            : ""
                        viewModel?.benchmarkToolCallMismatchDetails = hasToolStep
                            ? toolCallMismatchDetails
                            : []
                    }

                    if let runtimeStopStatus = benchmarkRuntimeStopStatus(
                        transcription: transcription,
                        toolCall: toolResult
                    ) {
                        finishStatus = runtimeStopStatus
                        await MainActor.run {
                            viewModel?.benchmarkRequested = false
                            viewModel?.benchmarkRunProgress = "Stopped"
                        }
                        break benchmarkLoop
                    }

                    let isLastSelectedItem = offset == items.indices.last
                    let isLastInferenceForItem = inferenceIndex == inferenceCount
                    if isLastSelectedItem && isLastInferenceForItem {
                        let passCompleteStatus = "Benchmark pass \(iteration) complete. Restarting..."
                        await MainActor.run {
                            viewModel?.benchmarkStatus = passCompleteStatus
                            viewModel?.benchmarkSleepCountdown = ""
                        }
                        guard await sleepBenchmarkDelay(seconds: settings.benchmarkDelaySeconds, viewModel: viewModel) else {
                            break
                        }
                        continue
                    }

                    guard await sleepBenchmarkDelay(seconds: settings.benchmarkDelaySeconds, viewModel: viewModel) else {
                        break
                    }
                }
            }
            iteration += 1
        }

        await finishBenchmarkLoop(viewModel: viewModel, status: finishStatus)
    }

    private nonisolated static func finishBenchmarkLoop(
        viewModel: RecorderViewModel?,
        status: String
    ) async {
        await MainActor.run {
            viewModel?.isBenchmarking = false
            Self.setBenchmarkIdleTimerDisabled(false)
            viewModel?.benchmarkStatus = status
            viewModel?.benchmarkTask = nil
            viewModel?.benchmarkRunProgress = "Completed"
            viewModel?.benchmarkSleepCountdown = ""
        }
    }

    private static func setBenchmarkIdleTimerDisabled(_ disabled: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private nonisolated static func benchmarkRuntimeStopStatus(
        transcription: SpeechTranscriptionResult?,
        toolCall: BenchmarkToolCallResult?
    ) -> String? {
        let errors = [
            transcription?.errorDescription,
            toolCall?.errorDescription
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let error = errors.first(where: isBenchmarkModelLoadFailure) else {
            return nil
        }
        return "Benchmark stopped after model load failure: \(error)"
    }

    private nonisolated static func isBenchmarkModelLoadFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("model load failed")
            || lowercased.contains("failed to load model")
            || lowercased.contains("model is corrupted")
            || lowercased.contains("corrupted or incomplete")
    }

    private nonisolated static func benchmarkWarmupKey(
        settings: VoiceRecorderEffectiveSettings,
        item: BenchmarkDatasetItem
    ) -> String {
        [
            settings.benchmarkSteps.map(\.rawValue).joined(separator: "+"),
            settings.voiceToTextMode.rawValue,
            settings.whisperModelSize.rawValue,
            settings.audioToToolArchitecture.rawValue,
            settings.benchmarkTextToToolModel.signature,
            settings.benchmarkSpeechToToolModel.signature,
            settings.benchmarkRecordingsMatch.joined(separator: ","),
            item.processingAudioURL.lastPathComponent
        ].joined(separator: "|")
    }

    private nonisolated static func runBenchmarkWarmup(
        item: BenchmarkDatasetItem,
        settings: VoiceRecorderEffectiveSettings,
        viewModel: RecorderViewModel?
    ) async -> BenchmarkWarmupResult {
        let needsSpeechToText = settings.benchmarkSteps.contains(.speechToText)
        let needsTextToTool = settings.benchmarkSteps.contains(.textToTool)
        let needsSpeechToTool = settings.benchmarkSteps.contains(.speechToTool)
        let hasToolStep = needsTextToTool || needsSpeechToTool

        guard needsSpeechToText == false || settings.voiceToTextMode != .disabled else {
            return BenchmarkWarmupResult(completed: false, runtimeStopStatus: nil)
        }

        print(
            "Benchmark warm-up starting: steps=\(settings.benchmarkSteps.map(\.rawValue).joined(separator: ",")), file=\(item.processingAudioURL.lastPathComponent)"
        )
        await MainActor.run {
            viewModel?.isBenchmarking = true
            viewModel?.benchmarkStatus = "Warming up \(benchmarkStepsDescription(settings.benchmarkSteps, textToToolModel: settings.benchmarkTextToToolModel, speechToToolModel: settings.benchmarkSpeechToToolModel))..."
            viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
            viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
            viewModel?.benchmarkRunProgress = "Warm-up (not measured)"
            viewModel?.benchmarkSleepCountdown = ""
            viewModel?.benchmarkTranscript = ""
            viewModel?.benchmarkExpectedTranscript = needsSpeechToText ? item.expectedTranscript ?? "" : ""
            viewModel?.benchmarkStepsText = benchmarkStepsDescription(
                settings.benchmarkSteps,
                textToToolModel: settings.benchmarkTextToToolModel,
                speechToToolModel: settings.benchmarkSpeechToToolModel
            )
            viewModel?.benchmarkExpectedToolCall = hasToolStep ? expectedToolCallDisplay(for: item) : ""
            viewModel?.benchmarkActualToolCall = ""
            viewModel?.benchmarkRawModelText = ""
            viewModel?.benchmarkLatencyText = ""
            viewModel?.benchmarkTranscriptMatchText = ""
            viewModel?.benchmarkToolCallMatchText = hasToolStep ? "warm-up not measured" : ""
        }

        let totalStart = Date()
        var transcription: SpeechTranscriptionResult?
        var toolResult: BenchmarkToolCallResult?

        if needsSpeechToText {
            transcription = await transcribeIfNeeded(
                url: item.processingAudioURL,
                voiceToTextMode: settings.voiceToTextMode,
                whisperModelSize: settings.whisperModelSize,
                progressHandler: { progress, speed in
                    guard settings.voiceToTextMode == .leap else { return }
                    Task { @MainActor [weak viewModel] in
                        guard viewModel?.benchmarkRequested == true else { return }
                        viewModel?.benchmarkStatus = leapDownloadMessage(progress: progress, speed: speed)
                    }
                }
            )
        }

        if hasToolStep {
            if needsTextToTool {
                toolResult = await generateTextToolCall(
                    transcript: transcription?.transcript,
                    model: settings.benchmarkTextToToolModel,
                    viewModel: viewModel
                )
            } else {
                toolResult = await generateSpeechToolCall(
                    url: item.processingAudioURL,
                    model: settings.benchmarkSpeechToToolModel,
                    viewModel: viewModel
                )
            }
        }

        let totalDurationMs = Int(Date().timeIntervalSince(totalStart) * 1000)
        let runtimeStopStatus = benchmarkRuntimeStopStatus(
            transcription: transcription,
            toolCall: toolResult
        )
        await MainActor.run {
            let transcriptText = benchmarkTranscriptText(from: transcription)
            viewModel?.benchmarkStatus = runtimeStopStatus
                ?? "Warm-up complete. Starting measured benchmark runs..."
            viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
            viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
            viewModel?.benchmarkRunProgress = runtimeStopStatus == nil
                ? "Warm-up complete"
                : "Stopped"
            viewModel?.benchmarkSleepCountdown = ""
            viewModel?.benchmarkTranscript = needsSpeechToText ? transcriptText : ""
            viewModel?.benchmarkExpectedTranscript = needsSpeechToText ? item.expectedTranscript ?? "" : ""
            viewModel?.benchmarkExpectedToolCall = hasToolStep ? expectedToolCallDisplay(for: item) : ""
            viewModel?.benchmarkActualToolCall = hasToolStep ? actualToolCallDisplay(for: toolResult) : ""
            viewModel?.benchmarkRawModelText = hasToolStep ? rawModelTextDisplay(for: toolResult) : ""
            viewModel?.benchmarkLatencyText = "Warm-up only; " + benchmarkLatencyText(
                transcription: transcription,
                toolCall: toolResult,
                totalDurationMs: totalDurationMs
            )
            viewModel?.benchmarkTranscriptMatchText = needsSpeechToText ? "warm-up not measured" : ""
            viewModel?.benchmarkToolCallMatchText = hasToolStep ? "warm-up not measured" : ""
        }
        print(
            "Benchmark warm-up complete: file=\(item.processingAudioURL.lastPathComponent), total_duration_ms=\(totalDurationMs), runtime_stop=\(runtimeStopStatus ?? "none")"
        )

        return BenchmarkWarmupResult(completed: runtimeStopStatus == nil, runtimeStopStatus: runtimeStopStatus)
    }

    private nonisolated static func prepareWhisperBenchmarkModel(
        _ model: WhisperModelSize,
        viewModel: RecorderViewModel?
    ) async -> Bool {
        await MainActor.run {
            viewModel?.benchmarkStatus = "Preparing Whisper \(model.displayName) before measurement..."
            viewModel?.benchmarkPreprocessingFile = "Whisper \(model.displayName)"
            viewModel?.benchmarkRunProgress = ""
            viewModel?.benchmarkSleepCountdown = ""
            viewModel?.benchmarkLatencyText = ""
            viewModel?.benchmarkTranscriptMatchText = ""
            viewModel?.benchmarkToolCallMatchText = ""
        }

        do {
	            try await WhisperSpeechTranscriber.shared.prepareModels([model]) { progress in
	                Task { @MainActor [weak viewModel] in
	                    guard viewModel?.benchmarkRequested == true else { return }
	                    viewModel?.benchmarkStatus = whisperPreparationMessage(progress)
	                    viewModel?.benchmarkPreprocessingFile = "Whisper \(progress.model.displayName)"
	                }
	            }
            await MainActor.run {
                viewModel?.benchmarkStatus = "Whisper \(model.displayName) ready."
                viewModel?.benchmarkPreprocessingFile = "Whisper \(model.displayName)"
            }
            return true
        } catch {
            await MainActor.run {
                viewModel?.benchmarkStatus = "Whisper \(model.displayName) preparation failed: \(error.localizedDescription)"
                viewModel?.benchmarkPreprocessingFile = "Whisper \(model.displayName)"
                viewModel?.benchmarkLatencyText = ""
                viewModel?.benchmarkTranscriptMatchText = "model error"
                viewModel?.benchmarkToolCallMatchText = ""
            }
            return false
        }
    }

    private nonisolated static func prepareTextToToolBenchmarkModel(
        _ model: BenchmarkTextToToolModel,
        viewModel: RecorderViewModel?
    ) async -> Bool {
        await MainActor.run {
            viewModel?.benchmarkStatus = "Checking \(model.displayName) before measurement..."
            viewModel?.benchmarkPreprocessingFile = model.displayName
            viewModel?.benchmarkRunProgress = ""
            viewModel?.benchmarkSleepCountdown = ""
            viewModel?.benchmarkLatencyText = ""
            viewModel?.benchmarkTranscriptMatchText = ""
            viewModel?.benchmarkToolCallMatchText = ""
        }

        do {
            let status: ModelAssetStatus
            if model.provider == "mlx" {
                status = await MlxBenchmarkTextToToolModel.shared.modelStatus(model)
            } else {
                status = await LlamaCppBenchmarkTextToToolModel.shared.modelStatus(model)
            }
            if status.isCached {
                await MainActor.run {
                    viewModel?.benchmarkStatus = "Using cached \(model.displayName)."
                    viewModel?.benchmarkPreprocessingFile = model.displayName
                }
            } else if status.state == .partial {
                await MainActor.run {
                    viewModel?.benchmarkStatus = "Resuming \(model.displayName) download..."
                    viewModel?.benchmarkPreprocessingFile = model.displayName
                }
            }

            if model.provider == "mlx" {
                try await MlxBenchmarkTextToToolModel.shared.prepareModel(model) { progress, speed in
                    Task { @MainActor [weak viewModel] in
                        guard viewModel?.benchmarkRequested == true else { return }
                        viewModel?.benchmarkStatus = modelDownloadMessage(
                            modelName: model.displayName,
                            progress: progress,
                            speed: speed
                        )
                        viewModel?.benchmarkPreprocessingFile = model.displayName
                    }
                }
            } else {
                try await LlamaCppBenchmarkTextToToolModel.shared.prepareModel(model) { progress, speed in
                    Task { @MainActor [weak viewModel] in
                        guard viewModel?.benchmarkRequested == true else { return }
                        viewModel?.benchmarkStatus = modelDownloadMessage(
                            modelName: model.displayName,
                            progress: progress,
                            speed: speed
                        )
                        viewModel?.benchmarkPreprocessingFile = model.displayName
                    }
                }
            }
            await MainActor.run {
                viewModel?.benchmarkStatus = "\(model.displayName) ready."
                viewModel?.benchmarkPreprocessingFile = model.displayName
            }
            return true
        } catch {
            await MainActor.run {
                viewModel?.benchmarkStatus = "\(model.displayName) preparation failed: \(error.localizedDescription)"
                viewModel?.benchmarkPreprocessingFile = model.displayName
                viewModel?.benchmarkLatencyText = ""
                viewModel?.benchmarkTranscriptMatchText = ""
                viewModel?.benchmarkToolCallMatchText = "model error"
            }
            return false
        }
    }

    private nonisolated static func needsLocalTextToToolPreparation(_ model: BenchmarkTextToToolModel) -> Bool {
        model.provider == "llama_cpp" || model.provider == "llama_cpp_mtmd" || model.provider == "mlx"
    }

    private nonisolated static func benchmarkSettings(from viewModel: RecorderViewModel?) async -> VoiceRecorderEffectiveSettings? {
        await MainActor.run {
            viewModel?.benchmarkSettings
        }
    }

    private nonisolated static func isBenchmarkRequested(_ viewModel: RecorderViewModel?) async -> Bool {
        await MainActor.run {
            viewModel?.benchmarkRequested ?? false
        }
    }

    private nonisolated static func loadBenchmarkDataset() -> [BenchmarkDatasetItem] {
        let audioURLs = ["wav", "mp3", "m4a"].flatMap { fileExtension in
            Bundle.main.urls(
                forResourcesWithExtension: fileExtension,
                subdirectory: "benchmark_data"
            ) ?? []
        }.filter { url in
            let baseName = url.deletingPathExtension().lastPathComponent
            let isSupported = isSupportedBenchmarkAudioBaseName(baseName)
            if isSupported == false {
                print("Benchmark skipping unsupported audio fixture: \(url.lastPathComponent)")
            }
            return isSupported
        }
        let groupedAudioURLs = Dictionary(grouping: audioURLs) { url in
            url.deletingPathExtension().lastPathComponent
        }
        let preferredAudioURLs = groupedAudioURLs.compactMap { _, urls -> URL? in
            if let m4aURL = urls.first(where: { $0.pathExtension.lowercased() == "m4a" }) {
                return m4aURL
            }
            if let mp3URL = urls.first(where: { $0.pathExtension.lowercased() == "mp3" }) {
                return mp3URL
            }
            return urls.first(where: { $0.pathExtension.lowercased() == "wav" })
        }

        return preferredAudioURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { audioURL in
                let baseName = audioURL.deletingPathExtension().lastPathComponent
                let transcriptResourceName = expectedTranscriptResourceName(for: baseName)
                let toolCallResourceName = expectedToolCallResourceName(for: baseName)
                let transcriptURL = Bundle.main.url(
                    forResource: transcriptResourceName,
                    withExtension: "txt",
                    subdirectory: "benchmark_data"
                ) ?? Bundle.main.url(
                    forResource: baseName,
                    withExtension: "txt",
                    subdirectory: "benchmark_data"
                )
                let toolCallURL = Bundle.main.url(
                    forResource: toolCallResourceName,
                    withExtension: "json",
                    subdirectory: "benchmark_data"
                ) ?? Bundle.main.url(
                    forResource: baseName,
                    withExtension: "json",
                    subdirectory: "benchmark_data"
                )
                let expectedToolCall = readExpectedText(from: toolCallURL)
                let parsedExpectedToolCall = ToolCallJSON.parseAndValidate(from: expectedToolCall ?? "")
                return BenchmarkDatasetItem(
                    audioURL: audioURL,
                    processingAudioURL: audioURL,
                    audioDurationSeconds: benchmarkAudioDurationSeconds(for: audioURL),
                    processingAudioDurationSeconds: benchmarkAudioDurationSeconds(for: audioURL),
                    expectedTranscriptURL: transcriptURL,
                    expectedToolCallURL: toolCallURL,
                    expectedTranscript: readExpectedTranscript(from: transcriptURL),
                    expectedToolCall: expectedToolCall,
                    expectedToolCallJSON: parsedExpectedToolCall.value,
                    expectedToolCallCanonicalJSON: parsedExpectedToolCall.canonicalJSON,
                    expectedToolCallParseError: expectedToolCall == nil ? nil : parsedExpectedToolCall.error
                )
            }
    }

    private nonisolated static func benchmarkAudioDurationSeconds(for url: URL) -> Double? {
        if let audioFile = try? AVAudioFile(forReading: url) {
            let sampleRate = audioFile.processingFormat.sampleRate
            if sampleRate > 0 {
                return roundedDurationSeconds(Double(audioFile.length) / sampleRate)
            }
        }

        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return roundedDurationSeconds(seconds)
    }

    private nonisolated static func prepareBenchmarkDataset(
        _ items: [BenchmarkDatasetItem],
        viewModel: RecorderViewModel?
    ) async -> [BenchmarkDatasetItem] {
        var prepared: [BenchmarkDatasetItem] = []

        for item in items {
            guard await isBenchmarkRequested(viewModel) else { break }

            let fileExtension = item.audioURL.pathExtension.lowercased()
            guard ["m4a", "mp3"].contains(fileExtension) else {
                prepared.append(item)
                continue
            }

            await MainActor.run {
                viewModel?.benchmarkStatus = "Preparing \(item.audioURL.lastPathComponent)..."
                viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                viewModel?.benchmarkPreprocessingFile = "Converting to WAV..."
            }

            do {
                let convertedURL = try convertBenchmarkAudioToWAV(item.audioURL)
                await MainActor.run {
                    viewModel?.benchmarkPreprocessingFile = convertedURL.lastPathComponent
                }
                prepared.append(item.preparedForProcessing(at: convertedURL))
            } catch {
                let message = "\(fileExtension.uppercased()) conversion failed for \(item.audioURL.lastPathComponent). Skipping fixture. \(error.localizedDescription)"
                print("Benchmark \(message)")
                await MainActor.run {
                    viewModel?.benchmarkStatus = message
                    viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                    viewModel?.benchmarkPreprocessingFile = "Skipped"
                }
            }
        }

        return prepared
    }

    private final class LockedErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        var error: Error? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedError
            }
            set {
                lock.lock()
                storedError = newValue
                lock.unlock()
            }
        }
    }

    private nonisolated static func convertBenchmarkAudioToWAV(_ sourceURL: URL) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).wav")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let asset = AVURLAsset(url: sourceURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw SpeechTranscriptionError.transcriptionFailed("Benchmark audio has no audio track.")
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw SpeechTranscriptionError.transcriptionFailed("Could not prepare benchmark audio reader.")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw SpeechTranscriptionError.transcriptionFailed("Could not prepare benchmark audio writer.")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? SpeechTranscriptionError.transcriptionFailed("Benchmark audio reader failed to start.")
        }

        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? SpeechTranscriptionError.transcriptionFailed("Benchmark WAV writer failed to start.")
        }
        writer.startSession(atSourceTime: .zero)

        let writeQueue = DispatchQueue(label: "dev.wildedge.voice.benchmark.wav-writer")
        let writingFinished = DispatchSemaphore(value: 0)
        let appendError = LockedErrorBox()

        writerInput.requestMediaDataWhenReady(on: writeQueue) {
            while writerInput.isReadyForMoreMediaData {
                if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                    if writerInput.append(sampleBuffer) == false {
                        appendError.error = writer.error
                            ?? SpeechTranscriptionError.transcriptionFailed("Benchmark WAV writer failed while appending audio.")
                        reader.cancelReading()
                        writerInput.markAsFinished()
                        writingFinished.signal()
                        return
                    }
                } else {
                    writerInput.markAsFinished()
                    writingFinished.signal()
                    return
                }
            }
        }

        writingFinished.wait()

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? SpeechTranscriptionError.transcriptionFailed("Benchmark WAV conversion failed.")
        }
        if let error = appendError.error {
            writer.cancelWriting()
            throw error
        }

        let finishingFinished = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finishingFinished.signal()
        }
        finishingFinished.wait()

        guard writer.status == .completed else {
            throw writer.error ?? SpeechTranscriptionError.transcriptionFailed("Benchmark WAV writer did not complete.")
        }

        return outputURL
    }

    private nonisolated static func write(
        sampleBuffer: CMSampleBuffer,
        outputFile: AVAudioFile
    ) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw SpeechTranscriptionError.transcriptionFailed("Benchmark sample buffer has no audio format.")
        }

        var mutableStreamDescription = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &mutableStreamDescription) else {
            throw SpeechTranscriptionError.transcriptionFailed("Benchmark sample buffer audio format is unsupported.")
        }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw SpeechTranscriptionError.transcriptionFailed("Benchmark WAV conversion failed with status \(status).")
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: &audioBufferList
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("Benchmark sample buffer could not be converted to PCM.")
        }
        pcmBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        try outputFile.write(from: pcmBuffer)
        _ = blockBuffer
    }

    private nonisolated static func selectedBenchmarkItems(
        from items: [BenchmarkDatasetItem],
        settings: VoiceRecorderEffectiveSettings
    ) -> [BenchmarkDatasetItem] {
        let patterns = settings.benchmarkRecordingsMatch
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !patterns.isEmpty else { return items }

        return items.filter { item in
            patterns.contains { pattern in
                recording(item, matches: pattern)
            }
        }
    }

    private nonisolated static func recording(_ item: BenchmarkDatasetItem, matches pattern: String) -> Bool {
        let targets = [
            item.recordingID,
            item.audioURL.lastPathComponent,
            item.audioBundlePath
        ]

        if shouldUseWildcardMatching(for: pattern) {
            return recording(matchesWildcard: pattern, targets: targets)
        }

        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            return targets.contains { target in
                let range = NSRange(target.startIndex..<target.endIndex, in: target)
                return regex.firstMatch(in: target, options: [], range: range) != nil
            }
        }

        return recording(matchesWildcard: pattern, targets: targets)
    }

    private nonisolated static func shouldUseWildcardMatching(for pattern: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else { return false }
        let explicitRegexMarkers = CharacterSet(charactersIn: "^$[](){}\\|+")
        return pattern.rangeOfCharacter(from: explicitRegexMarkers) == nil
    }

    private nonisolated static func recording(
        matchesWildcard pattern: String,
        targets: [String]
    ) -> Bool {
        let wildcardPattern = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        guard let wildcardRegex = try? NSRegularExpression(
            pattern: "^\(wildcardPattern)$",
            options: [.caseInsensitive]
        ) else {
            return false
        }

        return targets.contains { target in
            let range = NSRange(target.startIndex..<target.endIndex, in: target)
            return wildcardRegex.firstMatch(in: target, options: [], range: range) != nil
        }
    }

    private nonisolated static func expectedTranscriptResourceName(for baseName: String) -> String {
        let parts = benchmarkIdentifierParts(for: baseName)
        guard parts.count >= 2 else { return baseName }
        return "\(parts[0])-\(parts[1])"
    }

    private nonisolated static func expectedToolCallResourceName(for baseName: String) -> String {
        benchmarkIdentifierParts(for: baseName).first ?? baseName
    }

    private nonisolated static func benchmarkIdentifierParts(for baseName: String) -> [String] {
        baseName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    }

    private nonisolated static func isSupportedBenchmarkAudioBaseName(_ baseName: String) -> Bool {
        let parts = benchmarkIdentifierParts(for: baseName)
        guard parts.count == 3,
              parts[0].range(of: #"^\d{3}$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^\d{3}$"#, options: .regularExpression) != nil,
              parts[2].range(of: #"^[A-Za-z]+$"#, options: .regularExpression) != nil
        else {
            return false
        }
        return true
    }

    private nonisolated static func displayUnsupportedBenchmarkConfig(
        settings: VoiceRecorderEffectiveSettings,
        warning: String,
        viewModel: RecorderViewModel?
    ) async {
        await MainActor.run {
            viewModel?.isBenchmarking = false
            Self.setBenchmarkIdleTimerDisabled(false)
            viewModel?.benchmarkStatus = warning
            viewModel?.benchmarkCurrentInput = settings.benchmarkRecordingsMatch.joined(separator: ", ")
            viewModel?.benchmarkPreprocessingFile = ""
            viewModel?.benchmarkRunProgress = "Stopped"
            viewModel?.benchmarkSleepCountdown = ""
            viewModel?.benchmarkTranscript = ""
            viewModel?.benchmarkExpectedTranscript = ""
            viewModel?.benchmarkStepsText = benchmarkStepsDescription(
                settings.benchmarkSteps,
                textToToolModel: settings.benchmarkTextToToolModel,
                speechToToolModel: settings.benchmarkSpeechToToolModel
            )
            viewModel?.benchmarkExpectedToolCall = ""
            viewModel?.benchmarkActualToolCall = ""
            viewModel?.benchmarkRawModelText = ""
            viewModel?.benchmarkLatencyText = ""
            viewModel?.benchmarkTranscriptMatchText = ""
            viewModel?.benchmarkToolCallMatchText = ""
        }
    }

    private nonisolated static func unsupportedBenchmarkConfigSleepSeconds(
        for settings: VoiceRecorderEffectiveSettings
    ) -> TimeInterval {
        min(max(settings.benchmarkDelaySeconds, 1), 5)
    }

    private nonisolated static func sleepBenchmarkDelay(
        seconds: TimeInterval,
        viewModel: RecorderViewModel?,
        statusText: String = "Sleeping before next benchmark run..."
    ) async -> Bool {
        let seconds = max(0, seconds)
        guard seconds > 0 else {
            return await isBenchmarkRequested(viewModel)
        }

        let end = Date().addingTimeInterval(seconds)
        await MainActor.run {
            viewModel?.benchmarkStatus = statusText
            viewModel?.benchmarkSleepCountdown = formatBenchmarkCountdown(seconds)
        }
        while !Task.isCancelled {
            guard await isBenchmarkRequested(viewModel) else { return false }
            let remaining = end.timeIntervalSinceNow
            guard remaining > 0 else {
                await MainActor.run {
                    viewModel?.benchmarkSleepCountdown = ""
                }
                return true
            }
            await MainActor.run {
                viewModel?.benchmarkSleepCountdown = formatBenchmarkCountdown(remaining)
            }
            let step = min(remaining, 0.25)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        return false
    }

    private nonisolated static func formatBenchmarkCountdown(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped >= 10 {
            return "\(Int(ceil(clamped)))s"
        }
        return String(format: "%.1fs", clamped)
    }

    private nonisolated static func readExpectedTranscript(from url: URL?) -> String? {
        readExpectedText(from: url)
    }

    private nonisolated static func readExpectedText(from url: URL?) -> String? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func generateTextToolCall(
        transcript: String?,
        model: BenchmarkTextToToolModel,
        viewModel: RecorderViewModel?
    ) async -> BenchmarkToolCallResult {
        let trimmedTranscript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await MainActor.run {
            viewModel?.benchmarkStatus = "Generating tool call from transcript with \(model.displayName)..."
        }
        let result = await LeapBenchmarkToolCallModel.shared.generate(
            input: .text(trimmedTranscript),
            textToToolModel: model,
            progressHandler: { progress, speed in
                Task { @MainActor [weak viewModel] in
                    guard viewModel?.benchmarkRequested == true else { return }
                    viewModel?.benchmarkStatus = modelDownloadMessage(
                        modelName: model.displayName,
                        progress: progress,
                        speed: speed
                    )
                }
            }
        )
        return benchmarkToolCallResult(step: .textToTool, generation: result)
    }

    private nonisolated static func generateSpeechToolCall(
        url: URL,
        model: BenchmarkTextToToolModel,
        viewModel: RecorderViewModel?
    ) async -> BenchmarkToolCallResult {
        print("Benchmark speech_to_tool starting: model=\(model.modelId), file=\(url.lastPathComponent)")
        await MainActor.run {
            viewModel?.benchmarkStatus = "Generating tool call from audio with \(model.displayName)..."
        }
        let result = await LeapBenchmarkToolCallModel.shared.generate(
            input: .audio(url),
            speechToToolModel: model,
            progressHandler: { progress, speed in
                Task { @MainActor [weak viewModel] in
                    guard viewModel?.benchmarkRequested == true else { return }
                    viewModel?.benchmarkStatus = model.usesSharedAudioModel
                        ? leapDownloadMessage(progress: progress, speed: speed)
                        : modelDownloadMessage(modelName: model.displayName, progress: progress, speed: speed)
                }
            }
        )
        return benchmarkToolCallResult(step: .speechToTool, generation: result)
    }

    private nonisolated static func textToToolModelHandle(
        for model: BenchmarkTextToToolModel,
        leapAudioTextToolModelHandle: ModelHandle,
        leapSmallTextToolModelHandle: ModelHandle,
        leapInstructTextToolModelHandle: ModelHandle,
        functionGemmaTextToolModelHandle: ModelHandle,
        functionGemmaMLXTextToolModelHandle: ModelHandle,
        qwen35SmallMLXTextToolModelHandle: ModelHandle,
        tinyLlamaTextToolModelHandle: ModelHandle,
        qwen2SmallTextToolModelHandle: ModelHandle,
        qwen25TextToolModelHandle: ModelHandle,
        qwen3SmallTextToolModelHandle: ModelHandle,
        qwen3TextToolModelHandle: ModelHandle,
        onnxTextToolModelHandle: ModelHandle,
        appleFoundationTextToolModelHandle: ModelHandle,
        customTextToolModelHandle: ModelHandle
    ) -> ModelHandle {
        switch model.kind {
        case .leapLFM25Audio:
            return leapAudioTextToolModelHandle
        case .liquidLFM25AudioOnePointFiveB:
            return customTextToolModelHandle
        case .ultravoxLlama32OneB:
            return customTextToolModelHandle
        case .qwen3ASRZeroPointSixB:
            return customTextToolModelHandle
        case .leapLFM25350M:
            return leapSmallTextToolModelHandle
        case .leapLFM2512BInstruct:
            return leapInstructTextToolModelHandle
        case .functionGemma:
            return functionGemmaTextToolModelHandle
        case .functionGemmaMLX:
            return functionGemmaMLXTextToolModelHandle
        case .qwen35ZeroPointEightBOptiQMLX:
            return qwen35SmallMLXTextToolModelHandle
        case .tinyLlamaOnePointOneB:
            return tinyLlamaTextToolModelHandle
        case .qwen2ZeroPointFiveBInstruct:
            return qwen2SmallTextToolModelHandle
        case .qwen25OnePointFiveBInstruct:
            return qwen25TextToolModelHandle
        case .qwen3ZeroPointSixB:
            return qwen3SmallTextToolModelHandle
        case .qwen3FourB:
            return qwen3TextToolModelHandle
        case .onnxRuntime:
            return onnxTextToolModelHandle
        case .appleFoundationModels:
            return appleFoundationTextToolModelHandle
        case .custom:
            return customTextToolModelHandle
        }
    }

    private nonisolated static func speechToToolModelHandle(
        for model: BenchmarkTextToToolModel,
        leapSpeechToolModelHandle: ModelHandle,
        localMultimodalSpeechToolModelHandle: ModelHandle,
        ultravoxSpeechToolModelHandle: ModelHandle,
        qwen3ASRSpeechToolModelHandle: ModelHandle
    ) -> ModelHandle {
        switch model.kind {
        case .liquidLFM25AudioOnePointFiveB:
            return localMultimodalSpeechToolModelHandle
        case .qwen3ASRZeroPointSixB:
            return qwen3ASRSpeechToolModelHandle
        case .ultravoxLlama32OneB:
            return ultravoxSpeechToolModelHandle
        default:
            return leapSpeechToolModelHandle
        }
    }

    private nonisolated static func benchmarkToolCallResult(
        step: BenchmarkStep,
        generation: BenchmarkToolCallGenerationResult
    ) -> BenchmarkToolCallResult {
        BenchmarkToolCallResult(
            step: step,
            rawOutput: generation.rawOutput,
            rawText: generation.rawText,
            durationMs: generation.durationMs,
            parsedJSON: generation.parsedJSON,
            canonicalJSON: generation.canonicalJSON,
            errorDescription: generation.errorDescription,
            provider: generation.provider,
            modelId: generation.modelId,
            modelName: generation.modelName,
            modelSource: generation.modelSource,
            modelFormat: generation.modelFormat,
            quantization: generation.quantization
        )
    }

    private nonisolated static func benchmarkToolCallComparisonMeta(
        actualToolCall: BenchmarkToolCallResult?,
        expectedItem item: BenchmarkDatasetItem
    ) -> [String: Any] {
        let actualCanonical = actualToolCall?.canonicalJSON ?? ""
        let expectedCanonical = item.expectedToolCallCanonicalJSON ?? ""
        let exactMatch = actualToolCall?.parsedJSON != nil
            && item.expectedToolCallJSON != nil
            && actualToolCall?.parsedJSON == item.expectedToolCallJSON

        return [
            "expected_tool_call": item.expectedToolCall ?? "",
            "expected_tool_call_json": expectedCanonical,
            "expected_tool_call_missing": item.expectedToolCall == nil,
            "expected_tool_call_parse_error": item.expectedToolCallParseError ?? "",
            "actual_tool_call": actualToolCall?.rawOutput ?? "",
            "actual_raw_model_text": actualToolCall?.rawText ?? "",
            "actual_tool_call_json": actualCanonical,
            "actual_tool_call_parse_error": actualToolCall?.parsedSuccessfully == true ? "" : actualToolCall?.errorDescription ?? "",
            "tool_call_step": actualToolCall?.step.rawValue ?? "",
            "tool_call_model": actualToolCall?.modelId ?? "",
            "tool_call_model_name": actualToolCall?.modelName ?? "",
            "tool_call_model_source": actualToolCall?.modelSource ?? "",
            "tool_call_quantization": actualToolCall?.quantization ?? "",
            "tool_call_duration_ms": actualToolCall?.durationMs ?? 0,
            "tool_call_exact_match": exactMatch
        ]
    }

    private nonisolated static func expectedToolCallDisplay(for item: BenchmarkDatasetItem) -> String {
        if let pretty = ToolCallJSON.prettyString(from: item.expectedToolCallJSON) {
            return pretty
        }
        if let expectedToolCall = item.expectedToolCall, expectedToolCall.isEmpty == false {
            return expectedToolCall
        }
        if let error = item.expectedToolCallParseError {
            return "Expected JSON error: \(error)"
        }
        return ""
    }

    private nonisolated static func actualToolCallDisplay(for result: BenchmarkToolCallResult?) -> String {
        guard let result else { return "" }
        if let pretty = ToolCallJSON.prettyString(from: result.parsedJSON) {
            return pretty
        }
        if result.rawOutput.isEmpty == false {
            return result.rawOutput
        }
        if let error = result.errorDescription {
            return "Error: \(error)"
        }
        return ""
    }

    private nonisolated static func rawModelTextDisplay(for result: BenchmarkToolCallResult?) -> String {
        guard let result else { return "" }
        let rawText = result.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawText.isEmpty == false else { return "" }
        return rawText
    }

    private nonisolated static func benchmarkStepsDescription(
        _ steps: [BenchmarkStep],
        textToToolModel: BenchmarkTextToToolModel? = nil,
        speechToToolModel: BenchmarkTextToToolModel? = nil
    ) -> String {
        guard steps.isEmpty == false else { return "unsupported steps" }
        var description = steps.map(\.rawValue).joined(separator: " + ")
        if steps.contains(.speechToTool), let speechToToolModel {
            description += " (\(speechToToolModel.displayName))"
            return description
        }
        if steps.contains(.textToTool), let textToToolModel {
            description += " (\(textToToolModel.displayName))"
        }
        return description
    }

    private nonisolated static func benchmarkLatencyText(
        transcription: SpeechTranscriptionResult?,
        toolCall: BenchmarkToolCallResult?,
        totalDurationMs: Int
    ) -> String {
        var parts: [String] = []
        if let transcription {
            parts.append("STT \(transcription.durationMs) ms")
        }
        if let toolCall {
            parts.append("tool \(toolCall.durationMs) ms")
        }
        guard parts.isEmpty == false else {
            return "\(totalDurationMs) ms"
        }
        guard parts.count > 1 else {
            return parts[0]
        }
        return "\(parts.joined(separator: " + ")) = \(totalDurationMs) ms"
    }

    private nonisolated static func benchmarkResultText(
        needsSpeechToText: Bool,
        transcription: SpeechTranscriptionResult?,
        transcriptMatched: Bool?,
        toolCall: BenchmarkToolCallResult?,
        toolMatched: Bool?
    ) -> String {
        if let toolCall {
            if toolCall.errorDescription != nil {
                return "tool failed"
            }
            return toolMatched == true ? "tool matched" : "tool mismatch"
        }
        guard needsSpeechToText else { return "completed" }
        return transcription?.errorDescription == nil
            ? transcriptMatched == true ? "matched" : "completed"
            : "failed"
    }

    private nonisolated static func transcriptResultText(
        transcription: SpeechTranscriptionResult?,
        matched: Bool?
    ) -> String {
        guard let transcription else { return "" }
        guard transcription.errorDescription == nil else { return "error" }
        return matched == true ? "match" : "no match"
    }

    private nonisolated static func toolCallResultText(
        toolCall: BenchmarkToolCallResult?,
        matched: Bool?
    ) -> String {
        guard let toolCall else { return "" }
        guard toolCall.errorDescription == nil else { return "error" }
        return matched == true ? "match" : "no match"
    }

    private nonisolated static func benchmarkToolCallMatchProgressText(
        matched: Int,
        measured: Int,
        total: Int
    ) -> String {
        guard total > 0 else { return "" }
        let accuracy = measured > 0
            ? Double(matched) / Double(measured) * 100
            : 0
        let progress = Double(measured) / Double(total) * 100
        return String(
            format: "%d/%d matched, %d/%d measured, %.1f%% accuracy, %.1f%% progress",
            matched,
            measured,
            measured,
            total,
            accuracy,
            progress
        )
    }

    private nonisolated static func benchmarkToolCallMismatchDetail(
        item: BenchmarkDatasetItem,
        inferenceIndex: Int,
        inferenceCount: Int,
        toolCall: BenchmarkToolCallResult?
    ) -> String {
        var parts = [item.audioURL.lastPathComponent]
        if inferenceCount > 1 {
            parts.append("run \(inferenceIndex)/\(inferenceCount)")
        }
        if let error = toolCall?.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           error.isEmpty == false {
            parts.append(error)
        } else if toolCall?.parsedJSON == nil {
            parts.append("actual JSON parse failed")
        } else if item.expectedToolCallJSON == nil {
            parts.append("expected JSON parse failed")
        } else {
            parts.append("actual JSON differed")
        }
        return parts.joined(separator: " - ")
    }

    private nonisolated static func benchmarkToolCallMismatchKey(
        item: BenchmarkDatasetItem,
        settings: VoiceRecorderEffectiveSettings,
        inferenceIndex: Int,
        inferenceCount: Int
    ) -> String {
        var parts = [
            settings.benchmarkSteps.map(\.rawValue).joined(separator: "+"),
            settings.benchmarkSteps.contains(.speechToTool)
                ? settings.benchmarkSpeechToToolModel.modelId
                : settings.benchmarkTextToToolModel.modelId,
            item.audioBundlePath
        ]
        if inferenceCount > 1 {
            parts.append(String(inferenceIndex))
        }
        return parts.joined(separator: "|")
    }

    private nonisolated static func benchmarkMismatchDetails(from detailsByKey: [String: String]) -> [String] {
        detailsByKey.keys.sorted().compactMap { detailsByKey[$0] }
    }

    private nonisolated static func benchmarkMismatchSummary(_ details: [String]) -> String {
        guard !details.isEmpty else { return "" }
        let prefix = details.prefix(5).joined(separator: "\n")
        let remaining = details.count - min(details.count, 5)
        guard remaining > 0 else { return prefix }
        return "\(prefix)\n... \(remaining) more mismatch(es)"
    }

    private nonisolated static func trackToolCallInference(
        toolCall: BenchmarkToolCallResult,
        modelHandle: ModelHandle,
        inputModality: InputModality,
        additionalInputMeta: [String: Any],
        additionalOutputMeta: [String: Any],
        runId: String,
        inputText: String? = nil,
        traceId: String? = nil,
        parentSpanId: String? = nil
    ) -> String {
        var inputMeta: [String: Any] = [
            "source": "VoiceRecorderSample",
            "provider": toolCall.provider,
            "model_id": toolCall.modelId,
            "model_name": toolCall.modelName,
            "model_source": toolCall.modelSource,
            "model_format": toolCall.modelFormat,
            "quantization": toolCall.quantization,
            "logical_model_id": modelHandle.modelId,
            "benchmark_tool_step": toolCall.step.rawValue
        ]
        if let inputText = nonEmptyText(inputText) {
            inputMeta["input_text"] = inputText
            mergeTextInputMeta(
                into: &inputMeta,
                text: inputText,
                promptType: toolCall.step.rawValue
            )
        }
        for (key, value) in additionalInputMeta {
            inputMeta[key] = value
        }

        let outputText = nonEmptyText(toolCall.rawOutput) ?? toolCall.canonicalJSON ?? ""
        var outputMeta: [String: Any] = [
            "raw_tool_call": toolCall.rawOutput,
            "raw_model_text": toolCall.rawText,
            "output_text": outputText,
            "tool_call_json": toolCall.canonicalJSON ?? "",
            "tool_call_parse_error": toolCall.parsedSuccessfully ? "" : toolCall.errorDescription ?? "",
            "duration_ms": toolCall.durationMs
        ]
        let outputTokenCount = estimatedTokenCount(outputText)
        outputMeta["tokens_out"] = outputTokenCount
        outputMeta["token_count"] = outputTokenCount
        if let inputText = nonEmptyText(inputText) {
            outputMeta["tokens_in"] = estimatedTokenCount(inputText)
        }
        for (key, value) in additionalOutputMeta {
            outputMeta[key] = value
        }

        let success = toolCall.errorDescription == nil && toolCall.parsedSuccessfully
        let errorCode = success
            ? nil
            : toolCall.rawOutput.isEmpty
            ? "tool_call_generation_failed"
            : "tool_call_parse_failed"
        return modelHandle.trackInference(
            durationMs: toolCall.durationMs,
            inputModality: inputModality,
            outputModality: .generation,
            success: success,
            errorCode: errorCode,
            inputMeta: inputMeta,
            outputMeta: outputMeta,
            attachments: [],
            traceId: traceId,
            parentSpanId: parentSpanId,
            runId: runId
        )
    }

    private nonisolated static func benchmarkInputMeta(
        item: BenchmarkDatasetItem,
        settings: VoiceRecorderEffectiveSettings,
        iteration: Int,
        itemIndex: Int,
        itemCount: Int,
        inferenceIndex: Int,
        inferenceCount: Int
    ) -> [String: Any] {
        var meta: [String: Any] = [
            "benchmark_enabled": true,
            "benchmark_suite": "voice_recorder",
            "source": "VoiceRecorderSample",
            "benchmark_steps": settings.benchmarkSteps.map(\.rawValue).joined(separator: ","),
            "benchmark_iteration": iteration,
            "benchmark_item_index": itemIndex,
            "benchmark_item_count": itemCount,
            "benchmark_inference_index": inferenceIndex,
            "benchmark_inference_count": inferenceCount,
            "benchmark_file": item.audioBundlePath,
            "benchmark_recording_id": item.recordingID,
            "input_data_name": item.audioURL.lastPathComponent,
            "input_data_file": item.audioBundlePath,
            "recording_duration_seconds": item.audioDurationSeconds ?? 0,
            "input_audio_duration_seconds": item.audioDurationSeconds ?? 0,
            "preprocessing_file": item.processingAudioURL.lastPathComponent,
            "processing_audio_extension": item.processingAudioURL.pathExtension.lowercased(),
            "processing_audio_duration_seconds": item.processingAudioDurationSeconds ?? item.audioDurationSeconds ?? 0,
            "converted_to_wav_before_inference": item.wasConvertedForProcessing,
            "benchmark_delay_seconds": settings.benchmarkDelaySeconds,
            "benchmark_number_of_inferences": settings.benchmarkNumberOfInferences,
            "benchmark_recordings_match": settings.benchmarkRecordingsMatch.joined(separator: ","),
            "benchmark_audio_extension": item.audioURL.pathExtension.lowercased(),
            "text_to_tool_model": settings.benchmarkTextToToolModel.modelId,
            "text_to_tool_model_name": settings.benchmarkTextToToolModel.displayName,
            "text_to_tool_model_source": settings.benchmarkTextToToolModel.modelSource,
            "text_to_tool_quantization": settings.benchmarkTextToToolModel.quantization,
            "speech_to_tool_model": settings.benchmarkSpeechToToolModel.modelId,
            "speech_to_tool_model_name": settings.benchmarkSpeechToToolModel.displayName,
            "speech_to_tool_model_source": settings.benchmarkSpeechToToolModel.modelSource,
            "speech_to_tool_quantization": settings.benchmarkSpeechToToolModel.quantization
        ]
        if let lineID = item.lineID {
            meta["benchmark_line_id"] = lineID
        }
        if let variantID = item.variantID {
            meta["benchmark_variant_id"] = variantID
        }
        if let speakerID = item.speakerID {
            meta["benchmark_speaker_id"] = speakerID
        }
        if let expectedTranscriptBundlePath = item.expectedTranscriptBundlePath {
            meta["expected_transcript_file"] = expectedTranscriptBundlePath
        }
        if let expectedToolCallBundlePath = item.expectedToolCallBundlePath {
            meta["expected_tool_call_file"] = expectedToolCallBundlePath
        }
        if let expectedToolCall = item.expectedToolCall {
            meta["expected_tool_call"] = expectedToolCall
        }
        if let expectedToolCallCanonicalJSON = item.expectedToolCallCanonicalJSON {
            meta["expected_tool_call_json"] = expectedToolCallCanonicalJSON
        }
        return meta
    }

    private nonisolated static func benchmarkSpanAttributes(
        item: BenchmarkDatasetItem,
        transcription: SpeechTranscriptionResult?,
        toolCall: BenchmarkToolCallResult?,
        settings: VoiceRecorderEffectiveSettings,
        inferenceIndex: Int,
        inferenceCount: Int,
        totalDurationMs: Int,
        transcriptMatched: Bool?,
        toolCallMatched: Bool?,
        toolCallMatchCount: Int,
        toolCallMeasuredCount: Int,
        toolCallExpectedCount: Int,
        toolCallMismatchDetails: [String]
    ) -> [String: Any] {
        let hasSpeechToTextStep = settings.benchmarkSteps.contains(.speechToText)
        let hasToolStep = settings.benchmarkSteps.contains(.textToTool)
            || settings.benchmarkSteps.contains(.speechToTool)
        let matchedExpected: Bool?
        if hasToolStep {
            matchedExpected = toolCallMatched
        } else if hasSpeechToTextStep {
            matchedExpected = transcriptMatched
        } else {
            matchedExpected = nil
        }

        var attributes: [String: Any] = [
            "source": "VoiceRecorderSample",
            "benchmark_suite": "voice_recorder",
            "benchmark_steps": settings.benchmarkSteps.map(\.rawValue).joined(separator: ","),
            "benchmark_file": item.audioBundlePath,
            "benchmark_recording_id": item.recordingID,
            "benchmark_inference_index": inferenceIndex,
            "benchmark_inference_count": inferenceCount,
            "input_data_name": item.audioURL.lastPathComponent,
            "input_data_file": item.audioBundlePath,
            "recording_duration_seconds": item.audioDurationSeconds ?? 0,
            "input_audio_duration_seconds": item.audioDurationSeconds ?? 0,
            "preprocessing_file": item.processingAudioURL.lastPathComponent,
            "processing_audio_extension": item.processingAudioURL.pathExtension.lowercased(),
            "processing_audio_duration_seconds": item.processingAudioDurationSeconds ?? item.audioDurationSeconds ?? 0,
            "converted_to_wav_before_inference": item.wasConvertedForProcessing,
            "voice_to_text_mode": settings.voiceToTextMode.rawValue,
            "speech_to_text_model": transcription?.modelId ?? "",
            "speech_to_text_duration_ms": transcription?.durationMs ?? 0,
            "selected_text_to_tool_model": settings.benchmarkTextToToolModel.modelId,
            "selected_text_to_tool_model_name": settings.benchmarkTextToToolModel.displayName,
            "selected_text_to_tool_quantization": settings.benchmarkTextToToolModel.quantization,
            "selected_speech_to_tool_model": settings.benchmarkSpeechToToolModel.modelId,
            "selected_speech_to_tool_model_name": settings.benchmarkSpeechToToolModel.displayName,
            "selected_speech_to_tool_quantization": settings.benchmarkSpeechToToolModel.quantization,
            "tool_call_step": toolCall?.step.rawValue ?? "",
            "tool_call_duration_ms": toolCall?.durationMs ?? 0,
            "benchmark_total_duration_ms": totalDurationMs,
            "benchmark_matched_expected": matchedExpected ?? false,
            "benchmark_match_evaluated": matchedExpected != nil,
            "transcript_exact_match": transcriptMatched ?? false,
            "transcript_match_evaluated": transcriptMatched != nil,
            "tool_call_exact_match": toolCallMatched ?? false,
            "tool_call_match_evaluated": toolCallMatched != nil,
            "benchmark_tool_call_match_count": toolCallMatchCount,
            "benchmark_tool_call_measured_count": toolCallMeasuredCount,
            "benchmark_tool_call_expected_count": toolCallExpectedCount,
            "benchmark_tool_call_match_rate": toolCallMeasuredCount > 0
                ? Double(toolCallMatchCount) / Double(toolCallMeasuredCount)
                : 0,
            "benchmark_tool_call_progress_rate": toolCallExpectedCount > 0
                ? Double(toolCallMeasuredCount) / Double(toolCallExpectedCount)
                : 0,
            "benchmark_tool_call_mismatch_count": toolCallMismatchDetails.count,
            "benchmark_tool_call_mismatches": benchmarkMismatchSummary(toolCallMismatchDetails)
        ]
        if let expectedToolCallBundlePath = item.expectedToolCallBundlePath {
            attributes["expected_tool_call_file"] = expectedToolCallBundlePath
        }
        if let expectedToolCallCanonicalJSON = item.expectedToolCallCanonicalJSON {
            attributes["expected_tool_call_json"] = expectedToolCallCanonicalJSON
        }
        if let actualToolCallCanonicalJSON = toolCall?.canonicalJSON {
            attributes["actual_tool_call_json"] = actualToolCallCanonicalJSON
        }
        if let toolCall {
            attributes["actual_raw_model_text"] = toolCall.rawText
            attributes["tool_call_model"] = toolCall.modelId
            attributes["tool_call_model_name"] = toolCall.modelName
            attributes["tool_call_model_source"] = toolCall.modelSource
            attributes["tool_call_quantization"] = toolCall.quantization
        }
        return attributes
    }

    private nonisolated static func benchmarkComparisonMeta(
        actualTranscript: String?,
        expectedTranscript: String?
    ) -> [String: Any] {
        let actual = actualTranscript ?? ""
        let expected = expectedTranscript ?? ""
        let normalizedActual = normalizeTranscript(actual)
        let normalizedExpected = normalizeTranscript(expected)
        let wordExactMatch = normalizedActual == normalizedExpected

        return [
            "expected_transcript": expected,
            "expected_transcript_missing": expectedTranscript == nil,
            "normalized_transcript": normalizedActual,
            "normalized_expected_transcript": normalizedExpected,
            "normalized_exact_match": wordExactMatch,
            "word_exact_match": wordExactMatch,
            "wer": wordErrorRate(actual: normalizedActual, expected: normalizedExpected)
        ]
    }

    private nonisolated static func benchmarkTranscriptText(from transcription: SpeechTranscriptionResult?) -> String {
        if let transcript = transcription?.transcript, !transcript.isEmpty {
            return transcript
        }
        if let error = transcription?.errorDescription, !error.isEmpty {
            return "Error: \(error)"
        }
        return ""
    }

    private nonisolated static func normalizeTranscript(_ text: String) -> String {
        let words = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "°", with: " degrees ")
            .replacingOccurrences(of: "\u{00BA}", with: " degrees ")
            .replacingOccurrences(of: "℃", with: " degrees celsius ")
            .replacingOccurrences(of: "℉", with: " degrees fahrenheit ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return normalizeNumberWords(words)
            .joined(separator: " ")
    }

    private nonisolated static func normalizeNumberWords(_ words: [String]) -> [String] {
        let units = [
            "zero": 0,
            "one": 1,
            "two": 2,
            "three": 3,
            "four": 4,
            "five": 5,
            "six": 6,
            "seven": 7,
            "eight": 8,
            "nine": 9
        ]
        let teens = [
            "ten": 10,
            "eleven": 11,
            "twelve": 12,
            "thirteen": 13,
            "fourteen": 14,
            "fifteen": 15,
            "sixteen": 16,
            "seventeen": 17,
            "eighteen": 18,
            "nineteen": 19
        ]
        let tens = [
            "twenty": 20,
            "thirty": 30,
            "forty": 40,
            "fifty": 50,
            "sixty": 60,
            "seventy": 70,
            "eighty": 80,
            "ninety": 90
        ]

        var normalized: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let tensValue = tens[word] {
                let nextIndex = index + 1
                if nextIndex < words.count, let unitValue = units[words[nextIndex]], unitValue > 0 {
                    normalized.append(String(tensValue + unitValue))
                    index += 2
                } else {
                    normalized.append(String(tensValue))
                    index += 1
                }
            } else if let teenValue = teens[word] {
                normalized.append(String(teenValue))
                index += 1
            } else if let unitValue = units[word] {
                normalized.append(String(unitValue))
                index += 1
            } else {
                normalized.append(word)
                index += 1
            }
        }
        return normalized
    }

    private nonisolated static func wordErrorRate(actual: String, expected: String) -> Double {
        let actualWords = actual.split(separator: " ").map(String.init)
        let expectedWords = expected.split(separator: " ").map(String.init)
        guard !expectedWords.isEmpty else {
            return actualWords.isEmpty ? 0 : 1
        }

        let distance = levenshteinDistance(actualWords, expectedWords)
        return Double(distance) / Double(expectedWords.count)
    }

    private nonisolated static func levenshteinDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for lhsIndex in 1...lhs.count {
            current[0] = lhsIndex
            for rhsIndex in 1...rhs.count {
                let substitution = previous[rhsIndex - 1] + (lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1)
                let insertion = current[rhsIndex - 1] + 1
                let deletion = previous[rhsIndex] + 1
                current[rhsIndex] = min(substitution, insertion, deletion)
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
    #endif

    private nonisolated static func roundedDurationSeconds(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        return (seconds * 1_000).rounded() / 1_000
    }

    private nonisolated static func leapDownloadMessage(progress: Double, speed: Int64) -> String {
        modelDownloadMessage(modelName: "Leap LFM2.5 Audio", progress: progress, speed: speed)
    }

    private nonisolated static func whisperPreparationMessage(_ progress: WhisperModelDownloadProgress) -> String {
        switch progress.phase {
        case .checking:
            return "Checking Whisper \(progress.model.displayName)..."
        case .cached:
            return "Using cached Whisper \(progress.model.displayName)."
        case .downloading:
            return "Downloading Whisper \(progress.model.displayName) \(Int(progress.modelProgress * 100))%"
        case .loading:
            return "Loading Whisper \(progress.model.displayName)..."
        case .blocked:
            return "Blocked: Whisper \(progress.model.displayName)"
        }
    }

    private nonisolated static func modelDownloadMessage(
        modelName: String,
        progress: Double,
        speed: Int64
    ) -> String {
        "Downloading \(modelName) \(Int(progress * 100))% - \(formattedByteRate(speed))"
    }

    private nonisolated static func formattedByteRate(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "waiting" }
        let value = Double(bytesPerSecond)
        if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f KB/s", value / 1_000)
        }
        return "\(bytesPerSecond) B/s"
    }

    private nonisolated static func nonEmptyText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func estimatedTokenCount(_ text: String) -> Int {
        guard nonEmptyText(text) != nil else { return 0 }
        return WildEdge.analyzeText(text).tokenCount ?? 0
    }

    private nonisolated static func mergeTextInputMeta(
        into meta: inout [String: Any],
        text: String,
        promptType: String
    ) {
        let textMeta = WildEdge.analyzeText(text, promptType: promptType).toMap()
        for (key, value) in textMeta {
            meta[key] = value
        }
    }

    private nonisolated static func trackSpeechInferenceIfNeeded(
        transcription: SpeechTranscriptionResult?,
        audioToToolArchitecture: AudioToToolArchitecture,
        appleSpeechModelHandle: ModelHandle,
        whisperTinySpeechModelHandle: ModelHandle,
        whisperBaseSpeechModelHandle: ModelHandle,
        leapSpeechModelHandle: ModelHandle,
        recordingDurationSeconds: Double? = nil,
        attachments: [InferenceAttachment],
        additionalInputMeta: [String: Any] = [:],
        additionalOutputMeta: [String: Any] = [:],
        runId: String? = nil,
        traceId: String? = nil,
        parentSpanId: String? = nil
    ) -> String? {
        guard let transcription else { return nil }
        let speechModelHandle: ModelHandle
        switch transcription.provider {
        case "whisperkit":
            speechModelHandle = transcription.whisperModelSize == .base
                ? whisperBaseSpeechModelHandle
                : whisperTinySpeechModelHandle
        case "leap_sdk":
            speechModelHandle = leapSpeechModelHandle
        default:
            speechModelHandle = appleSpeechModelHandle
        }

        var inputMeta: [String: Any] = [
            "source": "VoiceRecorderSample",
            "provider": transcription.provider,
            "model_id": transcription.modelId,
            "audio_to_tool_architecture": audioToToolArchitecture.rawValue,
            "requires_on_device_recognition": transcription.requiresOnDeviceRecognition,
            "whisper_model_size": transcription.whisperModelSize?.rawValue ?? ""
        ]
        if let recordingDurationSeconds {
            let roundedDuration = roundedDurationSeconds(recordingDurationSeconds) ?? recordingDurationSeconds
            inputMeta["recording_duration_seconds"] = roundedDuration
            inputMeta["input_audio_duration_seconds"] = roundedDuration
        }
        for (key, value) in additionalInputMeta {
            inputMeta[key] = value
        }

        let transcriptText = transcription.transcript ?? ""
        var outputMeta: [String: Any] = [
            "transcript": transcriptText,
            "output_text": transcriptText,
            "error": transcription.errorDescription ?? "",
            "duration_ms": transcription.durationMs,
            "audio_to_tool_architecture": audioToToolArchitecture.rawValue
        ]
        let outputTokenCount = estimatedTokenCount(transcriptText)
        outputMeta["tokens_out"] = outputTokenCount
        outputMeta["token_count"] = outputTokenCount
        for (key, value) in additionalOutputMeta {
            outputMeta[key] = value
        }

        return speechModelHandle.trackInference(
            durationMs: transcription.durationMs,
            inputModality: .audio,
            outputModality: .generation,
            success: transcription.errorDescription == nil,
            errorCode: transcription.errorDescription == nil
                ? nil
                : "\(transcription.provider)_transcription_failed",
            inputMeta: inputMeta,
            outputMeta: outputMeta,
            attachments: attachments,
            traceId: traceId,
            parentSpanId: parentSpanId,
            runId: runId
        )
    }

    private nonisolated static func makeInputAttachments(
        audioAttachment: InferenceAttachment,
        audioURL: URL,
        includeSpectrogramAttachment: Bool,
        includeWAVAttachment: Bool
    ) -> RecordingInputAttachments {
        var attachments = includeWAVAttachment ? [audioAttachment] : []

        guard includeSpectrogramAttachment else {
            return RecordingInputAttachments(attachments: attachments, spectrogramURL: nil)
        }

        do {
            let spectrogramURL = try AudioSpectrogramRenderer().renderPNG(from: audioURL)
            attachments.append(
                InferenceAttachment(
                    name: spectrogramURL.lastPathComponent,
                    role: .input,
                    payload: .file(spectrogramURL, mimeType: "image/png")
                )
            )
            return RecordingInputAttachments(
                attachments: attachments,
                spectrogramURL: spectrogramURL
            )
        } catch {
            print("Audio spectrogram rendering failed: \(error.localizedDescription)")
            return RecordingInputAttachments(attachments: attachments, spectrogramURL: nil)
        }
    }

    func toggleProcessedPlayback() {
        guard let processedAudioURL else { return }

        if let audioPlayer, audioPlayer.isPlaying {
            stopPlayback()
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: processedAudioURL)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            isPlayingProcessedAudio = true
        } catch {
            processingMessage = "Could not play processed audio: \(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingProcessedAudio = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlayingProcessedAudio = false
        audioPlayer = nil
    }
}

struct LocalOnnxProcessingResult {
    let outputURL: URL
    let responseSummary: String
    let responseBytes: Int
    let outputNames: [String]
}

final class LocalOnnxVoiceProcessingClient {
    private let session: ORTSession
    private let targetSampleRate: Float = 16_000

    init(modelURL: URL) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let sessionOptions = try ORTSessionOptions()
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: sessionOptions)
    }

    func process(inputAudioURL: URL) throws -> LocalOnnxProcessingResult {
        let monoSamples = try loadMonoSamples(from: inputAudioURL)
        let prepared = buildModelInputs(from: monoSamples)

        let inputs: [String: ORTValue] = [
            "phone": try ORTValue(
                tensorData: NSMutableData(data: Self.data(from: prepared.phone)),
                elementType: .float,
                shape: [1, NSNumber(value: prepared.seqLen), 768]
            ),
            "phone_lengths": try ORTValue(
                tensorData: NSMutableData(data: Self.data(from: prepared.phoneLengths)),
                elementType: .int64,
                shape: [1]
            ),
            "pitch": try ORTValue(
                tensorData: NSMutableData(data: Self.data(from: prepared.pitch)),
                elementType: .int64,
                shape: [1, NSNumber(value: prepared.seqLen)]
            ),
            "pitchf": try ORTValue(
                tensorData: NSMutableData(data: Self.data(from: prepared.pitchf)),
                elementType: .float,
                shape: [1, NSNumber(value: prepared.seqLen)]
            ),
            "ds": try ORTValue(
                tensorData: NSMutableData(data: Self.data(from: prepared.ds)),
                elementType: .int64,
                shape: [1]
            ),
            "rnd": try ORTValue(
                tensorData: NSMutableData(data: Self.data(from: prepared.rnd)),
                elementType: .float,
                shape: [1, 192, NSNumber(value: prepared.seqLen)]
            )
        ]

        let outputs = try session.run(withInputs: inputs, outputNames: ["audio"], runOptions: nil)
        guard let audioValue = outputs["audio"] else {
            throw NSError(domain: "LocalOnnxVoiceProcessingClient", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Model output 'audio' is missing."])
        }

        let outputSamples = try decodeOutputAudio(from: audioValue)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpain-local-\(UUID().uuidString).wav")
        try writeWav(samples: outputSamples, to: outputURL, sampleRate: targetSampleRate)

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let responseBytes = Int(attrs?[.size] as? Int64 ?? 0)

        return LocalOnnxProcessingResult(
            outputURL: outputURL,
            responseSummary: "Local ONNX inference executed successfully.",
            responseBytes: responseBytes,
            outputNames: outputs.keys.sorted()
        )
    }

    private func loadMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "LocalOnnxVoiceProcessingClient", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer."])
        }
        try file.read(into: buffer)

        let channelCount = Int(format.channelCount)
        let sampleRate = Float(format.sampleRate)
        let frames = Int(buffer.frameLength)

        guard let channels = buffer.floatChannelData, frames > 0, channelCount > 0 else {
            throw NSError(domain: "LocalOnnxVoiceProcessingClient", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio input format."])
        }

        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channelCount {
                sum += channels[c][i]
            }
            mono[i] = sum / Float(channelCount)
        }

        if abs(sampleRate - targetSampleRate) < 1 {
            return mono
        }

        let ratio = sampleRate / targetSampleRate
        let outCount = max(1, Int(Float(mono.count) / ratio))
        var resampled = [Float](repeating: 0, count: outCount)

        for i in 0..<outCount {
            let src = Float(i) * ratio
            let lo = Int(src)
            let hi = min(lo + 1, mono.count - 1)
            let t = src - Float(lo)
            resampled[i] = mono[lo] * (1 - t) + mono[hi] * t
        }

        return resampled
    }

    private func buildModelInputs(from samples: [Float]) -> (
        phone: [Float],
        phoneLengths: [Int64],
        pitch: [Int64],
        pitchf: [Float],
        ds: [Int64],
        rnd: [Float],
        seqLen: Int
    ) {
        let frameSize = 160
        let availableFrames = max(1, samples.count / frameSize)
        let seqLen = min(400, max(64, availableFrames))
        let neededSamples = seqLen * frameSize

        var padded = samples
        if padded.count < neededSamples {
            padded += [Float](repeating: 0, count: neededSamples - padded.count)
        } else if padded.count > neededSamples {
            padded = Array(padded.prefix(neededSamples))
        }

        var phone = [Float](repeating: 0, count: seqLen * 768)
        var pitch = [Int64](repeating: 1, count: seqLen)
        var pitchf = [Float](repeating: 0, count: seqLen)
        var rnd = [Float](repeating: 0, count: 192 * seqLen)
        var seed: UInt64 = 0x9E3779B97F4A7C15

        for t in 0..<seqLen {
            let start = t * frameSize
            let frame = Array(padded[start..<(start + frameSize)])
            let energy = sqrt(frame.reduce(0) { $0 + $1 * $1 } / Float(frameSize))

            var zc: Float = 0
            for i in 1..<frame.count where (frame[i - 1] >= 0) != (frame[i] >= 0) {
                zc += 1
            }
            zc /= Float(frameSize)

            let (f0, confidence) = estimatePitch(frame: frame, sampleRate: targetSampleRate)
            pitchf[t] = confidence > 0.05 ? f0 : 0
            pitch[t] = coarsePitchBin(from: pitchf[t])

            var base = [Float](repeating: 0, count: 48)
            base[0] = energy
            base[1] = zc
            base[2] = min(1.0, pitchf[t] / 600.0)
            for i in 3..<48 {
                let idx = min(frame.count - 1, (i - 3) * frame.count / 45)
                base[i] = frame[idx]
            }

            for j in 0..<768 {
                let b = base[j % base.count]
                let phase = Float(j) * 0.013 + Float(t) * 0.07
                phone[t * 768 + j] = b * 0.8 + sin(phase) * 0.2
            }

            for c in 0..<192 {
                seed = seed &* 6364136223846793005 &+ 1
                let v = Float((seed >> 33) & 0xffff) / Float(0xffff)
                rnd[c * seqLen + t] = (v * 2 - 1) * max(0.01, energy)
            }
        }

        return (
            phone: phone,
            phoneLengths: [Int64(seqLen)],
            pitch: pitch,
            pitchf: pitchf,
            ds: [0],
            rnd: rnd,
            seqLen: seqLen
        )
    }

    private func estimatePitch(frame: [Float], sampleRate: Float) -> (hz: Float, confidence: Float) {
        let minLag = Int(sampleRate / 500)
        let maxLag = Int(sampleRate / 50)

        guard frame.count > maxLag + 1 else { return (0, 0) }

        var bestLag = minLag
        var bestCorr: Float = 0

        for lag in minLag...maxLag {
            var corr: Float = 0
            var normA: Float = 0
            var normB: Float = 0

            for i in 0..<(frame.count - lag) {
                let a = frame[i]
                let b = frame[i + lag]
                corr += a * b
                normA += a * a
                normB += b * b
            }

            let denom = sqrt(normA * normB)
            if denom > 1e-6 {
                corr /= denom
                if corr > bestCorr {
                    bestCorr = corr
                    bestLag = lag
                }
            }
        }

        let hz = sampleRate / Float(bestLag)
        return (hz, bestCorr)
    }

    private func coarsePitchBin(from hz: Float) -> Int64 {
        guard hz > 0 else { return 1 }
        let melMin = 1127.0 * log(1 + 50.0 / 700.0)
        let melMax = 1127.0 * log(1 + 1100.0 / 700.0)
        let mel = 1127.0 * log(1 + Double(hz) / 700.0)
        let norm = max(0.0, min(1.0, (mel - melMin) / (melMax - melMin)))
        return Int64(max(1, min(255, Int(norm * 254.0 + 1.0))))
    }

    private func decodeOutputAudio(from output: ORTValue) throws -> [Float] {
        let typeInfo = try output.tensorTypeAndShapeInfo()
        let shape = typeInfo.shape.map { $0.intValue }
        let raw = try output.tensorData()
        let rawData = Data(referencing: raw)

        let samples = rawData.withUnsafeBytes { buffer -> [Float] in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return [] }
            let count = buffer.count / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }

        if samples.isEmpty {
            throw NSError(domain: "LocalOnnxVoiceProcessingClient", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Model output audio tensor is empty."])
        }

        // Flatten common shapes like [1, 1, N] or [1, N] to mono samples.
        let flattenedCount = shape.reduce(1, *)
        let mono = Array(samples.prefix(flattenedCount))

        var maxAbs: Float = 1e-6
        for v in mono {
            maxAbs = max(maxAbs, abs(v))
        }
        let gain: Float = maxAbs > 1 ? (1 / maxAbs) : 1
        return mono.map { $0 * gain }
    }

    private func writeWav(samples: [Float], to url: URL, sampleRate: Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "LocalOnnxVoiceProcessingClient", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Could not allocate output audio buffer."])
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "LocalOnnxVoiceProcessingClient", code: 1006, userInfo: [NSLocalizedDescriptionKey: "Could not access output audio channel."])
        }

        for i in 0..<samples.count {
            channel[i] = samples[i]
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func data<T>(from values: [T]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
