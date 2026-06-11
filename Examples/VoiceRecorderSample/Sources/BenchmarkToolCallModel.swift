import Foundation
import LeapSDK
#if canImport(FoundationModels)
import FoundationModels
#endif

enum BenchmarkToolCallInput {
    case text(String)
    case audio(URL)
}

struct BenchmarkGenerationMetrics {
    let tokensIn: Int?
    let tokensOut: Int?
    let totalTokens: Int?
    let cachedInputTokens: Int?
    let tokensPerSecond: Double?

    init(
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        totalTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        tokensPerSecond: Double? = nil
    ) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.tokensPerSecond = tokensPerSecond
    }

    init(stats: GenerationStats) {
        self.init(
            tokensIn: Self.nonNegativeInt(stats.promptTokens),
            tokensOut: Self.nonNegativeInt(stats.completionTokens),
            totalTokens: Self.nonNegativeInt(stats.totalTokens),
            cachedInputTokens: Self.nonNegativeInt(stats.cachedPromptTokens),
            tokensPerSecond: Self.finiteDouble(stats.tokenPerSecond)
        )
    }

    private static func nonNegativeInt(_ value: Int64) -> Int? {
        guard value >= 0 else { return nil }
        return Int(value)
    }

    private static func finiteDouble(_ value: Float) -> Double? {
        guard value.isFinite else { return nil }
        return Double(value)
    }
}

struct BenchmarkToolCallGenerationResult {
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
    let generationMetrics: BenchmarkGenerationMetrics?

    var parsedSuccessfully: Bool {
        parsedJSON != nil && errorDescription == nil
    }
}

actor LeapBenchmarkToolCallModel {
    static let shared = LeapBenchmarkToolCallModel()

    private init() {
    }

    func generate(
        input: BenchmarkToolCallInput,
        textToToolModel: BenchmarkTextToToolModel = .default,
        speechToToolPrompt: String? = nil,
        speechToToolModel: BenchmarkTextToToolModel = .leapLFM25Audio,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async -> BenchmarkToolCallGenerationResult {
        let start = Date()
        do {
            var rawOutput: String
            var rawText: String?
            var measuredDurationMs: Int?
            var generationMetrics: BenchmarkGenerationMetrics?
            let model: BenchmarkTextToToolModel
            switch input {
            case .text(let transcript):
                let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedTranscript.isEmpty == false else {
                    return Self.result(
                        rawOutput: "",
                        rawText: "",
                        durationMs: 0,
                        parseResult: ToolCallParseResult(value: nil, error: "Text-to-tool skipped because speech-to-text produced no transcript."),
                        generationError: nil
                    )
                }
                model = textToToolModel
                if textToToolModel.usesSharedAudioModel {
                    let transcriber = await LeapSpeechTranscriber.shared()
                    let response = try await transcriber.appMeasuredToolCall(fromTranscript: trimmedTranscript)
                    rawOutput = ToolCallTranscriptHeuristics.correctedToolCallJSON(
                        rawOutput: response.text,
                        transcript: trimmedTranscript
                    )
                    rawText = rawOutput
                    measuredDurationMs = response.durationMs
                    generationMetrics = response.generationMetrics
                } else if textToToolModel.kind == .appleFoundationModels {
                    rawOutput = try await AppleFoundationModelsBenchmarkTextToToolModel.shared.toolCall(
                        fromTranscript: trimmedTranscript
                    )
                } else if textToToolModel.kind == .functionGemma
                    || textToToolModel.kind == .liquidLFM25AudioOnePointFiveB
                    || textToToolModel.kind == .leapLFM25350M
                    || textToToolModel.kind == .leapLFM2512BInstruct
                    || textToToolModel.kind == .tinyLlamaOnePointOneB
                    || textToToolModel.kind == .qwen2ZeroPointFiveBInstruct
                    || textToToolModel.kind == .qwen25OnePointFiveBInstruct
                    || textToToolModel.kind == .qwen3ZeroPointSixB
                    || textToToolModel.kind == .qwen3FourB {
                    rawOutput = try await LlamaCppBenchmarkTextToToolModel.shared.toolCall(
                        fromTranscript: trimmedTranscript,
                        model: textToToolModel,
                        progressHandler: progressHandler
                    )
                    rawText = rawOutput
                } else if textToToolModel.kind == .functionGemmaMLX
                    || textToToolModel.kind == .qwen35ZeroPointEightBOptiQMLX
                    || textToToolModel.kind == .qwen3ZeroPointSixBInstructMLX
                    || textToToolModel.kind == .qwen25ZeroPointFiveBInstructMLX {
                    rawOutput = try await MlxBenchmarkTextToToolModel.shared.toolCall(
                        fromTranscript: trimmedTranscript,
                        model: textToToolModel,
                        progressHandler: progressHandler
                    )
                    rawText = rawOutput
                } else if textToToolModel.kind == .onnxRuntime {
                    rawOutput = try await OnnxBenchmarkTextToToolModel.shared.toolCall(
                        fromTranscript: trimmedTranscript,
                        model: textToToolModel
                    )
                    rawText = rawOutput
                } else {
                    rawOutput = try await LeapBenchmarkTextToToolModel.shared.toolCall(
                        fromTranscript: trimmedTranscript,
                        model: textToToolModel,
                        progressHandler: progressHandler
                    )
                    rawText = rawOutput
                }
            case .audio(let url):
                model = speechToToolModel
                if speechToToolModel.usesSharedAudioModel {
                    let transcriber = await LeapSpeechTranscriber.shared()
                    let response = try await transcriber.appMeasuredToolCall(
                        fromAudio: url,
                        progressHandler: progressHandler,
                        userPrompt: speechToToolPrompt
                    )
                    rawOutput = speechToToolPrompt == nil
                        ? ToolCallTranscriptHeuristics.correctedToolCallJSON(
                            rawOutput: response.text,
                            transcript: response.text
                        )
                        : response.text
                    rawText = response.text
                    measuredDurationMs = response.durationMs
                    generationMetrics = response.generationMetrics
                } else if (speechToToolModel.kind == .liquidLFM25AudioOnePointFiveB
                           || speechToToolModel.kind == .qwen3ASRZeroPointSixB
                           || speechToToolModel.kind == .ultravoxLlama32OneB),
                          speechToToolModel.provider == "llama_cpp_mtmd" {
                    let result = try await LlamaMultimodalSpeechToToolModel.shared.toolCallResult(
                        fromAudio: url,
                        model: speechToToolModel,
                        progressHandler: progressHandler
                    )
                    rawOutput = result.toolJSON
                    rawText = result.rawText
                } else if speechToToolModel.kind == .ultravoxLlama32OneB,
                          speechToToolModel.provider == "llama_server" {
                    rawOutput = try await LlamaServerSpeechToToolModel.shared.toolCall(
                        fromAudio: url,
                        model: speechToToolModel
                    )
                    rawText = rawOutput
                } else {
                    throw SpeechTranscriptionError.transcriptionFailed(
                        "\(speechToToolModel.displayName) does not support direct speech-to-tool generation."
                    )
                }
            }

            let parseResult = ToolCallJSON.parseAndValidate(from: rawOutput)
            Self.logGenerationResult(
                model: model,
                rawOutput: rawOutput,
                rawText: rawText,
                parseResult: parseResult,
                generationError: nil,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            return Self.result(
                rawOutput: rawOutput,
                rawText: rawText,
                durationMs: measuredDurationMs ?? Int(Date().timeIntervalSince(start) * 1000),
                parseResult: parseResult,
                generationError: nil,
                generationMetrics: generationMetrics,
                model: model
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let model: BenchmarkTextToToolModel = {
                switch input {
                case .text:
                    return textToToolModel
                case .audio:
                    return speechToToolModel
                }
            }()
            Self.logGenerationResult(
                model: model,
                rawOutput: "",
                rawText: nil,
                parseResult: ToolCallParseResult(value: nil, error: nil),
                generationError: error.localizedDescription,
                durationMs: durationMs
            )
            return Self.result(
                rawOutput: "",
                rawText: "",
                durationMs: durationMs,
                parseResult: ToolCallParseResult(value: nil, error: nil),
                generationError: error.localizedDescription,
                model: model
            )
        }
    }

    private nonisolated static func result(
        rawOutput: String,
        rawText: String? = nil,
        durationMs: Int,
        parseResult: ToolCallParseResult,
        generationError: String?,
        generationMetrics: BenchmarkGenerationMetrics? = nil,
        model: BenchmarkTextToToolModel = .default
    ) -> BenchmarkToolCallGenerationResult {
        BenchmarkToolCallGenerationResult(
            rawOutput: rawOutput,
            rawText: rawText ?? rawOutput,
            durationMs: durationMs,
            parsedJSON: generationError == nil ? parseResult.value : nil,
            canonicalJSON: generationError == nil ? parseResult.canonicalJSON : nil,
            errorDescription: generationError ?? parseResult.error,
            provider: model.provider,
            modelId: model.modelId,
            modelName: model.displayName,
            modelSource: model.modelSource,
            modelFormat: model.modelFormat,
            quantization: model.quantization,
            generationMetrics: generationMetrics
        )
    }

    private nonisolated static func logGenerationResult(
        model: BenchmarkTextToToolModel,
        rawOutput: String,
        rawText: String?,
        parseResult: ToolCallParseResult,
        generationError: String?,
        durationMs: Int
    ) {
        print(
            "Benchmark tool generation result: model=\(model.modelId), provider=\(model.provider), format=\(model.modelFormat), duration_ms=\(durationMs), raw_chars=\(rawOutput.count), parse_success=\(parseResult.parsedSuccessfully), parse_error=\(parseResult.error ?? "none"), generation_error=\(generationError ?? "none"), canonical_json=\(parseResult.canonicalJSON ?? "")"
        )
        if rawOutput.isEmpty == false {
            logText("Benchmark tool generation raw output", rawOutput)
        }
        if let rawText,
           rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           rawText != rawOutput {
            logText("Benchmark tool generation raw model text", rawText)
        }
    }

    private nonisolated static func logText(_ label: String, _ text: String, limit: Int = 8_000) {
        let suffix: String
        let body: String
        if text.count > limit {
            body = String(text.prefix(limit))
            suffix = "\n... truncated \(text.count - limit) chars"
        } else {
            body = text
            suffix = ""
        }
        print("\(label) BEGIN\n\(body)\(suffix)\n\(label) END")
    }
}

actor AppleFoundationModelsBenchmarkTextToToolModel {
    static let shared = AppleFoundationModelsBenchmarkTextToToolModel()

    private init() {
    }

    func toolCall(fromTranscript transcript: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return try await generateToolCall(fromTranscript: transcript)
        }
        throw SpeechTranscriptionError.transcriptionFailed(
            "Apple Foundation Models require iOS 26.0 or later."
        )
        #else
        throw SpeechTranscriptionError.transcriptionFailed(
            "Apple Foundation Models framework is not available in this SDK."
        )
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func generateToolCall(fromTranscript transcript: String) async throws -> String {
        let model = FoundationModels.SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw SpeechTranscriptionError.transcriptionFailed(
                "Apple Foundation Models unavailable: \(Self.availabilityReasonDescription(reason))."
            )
        }

        let session = FoundationModels.LanguageModelSession(
            model: model,
            instructions: ToolCallPromptBuilder.systemPrompt
        )
        let options = FoundationModels.GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: 192
        )
        let response = try await session.respond(
            to: ToolCallPromptBuilder.textToToolUserPrompt(transcript: transcript),
            options: options
        )
        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            return trimmed
        }

        let rawContent = response.rawContent.jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawContent.isEmpty == false {
            return rawContent
        }

        throw SpeechTranscriptionError.transcriptionFailed(
            "Apple Foundation Models returned no text output."
        )
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private nonisolated static func availabilityReasonDescription(
        _ reason: FoundationModels.SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "device not eligible"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence not enabled"
        case .modelNotReady:
            return "model not ready"
        @unknown default:
            return "unknown"
        }
    }
    #endif
}

actor LeapBenchmarkTextToToolModel {
    static let shared = LeapBenchmarkTextToToolModel()

    private var loadedModel: BenchmarkTextToToolModel?
    private var runner: LeapSDK.ModelRunner?

    private init() {
    }

    func toolCall(
        fromTranscript transcript: String,
        model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> String {
        try await prepareModel(model, progressHandler: progressHandler)

        guard let runner else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) runner is unavailable.")
        }

        let conversation = runner.createConversation(
            systemPrompt: ToolCallPromptBuilder.systemPrompt
        )
        let message = LeapSDK.ChatMessage(
            role: .user,
            content: [
                LeapSDK.ChatMessageContent.text(ToolCallPromptBuilder.textToToolUserPrompt(transcript: transcript))
            ],
            reasoningContent: nil,
            functionCalls: nil
        )
        return try await generateTextResponse(
            conversation: conversation,
            message: message,
            logPrefix: "\(model.displayName) text-to-tool"
        )
    }

    private func prepareModel(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws {
        if loadedModel == model, runner != nil {
            return
        }

        if let runner {
            try? await runner.unload()
        }
        runner = nil
        loadedModel = nil

        print("LeapSDK text-to-tool load started: \(model.modelName) \(model.quantization)")
        runner = try await LeapSDK.Leap.shared.load(
            model: model.modelName,
            quantization: model.quantization,
            options: nil,
            progress: { progress, speed in
                let normalizedProgress = Self.normalizedProgress(progress)
                progressHandler?(normalizedProgress, speed)
            }
        )
        loadedModel = model
        print("LeapSDK text-to-tool load completed: \(model.modelName) \(model.quantization)")
    }

    private func generateTextResponse(
        conversation: LeapSDK.Conversation,
        message: LeapSDK.ChatMessage,
        logPrefix: String
    ) async throws -> String {
        var generatedText = ""
        var reasoningFallback = ""
        var responseEvents: [String] = []
        for try await response in conversation.generateResponse(message: message) {
            switch LeapSDK.onEnum(of: response) {
            case .chunk(let chunk):
                generatedText += chunk.text
                responseEvents.append("chunk(\(chunk.text.count))")
                print("\(logPrefix) chunk: \(chunk.text)")
            case .complete(let completion):
                let finalText = completion.fullMessage.content.compactMap { part -> String? in
                    if case let .text(text) = LeapSDK.onEnum(of: part) {
                        return text.text
                    }
                    return nil
                }.joined()
                if let stats = completion.stats {
                    print("\(logPrefix) complete: tokens=\(stats.totalTokens), tps=\(stats.tokenPerSecond)")
                } else {
                    print("\(logPrefix) complete: no generation stats")
                }
                responseEvents.append("complete(text:\(finalText.count))")
                if generatedText.isEmpty {
                    generatedText = finalText
                }
            case .reasoningChunk(let text):
                reasoningFallback += text.reasoning
                responseEvents.append("reasoning(\(text.reasoning.count))")
                print("\(logPrefix) reasoning chunk: \(text.reasoning)")
            case .audioSample:
                responseEvents.append("audio_sample")
            case .functionCalls(let calls):
                let names = calls.functionCalls.map { $0.name }.joined(separator: ", ")
                print("\(logPrefix) returned function calls: \(names)")
                responseEvents.append("function_calls(\(names))")
                if generatedText.isEmpty,
                   let firstFunctionCallJSON = Self.toolCallJSON(from: calls.functionCalls.first) {
                    generatedText = firstFunctionCallJSON
                }
            }
        }

        let trimmed = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = reasoningFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            return trimmed
        }
        if fallback.isEmpty == false {
            return fallback
        }
        let events = responseEvents.isEmpty
            ? "no response events"
            : responseEvents.joined(separator: ", ")
        throw SpeechTranscriptionError.transcriptionFailed("Text-to-tool model returned no output. Response events: \(events).")
    }

    private nonisolated static func toolCallJSON(from functionCall: LeapSDK.LeapFunctionCall?) -> String? {
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

    private nonisolated static func normalizedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let normalized = progress > 1 ? progress / 100 : progress
        return min(max(normalized, 0), 1)
    }
}
