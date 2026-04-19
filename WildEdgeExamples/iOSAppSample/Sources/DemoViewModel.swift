import Foundation
import WildEdge

@MainActor
final class DemoViewModel: ObservableObject {
    @Published var statusText = "Initializing..."
    @Published var logText = ""
    @Published var isRunning = false

    private var wildEdge: WildEdgeClient?
    private var initialized = false

    private let modelId = "mobilenet-v1"
    private let modelURL = URL(string: "https://drive.usercontent.google.com/download?id=1xUQklFyuYFV_ZsuO8Rskc52xsuSPZCip&export=download&authuser=0")!

    func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true

        let dsn = (Bundle.main.object(forInfoDictionaryKey: "WILDEDGE_DSN") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        if dsn.isEmpty {
            statusText = "noop mode -- set WILDEDGE_DSN in Build Settings to enable reporting"
        } else {
            statusText = "reporting enabled"
        }
    }

    func runDemo() {
        guard !isRunning else { return }
        initializeIfNeeded()
        guard let wildEdge else {
            appendLog("WildEdge is not initialized")
            return
        }

        isRunning = true
        Task {
            defer { isRunning = false }

            let handle = wildEdge.registerModel(
                modelId: modelId,
                info: ModelInfo(
                    modelName: "MobileNet V1",
                    modelVersion: "1.0",
                    modelSource: "remote",
                    modelFormat: "tflite",
                    quantization: "uint8"
                )
            )

            do {
                let modelFile = try Self.cachedModelFileURL()
                appendLog("Downloading MobileNet V1 quant (~4 MB)...")
                let downloadOK = try await ModelDownloader.downloadIfNeeded(
                    handle: handle,
                    sourceURL: modelURL,
                    destinationURL: modelFile
                )

                guard downloadOK else {
                    appendLog("Download failed. Check network connection.")
                    return
                }

                appendLog("Download complete.")
                appendLog("Running 10 synthetic inferences...")

                let lines: [String] = wildEdge.trace("demo-batch") { trace in
                    (1...10).map { runIndex in
                        trace.span("inference-\(runIndex)") { _ in
                            let started = Date()

                            let topClass = (runIndex * 97) % 1001
                            let scorePercent = Double((runIndex * 17) % 100)
                            let confidence = max(0.01, min(0.99, scorePercent / 100.0))

                            _ = handle.trackInference(
                                durationMs: max(1, Int(Date().timeIntervalSince(started) * 1000)),
                                inputModality: .image,
                                outputModality: .classification,
                                success: true,
                                outputMeta: DetectionOutputMeta(numPredictions: 1, avgConfidence: confidence).toMap()
                            )

                            let scoreText = String(format: "%.1f", scorePercent)
                            return "  run \(runIndex)  class \(topClass)  score \(scoreText)%"
                        }
                    }
                }

                lines.forEach { appendLog($0) }

                handle.trackFeedback(.accepted)
                appendLog("Tracked feedback: accepted")

                appendLog("Pending events: \(wildEdge.pendingCount)")
                wildEdge.flush(timeoutMs: 5_000)
                appendLog("Flushed. Pending after flush: \(wildEdge.pendingCount)")
            } catch {
                appendLog("Error: \(error.localizedDescription)")
            }
        }
    }

    private func appendLog(_ message: String) {
        if logText.isEmpty {
            logText = message
        } else {
            logText += "\n" + message
        }
    }

    private static func cachedModelFileURL() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return caches.appendingPathComponent("mobilenet_v1_quant.tflite")
    }
}
