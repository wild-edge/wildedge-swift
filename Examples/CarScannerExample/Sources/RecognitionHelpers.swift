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

/// Sends `request` and reports a transport failure (timeout, no connection,
/// TLS) to `handle` before rethrowing it. Such a failure throws before there is
/// any response to check, so without this it would never reach WildEdge.
/// A cancelled request is not a failure and is not reported.
func send(_ request: URLRequest, reportingTo handle: ModelHandle) async throws -> (Data, URLResponse) {
    do {
        return try await URLSession.shared.data(for: request)
    } catch {
        if let code = networkErrorCode(for: error) {
            handle.trackError(
                errorCode: code,
                errorMessage: String(error.localizedDescription.prefix(256))
            )
        }
        throw error
    }
}

/// `nil` for a cancellation, which is not reported.
private func networkErrorCode(for error: Error) -> String? {
    if error is CancellationError { return nil }
    guard let urlError = error as? URLError else { return "NETWORK_ERROR" }
    switch urlError.code {
    case .cancelled:
        return nil
    case .timedOut:
        return "NETWORK_TIMEOUT"
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
        return "NETWORK_OFFLINE"
    default:
        return "NETWORK_\(urlError.code.rawValue)"
    }
}

/// The WildEdge handle for the model version that actually answered.
///
/// The clients call `-latest` aliases, so the version behind a request is only
/// known from its response. Each version gets its own handle, registered the
/// first time it answers, so the dashboard shows real versions rather than the
/// alias. `fallback`, the alias's own handle, covers a response that names no
/// version.
func versionHandle(_ version: String?, idPrefix: String, source: String, fallback: ModelHandle) -> ModelHandle {
    guard let version, !version.isEmpty else { return fallback }
    return WildEdge.shared.registerModel(
        modelId: "\(idPrefix)/\(version)",
        info: ModelInfo(modelName: version, modelSource: source, modelFormat: "api", modelFamily: "gemini")
    )
}

func assertHTTP200(data: Data, response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw apiError(String(data: data, encoding: .utf8) ?? "unknown error")
    }
}

/// Boxes are reported as [x_min, y_min, x_max, y_max] in pixels of the image
/// uploaded as the attachment, so they line up with it directly. A scan uploads
/// a crop of the car, so these are crop coordinates, not coordinates in the
/// original photo.
func detectionMeta(from info: CarInfo, imageSize: CGSize? = nil) -> [String: Any] {
    guard info.found, let candidates = info.candidates, !candidates.isEmpty else {
        return DetectionOutputMeta(numPredictions: 0).toMap()
    }
    let topK: [TopPrediction] = candidates.compactMap { c in
        let parts = [c.brand, c.model].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let conf = c.confidence.map { Double($0) / 100.0 }
        // Without a size there is nothing to scale the normalized box by, and
        // scaling by 1x1 would round every box to zero. Send no box instead.
        //
        // The model answers with an origin and a span; WildEdge wants two
        // corners, so the span is added on before scaling.
        let bbox: [Int]? = imageSize.flatMap { size in
            c.bbox.map { b in
                [Int((b.x * size.width).rounded()),
                 Int((b.y * size.height).rounded()),
                 Int(((b.x + b.width) * size.width).rounded()),
                 Int(((b.y + b.height) * size.height).rounded())]
            }
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
