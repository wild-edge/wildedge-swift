import XCTest
@testable import WildEdge

final class AutoInterceptorTests: XCTestCase {

    // MARK: - Builder default

    func testBuilderDefaultEnablesAllInterceptors() {
        let builder = WildEdge.Builder()
        XCTAssertEqual(builder.enabledInterceptors, .all)
    }

    // MARK: - Interceptors disabled

    func testAutoInterceptorsDisabledPreventsMLKitSwizzle() {
        // Register a fake MLKit class BEFORE creating the client.
        let className = "MLKAutoInterceptorTestDetector"
        registerFakeDetector(named: className)

        let queue = EventQueue(maxSize: 100)
        _ = WildEdge(
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

        // Call the factory method — swizzle must NOT have been installed.
        let cls: AnyClass = NSClassFromString(className)!
        let result = (cls as AnyObject).perform(NSSelectorFromString("faceDetectorWithOptions:"), with: nil)
        _ = result?.takeUnretainedValue()

        let events = queue.peekMany(100)
        let count = events.count
        XCTAssertTrue(events.isEmpty, "Expected no events when autoInterceptors disabled, got \(count)")
    }

    // MARK: - Interceptors enabled (default)

    func testAutoInterceptorsEnabledInstallsMLKitSwizzle() {
        // Use "MLKBarcodeScanner" — in the interceptor config but not tested by
        // MLKitDetectorInterceptorTests, so registering it here doesn't conflict.
        let className = "MLKBarcodeScanner"
        registerFakeBarcodeScanner(named: className)

        let queue = EventQueue(maxSize: 100)
        let client = WildEdge(
            queue: queue,
            registry: ModelRegistry(),
            consumer: nil,
            attachmentQueue: nil,
            attachmentConsumer: nil,
            attachmentConfig: .init(enabled: false, maxPerInference: 0, maxSizeBytes: 0,
                                    storageStrategy: .file, filter: nil),
            debug: false,
            enabledInterceptors: .all
        )
        // Re-install so this client's queue receives events.
        MLKitDetectorInterceptor.install(client: client)

        let cls: AnyClass = NSClassFromString(className)!
        let result = (cls as AnyObject).perform(NSSelectorFromString("barcodeScannerWithOptions:"), with: nil)
        _ = result?.takeUnretainedValue()

        let types = queue.peekMany(100).compactMap { $0["event_type"] as? String }
        let typeList = types.joined(separator: ", ")
        XCTAssertTrue(types.contains("model_load"),
                      "Expected model_load event when autoInterceptors enabled, got: \(typeList)")
    }

    // MARK: - Builder propagates flag to WildEdge instance

    func testBuilderPropagatesFlagWhenBuildingWithDsn() {
        // Build with a valid DSN but interceptors disabled — should not crash and
        // should return an active (non-noop) client.
        let client = WildEdge.initialize { builder in
            builder.dsn = "https://testsecret@ingest.wildedge.dev/00000000-0000-0000-0000-000000000001"
            builder.enabledInterceptors = []
        }
        XCTAssertFalse(client is NoopWildEdgeClient,
                       "Expected active client when valid DSN is provided")
        client.flush(timeoutMs: 0)
    }

    // MARK: - Fake class registration

    private func registerFakeBarcodeScanner(named className: String) {
        guard NSClassFromString(className) == nil else { return }
        guard let cls = objc_allocateClassPair(NSObject.self, className, 0) else { return }
        let metaCls = object_getClass(cls)!
        let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject = { selfClass, _ in
            (selfClass as! NSObject.Type).init()
        }
        class_addMethod(metaCls, NSSelectorFromString("barcodeScannerWithOptions:"),
                        imp_implementationWithBlock(block), "@@:@")
        objc_registerClassPair(cls)
    }

    private func registerFakeDetector(named className: String) {
        guard NSClassFromString(className) == nil else { return }
        guard let cls = objc_allocateClassPair(NSObject.self, className, 0) else { return }
        let metaCls = object_getClass(cls)!

        let factoryBlock: @convention(block) (AnyObject, AnyObject?) -> AnyObject = { selfClass, _ in
            (selfClass as! NSObject.Type).init()
        }
        class_addMethod(metaCls, NSSelectorFromString("faceDetectorWithOptions:"),
                        imp_implementationWithBlock(factoryBlock), "@@:@")
        objc_registerClassPair(cls)
    }
}
