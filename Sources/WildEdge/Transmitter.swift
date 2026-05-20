import Foundation
import zlib

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
    private let enableCompression: Bool
    private let debug: Bool
    private let logger: (String) -> Void

    init(
        host: String,
        apiKey: String,
        timeoutMs: TimeInterval = Config.httpTimeoutMs,
        enableCompression: Bool = Config.defaultEnableCompression,
        debug: Bool = false,
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.host = host
        self.apiKey = apiKey
        self.timeout = timeoutMs / 1000.0
        self.enableCompression = enableCompression
        self.debug = debug
        self.logger = logger
    }

    func send(batchData: Data) throws -> IngestResponse {
        guard let url = URL(string: "\(host.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/ingest") else {
            throw TransmitError.invalidUrl
        }

        if debug {
            let payload = prettyJSONString(from: batchData) ?? String(data: batchData, encoding: .utf8) ?? "<non-utf8>"
            logger("Ingest request payload:\n\(payload)")
        }

        let body: Data
        if enableCompression, let compressed = gzipCompress(batchData) {
            body = compressed
            if debug {
                let ratio = Int((1.0 - Double(compressed.count) / Double(batchData.count)) * 100)
                logger("Compression: \(batchData.count) B → \(compressed.count) B (\(ratio)% saved)")
            }
        } else {
            body = batchData
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if enableCompression {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
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

        if debug {
            let responseBody = outData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            logger("Ingest response status=\(http.statusCode) body=\(responseBody)")
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

// windowBits = 31 (15 + 16) selects gzip format instead of raw deflate.
internal func gzipCompress(_ input: Data) -> Data? {
    guard !input.isEmpty else { return input }
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { deflateEnd(&stream) }

    let chunkSize = 64 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    var output = Data()
    output.reserveCapacity(input.count / 2)

    input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
        stream.avail_in = uInt(input.count)
        repeat {
            var written = 0
            chunk.withUnsafeMutableBytes { dst in
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkSize)
                deflate(&stream, Z_FINISH)
                written = chunkSize - Int(stream.avail_out)
            }
            output.append(contentsOf: chunk[..<written])
        } while stream.avail_out == 0
    }
    return output
}
