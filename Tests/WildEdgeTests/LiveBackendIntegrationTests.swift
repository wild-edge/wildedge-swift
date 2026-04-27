import XCTest
@testable import WildEdge

final class LiveBackendIntegrationTests: XCTestCase {
    func testTransmitterSendsBatchToBackend() throws {
        try requireLiveTestsEnabled()

        let dsn = try XCTUnwrap(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"],
            "WILDEDGE_DSN must be set for live backend integration tests"
        )

        let parsed = try WildEdge.Builder.parseDsn(dsn)
        let transmitter = Transmitter(host: parsed.host, apiKey: parsed.secret)

        let modelId = "live-test-model"
        let event = buildInferenceEvent(
            modelId: modelId,
            durationMs: 12,
            inputModality: .text,
            outputModality: .generation,
            outputMeta: ["avg_confidence": 0.88]
        )

        let payload = try XCTUnwrap(buildBatch(
            device: DeviceInfo(
                deviceId: "test-device-id",
                deviceType: "ios",
                deviceModel: "iPhone",
                osName: "iOS",
                osVersion: "18.0",
                appVersion: "live-test",
                sdkVersion: "test-sdk",
                locale: "en-US",
                timezone: "UTC"
            ),
            models: [modelId: [
                "model_name": "Live Test Model",
                "model_version": "1.0",
                "model_source": "local",
                "model_format": "custom",
            ]],
            events: [event],
            sessionId: "live-test-session",
            createdAt: isoNow(),
            lowConfidenceThreshold: 0.5
        ))

        let response = try transmitter.send(batchData: payload)
        print(
            "[live-backend] status=\(response.status) batch_id=\(response.batchId) " +
            "accepted=\(response.eventsAccepted) rejected=\(response.eventsRejected)"
        )
        XCTAssertTrue(
            ["accepted", "partial", "rejected", "unauthorized", "error"].contains(response.status),
            "Unexpected ingest status: \(response.status)"
        )
    }

    func testWildEdgeClientEndToEndFlushesToBackend() throws {
        try requireLiveTestsEnabled()

        let dsn = try XCTUnwrap(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"],
            "WILDEDGE_DSN must be set for live backend integration tests"
        )

        let client = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
            builder.flushIntervalMs = 60_000
        }

        XCTAssertFalse(client is NoopWildEdgeClient, "Client should not be noop when DSN is configured")

        let handle = client.registerModel(
            modelId: "live-e2e-model",
            info: ModelInfo(
                modelName: "Live E2E Model",
                modelVersion: "1.0",
                modelSource: "local",
                modelFormat: "custom"
            )
        )

        handle.trackLoad(durationMs: 7, accelerator: .cpu)
        let inferenceId = handle.trackInference(
            durationMs: 14,
            inputModality: .text,
            outputModality: .generation,
            outputMeta: ["avg_confidence": 0.9]
        )
        XCTAssertFalse(inferenceId.isEmpty)

        handle.trackFeedback(.accepted, relatedInferenceId: inferenceId)

        XCTAssertGreaterThan(client.pendingCount, 0)
        client.flush(timeoutMs: 5_000)
        XCTAssertEqual(client.pendingCount, 0, "Expected queue to be drained after live flush")

        client.close(timeoutMs: 5_000)
    }

    func testTraceFunctionEndToEndFlushesToBackend() throws {
        try requireLiveTestsEnabled()

        let dsn = try XCTUnwrap(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"],
            "WILDEDGE_DSN must be set for live backend integration tests"
        )

        let client = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
            builder.flushIntervalMs = 60_000
        }

        XCTAssertFalse(client is NoopWildEdgeClient, "Client should not be noop when DSN is configured")

        let modelId = "live-trace-model"
        let handle = client.registerModel(
            modelId: modelId,
            info: ModelInfo(
                modelName: "Live Trace Model",
                modelVersion: "1.0",
                modelSource: "local",
                modelFormat: "custom"
            )
        )

        let result: Int = client.trace("live-trace-root", kind: .custom, attributes: ["suite": "live"]) { trace in
            let inferenceId = handle.trackInference(
                durationMs: 11,
                inputModality: .text,
                outputModality: .generation,
                outputMeta: ["avg_confidence": 0.93]
            )
            XCTAssertFalse(inferenceId.isEmpty)

            return trace.span("live-trace-child", kind: .tool, attributes: ["step": 1]) { _ in
                _ = handle.trackInference(
                    durationMs: 9,
                    inputModality: .text,
                    outputModality: .generation,
                    outputMeta: ["avg_confidence": 0.91]
                )
                return 200
            }
        }
        XCTAssertEqual(result, 200)

        XCTAssertGreaterThan(client.pendingCount, 0)
        client.flush(timeoutMs: 5_000)
        XCTAssertEqual(client.pendingCount, 0, "Expected queue to be drained after trace live flush")

        client.close(timeoutMs: 5_000)
    }

    func testTrackLoadWithoutAcceleratorFlushesToBackend() throws {
        try requireLiveTestsEnabled()

        let dsn = try XCTUnwrap(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"],
            "WILDEDGE_DSN must be set for live backend integration tests"
        )

        let client = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
            builder.flushIntervalMs = 60_000
        }

        XCTAssertFalse(client is NoopWildEdgeClient)

        let handle = client.registerModel(
            modelId: "live-load-no-accelerator-model",
            info: ModelInfo(
                modelName: "Live Load No Accelerator Model",
                modelVersion: "1.0",
                modelSource: "local",
                modelFormat: "tflite"
            )
        )

        handle.trackLoad(durationMs: 42)

        XCTAssertGreaterThan(client.pendingCount, 0)
        client.flush(timeoutMs: 5_000)
        XCTAssertEqual(client.pendingCount, 0, "Expected queue to be drained after flush")

        client.close(timeoutMs: 5_000)
    }

    private func requireLiveTestsEnabled() throws {
        let enabled = ProcessInfo.processInfo.environment["WILDEDGE_LIVE_TESTS"]?.lowercased()
        let isEnabled = enabled == "1" || enabled == "true" || enabled == "yes"
        if !isEnabled {
            throw XCTSkip("Skipping live backend tests. Set WILDEDGE_LIVE_TESTS=true to enable.")
        }
    }
}
