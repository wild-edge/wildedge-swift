import Foundation
import CoreGraphics
import WildEdge

struct OpenRouterClient {
    /// The alias's handle. It only records failures that happen before a
    /// response names the version; everything after goes to `versionHandle`.
    static let handle: ModelHandle = WildEdge.shared.registerModel(
        modelId: "openrouter/gemini-flash-latest",
        info: ModelInfo(
            modelName: "gemini-flash-latest",
            modelSource: "openrouter",
            modelFormat: "api",
            modelFamily: "gemini"
        )
    )

    private var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "OPENROUTER_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func analyze(_ imageData: Data, prompt: String, imageSize: CGSize? = nil) async throws -> (CarInfo, String, HTTPStats, String, Date, ModelHandle) {
        let key = apiKey
        guard !key.isEmpty, key != "YOUR_OPENROUTER_API_KEY" else {
            throw configError("Set OPENROUTER_API_KEY in Info.plist")
        }
        let body: [String: Any] = [
            "model": "~google/gemini-flash-latest",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response) = try await send(request, reportingTo: Self.handle)
        let stats = HTTPStats(
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            responseSize: data.count
        )

        print("[OpenRouterClient] raw response:\n\(prettyPrinted(data))")

        if stats.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            Self.handle.trackError(
                errorCode: "HTTP_\(stats.statusCode)",
                errorMessage: String(body.prefix(256))
            )
            try assertHTTP200(data: data, response: response)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // OpenRouter names the model it routed to in `model`, as `google/<version>`.
        let handle = versionHandle((json?["model"] as? String).map { $0.split(separator: "/").last.map(String.init) ?? $0 },
                                   idPrefix: "openrouter", source: "openrouter", fallback: Self.handle)
        guard
            let choices = json?["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else {
            handle.trackError(
                errorCode: "PARSE_ERROR",
                errorMessage: "Unexpected OpenRouter response format"
            )
            throw apiError("Unexpected OpenRouter response format")
        }

        let info: CarInfo
        do {
            info = try decodeCarInfo(from: text)
        } catch {
            handle.trackError(
                errorCode: "PARSE_ERROR",
                errorMessage: error.localizedDescription
            )
            throw error
        }

        let inferenceDate = Date()
        let inferenceId = handle.trackInference(
            durationMs: stats.durationMs,
            inputModality: .multimodal,
            outputModality: .detection,
            success: true,
            outputMeta: mergedOutputMeta(detection: detectionMeta(from: info, imageSize: imageSize),
                                         generation: openRouterGenerationMeta(from: json)),
            apiMeta: openRouterApiMeta(from: json),
            attachments: [InferenceAttachment(name: "input.jpg", role: .input,
                                              payload: .data(imageData, mimeType: "image/jpeg"))]
        )
        return (info, prettyPrinted(data), stats, inferenceId, inferenceDate, handle)
    }
}
