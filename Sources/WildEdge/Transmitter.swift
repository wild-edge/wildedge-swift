import Foundation

internal struct IngestResponse {
    let status: String
    let batchId: String
    let eventsAccepted: Int
    let eventsRejected: Int
}

internal enum TransmitError: Error {
    case invalidUrl
    case transport(String)
}

internal protocol Transmitting {
    func send(batchData: Data) throws -> IngestResponse
}

internal final class Transmitter: Transmitting {
    private let host: String
    private let apiKey: String
    private let timeout: TimeInterval

    init(host: String, apiKey: String, timeoutMs: TimeInterval = Config.httpTimeoutMs) {
        self.host = host
        self.apiKey = apiKey
        self.timeout = timeoutMs / 1000.0
    }

    func send(batchData: Data) throws -> IngestResponse {
        guard let url = URL(string: "\(host.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/ingest") else {
            throw TransmitError.invalidUrl
        }

        if isLiveTestsEnabled {
            let payload = prettyJSONString(from: batchData) ?? String(data: batchData, encoding: .utf8) ?? "<non-utf8-payload>"
            print("[wildedge] Sending ingest payload:\n\(payload)")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = batchData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Project-Secret")
        request.setValue(Config.sdkVersion, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResponse: URLResponse?
        var outError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            outData = data
            outResponse = response
            outError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let outError {
            throw TransmitError.transport(outError.localizedDescription)
        }

        guard let http = outResponse as? HTTPURLResponse else {
            throw TransmitError.transport("Missing HTTP response")
        }

        let statusCode = http.statusCode
        let bodyJson = parseJson(outData)

        switch statusCode {
        case 202:
            return IngestResponse(
                status: (bodyJson?["status"] as? String) ?? "accepted",
                batchId: (bodyJson?["batch_id"] as? String) ?? "",
                eventsAccepted: (bodyJson?["events_accepted"] as? Int) ?? 0,
                eventsRejected: (bodyJson?["events_rejected"] as? Int) ?? 0
            )
        case 400:
            return IngestResponse(status: "rejected", batchId: "", eventsAccepted: 0, eventsRejected: 0)
        case 401:
            return IngestResponse(status: "unauthorized", batchId: "", eventsAccepted: 0, eventsRejected: 0)
        case 404:
            return IngestResponse(status: "error", batchId: "", eventsAccepted: 0, eventsRejected: 0)
        case 429, 500 ... 599:
            let message = String(data: outData ?? Data(), encoding: .utf8) ?? ""
            throw TransmitError.transport("HTTP \(statusCode): \(String(message.prefix(Config.errorMsgMaxLen)))")
        case 300 ... 399:
            return IngestResponse(status: "error", batchId: "", eventsAccepted: 0, eventsRejected: 0)
        case 400 ... 499:
            return IngestResponse(status: "rejected", batchId: "", eventsAccepted: 0, eventsRejected: 0)
        default:
            throw TransmitError.transport("Unexpected HTTP \(statusCode)")
        }
    }

    private func parseJson(_ data: Data?) -> [String: Any]? {
        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data),
            let map = object as? [String: Any]
        else {
            return nil
        }
        return map
    }

    private var isLiveTestsEnabled: Bool {
        let enabled = ProcessInfo.processInfo.environment["WILDEDGE_LIVE_TESTS"]?.lowercased()
        return enabled == "1" || enabled == "true" || enabled == "yes"
    }

    private func prettyJSONString(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            return nil
        }
        return String(data: prettyData, encoding: .utf8)
    }
}
