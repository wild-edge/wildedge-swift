import Foundation

enum BenchmarkToolCallInput {
    case text(String)
    case audio(URL)
}

struct BenchmarkToolCallGenerationResult {
    let rawOutput: String
    let durationMs: Int
    let parsedJSON: ToolCallJSONValue?
    let canonicalJSON: String?
    let errorDescription: String?
    let provider: String
    let modelId: String
    let modelName: String

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
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async -> BenchmarkToolCallGenerationResult {
        let start = Date()
        do {
            let transcriber = await LeapSpeechTranscriber.shared()
            let rawOutput: String
            switch input {
            case .text(let transcript):
                let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedTranscript.isEmpty == false else {
                    return Self.result(
                        rawOutput: "",
                        durationMs: 0,
                        parseResult: ToolCallParseResult(value: nil, error: "Text-to-tool requires a transcript."),
                        generationError: nil
                    )
                }
                rawOutput = try await transcriber.toolCall(fromTranscript: trimmedTranscript)
            case .audio(let url):
                rawOutput = try await transcriber.toolCall(
                    fromAudio: url,
                    progressHandler: progressHandler
                )
            }

            let parseResult = ToolCallJSON.parseAndValidate(from: rawOutput)
            return Self.result(
                rawOutput: rawOutput,
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                parseResult: parseResult,
                generationError: nil
            )
        } catch {
            return Self.result(
                rawOutput: "",
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                parseResult: ToolCallParseResult(value: nil, error: nil),
                generationError: error.localizedDescription
            )
        }
    }

    private nonisolated static func result(
        rawOutput: String,
        durationMs: Int,
        parseResult: ToolCallParseResult,
        generationError: String?
    ) -> BenchmarkToolCallGenerationResult {
        BenchmarkToolCallGenerationResult(
            rawOutput: rawOutput,
            durationMs: durationMs,
            parsedJSON: generationError == nil ? parseResult.value : nil,
            canonicalJSON: generationError == nil ? parseResult.canonicalJSON : nil,
            errorDescription: generationError ?? parseResult.error,
            provider: "leap_sdk",
            modelId: "\(LeapSpeechTranscriber.modelName)-\(LeapSpeechTranscriber.quantization)",
            modelName: "Leap LFM2.5 Audio"
        )
    }
}
