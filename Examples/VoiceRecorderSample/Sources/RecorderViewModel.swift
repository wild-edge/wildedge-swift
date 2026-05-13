import AVFoundation
import OnnxRuntimeBindings
import WildEdge

struct RecordingResult {
    let duration: TimeInterval
    let fileURL: URL
    let fileSizeBytes: Int64
    let inferenceId: String

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
    @Published var processedAudioURL: URL?

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingURL: URL?
    private let modelHandle: ModelHandle
    private let localOnnxProcessor: LocalOnnxVoiceProcessingClient?

    override init() {
        WildEdge.initialize { builder in
//            builder.dsn = "TODO"
            builder.enableAttachments = true
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

    func toggleRecording() async {
        if isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard await requestMicrophonePermission() else { return }

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

    private func stopRecording() {
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
        processingMessage = localOnnxProcessor == nil
            ? "TPain.onnx is missing in app bundle."
            : "Running local ONNX inference..."

        // File I/O, session teardown, and inference tracking on a background thread
        Task.detached { [weak self, modelHandle = self.modelHandle, localOnnxProcessor = self.localOnnxProcessor] in
            try? AVAudioSession.sharedInstance().setActive(false)
            guard let url else {
                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
                }
                return
            }

            guard let localOnnxProcessor else {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                let inferenceId = modelHandle.trackInference(
                    durationMs: Int(finalDuration * 1000),
                    inputModality: .audio,
                    outputModality: .generation,
                    success: false,
                    errorCode: "local_onnx_model_not_available",
                    inputMeta: [
                        "source": "VoiceRecorderSample",
                        "model_id": "TPain.onnx"
                    ]
                )

                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
                    self?.processingMessage = "TPain.onnx is missing in app bundle."
                    self?.lastRecording = RecordingResult(
                        duration: finalDuration,
                        fileURL: url,
                        fileSizeBytes: fileSize,
                        inferenceId: inferenceId
                    )
                }
                return
            }

            let attachment = InferenceAttachment(
                name: url.lastPathComponent,
                role: .input,
                payload: .file(url, mimeType: "audio/wav")
            )

            let processStart = Date()

            do {
                let result = try localOnnxProcessor.process(inputAudioURL: url)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
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
                        "output_names": result.outputNames.joined(separator: ",")
                    ],
                    attachments: [
                        attachment,
                        InferenceAttachment(
                            name: result.outputURL.lastPathComponent,
                            role: .output,
                            payload: .file(result.outputURL, mimeType: "audio/wav")
                        )
                    ]
                )

                let recording = RecordingResult(
                    duration: finalDuration,
                    fileURL: url,
                    fileSizeBytes: fileSize,
                    inferenceId: inferenceId
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
                        "model_id": "TPain.onnx"
                    ],
                    attachments: [attachment]
                )

                let recording = RecordingResult(
                    duration: finalDuration,
                    fileURL: url,
                    fileSizeBytes: fileSize,
                    inferenceId: inferenceId
                )

                await MainActor.run {
                    self?.isFinishing = false
                    self?.isProcessing = false
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
