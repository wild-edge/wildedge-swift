import XCTest
@testable import WildEdge

final class QueueConsumerTests: XCTestCase {
    func testEventQueueDropsOldestWhenMaxSizeReached() {
        let queue = EventQueue(maxSize: 2)
        queue.add(["event_id": "1"])
        queue.add(["event_id": "2"])
        queue.add(["event_id": "3"])

        XCTAssertEqual(queue.length(), 2)
        let ids = queue.peekMany(2).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["2", "3"])
    }

    func testConsumerFlushRemovesAcceptedEvents() {
        let queue = EventQueue(maxSize: 10)
        queue.add(makeEvent(modelId: "m1", queuedAt: nowMs()))
        queue.add(makeEvent(modelId: "m1", queuedAt: nowMs()))

        let registry = ModelRegistry()
        registry.register(modelId: "m1", info: ModelInfo(modelName: "M", modelVersion: "1", modelSource: "local", modelFormat: "coreml"))

        let transmitter = MockTransmitter(result: .success(IngestResponse(status: "accepted", batchId: "b1", eventsAccepted: 2, eventsRejected: 0)))

        let consumer = Consumer(
            queue: queue,
            transmitter: transmitter,
            device: DeviceInfo(
                deviceId: "test-device-id",
                deviceType: "ios",
                deviceModel: "iPhone",
                osVersion: "18.0",
                sdkVersion: "test-sdk",
                locale: "en-US",
                timezone: "UTC"
            ),
            registry: registry,
            sessionId: "s1",
            createdAt: isoNow(),
            batchSize: 10,
            flushIntervalMs: 60_000,
            maxEventAgeMs: 900_000,
            lowConfidenceThreshold: 0.5,
            logger: { _ in }
        )

        consumer.flush(timeoutMs: 1_000)

        XCTAssertEqual(queue.length(), 0)
        XCTAssertEqual(transmitter.sendCalls, 1)
    }

    func testConsumerFlushKeepsEventsOnTransportFailure() {
        let queue = EventQueue(maxSize: 10)
        queue.add(makeEvent(modelId: "m1", queuedAt: nowMs()))

        let transmitter = MockTransmitter(result: .failure(TransmitError.transport("network")))

        let consumer = Consumer(
            queue: queue,
            transmitter: transmitter,
            device: DeviceInfo(
                deviceId: "test-device-id",
                deviceType: "ios",
                deviceModel: "iPhone",
                osVersion: "18.0",
                sdkVersion: "test-sdk",
                locale: "en-US",
                timezone: "UTC"
            ),
            registry: ModelRegistry(),
            sessionId: "s1",
            createdAt: isoNow(),
            batchSize: 10,
            flushIntervalMs: 60_000,
            maxEventAgeMs: 900_000,
            lowConfidenceThreshold: 0.5,
            logger: { _ in }
        )

        consumer.flush(timeoutMs: 100)

        XCTAssertEqual(queue.length(), 1)
        XCTAssertGreaterThanOrEqual(transmitter.sendCalls, 1)
    }

    func testConsumerDropsStaleEventsWithoutSending() {
        let queue = EventQueue(maxSize: 10)
        queue.add(makeEvent(modelId: "m1", queuedAt: nowMs() - 10_000))

        let transmitter = MockTransmitter(result: .success(IngestResponse(status: "accepted", batchId: "b1", eventsAccepted: 1, eventsRejected: 0)))

        let consumer = Consumer(
            queue: queue,
            transmitter: transmitter,
            device: DeviceInfo(
                deviceId: "test-device-id",
                deviceType: "ios",
                deviceModel: "iPhone",
                osVersion: "18.0",
                sdkVersion: "test-sdk",
                locale: "en-US",
                timezone: "UTC"
            ),
            registry: ModelRegistry(),
            sessionId: "s1",
            createdAt: isoNow(),
            batchSize: 10,
            flushIntervalMs: 60_000,
            maxEventAgeMs: 1,
            lowConfidenceThreshold: 0.5,
            logger: { _ in }
        )

        consumer.flush(timeoutMs: 1_000)

        XCTAssertEqual(queue.length(), 0)
        XCTAssertEqual(transmitter.sendCalls, 0)
    }

    private func makeEvent(modelId: String, queuedAt: Int64) -> [String: Any] {
        var event = buildInferenceEvent(modelId: modelId, durationMs: 10)
        event["__we_queued_at"] = queuedAt
        return event
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private final class MockTransmitter: Transmitting {
    private let result: Result<IngestResponse, Error>
    private(set) var sendCalls = 0

    init(result: Result<IngestResponse, Error>) {
        self.result = result
    }

    func send(batchData: Data) throws -> IngestResponse {
        sendCalls += 1
        return try result.get()
    }
}
