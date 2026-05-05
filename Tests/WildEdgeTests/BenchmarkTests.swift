import XCTest
@testable import WildEdge

final class BenchmarkTests: XCTestCase {

    private let hardware = HardwareContext(
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
    )

    // Full pipeline — establishes the baseline
    func testBuildInferenceEvent() {
        measure {
            for _ in 0..<1_000 {
                _ = buildInferenceEvent(
                    modelId: "bench-model",
                    durationMs: 42,
                    inputModality: .text,
                    outputModality: .generation,
                    success: true,
                    inputMeta: ["token_count": 128],
                    outputMeta: ["avg_confidence": 0.95],
                    generationConfig: ["temperature": 0.7],
                    hardware: hardware,
                    traceId: "trace-1",
                    spanId: "span-1",
                    parentSpanId: "parent-1"
                )
            }
        }
    }

    // ISO8601DateFormatter is created fresh on each isoNow() call
    func testIsoNow() {
        measure {
            for _ in 0..<1_000 {
                _ = isoNow()
            }
        }
    }

    // UUID().uuidString — called twice per buildInferenceEvent
    func testUUIDStringGeneration() {
        measure {
            for _ in 0..<10_000 {
                _ = UUID().uuidString
            }
        }
    }

    // hardware.toMap() — dict assembly from struct fields
    func testHardwareToMap() {
        measure {
            for _ in 0..<10_000 {
                _ = hardware.toMap()
            }
        }
    }
}
