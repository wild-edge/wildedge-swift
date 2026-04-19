import Foundation
import WildEdge

final class CoroutinesExample {
    private let wildEdge: WildEdgeClient
    private let classifyHandle: ModelHandle
    private let llmHandle: ModelHandle

    init() {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        self.classifyHandle = wildEdge.registerModel(
            modelId: "mobilenet-v3",
            info: ModelInfo(
                modelName: "MobileNet V3",
                modelVersion: "3.0",
                modelSource: "local",
                modelFormat: "coreml",
                quantization: "int8"
            )
        )

        self.llmHandle = wildEdge.registerModel(
            modelId: "gemma-3n",
            info: ModelInfo(
                modelName: "Gemma 3N",
                modelVersion: "1.0",
                modelSource: "local",
                modelFormat: "coreml",
                quantization: "int4"
            )
        )
    }

    // Tracks an async classification call and records inference metrics.
    func classify(input: Data) async throws -> String {
        let start = Date()
        do {
            let label = try await runClassifier(input)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            _ = classifyHandle.trackInference(
                durationMs: durationMs,
                inputModality: .image,
                outputModality: .classification,
                success: true,
                outputMeta: DetectionOutputMeta(numPredictions: 1, avgConfidence: 0.93).toMap()
            )
            return label
        } catch {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            _ = classifyHandle.trackInference(
                durationMs: durationMs,
                inputModality: .image,
                outputModality: .classification,
                success: false,
                errorCode: "classifier_error"
            )
            throw error
        }
    }

    // Streams generated tokens and records aggregate generation metrics.
    func streamResponse(prompt: String) -> AsyncStream<String> {
        let inputMeta = WildEdge.analyzeText(prompt).toMap()

        return AsyncStream { continuation in
            Task {
                let start = Date()
                var tokenCount = 0
                for token in ["Hello", ", ", "world!"] {
                    tokenCount += 1
                    continuation.yield(token)
                }
                continuation.finish()

                let durationSec = Date().timeIntervalSince(start)
                let tokensPerSecond = durationSec > 0 ? Double(tokenCount) / durationSec : nil
                let outputMeta = GenerationOutputMeta(
                    tokensIn: inputMeta["token_count"] as? Int,
                    tokensOut: tokenCount,
                    tokensPerSecond: tokensPerSecond,
                    stopReason: "end"
                ).toMap()

                _ = llmHandle.trackInference(
                    durationMs: Int(durationSec * 1000),
                    inputModality: .text,
                    outputModality: .generation,
                    inputMeta: inputMeta,
                    outputMeta: outputMeta
                )
            }
        }
    }

    func close() {
        wildEdge.close()
    }

    private func runClassifier(_ input: Data) async throws -> String {
        _ = input
        try await Task.sleep(nanoseconds: 10_000_000)
        return "label"
    }
}
