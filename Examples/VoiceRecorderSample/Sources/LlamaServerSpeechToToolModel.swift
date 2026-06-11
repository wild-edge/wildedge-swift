import Foundation

actor LlamaServerSpeechToToolModel {
    static let shared = LlamaServerSpeechToToolModel()

    private let session: URLSession

    private init(session: URLSession = .shared) {
        self.session = session
    }

    func toolCall(
        fromAudio url: URL,
        model: BenchmarkTextToToolModel
    ) async throws -> String {
        guard model.kind == .ultravoxLlama32OneB,
              model.provider == "llama_server"
        else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) is not configured for llama-server speech-to-tool."
            )
        }

        let audioData = try Data(contentsOf: url)
        guard audioData.isEmpty == false else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) audio input is empty.")
        }

        let endpoint = try endpointURL(for: model)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LlamaServerChatRequest(
                model: model.modelName,
                messages: [
                    LlamaServerChatMessage(
                        role: "system",
                        content: [
                            .text(ToolCallPromptBuilder.speechToToolSystemPrompt)
                        ]
                    ),
                    LlamaServerChatMessage(
                        role: "user",
                        content: [
                            .text(ToolCallPromptBuilder.speechToToolUserPrompt()),
                            .inputAudio(
                                data: audioData.base64EncodedString(),
                                format: audioFormat(for: url)
                            )
                        ]
                    )
                ],
                maxTokens: max(1, model.maxGenerationTokens)
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) returned an invalid response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) llama-server request failed with HTTP \(httpResponse.statusCode): \(message)"
            )
        }

        let decoded = try JSONDecoder().decode(LlamaServerChatResponse.self, from: data)
        let content = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard content.isEmpty == false else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) returned no text output.")
        }

        return ToolCallJSON.firstValidToolCallJSONString(from: content)
            ?? ToolCallJSON.textWithoutThinkBlocks(from: content)
    }

    private nonisolated func endpointURL(for model: BenchmarkTextToToolModel) throws -> URL {
        guard let rawURL = model.serverURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawURL.isEmpty == false,
              let url = URL(string: rawURL)
        else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) needs a llama-server URL."
            )
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("v1/chat/completions") || path.hasSuffix("chat/completions") {
            return url
        }

        if path == "v1" {
            return url.appendingPathComponent("chat/completions")
        }

        if path.isEmpty {
            return url
                .appendingPathComponent("v1")
                .appendingPathComponent("chat/completions")
        }

        return url
    }

    private nonisolated func audioFormat(for url: URL) -> String {
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch fileExtension {
        case "wav", "mp3", "m4a":
            return fileExtension
        default:
            return "wav"
        }
    }

    private nonisolated static func errorMessage(from data: Data) -> String {
        if let error = try? JSONDecoder().decode(LlamaServerErrorResponse.self, from: data),
           let message = error.error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           message.isEmpty == false {
            return message
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           text.isEmpty == false {
            return text
        }
        return "empty response body"
    }
}

private struct LlamaServerChatRequest: Encodable {
    let model: String
    let messages: [LlamaServerChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    init(
        model: String,
        messages: [LlamaServerChatMessage],
        temperature: Double = 0,
        maxTokens: Int,
        stream: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct LlamaServerChatMessage: Encodable {
    let role: String
    let content: [LlamaServerChatContent]
}

private enum LlamaServerChatContent: Encodable {
    case text(String)
    case inputAudio(data: String, format: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case inputAudio = "input_audio"
    }

    private struct AudioPayload: Encodable {
        let data: String
        let format: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputAudio(let data, let format):
            try container.encode("input_audio", forKey: .type)
            try container.encode(
                AudioPayload(data: data, format: format),
                forKey: .inputAudio
            )
        }
    }
}

private struct LlamaServerChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct LlamaServerErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    let error: ErrorBody
}
