import Foundation
import LeapSDK

struct AppMeasuredTextResponse {
    let text: String
    let durationMs: Int
}

actor LeapSpeechTranscriber {
    static let modelName = "LFM2.5-Audio-1.5B"
    static let quantization = "Q4_0"
    static let approximateDownloadSize = "about 1.1 GB"
    static let statusMessage = "Model downloads automatically when Leap is used."
    static let isLoadTemporarilyDisabled = false
    static let loadDisabledReason = "Leap model loading is disabled in this build."
    private static let instanceStore = LeapSpeechTranscriberStore()
    private static let loadFailureCooldownSeconds: TimeInterval = 60

    private var runner: ModelRunner?
    private var lastLoadFailure: (date: Date, message: String)?

    static func shared() async -> LeapSpeechTranscriber {
        await instanceStore.shared()
    }

    fileprivate init() {
    }

    func prepareModel(
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws {
        if runner != nil { return }
        if let lastLoadFailure {
            let elapsed = Date().timeIntervalSince(lastLoadFailure.date)
            if elapsed < Self.loadFailureCooldownSeconds {
                let remaining = Int(ceil(Self.loadFailureCooldownSeconds - elapsed))
                throw SpeechTranscriptionError.transcriptionFailed(
                    "Previous Leap model load failed: \(lastLoadFailure.message). Waiting \(remaining)s before retry."
                )
            }
        }

        print("LeapSDK load started: \(Self.modelName) \(Self.quantization)")
        do {
            let options = try Self.inferenceOptions()
            runner = try await Leap.shared.load(
                model: Self.modelName,
                quantization: Self.quantization,
                options: options,
                progress: { progress, speed in
                    progressHandler?(Self.normalizedProgress(progress), speed)
                }
            )
            lastLoadFailure = nil
            print("LeapSDK load completed")
        } catch {
            let message = Self.loadFailureDescription(error)
            lastLoadFailure = (Date(), message)
            print("LeapSDK load failed: \(message)")
            throw SpeechTranscriptionError.transcriptionFailed("Leap model load failed: \(message)")
        }
    }

    private static func inferenceOptions() throws -> LiquidInferenceEngineManifestOptions {
        let cacheDirectory = try leapKVCacheDirectory()
        return LiquidInferenceEngineManifestOptions(
            cacheOptions: LiquidCacheOptions.enabled(path: cacheDirectory.path)
        )
    }

    private static func leapKVCacheDirectory() throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cacheDirectory = baseDirectory.appendingPathComponent("leap-kv-cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        return cacheDirectory
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

    func toolCall(fromTranscript transcript: String) async throws -> String {
        try await appMeasuredToolCall(fromTranscript: transcript).text
    }

    func appMeasuredToolCall(fromTranscript transcript: String) async throws -> AppMeasuredTextResponse {
        try await prepareModel()

        guard let runner else {
            throw SpeechTranscriptionError.transcriptionFailed("Leap model runner is unavailable.")
        }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTranscript.isEmpty == false else {
            throw SpeechTranscriptionError.transcriptionFailed("Text-to-tool skipped because speech-to-text produced no transcript.")
        }

        let conversation = runner.createConversation(
            systemPrompt: ToolCallPromptBuilder.systemPrompt
        )
        let message = ChatMessage(
            role: .user,
            content: [
                ChatMessageContent.text(ToolCallPromptBuilder.textToToolUserPrompt(transcript: trimmedTranscript))
            ],
            reasoningContent: nil,
            functionCalls: nil
        )
        return try await generateTextResponse(
            conversation: conversation,
            message: message,
            maxTokens: 192,
            logPrefix: "Leap text-to-tool"
        )
    }

    func toolCall(
        fromAudio url: URL,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> String {
        try await appMeasuredToolCall(fromAudio: url, progressHandler: progressHandler).text
    }

    func appMeasuredToolCall(
        fromAudio url: URL,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil,
        userPrompt: String? = nil
    ) async throws -> AppMeasuredTextResponse {
        try await prepareModel(progressHandler: progressHandler)

        guard let runner else {
            throw SpeechTranscriptionError.transcriptionFailed("Leap model runner is unavailable.")
        }

        let audioData = try Data(contentsOf: url)
        guard !audioData.isEmpty else {
            throw SpeechTranscriptionError.transcriptionFailed("Leap audio input is empty.")
        }
        let audioFormat = Self.audioFormat(for: url)
        let prompt = userPrompt ?? ToolCallPromptBuilder.speechToToolUserPrompt()
        print(
            "Leap speech-to-tool prompt override=\(userPrompt == nil ? "false" : "true") length=\(prompt.count) preview=\(Self.promptPreview(prompt))"
        )
        let conversation = runner.createConversation(
            systemPrompt: ToolCallPromptBuilder.speechToToolSystemPrompt
        )
        let message = ChatMessage(
            role: .user,
            content: [
                ChatMessageContent.text(prompt),
                ChatMessageContent.audio(data: audioData, format: audioFormat)
            ],
            reasoningContent: nil,
            functionCalls: nil
        )
        return try await generateTextResponse(
            conversation: conversation,
            message: message,
            maxTokens: 256,
            logPrefix: "Leap speech-to-tool"
        )
    }

    private func generateTextResponse(
        conversation: Conversation,
        message: ChatMessage,
        maxTokens: Int,
        logPrefix: String
    ) async throws -> AppMeasuredTextResponse {
        let options = GenerationOptions()
            .with(maxTokens: Int32(maxTokens))
            .with(temperature: 0)
            .with(enableThinking: false)

        var generatedText = ""
        var reasoningFallback = ""
        var responseEvents: [String] = []
        let start = Date()
        for try await response in conversation.generateResponse(message: message, generationOptions: options) {
            switch onEnum(of: response) {
            case .chunk(let chunk):
                generatedText += chunk.text
                responseEvents.append("chunk(\(chunk.text.count))")
                print("\(logPrefix) chunk: \(chunk.text)")
            case .complete(let completion):
                let finalText = completion.fullMessage.content.compactMap { part -> String? in
                    if case let .text(text) = onEnum(of: part) {
                        return text.text
                    }
                    return nil
                }.joined()
                let finalFunctionCallJSON = completion.fullMessage.functionCalls?.first.flatMap(Self.toolCallJSON(from:))
                if let stats = completion.stats {
                    print("\(logPrefix) complete: tokens=\(stats.totalTokens), tps=\(stats.tokenPerSecond)")
                } else {
                    print("\(logPrefix) complete: no generation stats")
                }
                responseEvents.append("complete(text:\(finalText.count))")
                if generatedText.isEmpty {
                    generatedText = finalFunctionCallJSON ?? finalText
                }
            case .reasoningChunk(let text):
                reasoningFallback += text.reasoning
                responseEvents.append("reasoning(\(text.reasoning.count))")
                print("\(logPrefix) reasoning chunk: \(text.reasoning)")
            case .audioSample:
                responseEvents.append("audio_sample")
            case .functionCalls(let calls):
                let names = calls.functionCalls.map { $0.name }.joined(separator: ", ")
                print("\(logPrefix) returned unexpected function calls: \(names)")
                responseEvents.append("function_calls(\(names))")
                if generatedText.isEmpty,
                   let firstFunctionCallJSON = Self.toolCallJSON(from: calls.functionCalls.first) {
                    generatedText = firstFunctionCallJSON
                }
            }
        }

        let trimmed = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = reasoningFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        if trimmed.isEmpty == false {
            return AppMeasuredTextResponse(text: trimmed, durationMs: durationMs)
        }
        if fallback.isEmpty == false {
            return AppMeasuredTextResponse(text: fallback, durationMs: durationMs)
        }
        let events = responseEvents.isEmpty
            ? "no response events"
            : responseEvents.joined(separator: ", ")
        throw SpeechTranscriptionError.transcriptionFailed("Leap returned no text tool call. Response events: \(events).")
    }

    private nonisolated static func toolCallJSON(from functionCall: LeapFunctionCall?) -> String? {
        guard let functionCall else { return nil }
        let object: [String: Any] = [
            "tool_name": functionCall.name,
            "arguments": jsonSafeObject(functionCall.arguments)
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
              )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func jsonSafeObject(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonSafeObject)
        case let array as [Any]:
            return array.map(jsonSafeObject)
        case let string as String:
            if string == "true" { return true }
            if string == "false" { return false }
            if let int = Int(string) { return int }
            if let double = Double(string), double.isFinite { return double }
            return string
        case let number as NSNumber:
            return number
        case _ as NSNull:
            return NSNull()
        default:
            let description = String(describing: value)
            if description == "true" { return true }
            if description == "false" { return false }
            if let int = Int(description) { return int }
            if let double = Double(description), double.isFinite { return double }
            return description
        }
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

    private static func promptPreview(_ prompt: String) -> String {
        let singleLine = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = singleLine.prefix(120)
        return String(preview)
    }

    private static func loadFailureDescription(_ error: Error) -> String {
        let description = error.localizedDescription
        guard description.isEmpty == false else { return String(describing: error) }
        return description
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
