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
    @Published var benchmarkLatencyText = ""
    @Published var benchmarkTranscriptMatchText = ""
    @Published var benchmarkToolCallMatchText = ""
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
    private let leapTextToolModelHandle: ModelHandle
    private let leapSpeechToolModelHandle: ModelHandle
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
        leapTextToolModelHandle = WildEdge.shared.registerModel(
            modelId: "leap-lfm2.5-audio-1.5b-text-to-tool",
            info: ModelInfo(
                modelName: "Leap LFM2.5 Audio 1.5B Text To Tool",
                modelSource: "leap-sdk",
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
            benchmarkLatencyText = ""
            benchmarkTranscriptMatchText = ""
            benchmarkToolCallMatchText = ""
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
        benchmarkLatencyText = ""
        benchmarkTranscriptMatchText = ""
        benchmarkToolCallMatchText = ""

        benchmarkTask = Task.detached(priority: .utility) { [
            weak self,
            appleSpeechModelHandle = self.appleSpeechModelHandle,
            whisperTinySpeechModelHandle = self.whisperTinySpeechModelHandle,
            whisperBaseSpeechModelHandle = self.whisperBaseSpeechModelHandle,
            leapSpeechModelHandle = self.leapSpeechModelHandle,
            leapTextToolModelHandle = self.leapTextToolModelHandle,
            leapSpeechToolModelHandle = self.leapSpeechToolModelHandle
        ] in
            await Self.runBenchmarkLoop(
                viewModel: self,
                runId: runId,
                appleSpeechModelHandle: appleSpeechModelHandle,
                whisperTinySpeechModelHandle: whisperTinySpeechModelHandle,
                whisperBaseSpeechModelHandle: whisperBaseSpeechModelHandle,
                leapSpeechModelHandle: leapSpeechModelHandle,
                leapTextToolModelHandle: leapTextToolModelHandle,
                leapSpeechToolModelHandle: leapSpeechToolModelHandle
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
                attachments: inputAttachmentBundle.attachments
            )
            if speechInferenceId != nil {
                WildEdge.shared.flush(timeoutMs: 5_000)
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
                    durationMs: Int(finalDuration * 1000),
                    inputModality: .audio,
                    outputModality: .generation,
                    success: true,
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
                    durationMs: Int(finalDuration * 1000),
                    inputModality: .audio,
                    outputModality: .generation,
                    success: false,
                    errorCode: String(describing: type(of: error)),
                    inputMeta: [
                        "source": "VoiceRecorderSample",
                        "model_id": "TPain.onnx",
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

    #if BENCHMARK_BUILD
    private enum BenchmarkJSONValue: Equatable {
        case object([String: BenchmarkJSONValue])
        case array([BenchmarkJSONValue])
        case string(String)
        case number(String)
        case bool(Bool)
        case null

        init(any value: Any) throws {
            switch value {
            case let object as [String: Any]:
                var parsed: [String: BenchmarkJSONValue] = [:]
                for (key, value) in object {
                    parsed[key] = try BenchmarkJSONValue(any: value)
                }
                self = .object(parsed)
            case let array as [Any]:
                self = .array(try array.map(BenchmarkJSONValue.init(any:)))
            case let string as String:
                self = .string(string)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool(number.boolValue)
                } else {
                    self = .number(Self.normalizedNumber(number))
                }
            case _ as NSNull:
                self = .null
            default:
                throw NSError(
                    domain: "BenchmarkJSONValue",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value \(type(of: value))."]
                )
            }
        }

        var canonicalString: String {
            switch self {
            case .object(let object):
                let fields = object.keys.sorted().map { key in
                    "\(Self.quoted(key)):\(object[key]?.canonicalString ?? "null")"
                }
                return "{\(fields.joined(separator: ","))}"
            case .array(let array):
                return "[\(array.map(\.canonicalString).joined(separator: ","))]"
            case .string(let string):
                return Self.quoted(string)
            case .number(let number):
                return number
            case .bool(let bool):
                return bool ? "true" : "false"
            case .null:
                return "null"
            }
        }

        var foundationObject: Any {
            switch self {
            case .object(let object):
                var result: [String: Any] = [:]
                for (key, value) in object {
                    result[key] = value.foundationObject
                }
                return result
            case .array(let array):
                return array.map(\.foundationObject)
            case .string(let string):
                return string
            case .number(let number):
                if let int = Int(number) {
                    return int
                }
                return Double(number) ?? number
            case .bool(let bool):
                return bool
            case .null:
                return NSNull()
            }
        }

        private static func normalizedNumber(_ number: NSNumber) -> String {
            let double = number.doubleValue
            guard double.isFinite else { return "\(double)" }
            if double.rounded() == double,
               double >= Double(Int64.min),
               double <= Double(Int64.max) {
                return String(Int64(double))
            }
            return String(format: "%.15g", double)
        }

        private static func quoted(_ string: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [string]),
                  let encoded = String(data: data, encoding: .utf8),
                  encoded.count >= 2
            else {
                return "\"\(string)\""
            }
            return String(encoded.dropFirst().dropLast())
        }
    }

    private struct BenchmarkToolCallResult {
        let step: BenchmarkStep
        let rawOutput: String
        let durationMs: Int
        let parsedJSON: BenchmarkJSONValue?
        let canonicalJSON: String?
        let errorDescription: String?

        var parsedSuccessfully: Bool {
            parsedJSON != nil
        }
    }

    private struct BenchmarkDatasetItem {
        let audioURL: URL
        let processingAudioURL: URL
        let expectedTranscriptURL: URL?
        let expectedToolCallURL: URL?
        let expectedTranscript: String?
        let expectedToolCall: String?
        let expectedToolCallJSON: BenchmarkJSONValue?
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
        leapTextToolModelHandle: ModelHandle,
        leapSpeechToolModelHandle: ModelHandle
    ) async {
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
                viewModel?.benchmarkLatencyText = ""
                viewModel?.benchmarkTranscriptMatchText = ""
                viewModel?.benchmarkToolCallMatchText = ""
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
            viewModel?.benchmarkLatencyText = ""
            viewModel?.benchmarkTranscriptMatchText = ""
            viewModel?.benchmarkToolCallMatchText = ""
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
                viewModel?.benchmarkLatencyText = ""
                viewModel?.benchmarkTranscriptMatchText = ""
                viewModel?.benchmarkToolCallMatchText = ""
            }
            return
        }

        var iteration = 1
        var preparedWhisperModels = Set<WhisperModelSize>()
        while !Task.isCancelled {
            guard await isBenchmarkRequested(viewModel) else { break }
            guard let passSettings = await benchmarkSettings(from: viewModel) else { break }
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
                    viewModel?.benchmarkStepsText = benchmarkStepsDescription(passSettings.benchmarkSteps)
                    viewModel?.benchmarkExpectedToolCall = ""
                    viewModel?.benchmarkActualToolCall = ""
                    viewModel?.benchmarkLatencyText = ""
                    viewModel?.benchmarkTranscriptMatchText = ""
                    viewModel?.benchmarkToolCallMatchText = ""
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
                    viewModel?.benchmarkStepsText = benchmarkStepsDescription(passSettings.benchmarkSteps)
                    viewModel?.benchmarkExpectedToolCall = ""
                    viewModel?.benchmarkActualToolCall = ""
                    viewModel?.benchmarkLatencyText = ""
                    viewModel?.benchmarkTranscriptMatchText = ""
                    viewModel?.benchmarkToolCallMatchText = ""
                }
                guard await sleepBenchmarkDelay(seconds: passSettings.benchmarkDelaySeconds, viewModel: viewModel) else {
                    break
                }
                continue
            }

            for (offset, item) in items.enumerated() {
                guard !Task.isCancelled else { break }
                guard await isBenchmarkRequested(viewModel) else { break }
                guard let settings = await benchmarkSettings(from: viewModel) else { break }

                let needsSpeechToText = settings.benchmarkSteps.contains(.speechToText)
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

                guard needsSpeechToText == false || settings.voiceToTextMode != .disabled else {
                    await MainActor.run {
                        viewModel?.benchmarkStatus = "Benchmark requires voice to text."
                        viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                        viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
                        viewModel?.benchmarkRunProgress = ""
                        viewModel?.benchmarkSleepCountdown = ""
                        viewModel?.benchmarkTranscript = ""
                        viewModel?.benchmarkExpectedTranscript = item.expectedTranscript ?? ""
                        viewModel?.benchmarkStepsText = benchmarkStepsDescription(settings.benchmarkSteps)
                        viewModel?.benchmarkExpectedToolCall = ""
                        viewModel?.benchmarkActualToolCall = ""
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
                        viewModel?.benchmarkStatus = "Measuring \(benchmarkStepsDescription(settings.benchmarkSteps))..."
                        viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                        viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
                        viewModel?.benchmarkRunProgress = "Run \(inferenceIndex)/\(inferenceCount)"
                        viewModel?.benchmarkSleepCountdown = ""
                        viewModel?.benchmarkTranscript = ""
                        viewModel?.benchmarkExpectedTranscript = needsSpeechToText ? item.expectedTranscript ?? "" : ""
                        viewModel?.benchmarkStepsText = benchmarkStepsDescription(settings.benchmarkSteps)
                        viewModel?.benchmarkExpectedToolCall = hasToolStep ? expectedToolCallDisplay(for: item) : ""
                        viewModel?.benchmarkActualToolCall = ""
                        viewModel?.benchmarkLatencyText = ""
                        viewModel?.benchmarkTranscriptMatchText = ""
                        viewModel?.benchmarkToolCallMatchText = ""
                    }

                    let totalStart = Date()
                    let transcription: SpeechTranscriptionResult?
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
                    } else {
                        transcription = nil
                    }

                    let comparison = benchmarkComparisonMeta(
                        actualTranscript: transcription?.transcript,
                        expectedTranscript: needsSpeechToText ? item.expectedTranscript : nil
                    )
                    let toolResult: BenchmarkToolCallResult?
                    if needsTextToTool {
                        toolResult = await generateTextToolCall(
                            transcript: transcription?.transcript,
                            viewModel: viewModel
                        )
                    } else if needsSpeechToTool {
                        toolResult = await generateSpeechToolCall(
                            url: item.processingAudioURL,
                            viewModel: viewModel
                        )
                    } else {
                        toolResult = nil
                    }
                    let toolComparison = benchmarkToolCallComparisonMeta(
                        actualToolCall: toolResult,
                        expectedItem: item
                    )
                    let totalDurationMs = Int(Date().timeIntervalSince(totalStart) * 1000)
                    let inputMeta = benchmarkInputMeta(
                        item: item,
                        settings: settings,
                        iteration: iteration,
                        itemIndex: offset + 1,
                        itemCount: items.count,
                        inferenceIndex: inferenceIndex,
                        inferenceCount: inferenceCount
                    )

                    var speechInferenceId: String?
                    var toolInferenceId: String?
                    let inferenceId = WildEdge.shared.trace(
                        item.audioURL.lastPathComponent,
                        kind: .eval,
                        attributes: benchmarkSpanAttributes(
                            item: item,
                            transcription: transcription,
                            toolCall: toolResult,
                            settings: settings,
                            inferenceIndex: inferenceIndex,
                            inferenceCount: inferenceCount,
                            totalDurationMs: totalDurationMs
                        )
                    ) { _ in
                        if needsSpeechToText {
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
                                runId: runId
                            )
                        }
                        if let toolResult {
                            let toolHandle = toolResult.step == .textToTool
                                ? leapTextToolModelHandle
                                : leapSpeechToolModelHandle
                            toolInferenceId = trackToolCallInference(
                                toolCall: toolResult,
                                modelHandle: toolHandle,
                                inputModality: toolResult.step == .textToTool ? .text : .audio,
                                additionalInputMeta: inputMeta,
                                additionalOutputMeta: toolComparison,
                                runId: runId
                            )
                        }
                        return toolInferenceId ?? speechInferenceId
                    }
                    if inferenceId != nil {
                        WildEdge.shared.flush(timeoutMs: 5_000)
                    }

                    await MainActor.run {
                        let transcriptMatched = comparison["normalized_exact_match"] as? Bool
                        let toolMatched = toolComparison["tool_call_exact_match"] as? Bool
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
                        viewModel?.benchmarkStepsText = benchmarkStepsDescription(settings.benchmarkSteps)
                        viewModel?.benchmarkExpectedToolCall = hasToolStep ? expectedToolCallDisplay(for: item) : ""
                        viewModel?.benchmarkActualToolCall = hasToolStep ? actualToolCallDisplay(for: toolResult) : ""
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
                    }

                    guard await sleepBenchmarkDelay(seconds: settings.benchmarkDelaySeconds, viewModel: viewModel) else {
                        break
                    }
                }
            }
            iteration += 1
        }

        await MainActor.run {
            viewModel?.isBenchmarking = false
            Self.setBenchmarkIdleTimerDisabled(false)
            viewModel?.benchmarkStatus = "Benchmark disabled."
            viewModel?.benchmarkTask = nil
            viewModel?.benchmarkCurrentInput = ""
            viewModel?.benchmarkPreprocessingFile = ""
            viewModel?.benchmarkRunProgress = ""
            viewModel?.benchmarkSleepCountdown = ""
            viewModel?.benchmarkTranscript = ""
            viewModel?.benchmarkExpectedTranscript = ""
            viewModel?.benchmarkStepsText = ""
            viewModel?.benchmarkExpectedToolCall = ""
            viewModel?.benchmarkActualToolCall = ""
            viewModel?.benchmarkLatencyText = ""
            viewModel?.benchmarkTranscriptMatchText = ""
            viewModel?.benchmarkToolCallMatchText = ""
        }
    }

    private static func setBenchmarkIdleTimerDisabled(_ disabled: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
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
                    viewModel?.benchmarkStatus = "Preparing Whisper \(progress.model.displayName) \(Int(progress.modelProgress * 100))%"
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
                let parsedExpectedToolCall = parseBenchmarkJSON(from: expectedToolCall ?? "")
                return BenchmarkDatasetItem(
                    audioURL: audioURL,
                    processingAudioURL: audioURL,
                    expectedTranscriptURL: transcriptURL,
                    expectedToolCallURL: toolCallURL,
                    expectedTranscript: readExpectedTranscript(from: transcriptURL),
                    expectedToolCall: expectedToolCall,
                    expectedToolCallJSON: parsedExpectedToolCall.value,
                    expectedToolCallCanonicalJSON: parsedExpectedToolCall.value?.canonicalString,
                    expectedToolCallParseError: expectedToolCall == nil ? nil : parsedExpectedToolCall.error
                )
            }
    }

    private nonisolated static func prepareBenchmarkDataset(
        _ items: [BenchmarkDatasetItem],
        viewModel: RecorderViewModel?
    ) async -> [BenchmarkDatasetItem] {
        var prepared: [BenchmarkDatasetItem] = []

        for item in items {
            guard await isBenchmarkRequested(viewModel) else { break }
            guard item.audioURL.pathExtension.lowercased() == "m4a" else {
                prepared.append(item)
                continue
            }

            await MainActor.run {
                viewModel?.benchmarkStatus = "Preparing \(item.audioURL.lastPathComponent)..."
                viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                viewModel?.benchmarkPreprocessingFile = "Converting to WAV..."
            }

            if let bundledWAVURL = Bundle.main.url(
                forResource: item.baseName,
                withExtension: "wav",
                subdirectory: "benchmark_data"
            ) {
                await MainActor.run {
                    viewModel?.benchmarkStatus = "Prepared \(item.audioURL.lastPathComponent)."
                    viewModel?.benchmarkPreprocessingFile = bundledWAVURL.lastPathComponent
                }
                prepared.append(item.preparedForProcessing(at: bundledWAVURL))
                continue
            }

            do {
                let convertedURL = try convertBenchmarkAudioToWAV(item.audioURL)
                await MainActor.run {
                    viewModel?.benchmarkPreprocessingFile = convertedURL.lastPathComponent
                }
                prepared.append(item.preparedForProcessing(at: convertedURL))
            } catch {
                let message = "M4A conversion failed for \(item.audioURL.lastPathComponent). Using original file. \(error.localizedDescription)"
                print("Benchmark \(message)")
                await MainActor.run {
                    viewModel?.benchmarkStatus = message
                    viewModel?.benchmarkCurrentInput = item.audioURL.lastPathComponent
                    viewModel?.benchmarkPreprocessingFile = item.processingAudioURL.lastPathComponent
                }
                prepared.append(item)
            }
        }

        return prepared
    }

    private nonisolated static func convertBenchmarkAudioToWAV(_ sourceURL: URL) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).wav")
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

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings
        )

        guard reader.startReading() else {
            throw reader.error ?? SpeechTranscriptionError.transcriptionFailed("Benchmark audio reader failed to start.")
        }

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try write(sampleBuffer: sampleBuffer, outputFile: outputFile)
        }

        if reader.status == .failed {
            throw reader.error ?? SpeechTranscriptionError.transcriptionFailed("Benchmark WAV conversion failed.")
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

    private nonisolated static func sleepBenchmarkDelay(seconds: TimeInterval, viewModel: RecorderViewModel?) async -> Bool {
        let seconds = max(0, seconds)
        guard seconds > 0 else {
            return await isBenchmarkRequested(viewModel)
        }

        let end = Date().addingTimeInterval(seconds)
        await MainActor.run {
            viewModel?.benchmarkStatus = "Sleeping before next benchmark run..."
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
        viewModel: RecorderViewModel?
    ) async -> BenchmarkToolCallResult {
        let trimmedTranscript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedTranscript.isEmpty == false else {
            return BenchmarkToolCallResult(
                step: .textToTool,
                rawOutput: "",
                durationMs: 0,
                parsedJSON: nil,
                canonicalJSON: nil,
                errorDescription: "Text-to-tool requires a transcript."
            )
        }

        let start = Date()
        do {
            await MainActor.run {
                viewModel?.benchmarkStatus = "Generating tool call from transcript..."
            }
            let transcriber = await LeapSpeechTranscriber.shared()
            let rawToolCall = try await transcriber.toolCall(fromTranscript: trimmedTranscript)
            return benchmarkToolCallResult(
                step: .textToTool,
                rawOutput: rawToolCall,
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                generationError: nil
            )
        } catch {
            return benchmarkToolCallResult(
                step: .textToTool,
                rawOutput: "",
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                generationError: error.localizedDescription
            )
        }
    }

    private nonisolated static func generateSpeechToolCall(
        url: URL,
        viewModel: RecorderViewModel?
    ) async -> BenchmarkToolCallResult {
        let start = Date()
        do {
            await MainActor.run {
                viewModel?.benchmarkStatus = "Generating tool call from audio..."
            }
            let transcriber = await LeapSpeechTranscriber.shared()
            let rawToolCall = try await transcriber.toolCall(
                fromAudio: url,
                progressHandler: { progress, speed in
                    Task { @MainActor [weak viewModel] in
                        guard viewModel?.benchmarkRequested == true else { return }
                        viewModel?.benchmarkStatus = leapDownloadMessage(progress: progress, speed: speed)
                    }
                }
            )
            return benchmarkToolCallResult(
                step: .speechToTool,
                rawOutput: rawToolCall,
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                generationError: nil
            )
        } catch {
            return benchmarkToolCallResult(
                step: .speechToTool,
                rawOutput: "",
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                generationError: error.localizedDescription
            )
        }
    }

    private nonisolated static func benchmarkToolCallResult(
        step: BenchmarkStep,
        rawOutput: String,
        durationMs: Int,
        generationError: String?
    ) -> BenchmarkToolCallResult {
        guard generationError == nil else {
            return BenchmarkToolCallResult(
                step: step,
                rawOutput: rawOutput,
                durationMs: durationMs,
                parsedJSON: nil,
                canonicalJSON: nil,
                errorDescription: generationError
            )
        }

        let parsed = parseBenchmarkJSON(from: rawOutput)
        return BenchmarkToolCallResult(
            step: step,
            rawOutput: rawOutput,
            durationMs: durationMs,
            parsedJSON: parsed.value,
            canonicalJSON: parsed.value?.canonicalString,
            errorDescription: parsed.error
        )
    }

    private nonisolated static func parseBenchmarkJSON(
        from text: String
    ) -> (value: BenchmarkJSONValue?, error: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return (nil, "No JSON output.")
        }
        guard let jsonObjectText = extractFirstJSONObject(from: trimmed) else {
            return (nil, "No JSON object found.")
        }
        guard let data = jsonObjectText.data(using: .utf8) else {
            return (nil, "JSON output is not UTF-8.")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let value = try BenchmarkJSONValue(any: object)
            guard case .object = value else {
                return (nil, "Tool call must be a JSON object.")
            }
            return (value, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private nonisolated static func extractFirstJSONObject(from text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var isInString = false
        var isEscaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else if character == "\"" {
                isInString = true
            } else if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    let endIndex = text.index(after: index)
                    return String(text[startIndex..<endIndex])
                }
            }

            index = text.index(after: index)
        }

        return nil
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
            "actual_tool_call_json": actualCanonical,
            "actual_tool_call_parse_error": actualToolCall?.parsedSuccessfully == true ? "" : actualToolCall?.errorDescription ?? "",
            "tool_call_step": actualToolCall?.step.rawValue ?? "",
            "tool_call_duration_ms": actualToolCall?.durationMs ?? 0,
            "tool_call_exact_match": exactMatch
        ]
    }

    private nonisolated static func expectedToolCallDisplay(for item: BenchmarkDatasetItem) -> String {
        if let pretty = prettyJSONString(from: item.expectedToolCallJSON) {
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
        if let pretty = prettyJSONString(from: result.parsedJSON) {
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

    private nonisolated static func prettyJSONString(from value: BenchmarkJSONValue?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(
                withJSONObject: value.foundationObject,
                options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return value.canonicalString
        }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func benchmarkStepsDescription(_ steps: [BenchmarkStep]) -> String {
        guard steps.isEmpty == false else { return "unsupported steps" }
        return steps.map(\.rawValue).joined(separator: " + ")
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

    private nonisolated static func trackToolCallInference(
        toolCall: BenchmarkToolCallResult,
        modelHandle: ModelHandle,
        inputModality: InputModality,
        additionalInputMeta: [String: Any],
        additionalOutputMeta: [String: Any],
        runId: String
    ) -> String {
        var inputMeta: [String: Any] = [
            "source": "VoiceRecorderSample",
            "provider": "leap_sdk",
            "model_id": modelHandle.modelId,
            "benchmark_tool_step": toolCall.step.rawValue
        ]
        for (key, value) in additionalInputMeta {
            inputMeta[key] = value
        }

        var outputMeta: [String: Any] = [
            "raw_tool_call": toolCall.rawOutput,
            "tool_call_json": toolCall.canonicalJSON ?? "",
            "tool_call_parse_error": toolCall.parsedSuccessfully ? "" : toolCall.errorDescription ?? "",
            "duration_ms": toolCall.durationMs
        ]
        for (key, value) in additionalOutputMeta {
            outputMeta[key] = value
        }

        let success = toolCall.errorDescription == nil && toolCall.parsedSuccessfully
        return modelHandle.trackInference(
            durationMs: toolCall.durationMs,
            inputModality: inputModality,
            outputModality: .generation,
            success: success,
            errorCode: success ? nil : toolCall.parsedSuccessfully ? "leap_tool_call_failed" : "tool_call_parse_failed",
            inputMeta: inputMeta,
            outputMeta: outputMeta,
            attachments: [],
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
            "preprocessing_file": item.processingAudioURL.lastPathComponent,
            "processing_audio_extension": item.processingAudioURL.pathExtension.lowercased(),
            "converted_to_wav_before_inference": item.wasConvertedForProcessing,
            "benchmark_delay_seconds": settings.benchmarkDelaySeconds,
            "benchmark_number_of_inferences": settings.benchmarkNumberOfInferences,
            "benchmark_recordings_match": settings.benchmarkRecordingsMatch.joined(separator: ","),
            "benchmark_audio_extension": item.audioURL.pathExtension.lowercased()
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
        totalDurationMs: Int
    ) -> [String: Any] {
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
            "preprocessing_file": item.processingAudioURL.lastPathComponent,
            "processing_audio_extension": item.processingAudioURL.pathExtension.lowercased(),
            "converted_to_wav_before_inference": item.wasConvertedForProcessing,
            "voice_to_text_mode": settings.voiceToTextMode.rawValue,
            "speech_to_text_model": transcription?.modelId ?? "",
            "speech_to_text_duration_ms": transcription?.durationMs ?? 0,
            "tool_call_step": toolCall?.step.rawValue ?? "",
            "tool_call_duration_ms": toolCall?.durationMs ?? 0,
            "benchmark_total_duration_ms": totalDurationMs
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

    private nonisolated static func leapDownloadMessage(progress: Double, speed: Int64) -> String {
        "Downloading Leap LFM2.5 Audio \(Int(progress * 100))% - \(formattedByteRate(speed))"
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

    private nonisolated static func trackSpeechInferenceIfNeeded(
        transcription: SpeechTranscriptionResult?,
        audioToToolArchitecture: AudioToToolArchitecture,
        appleSpeechModelHandle: ModelHandle,
        whisperTinySpeechModelHandle: ModelHandle,
        whisperBaseSpeechModelHandle: ModelHandle,
        leapSpeechModelHandle: ModelHandle,
        attachments: [InferenceAttachment],
        additionalInputMeta: [String: Any] = [:],
        additionalOutputMeta: [String: Any] = [:],
        runId: String? = nil
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
        for (key, value) in additionalInputMeta {
            inputMeta[key] = value
        }

        var outputMeta: [String: Any] = [
            "transcript": transcription.transcript ?? "",
            "error": transcription.errorDescription ?? "",
            "duration_ms": transcription.durationMs,
            "audio_to_tool_architecture": audioToToolArchitecture.rawValue
        ]
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
