import Foundation
import WildEdge

final class TracingExample {
    private let wildEdge: WildEdgeClient
    private let embedHandle: ModelHandle
    private let classifyHandle: ModelHandle

    init() {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        self.embedHandle = wildEdge.registerModel(
            modelId: "embed",
            info: ModelInfo(modelName: "Embed", modelVersion: "1", modelSource: "local", modelFormat: "coreml")
        )

        self.classifyHandle = wildEdge.registerModel(
            modelId: "classify",
            info: ModelInfo(modelName: "Classify", modelVersion: "1", modelSource: "local", modelFormat: "coreml")
        )
    }

    // All inferences inside this trace share the same trace_id.
    func runPipeline(input: Data) {
        wildEdge.trace("pipeline") { trace in
            let embedding = trace.span("embed") { _ in
                let start = Date()
                let result = runEmbedding(input)
                _ = embedHandle.trackInference(durationMs: Int(Date().timeIntervalSince(start) * 1000))
                return result
            }

            trace.span("classify") { _ in
                let start = Date()
                _ = runClassification(embedding)
                _ = classifyHandle.trackInference(durationMs: Int(Date().timeIntervalSince(start) * 1000))
            }
        }
    }

    func close() {
        wildEdge.close()
    }

    private func runEmbedding(_ input: Data) -> [Float] {
        _ = input
        return Array(repeating: 0.0, count: 128)
    }

    private func runClassification(_ embedding: [Float]) -> String {
        _ = embedding
        return "label"
    }
}
