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
