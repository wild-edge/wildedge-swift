import Foundation
import CoreGraphics
import WildEdge

struct GeminiClient {
    private static let handle: ModelHandle = WildEdge.shared.registerModel(
        modelId: "google/gemini-2.5-flash",
        info: ModelInfo(
            modelName: "gemini-2.5-flash",
            modelSource: "google",
            modelFormat: "api",
            modelFamily: "gemini"
        )
    )

    private var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func analyze(_ imageData: Data, prompt: String, imageSize: CGSize? = nil, runId: String? = nil) async throws -> (CarInfo, String, HTTPStats) {
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
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let stats = HTTPStats(
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            responseSize: data.count
        )

        try assertHTTP200(data: data, response: response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let candidates = json?["candidates"] as? [[String: Any]],
            let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { throw apiError("Unexpected Gemini response format") }
        let info = try decodeCarInfo(from: text)

        Self.handle.trackInference(
            durationMs: stats.durationMs,
            inputModality: .multimodal,
            outputModality: .detection,
            success: true,
            outputMeta: detectionMeta(from: info, imageSize: imageSize),
            runId: runId,
            attachments: [InferenceAttachment(name: "input.jpg", role: .input,
                                              payload: .data(imageData, mimeType: "image/jpeg"))]
        )
        return (info, prettyPrinted(data), stats)
    }
}
