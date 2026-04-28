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

    func testHardwareSnapshotFieldsFlushToBackend() throws {
        try requireLiveTestsEnabled()

        let dsn = try XCTUnwrap(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"],
            "WILDEDGE_DSN must be set for live backend integration tests"
        )

        // Sample hardware directly and assert always-available fields.
        let sampler = HardwareSampler(intervalMs: 60_000)
        sampler.start()
        defer { sampler.stop() }
        let hw: HardwareContext = sampler.snapshot()

        XCTAssertNotNil(hw.thermalState,        "thermalState must always be readable")
        XCTAssertNotNil(hw.memoryAvailableBytes, "memoryAvailableBytes must always be readable")
        XCTAssertNotNil(hw.acceleratorActual,   "acceleratorActual must always be set")

        print("""
        [hw-snapshot] \
        thermal=\(hw.thermalState ?? "nil") \
        mem=\(hw.memoryAvailableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "nil") \
        accelerator=\(hw.acceleratorActual?.rawValue ?? "nil") \
        battery=\(hw.batteryLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "nil") \
        charging=\(hw.batteryCharging.map { "\($0)" } ?? "nil") \
        gpuBusy=\(hw.gpuBusyPercent.map { "\($0)%" } ?? "nil") \
        cpuTemp=\(hw.cpuTempCelsius.map { String(format: "%.1f°C", $0) } ?? "nil") \
        cpuFreq=\(hw.cpuFreqMhz.map { "\($0) MHz" } ?? "nil") \
        cpuFreqMax=\(hw.cpuFreqMaxMhz.map { "\($0) MHz" } ?? "nil")
        """)

        // Send an inference event to the backend — the client attaches the hardware snapshot automatically.
        let client = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
            builder.flushIntervalMs = 60_000
        }
        defer { client.close(timeoutMs: 5_000) }

        let handle = client.registerModel(
            modelId: "live-hw-snapshot-model",
            info: ModelInfo(
                modelName: "HW Snapshot Test",
                modelVersion: "1.0",
                modelSource: "local",
                modelFormat: "coreml"
            )
        )

        _ = handle.trackInference(durationMs: 8, inputModality: .image, outputModality: .classification)

        XCTAssertGreaterThan(client.pendingCount, 0)
        client.flush(timeoutMs: 5_000)
        XCTAssertEqual(client.pendingCount, 0, "Expected queue to be drained after hardware snapshot flush")
    }

    private func requireLiveTestsEnabled() throws {
        let enabled = ProcessInfo.processInfo.environment["WILDEDGE_LIVE_TESTS"]?.lowercased()
        let isEnabled = enabled == "1" || enabled == "true" || enabled == "yes"
        if !isEnabled {
            throw XCTSkip("Skipping live backend tests. Set WILDEDGE_LIVE_TESTS=true to enable.")
        }
    }
}
