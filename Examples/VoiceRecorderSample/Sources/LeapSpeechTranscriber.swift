import Foundation
import LeapSDK

actor LeapSpeechTranscriber {
    static let modelName = "LFM2.5-Audio-1.5B"
    static let quantization = "Q4_0"
    static let approximateDownloadSize = "about 1.1 GB"
    static let statusMessage = "Model downloads automatically when Leap is used."
    private static let instanceStore = LeapSpeechTranscriberStore()

    private var runner: ModelRunner?

    static func shared() async -> LeapSpeechTranscriber {
        await instanceStore.shared()
    }

    fileprivate init() {
    }

    func prepareModel(
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws {
        if runner != nil { return }
        print("LeapSDK load started: \(Self.modelName) \(Self.quantization)")
        runner = try await Leap.shared.load(
            model: Self.modelName,
            quantization: Self.quantization,
            options: nil,
            progress: { progress, speed in
                let normalizedProgress = Self.normalizedProgress(progress)
                print("LeapSDK load progress: \(normalizedProgress) at \(speed) bytes/s")
                progressHandler?(normalizedProgress, speed)
            }
        )
        print("LeapSDK load completed")
    }

    func downloadModel(
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws {
        try await prepareModel(progressHandler: progressHandler)
    }

    func transcribe(
        url: URL,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> String {
        try await prepareModel(progressHandler: progressHandler)

        guard let runner else {
            throw SpeechTranscriptionError.transcriptionFailed("Leap model runner is unavailable.")
        }

        let audioData = try Data(contentsOf: url)
        guard !audioData.isEmpty else {
            throw SpeechTranscriptionError.transcriptionFailed("Leap audio input is empty.")
        }
        let audioFormat = Self.audioFormat(for: url)
        let conversation = runner.createConversation(
            systemPrompt: "Perform ASR."
        )
        let message = ChatMessage(
            role: .user,
            content: [
                ChatMessageContent.text("Transcribe this audio. Return only the transcript. Prefer digits for spoken numbers, for example 20 instead of twenty."),
                ChatMessageContent.audio(data: audioData, format: audioFormat)
            ],
            reasoningContent: nil,
            functionCalls: nil
        )
        let options = GenerationOptions()
            .with(maxTokens: 256)
            .with(enableThinking: false)

        var transcript = ""
        var reasoningFallback = ""
        for try await response in conversation.generateResponse(message: message, generationOptions: options) {
            switch onEnum(of: response) {
            case .chunk(let chunk):
                transcript += chunk.text
                print("Leap ASR chunk: \(chunk.text)")
            case .complete(let completion):
                let finalText = completion.fullMessage.content.compactMap { part -> String? in
                    if case let .text(text) = onEnum(of: part) {
                        return text.text
                    }
                    return nil
                }.joined()
                if let stats = completion.stats {
                    print("Leap ASR complete: tokens=\(stats.totalTokens), tps=\(stats.tokenPerSecond)")
                } else {
                    print("Leap ASR complete: no generation stats")
                }
                if transcript.isEmpty {
                    transcript = finalText
                }
            case .reasoningChunk(let text):
                reasoningFallback += text.reasoning
                print("Leap ASR reasoning chunk: \(text.reasoning)")
            case .audioSample:
                break
            case .functionCalls(let calls):
                let names = calls.functionCalls.map { $0.name }.joined(separator: ", ")
                print("Leap ASR returned unexpected function calls: \(names)")
                break
            }
        }

        let trimmedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTranscript = reasoningFallback
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTranscript.isEmpty == false {
            return trimmedTranscript
        }
        if fallbackTranscript.isEmpty == false {
            return fallbackTranscript
        }
        throw SpeechTranscriptionError.transcriptionFailed("Leap returned an empty transcript.")
    }

    private static func audioFormat(for url: URL) -> String {
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch fileExtension {
        case "m4a", "mp3", "wav":
            return fileExtension
        default:
            return "wav"
        }
    }

    private static func normalizedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let normalized = progress > 1 ? progress / 100 : progress
        return min(max(normalized, 0), 1)
    }
}

private actor LeapSpeechTranscriberStore {
    private var instance: LeapSpeechTranscriber?

    func shared() async -> LeapSpeechTranscriber {
        if let instance {
            return instance
        }

        let created = await Task.detached(priority: .utility) {
            LeapSpeechTranscriber()
        }.value
        instance = created
        return created
    }
}
