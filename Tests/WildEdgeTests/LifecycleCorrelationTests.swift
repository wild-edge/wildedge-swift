import XCTest
@testable import WildEdge

final class LifecycleCorrelationTests: XCTestCase {

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
            info: ModelInfo(modelName: "m1", modelSource: "local", modelFormat: "coreml"),
            publishSynchronously: true
        )
        return (handle, queue)
    }

    private func events(_ queue: EventQueue, type: String) -> [[String: Any]] {
        queue.peekMany(100).filter { $0["event_type"] as? String == type }
    }

    /// Emits one of each lifecycle event, all with the same arguments.
    private func emitLifecycle(_ handle: ModelHandle, traceId: String? = nil, parentSpanId: String? = nil,
                               runId: String? = nil, agentId: String? = nil) {
        handle.trackLoad(durationMs: 1, traceId: traceId, parentSpanId: parentSpanId, runId: runId, agentId: agentId)
        handle.trackDownload(sourceUrl: "https://x", sourceType: "huggingface", fileSizeBytes: 1, downloadedBytes: 1,
                             durationMs: 1, traceId: traceId, parentSpanId: parentSpanId, runId: runId, agentId: agentId)
        handle.trackFeedback(.accepted, relatedInferenceId: "i1",
                             traceId: traceId, parentSpanId: parentSpanId, runId: runId, agentId: agentId)
        handle.trackError(errorCode: "E", traceId: traceId, parentSpanId: parentSpanId, runId: runId, agentId: agentId)
        handle.trackUnload(traceId: traceId, parentSpanId: parentSpanId, runId: runId, agentId: agentId)
    }

    private static let lifecycleTypes = ["model_load", "model_download", "feedback", "error", "model_unload"]

    func testExplicitCorrelationLandsOnEveryLifecycleEvent() throws {
        let (handle, queue) = makeHandle()

        emitLifecycle(handle, traceId: "t1", parentSpanId: "s1", runId: "r1", agentId: "a1")

        for type in Self.lifecycleTypes {
            let event = try XCTUnwrap(events(queue, type: type).first, type)
            XCTAssertEqual(event["trace_id"] as? String, "t1", type)
            XCTAssertEqual(event["parent_span_id"] as? String, "s1", type)
            XCTAssertEqual(event["run_id"] as? String, "r1", type)
            XCTAssertEqual(event["agent_id"] as? String, "a1", type)
        }
    }

    func testActiveSpanSuppliesTraceAndParent() throws {
        let (handle, queue) = makeHandle()

        let span = client.trace("scan", kind: .custom, attributes: nil) { ctx -> SpanContext in
            emitLifecycle(handle, runId: "r1")
            return ctx
        }

        for type in Self.lifecycleTypes {
            let event = try XCTUnwrap(events(queue, type: type).first, type)
            XCTAssertEqual(event["trace_id"] as? String, span.traceId, type)
            XCTAssertEqual(event["parent_span_id"] as? String, span.spanId, type)
            XCTAssertEqual(event["run_id"] as? String, "r1", type)
        }
    }

    func testExplicitArgumentsOverrideActiveSpan() throws {
        let (handle, queue) = makeHandle()

        client.trace("scan", kind: .custom, attributes: nil) { _ in
            handle.trackLoad(durationMs: 1, traceId: "t-explicit", parentSpanId: "s-explicit")
        }

        let load = try XCTUnwrap(events(queue, type: "model_load").first)
        XCTAssertEqual(load["trace_id"] as? String, "t-explicit")
        XCTAssertEqual(load["parent_span_id"] as? String, "s-explicit")
    }

    func testNoCorrelationOutsideAnyTrace() throws {
        let (handle, queue) = makeHandle()

        emitLifecycle(handle)

        for type in Self.lifecycleTypes {
            let event = try XCTUnwrap(events(queue, type: type).first, type)
            for key in ["trace_id", "parent_span_id", "run_id", "agent_id"] {
                XCTAssertNil(event[key], "\(type).\(key)")
            }
        }
    }
}
