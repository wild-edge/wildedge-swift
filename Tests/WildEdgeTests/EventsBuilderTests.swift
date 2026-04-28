import XCTest
@testable import WildEdge

final class EventsBuilderTests: XCTestCase {
    func testBuildInferenceEventContainsExpectedFields() throws {
        let event = buildInferenceEvent(
            modelId: "m1",
            durationMs: 42,
            inputModality: .text,
            outputModality: .generation,
            success: true,
            inputMeta: ["token_count": 10],
            outputMeta: ["avg_confidence": 0.2],
            traceId: "trace-1",
            parentSpanId: "parent-1"
        )

        XCTAssertEqual(event["event_type"] as? String, "inference")
        XCTAssertEqual(event["model_id"] as? String, "m1")
        XCTAssertEqual(event["trace_id"] as? String, "trace-1")
        XCTAssertEqual(event["parent_span_id"] as? String, "parent-1")

        let inference = try XCTUnwrap(event["inference"] as? [String: Any])
        XCTAssertEqual(inference["duration_ms"] as? Int, 42)
        XCTAssertEqual(inference["input_modality"] as? String, "text")
        XCTAssertEqual(inference["output_modality"] as? String, "generation")

        let inferenceId = inference["inference_id"] as? String
        let hiddenInferenceId = event["__we_inference_id"] as? String
        XCTAssertEqual(inferenceId, hiddenInferenceId)
    }

    func testInferencePayloadMatchesSchema() throws {
        let hw = HardwareContext(
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

        let event = buildInferenceEvent(
            modelId: "val-model",
            durationMs: 23,
            inputModality: .image,
            outputModality: .classification,
            success: true,
            outputMeta: ["avg_confidence": 0.91],
            hardware: hw,
            traceId: "trace-abc",
            spanId: "span-abc",
            parentSpanId: "parent-abc",
            runId: "run-abc",
            agentId: "agent-abc"
        )

        let device = DeviceInfo(
            deviceId: "device-123",
            deviceType: "ios",
            deviceModel: "iPhone 16 Pro",
            osVersion: "18.2",
            appVersion: "2.0",
            sdkVersion: "1.0",
            locale: "en-US",
            timezone: "America/New_York",
            cpuArch: "arm64",
            cpuCores: 6,
            ramTotalBytes: 8_000_000_000,
            accelerators: [.cpu, .gpu, .npu]
        )

        let data = try XCTUnwrap(buildBatch(
            device: device,
            models: ["val-model": [
                "model_name": "Validation Model",
                "model_version": "1.0",
                "model_source": "local",
                "model_format": "coreml"
            ]],
            events: [event],
            sessionId: "session-val",
            createdAt: "2026-01-01T00:00:00.000Z",
            lowConfidenceThreshold: 0.5
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Batch level
        XCTAssertNotNil(root["protocol_version"] as? String)
        XCTAssertNotNil(root["session_id"]       as? String)
        XCTAssertNotNil(root["batch_id"]          as? String)
        XCTAssertNotNil(root["created_at"]        as? String)
        XCTAssertNotNil(root["sent_at"]           as? String)

        // Device
        let dev = try XCTUnwrap(root["device"] as? [String: Any])
        XCTAssertNotNil(dev["device_id"]        as? String)
        XCTAssertNotNil(dev["device_type"]      as? String)
        XCTAssertNotNil(dev["device_model"]     as? String)
        XCTAssertNotNil(dev["os_version"]       as? String)
        XCTAssertNotNil(dev["app_version"]      as? String)
        XCTAssertNotNil(dev["sdk_version"]      as? String)
        XCTAssertNotNil(dev["locale"]           as? String)
        XCTAssertNotNil(dev["timezone"]         as? String)
        XCTAssertNotNil(dev["cpu_arch"]         as? String)
        XCTAssertNotNil(dev["cpu_cores"]        as? Int)
        XCTAssertNotNil(dev["ram_total_bytes"]  as? Int64)
        XCTAssertNotNil(dev["accelerators"]     as? [String])

        // Models
        let models = try XCTUnwrap(root["models"] as? [String: Any])
        let model  = try XCTUnwrap(models["val-model"] as? [String: Any])
        XCTAssertNotNil(model["model_name"]    as? String)
        XCTAssertNotNil(model["model_version"] as? String)
        XCTAssertNotNil(model["model_source"]  as? String)
        XCTAssertNotNil(model["model_format"]  as? String)

        // Event
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        let ev     = try XCTUnwrap(events.first)
        XCTAssertNotNil(ev["event_id"]    as? String)
        XCTAssertEqual (ev["event_type"]  as? String, "inference")
        XCTAssertNotNil(ev["timestamp"]   as? String)
        XCTAssertEqual (ev["model_id"]    as? String, "val-model")
        XCTAssertEqual (ev["trace_id"]    as? String, "trace-abc")
        XCTAssertEqual (ev["span_id"]     as? String, "span-abc")
        XCTAssertEqual (ev["parent_span_id"] as? String, "parent-abc")
        XCTAssertEqual (ev["run_id"]      as? String, "run-abc")
        XCTAssertEqual (ev["agent_id"]    as? String, "agent-abc")

        // Inference block
        let inf = try XCTUnwrap(ev["inference"] as? [String: Any])
        XCTAssertNotNil(inf["inference_id"]    as? String)
        XCTAssertEqual (inf["duration_ms"]     as? Int,    23)
        XCTAssertEqual (inf["input_modality"]  as? String, "image")
        XCTAssertEqual (inf["output_modality"] as? String, "classification")
        XCTAssertEqual (inf["success"]         as? Bool,   true)

        // Hardware inside inference
        let hwMap  = try XCTUnwrap(inf["hardware"] as? [String: Any])
        let thermal = try XCTUnwrap(hwMap["thermal"] as? [String: Any])
        XCTAssertEqual(thermal["state"]           as? String, "nominal")
        XCTAssertEqual(thermal["state_raw"]       as? String, "NSProcessInfoThermalStateNominal")
        XCTAssertEqual(thermal["cpu_temp_celsius"] as? Double, 45.5)
        XCTAssertEqual(hwMap["battery_level"]          as? Double, 0.82)
        XCTAssertEqual(hwMap["battery_charging"]        as? Bool,   false)
        XCTAssertEqual(hwMap["memory_available_bytes"]  as? Int64,  2_000_000_000)
        XCTAssertEqual(hwMap["cpu_freq_mhz"]            as? Int,    3200)
        XCTAssertEqual(hwMap["cpu_freq_max_mhz"]        as? Int,    4000)
        XCTAssertEqual(hwMap["accelerator_actual"]      as? String, "npu")
    }

    func testBuildBatchStripsInternalFieldsAndAddsSampling() throws {
        let event = buildInferenceEvent(
            modelId: "model-a",
            durationMs: 5,
            outputMeta: ["avg_confidence": 0.1]
        )

        let eventWithInternal = event.merging(["__we_queued_at": Int64(123)]) { current, _ in current }
        let device = DeviceInfo(
            deviceId: "test-device-id",
            deviceType: "ios",
            deviceModel: "iPhone",
            osVersion: "18.0",
            appVersion: "1.0",
            sdkVersion: "test-sdk",
            locale: "en-US",
            timezone: "UTC"
        )

        let data = try XCTUnwrap(buildBatch(
            device: device,
            models: ["model-a": ["model_name": "A", "model_version": "1", "model_source": "local", "model_format": "coreml"]],
            events: [eventWithInternal],
            sessionId: "session-1",
            createdAt: "2026-01-01T00:00:00.000Z",
            lowConfidenceThreshold: 0.5
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        let first = try XCTUnwrap(events.first)
        XCTAssertNil(first["__we_queued_at"])

        let sampling = try XCTUnwrap(root["sampling"] as? [String: Any])
        XCTAssertEqual(sampling["low_confidence_threshold"] as? Double, 0.5)

        let perModel = try XCTUnwrap(sampling["model-a"] as? [String: Any])
        XCTAssertEqual(perModel["low_confidence_seen"] as? Int, 1)
        XCTAssertEqual(perModel["total_inference_events_seen"] as? Int, 1)
    }
}
