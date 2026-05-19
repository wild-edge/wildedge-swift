import Foundation
import WildEdge

func decodeCarInfo(from text: String) throws -> CarInfo {
    let extracted = extractJSON(from: text)
    guard let jsonData = extracted.data(using: .utf8) else { throw apiError("Cannot parse model response") }
    return try JSONDecoder().decode(CarInfo.self, from: jsonData)
}

func prettyPrinted(_ data: Data) -> String {
    guard
        let obj = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
        let str = String(data: pretty, encoding: .utf8)
    else { return String(data: data, encoding: .utf8) ?? "" }
    return str
}

func extractJSON(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else { return trimmed }
    return String(trimmed[start...end])
}

func assertHTTP200(data: Data, response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw apiError(String(data: data, encoding: .utf8) ?? "unknown error")
    }
}

func detectionMeta(from info: CarInfo, imageSize: CGSize? = nil) -> [String: Any] {
    guard info.found, let candidates = info.candidates, !candidates.isEmpty else {
        return DetectionOutputMeta(numPredictions: 0).toMap()
    }
    let w = imageSize?.width ?? 1
    let h = imageSize?.height ?? 1
    let topK: [TopPrediction] = candidates.compactMap { c in
        let parts = [c.brand, c.model].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let conf = c.confidence.map { Double($0) / 100.0 }
        let bbox = c.bbox.map { b in
            [Int((b.x * w).rounded()), Int((b.y * h).rounded()),
             Int((b.width * w).rounded()), Int((b.height * h).rounded())]
        }
        return TopPrediction(label: parts.joined(separator: " "), confidence: conf, bbox: bbox)
    }
    let confidences = topK.compactMap { $0.confidence }
    let avg = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
    return DetectionOutputMeta(
        numPredictions: topK.count,
        topK: topK,
        avgConfidence: avg
    ).toMap()
}

func geminiGenerationMeta(from json: [String: Any]?) -> [String: Any] {
    var meta = GenerationOutputMeta()
    if let usage = json?["usageMetadata"] as? [String: Any] {
        meta.tokensIn  = usage["promptTokenCount"]    as? Int
        meta.tokensOut = usage["candidatesTokenCount"] as? Int
    }
    if let candidates = json?["candidates"] as? [[String: Any]],
       let reason = candidates.first?["finishReason"] as? String {
        meta.stopReason = reason.lowercased()
    }
    return meta.toMap()
}

/// Merges generation metadata fields into the detection meta map.
/// Generation fields (tokens, stop_reason) are added alongside detection
/// fields; the "task" key from detection is preserved.
func mergedOutputMeta(detection: [String: Any], generation: [String: Any]) -> [String: Any] {
    var merged = detection
    for (key, value) in generation where key != "task" {
        merged[key] = value
    }
    return merged
}

func geminiApiMeta(from json: [String: Any]?) -> ApiMeta {
    ApiMeta(resolvedModelId: json?["modelVersion"] as? String)
}

func openRouterGenerationMeta(from json: [String: Any]?) -> [String: Any] {
    var meta = GenerationOutputMeta()
    if let usage = json?["usage"] as? [String: Any] {
        meta.tokensIn  = usage["prompt_tokens"]     as? Int
        meta.tokensOut = usage["completion_tokens"]  as? Int
        if let promptDetails = usage["prompt_tokens_details"] as? [String: Any] {
            meta.cachedInputTokens = promptDetails["cached_tokens"] as? Int
        }
    }
    if let choices = json?["choices"] as? [[String: Any]],
       let reason = choices.first?["finish_reason"] as? String {
        meta.stopReason = reason.lowercased()
    }
    return meta.toMap()
}

func openRouterApiMeta(from json: [String: Any]?) -> ApiMeta {
    ApiMeta(
        resolvedModelId: json?["model"] as? String,
        systemFingerprint: json?["system_fingerprint"] as? String,
        serviceTier: json?["service_tier"] as? String
    )
}

func configError(_ msg: String) -> NSError {
    NSError(domain: "Config", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
}

func apiError(_ msg: String) -> NSError {
    NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
}
