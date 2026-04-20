import Foundation
import WildEdge

final class GalleryExample {
    private let wildEdge: WildEdgeClient
    private let llmHandle: ModelHandle

    init() {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

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

        llmHandle.trackLoad(durationMs: 120, accelerator: .gpu)
    }

    // Tracks token streaming output and completion metadata.
    func generate(userInput: String, hasImages: Bool, onToken: @escaping (String) -> Void, onDone: @escaping () -> Void) {
        let inputModality: InputModality = hasImages ? .multimodal : .text
        let inputMeta = WildEdge.analyzeText(userInput, hasAttachments: hasImages).toMap()

        Task {
            let start = Date()
            var tokenCount = 0
            for token in ["This", " is", " a response."] {
                tokenCount += 1
                onToken(token)
            }
            onDone()

            let durationSec = Date().timeIntervalSince(start)
            _ = llmHandle.trackInference(
                durationMs: Int(durationSec * 1000),
                inputModality: inputModality,
                outputModality: .generation,
                inputMeta: inputMeta,
                outputMeta: GenerationOutputMeta(
                    tokensOut: tokenCount,
                    tokensPerSecond: durationSec > 0 ? Double(tokenCount) / durationSec : nil,
                    stopReason: "end"
                ).toMap()
            )
        }
    }

    func close() {
        llmHandle.close()
        wildEdge.close()
    }
}
