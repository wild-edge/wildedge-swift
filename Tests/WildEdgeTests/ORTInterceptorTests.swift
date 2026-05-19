import XCTest
@testable import WildEdge

// Tests ORTInterceptor swizzle logic using a dynamically-registered fake ORTSession class.
// No OnnxRuntimeBindings framework is needed — the interceptor resolves the class via
// NSClassFromString and works on any class with the right selectors.
final class ORTInterceptorTests: XCTestCase {

    private var queue: EventQueue!
    private var client: WildEdge!

    // MARK: - Setup

    // Reset once and register the fake class before any test in this class runs.
    // The swizzle is applied on the first install() call; subsequent calls only
    // update activeClient — so per-test queues receive the right events.
    override class func setUp() {
        super.setUp()
        ORTInterceptor._resetForTesting()
        registerFakeORTSession()
    }

    override func setUp() {
        super.setUp()
        queue = EventQueue(maxSize: 200)
        client = WildEdge(
            queue: queue,
            registry: ModelRegistry(),
            consumer: nil,
            attachmentQueue: nil,
            attachmentConsumer: nil,
            attachmentConfig: .init(enabled: false, maxPerInference: 0, maxSizeBytes: 0,
                                    storageStrategy: .file, filter: nil),
            debug: false,
            enabledInterceptors: []
        )
        // install() applies the swizzle on first call; subsequent calls only
        // redirect activeClient so this test's queue captures events.
        ORTInterceptor.install(client: client)
    }

    override func tearDown() {
        client = nil
        queue = nil
        super.tearDown()
    }

    // MARK: - Init swizzle → model_load

    func testInitEmitsModelLoadEvent() {
        let session = makeSession(modelPath: "/models/yolo.onnx")
        XCTAssertNotNil(session, "Fake init must return an object")

        let events = queue.peekMany(200)
        let types = events.compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("model_load"), "Expected model_load; got \(types)")
    }

    func testInitExtractsModelNameFromPath() {
        _ = makeSession(modelPath: "/path/to/mobilenet_v2.onnx")

        let event = queue.peekMany(200).first { $0["event_type"] as? String == "model_load" }
        XCTAssertNotNil(event, "Expected model_load event")
        let modelId = event?["model_id"] as? String
        XCTAssertEqual(modelId, "mobilenet_v2")
    }

    func testInitWithNoExtensionFallsBackToFullPath() {
        _ = makeSession(modelPath: "/models/mymodel")
        client.flush(timeoutMs: 100)

        let event = queue.peekMany(200).first { $0["event_type"] as? String == "model_load" }
        let modelId = event?["model_id"] as? String
        XCTAssertEqual(modelId, "mymodel")
    }

    // MARK: - Run swizzle → inference

    func testRunEmitsInferenceEvent() {
        let session = makeSession(modelPath: "/models/bert.onnx")!
        XCTAssertNotNil(ORTInterceptor.sessions[ObjectIdentifier(session)],
                        "Session must be registered in sessions after init")
        callRun(on: session)
        client.flush(timeoutMs: 100)

        let types = queue.peekMany(200).compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("inference"), "Expected inference; got \(types)")
    }

    func testRunInferenceHasTensorModalities() {
        let session = makeSession(modelPath: "/models/bert.onnx")!
        callRun(on: session)
        client.flush(timeoutMs: 100)

        let event = queue.peekMany(200).first { $0["event_type"] as? String == "inference" }
        let inference = event?["inference"] as? [String: Any]
        XCTAssertEqual(inference?["input_modality"] as? String, "tensor")
        XCTAssertEqual(inference?["output_modality"] as? String, "tensor")
    }

    // MARK: - Dealloc observer → model_unload

    func testDeallocEmitsModelUnloadEvent() {
        autoreleasepool {
            var session: AnyObject? = makeSession(modelPath: "/models/resnet.onnx")
            XCTAssertNotNil(session)
            session = nil  // ARC release → SessionObserver deinit → model_unload
        }
        client.flush(timeoutMs: 100)  // drain publishWorker.async

        let types = queue.peekMany(200).compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("model_unload"), "Expected model_unload; got \(types)")
    }

    // MARK: - Non-active client receives no events

    func testNonActiveClientReceivesNoEvents() {
        // Create a second queue that is NOT the activeClient.
        let sideQueue = EventQueue(maxSize: 100)
        let sideClient = WildEdge(
            queue: sideQueue,
            registry: ModelRegistry(),
            consumer: nil,
            attachmentQueue: nil,
            attachmentConsumer: nil,
            attachmentConfig: .init(enabled: false, maxPerInference: 0, maxSizeBytes: 0,
                                    storageStrategy: .file, filter: nil),
            debug: false,
            enabledInterceptors: []
        )
        _ = sideClient

        // The swizzle routes to activeClient (setUp's client), not sideClient.
        _ = makeSession(modelPath: "/models/side.onnx")
        XCTAssertTrue(sideQueue.peekMany(100).isEmpty,
                      "Side client's queue must not receive events")
        // Primary queue should have the event.
        let types = queue.peekMany(200).compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("model_load"))
    }

    // MARK: - Helpers

    @discardableResult
    private func makeSession(modelPath: String) -> AnyObject? {
        guard let cls = NSClassFromString("ORTSession") else {
            XCTFail("ORTSession not registered"); return nil
        }
        let instance = (cls as! NSObject.Type).init()
        let sel = NSSelectorFromString("initWithEnv:modelPath:sessionOptions:error:")
        guard let method = class_getInstanceMethod(cls, sel) else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, NSString,
                                            AnyObject?, AnyObject?) -> AnyObject?
        let fn = unsafeBitCast(method_getImplementation(method), to: InitFn.self)
        return fn(instance, sel, NSObject(), modelPath as NSString, nil, nil)
    }

    private func callRun(on session: AnyObject) {
        guard let cls = NSClassFromString("ORTSession") else { return }
        let sel = NSSelectorFromString("runWithInputs:outputNames:runOptions:error:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias RunFn = @convention(c) (AnyObject, Selector, NSDictionary, NSSet, AnyObject?, AnyObject?) -> NSDictionary?
        let fn = unsafeBitCast(method_getImplementation(method), to: RunFn.self)
        _ = fn(session, sel, NSDictionary(), NSSet(), nil, nil)
    }

    // MARK: - Fake class registration

    private static func registerFakeORTSession() {
        guard NSClassFromString("ORTSession") == nil else { return }
        guard let cls = objc_allocateClassPair(NSObject.self, "ORTSession", 0) else { return }

        // -initWithEnv:modelPath:sessionOptions:error: → returns self
        let initBlock: @convention(block) (AnyObject, AnyObject, NSString, AnyObject?,
                                           AnyObject?) -> AnyObject = {
            selfObj, _, _, _, _ in selfObj
        }
        class_addMethod(cls,
            NSSelectorFromString("initWithEnv:modelPath:sessionOptions:error:"),
            imp_implementationWithBlock(initBlock), "@@:@@@@")

        // -runWithInputs:outputNames:runOptions:error: → returns empty NSDictionary
        let runBlock: @convention(block) (AnyObject, NSDictionary, NSSet,
                                          AnyObject?, AnyObject?) -> NSDictionary = {
            _, _, _, _, _ in NSDictionary()
        }
        class_addMethod(cls,
            NSSelectorFromString("runWithInputs:outputNames:runOptions:error:"),
            imp_implementationWithBlock(runBlock), "@@:@@@@")

        objc_registerClassPair(cls)
    }
}
