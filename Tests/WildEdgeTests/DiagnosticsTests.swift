import XCTest
@testable import WildEdge

final class DiagnosticsTests: XCTestCase {
    func testDiagnosticsAfterFillingQueueToMax() {
        let maxSize = 1000
        let queue = EventQueue(maxSize: maxSize)
        let client = WildEdge(
            queue: queue,
            registry: ModelRegistry(),
            consumer: nil,
            attachmentQueue: nil,
            attachmentConsumer: nil,
            attachmentConfig: .init(enabled: false, maxPerInference: 0, maxSizeBytes: 0, storageStrategy: .file, filter: nil),
            debug: false
        )

        let handle = client.registerModel(
            modelId: "diag-model",
            info: ModelInfo(modelName: "Diag Model", modelSource: "local", modelFormat: "coreml")
        )

        for _ in 0..<maxSize {
            _ = handle.trackInference(
                durationMs: 10,
                inputModality: .text,
                outputModality: .generation,
                success: true,
                errorCode: nil,
                inputMeta: TextInputMeta(
                    charCount: 512,
                    wordCount: 96,
                    tokenCount: 128,
                    language: "en",
                    languageConfidence: 0.99,
                    containsCode: false,
                    promptType: "instruction",
                    turnIndex: 0,
                    hasAttachments: false
                ).toMap(),
                outputMeta: GenerationOutputMeta(
                    tokensIn: 128,
                    tokensOut: 64,
                    cachedInputTokens: 32,
                    timeToFirstTokenMs: 120,
                    tokensPerSecond: 42.5,
                    stopReason: "eos",
                    contextUsed: 2048,
                    avgTokenEntropy: 1.3,
                    safetyTriggered: false
                ).toMap(),
                generationConfig: ["temperature": 0.7, "top_p": 0.9, "max_tokens": 256],
                hardware: HardwareContext(
                    thermalState: "nominal",
                    thermalStateRaw: "NSProcessInfoThermalStateNominal",
                    cpuTempCelsius: 45.5,
                    batteryLevel: 0.82,
                    batteryCharging: false,
                    memoryAvailableBytes: 2_000_000_000,
                    cpuFreqMhz: 3200,
                    cpuFreqMaxMhz: 4000,
                    acceleratorActual: .npu,
                    gpuBusyPercent: 12
                ),
                traceId: "trace-diag",
                spanId: "span-diag",
                parentSpanId: "parent-diag",
                runId: "run-diag",
                agentId: "agent-diag"
            )
        }

        let deadline = Date().addingTimeInterval(2.0)
        var diag = client.diagnostics()
        while diag.eventQueueCount < maxSize && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            diag = client.diagnostics()
        }

        let mb = { (bytes: Int64) in String(format: "%.3f MB", Double(bytes) / 1_048_576) }
        print("SDKDiagnostics:")
        print("  processMemoryBytes:         \(diag.processMemoryBytes) (\(mb(diag.processMemoryBytes)))")
        print("  systemAvailableMemoryBytes: \(diag.systemAvailableMemoryBytes.map { "\($0) (\(mb($0)))" } ?? "nil")")
        print("  eventQueueCount:            \(diag.eventQueueCount)")

        XCTAssertEqual(diag.eventQueueCount, maxSize)
    }
}
