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

    /// Span and memory-warning events are published asynchronously, so drain
    /// the publish queue first.
    private func events(_ queue: EventQueue, type: String) -> [[String: Any]] {
        client.flush(timeoutMs: 0)
        return queue.peekMany(100).filter { $0["event_type"] as? String == type }
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

    func testTraceRunIdReachesEveryEventInside() throws {
        let (handle, queue) = makeHandle()

        let span = client.trace("scan", runId: "r1", agentId: "a1") { ctx -> SpanContext in
            handle.trackInference(durationMs: 1)
            emitLifecycle(handle)
            return ctx
        }

        for type in ["inference"] + Self.lifecycleTypes {
            let event = try XCTUnwrap(events(queue, type: type).first, type)
            XCTAssertEqual(event["run_id"] as? String, "r1", type)
            XCTAssertEqual(event["agent_id"] as? String, "a1", type)
            XCTAssertEqual(event["trace_id"] as? String, span.traceId, type)
            XCTAssertEqual(event["parent_span_id"] as? String, span.spanId, type)
        }
        let spanEvent = try XCTUnwrap(events(queue, type: "span").first)
        XCTAssertEqual(spanEvent["run_id"] as? String, "r1")
        XCTAssertEqual(spanEvent["agent_id"] as? String, "a1")
    }

    func testChildSpanInheritsRunAndParentJoinsTrace() throws {
        let (handle, queue) = makeHandle()

        let root = client.trace("scan", runId: "r1") { $0 }
        let (child, grandchild) = client.trace("classify", parent: root) { child in
            child.span("decode") { grandchild -> (SpanContext, SpanContext) in
                handle.trackInference(durationMs: 1)
                return (child, grandchild)
            }
        }

        XCTAssertEqual(child.traceId, root.traceId)
        XCTAssertEqual(child.parentSpanId, root.spanId)
        XCTAssertEqual(child.runId, "r1")
        XCTAssertEqual(grandchild.runId, "r1")
        let inference = try XCTUnwrap(events(queue, type: "inference").first)
        XCTAssertEqual(inference["run_id"] as? String, "r1")
        XCTAssertEqual(inference["parent_span_id"] as? String, grandchild.spanId)
    }

    func testExplicitRunIdOverridesTrace() throws {
        let (handle, queue) = makeHandle()

        client.trace("scan", runId: "r-trace") { _ in
            handle.trackInference(durationMs: 1, runId: "r-explicit")
            handle.trackLoad(durationMs: 1, runId: "r-explicit")
        }

        XCTAssertEqual(events(queue, type: "inference").first?["run_id"] as? String, "r-explicit")
        XCTAssertEqual(events(queue, type: "model_load").first?["run_id"] as? String, "r-explicit")
    }

    func testTraceWithoutRunIdSendsNone() throws {
        let (handle, queue) = makeHandle()

        client.trace("warmup") { _ in handle.trackInference(durationMs: 1) }

        XCTAssertNil(events(queue, type: "inference").first?["run_id"])
        XCTAssertNil(events(queue, type: "span").first?["run_id"])
    }

    func testMemoryWarningTakesCorrelation() throws {
        let (_, queue) = makeHandle()

        client.trackMemoryWarning(level: .critical, memoryAvailableBytes: 1, activeModelIds: [],
                                  triggeredUnload: false)
        let span = client.trace("scan", runId: "r1", agentId: "a1") { ctx -> SpanContext in
            client.trackMemoryWarning(level: .critical, memoryAvailableBytes: 1, activeModelIds: ["m1"],
                                      triggeredUnload: true, unloadedModelId: "m1")
            client.trackMemoryWarning(level: .critical, memoryAvailableBytes: 1, activeModelIds: [],
                                      triggeredUnload: false, runId: "r-explicit")
            return ctx
        }

        let warnings = events(queue, type: "memory_warning")
        XCTAssertEqual(warnings.count, 3)
        for key in ["trace_id", "parent_span_id", "run_id", "agent_id"] {
            XCTAssertNil(warnings[0][key], "outside trace: \(key)")
        }
        XCTAssertEqual(warnings[1]["trace_id"] as? String, span.traceId)
        XCTAssertEqual(warnings[1]["parent_span_id"] as? String, span.spanId)
        XCTAssertEqual(warnings[1]["run_id"] as? String, "r1")
        XCTAssertEqual(warnings[1]["agent_id"] as? String, "a1")
        XCTAssertEqual(warnings[2]["run_id"] as? String, "r-explicit")
    }

    func testInferenceSpanIdDefaultsToInferenceId() throws {
        let (handle, queue) = makeHandle()

        let inferenceId = handle.trackInference(durationMs: 1)
        handle.trackInference(durationMs: 1, spanId: "s-explicit")

        let inferences = events(queue, type: "inference")
        let first = try XCTUnwrap(inferences.first?["inference"] as? [String: Any])
        XCTAssertEqual(first["inference_id"] as? String, inferenceId)
        XCTAssertEqual(inferences.first?["span_id"] as? String, inferenceId)
        XCTAssertEqual(inferences.last?["span_id"] as? String, "s-explicit")
    }

    func testAsyncTraceSurvivesAwaitAndChildTasks() async throws {
        let (handle, queue) = makeHandle()

        let scan = try await client.trace("scan", runId: "r1") { scan -> SpanContext in
            try await Task.sleep(nanoseconds: 1_000_000)
            handle.trackLoad(durationMs: 1)
            await Task.yield()
            async let child: Void = { handle.trackError(errorCode: "E") }()
            await child
            await scan.span("recognize") { _ in
                await Task.yield()
                handle.trackInference(durationMs: 1)
            }
            return scan
        }

        for type in ["model_load", "error"] {
            let event = try XCTUnwrap(events(queue, type: type).first, type)
            XCTAssertEqual(event["run_id"] as? String, "r1", type)
            XCTAssertEqual(event["trace_id"] as? String, scan.traceId, type)
            XCTAssertEqual(event["parent_span_id"] as? String, scan.spanId, type)
        }
        let inference = try XCTUnwrap(events(queue, type: "inference").first)
        let recognize = try XCTUnwrap(events(queue, type: "span").first {
            ($0["span"] as? [String: Any])?["name"] as? String == "recognize"
        })
        XCTAssertEqual(inference["run_id"] as? String, "r1")
        XCTAssertEqual(inference["parent_span_id"] as? String, recognize["span_id"] as? String)
        XCTAssertEqual(recognize["parent_span_id"] as? String, scan.spanId)
    }

    func testConcurrentRunsKeepTheirOwnRunId() async throws {
        let (handle, queue) = makeHandle()

        await withTaskGroup(of: Void.self) { group in
            for run in ["r1", "r2"] {
                group.addTask {
                    await self.client.trace("scan", runId: run) { _ in
                        for _ in 0..<20 {
                            await Task.yield()
                            handle.trackError(errorCode: run)
                        }
                    }
                }
            }
        }

        let errors = events(queue, type: "error")
        XCTAssertEqual(errors.count, 40)
        for event in errors {
            let code = (event["error"] as? [String: Any])?["error_code"] as? String
            XCTAssertEqual(event["run_id"] as? String, code)
        }
    }

    func testSpanContextCarriesCorrelationOntoAGCDQueue() throws {
        let (handle, queue) = makeHandle()
        let gcd = DispatchQueue(label: "test.gcd")

        let scan = client.trace("scan", runId: "r1") { $0 }
        gcd.sync {
            scan.span("detect") { _ in handle.trackInference(durationMs: 1) }
        }

        let inference = try XCTUnwrap(events(queue, type: "inference").first)
        XCTAssertEqual(inference["run_id"] as? String, "r1")
        XCTAssertEqual(inference["trace_id"] as? String, scan.traceId)
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
