import Foundation
import CoreGraphics
import WildEdge

struct GeminiClient {
    /// The alias's own handle. Only used for failures before this alias has
    /// ever answered on this install; see `versionHandle`.
    static let handle: ModelHandle = WildEdge.shared.registerModel(
        modelId: "google/gemini-flash-latest",
        info: ModelInfo(
            modelName: "gemini-flash-latest",
            modelSource: "google",
            modelFormat: "api",
            modelFamily: "gemini"
        )
    )

    private var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func analyze(_ imageData: Data, prompt: String, imageSize: CGSize? = nil) async throws -> (CarInfo, String, HTTPStats, String, Date, ModelHandle) {
        let key = apiKey
        guard !key.isEmpty, key != "YOUR_GEMINI_API_KEY" else {
            throw configError("Set GEMINI_API_KEY in Info.plist")
        }
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inline_data": ["mime_type": "image/jpeg", "data": imageData.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]]
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // A failure before the response names a version goes to the version
        // this alias last resolved to.
        let lastKnown = versionHandle(nil, idPrefix: "google", source: "google", fallback: Self.handle)
        let start = Date()
        let (data, response) = try await send(request, reportingTo: lastKnown)
        let stats = HTTPStats(
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            responseSize: data.count
        )

        print("[GeminiClient] raw response:\n\(prettyPrinted(data))")

        if stats.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            lastKnown.trackError(
                errorCode: "HTTP_\(stats.statusCode)",
                errorMessage: String(body.prefix(256))
            )
            try assertHTTP200(data: data, response: response)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Gemini names the version that answered in `modelVersion`.
        let handle = versionHandle(json?["modelVersion"] as? String,
                                   idPrefix: "google", source: "google", fallback: Self.handle)
        guard
            let candidates = json?["candidates"] as? [[String: Any]],
            let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else {
            handle.trackError(
                errorCode: "PARSE_ERROR",
                errorMessage: "Unexpected Gemini response format"
            )
            throw apiError("Unexpected Gemini response format")
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
                                         generation: geminiGenerationMeta(from: json)),
            apiMeta: geminiApiMeta(from: json),
            attachments: [InferenceAttachment(name: "input.jpg", role: .input,
                                              payload: .data(imageData, mimeType: "image/jpeg"))]
        )
        return (info, prettyPrinted(data), stats, inferenceId, inferenceDate, handle)
    }
}
