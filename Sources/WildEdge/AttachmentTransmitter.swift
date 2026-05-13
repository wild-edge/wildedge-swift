import Foundation

internal final class AttachmentTransmitter {
    private let host: String
    private let apiKey: String
    private let timeout: TimeInterval
    private let debug: Bool
    private let logger: (String) -> Void
    private let iso8601 = ISO8601DateFormatter()

    init(
        host: String,
        apiKey: String,
        timeoutMs: TimeInterval = Config.attachmentHttpTimeoutMs,
        debug: Bool = false,
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.host = host
        self.apiKey = apiKey
        self.timeout = timeoutMs / 1000.0
        self.debug = debug
        self.logger = logger
    }

    func transmit(_ attachment: PendingAttachment) -> AttachmentUploadResult {
        let mimeType: String
        let sizeBytes: Int

        switch attachment.payload.source {
        case .data(let data, let mime): mimeType = mime; sizeBytes = data.count
        case .file(_, let mime):        mimeType = mime; sizeBytes = attachment.payload.byteSize
        }

        switch presign(attachment: attachment, mimeType: mimeType, sizeBytes: sizeBytes) {
        case .failure(let uploadResult):
            return uploadResult
        case .success(let uploadURL):
            return putToStorage(attachment.payload.source, mimeType: mimeType, url: uploadURL)
        }
    }

    // MARK: - Private

    private enum PresignOutcome {
        case success(URL)
        case failure(AttachmentUploadResult)
    }

    private func presign(
        attachment: PendingAttachment,
        mimeType: String,
        sizeBytes: Int
    ) -> PresignOutcome {
        let baseURL = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/api/attachments/presign") else {
            return .failure(.transientFailure)
        }

        let body: [[String: Any]] = [[
            "attachment_id": attachment.attachmentId,
            "role": attachment.role,
            "content_type": mimeType,
            "size_bytes": sizeBytes,
            "inference_timestamp": iso8601.string(from: attachment.inferenceTimestamp),
        ]]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.permanentFailure(.badPayload))
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Project-Secret")
        request.setValue(Config.sdkVersion, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpResponse: HTTPURLResponse?
        var networkError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            httpResponse = response as? HTTPURLResponse
            networkError = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let networkError {
            if debug { logger("Presign network error: \(networkError.localizedDescription)") }
            return .failure(.transientFailure)
        }
        guard let http = httpResponse else { return .failure(.transientFailure) }

        if debug {
            let responseBody = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            logger("Presign response status=\(http.statusCode) body=\(responseBody)")
        }

        switch http.statusCode {
        case 200, 201:
            break
        case 400:
            return .failure(.permanentFailure(.badPayload))
        case 401, 403:
            return .failure(.permanentFailure(.unauthorized))
        default:
            return .failure(.transientFailure)
        }

        guard let responseData,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [[String: Any]],
              let entry = json.first,
              let uploadURLString = entry["upload_url"] as? String,
              let uploadURL = URL(string: uploadURLString) else {
            return .failure(.transientFailure)
        }

        return .success(uploadURL)
    }

    private func putToStorage(_ payload: InferenceAttachment.Payload, mimeType: String, url: URL) -> AttachmentUploadResult {
        if debug { logger("S3 upload PUT \(url.absoluteString)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResponse: URLResponse?
        var outError: Error?

        let completion: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            outData = data; outResponse = response; outError = error
            semaphore.signal()
        }

        switch payload {
        case .data(let body, _):
            request.httpBody = body
            URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
        case .file(let fileURL, _):
            URLSession.shared.uploadTask(with: request, fromFile: fileURL, completionHandler: completion).resume()
        }

        semaphore.wait()

        if let outError {
            if debug { logger("S3 upload network error: \(outError.localizedDescription)") }
            return .transientFailure
        }
        guard let http = outResponse as? HTTPURLResponse else { return .transientFailure }

        if debug {
            let body = outData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            logger("S3 upload response status=\(http.statusCode) body=\(body)")
        }

        switch http.statusCode {
        case 200, 201, 202, 204: return .uploaded
        case 400:                return .permanentFailure(.badPayload)
        case 401, 403:           return .permanentFailure(.unauthorized)
        case 429, 500...599:     return .transientFailure
        default:                 return .transientFailure
        }
    }
}
