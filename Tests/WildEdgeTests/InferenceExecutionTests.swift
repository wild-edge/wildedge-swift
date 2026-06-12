import XCTest
@testable import WildEdge

private struct ModelFailedError: Error {
    let message: String
}

final class InferenceExecutionTests: XCTestCase {

    private var client: WildEdge!

    override func tearDown() {
        client = nil
        super.tearDown()
    }

    private func makeHandle() -> (ModelHandle, EventQueue) {
        let queue = EventQueue(maxSize: 100)
        client = WildEdge(
            queue: queue,
            registry: ModelRegistry(),
            consumer: nil,
            attachmentQueue: nil,
            attachmentConsumer: nil,
            attachmentConfig: .init(enabled: false, maxPerInference: 0, maxSizeBytes: 0, storageStrategy: .file, filter: nil),
            debug: false
        )
        let handle = client.registerModel(
            modelId: "m1",
            info: ModelInfo(modelName: "m1", modelSource: "local", modelFormat: "tflite"),
            publishSynchronously: true
        )
        return (handle, queue)
    }

    private func inferenceMap(_ event: [String: Any]) -> [String: Any]? {
        event["inference"] as? [String: Any]
    }

    func testSuccessTracksInferenceAndReturnsResult() throws {
        let (handle, queue) = makeHandle()

        let result = try trackInferenceExecution(
            handle: handle,
            inputModality: .tensor,
            outputModality: .tensor
        ) { 42 }

        XCTAssertEqual(result, 42)
        let events = queue.peekMany(10)
        XCTAssertEqual(events.count, 1)
        let inference = try XCTUnwrap(inferenceMap(events[0]))
        XCTAssertEqual(inference["success"] as? Bool, true)
    }

    func testFailureTracksInferenceAndRethrowsOriginalError() {
        let (handle, queue) = makeHandle()

        XCTAssertThrowsError(try trackInferenceExecution(
            handle: handle,
            inputModality: .tensor,
            outputModality: .tensor
        ) {
            throw ModelFailedError(message: "model_failed")
        }) { error in
            XCTAssertEqual((error as? ModelFailedError)?.message, "model_failed")
        }

        let events = queue.peekMany(10)
        XCTAssertEqual(events.count, 1)
        let inference = inferenceMap(events[0])
        XCTAssertEqual(inference?["success"] as? Bool, false)
        XCTAssertEqual(inference?["error_code"] as? String, "ModelFailedError")
    }
}
