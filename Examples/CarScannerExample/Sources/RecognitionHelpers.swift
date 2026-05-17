import Foundation

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

func configError(_ msg: String) -> NSError {
    NSError(domain: "Config", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
}

func apiError(_ msg: String) -> NSError {
    NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
}
