import XCTest
@testable import WildEdge

// Tests MLKitDetectorInterceptor swizzle logic using dynamically-registered fake ObjC
// classes that mirror the MLKFaceDetector / MLKBarcodeScanner / MLKTextRecognizer API.
// No MLKit framework is needed — the interceptor uses NSClassFromString and works on
// any class with the right selectors.
final class MLKitDetectorInterceptorTests: XCTestCase {

    private var queue: EventQueue!
    private var client: WildEdge!

    // Fake class name matching one of the interceptor configs
    private let fakeClassName = "MLKFaceDetector"

    override func setUp() {
        super.setUp()
        // Register fake class BEFORE creating WildEdge so install() finds it and swizzles it.
        registerFakeFaceDetectorClass()
        queue = EventQueue(maxSize: 100)
        client = WildEdge(queue: queue, registry: ModelRegistry(), consumer: nil, debug: false)
    }

    override func tearDown() {
        client.close()
        client = nil
        queue = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testFactorySwizzleEmitsModelLoadEvent() {
        let cls: AnyClass = NSClassFromString(fakeClassName)!

        // Re-install so this client is the active one (install is idempotent for the class).
        MLKitDetectorInterceptor.install(client: client)

        // Call the factory class method — our swizzle should fire.
        let detector = (cls as AnyObject).perform(
            NSSelectorFromString("faceDetectorWithOptions:"), with: nil
        )?.takeUnretainedValue()
        XCTAssertNotNil(detector, "Factory method must return an object")

        let types = queue.peekMany(100).compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("model_load"), "Expected model_load; got \(types)")
    }

    func testProcessSwizzleEmitsInferenceEvent() {
        let cls: AnyClass = NSClassFromString(fakeClassName)!
        MLKitDetectorInterceptor.install(client: client)

        let detector = (cls as AnyObject).perform(
            NSSelectorFromString("faceDetectorWithOptions:"), with: nil
        )!.takeUnretainedValue()

        // Call processImage:completion: — swizzle wraps the completion and calls trackInference.
        let expectation = self.expectation(description: "completion called")
        let fakeImage = NSObject()
        let completionBlock: @convention(block) ([AnyObject]?, NSError?) -> Void = { _, _ in
            expectation.fulfill()
        }

        _ = detector.perform(
            NSSelectorFromString("processImage:completion:"),
            with: fakeImage,
            with: completionBlock as AnyObject
        )
        wait(for: [expectation], timeout: 2)

        let types = queue.peekMany(100).compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("inference"), "Expected inference; got \(types)")
    }

    func testResultsInImageEmitsInferenceEvent() {
        let cls: AnyClass = NSClassFromString(fakeClassName)!
        MLKitDetectorInterceptor.install(client: client)

        let detector = (cls as AnyObject).perform(
            NSSelectorFromString("faceDetectorWithOptions:"), with: nil
        )!.takeUnretainedValue()

        // Call synchronous resultsInImage:error:
        _ = detector.perform(
            NSSelectorFromString("resultsInImage:error:"),
            with: NSObject(),
            with: nil
        )

        let types = queue.peekMany(100).compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("inference"), "Expected inference from sync path; got \(types)")
    }

    func testProcessOutputMetaCountsArrayResults() {
        let cls: AnyClass = NSClassFromString(fakeClassName)!
        MLKitDetectorInterceptor.install(client: client)

        let detector = (cls as AnyObject).perform(
            NSSelectorFromString("faceDetectorWithOptions:"), with: nil
        )!.takeUnretainedValue()

        let expectation = self.expectation(description: "completion")
        let countBlock: @convention(block) ([AnyObject]?, NSError?) -> Void = { _, _ in expectation.fulfill() }
        _ = detector.perform(
            NSSelectorFromString("processImage:completion:"),
            with: NSObject(),
            with: countBlock as AnyObject
        )
        wait(for: [expectation], timeout: 2)

        // Fake implementation returns array of 3 NSObjects as "faces"
        let inferenceEvent = queue.peekMany(100).first { $0["event_type"] as? String == "inference" }
        let inference = inferenceEvent?["inference"] as? [String: Any]
        let outputMeta = inference?["output_meta"] as? [String: Any]
        XCTAssertEqual(outputMeta?["num_predictions"] as? Int, 3)
    }

    func testDeallocEmitsModelUnloadEvent() {
        let cls: AnyClass = NSClassFromString(fakeClassName)!
        MLKitDetectorInterceptor.install(client: client)

        autoreleasepool {
            _ = (cls as AnyObject).perform(
                NSSelectorFromString("faceDetectorWithOptions:"), with: nil
            )?.takeUnretainedValue()
            // detector goes out of scope here → dealloc fires
        }

        let types = queue.peekMany(100).compactMap { $0["event_type"] as? String }
        XCTAssertTrue(types.contains("model_unload"), "Expected model_unload; got \(types)")
    }

    func testNoClassLoadedIsNoop() {
        // A class name that was never registered — install must not crash.
        XCTAssertNil(NSClassFromString("MLKNonExistentDetector"))
        // install runs through allConfigs; unknown classes are skipped silently
        // (this test just ensures we don't crash)
    }

    // MARK: - Fake class registration

    // Registers a fake MLKFaceDetector ObjC class with:
    //   +faceDetectorWithOptions:  → returns a new instance
    //   -processImage:completion:  → calls completion with [NSObject, NSObject, NSObject]
    //   -resultsInImage:error:     → returns [NSObject] (array of 1)
    //   -dealloc                   → calls super
    private func registerFakeFaceDetectorClass() {
        guard NSClassFromString(fakeClassName) == nil else { return }

        guard let cls = objc_allocateClassPair(NSObject.self, fakeClassName, 0) else { return }
        let metaCls = object_getClass(cls)!

        // +faceDetectorWithOptions: → returns a new instance
        let factoryBlock: @convention(block) (AnyObject, AnyObject?) -> AnyObject = { selfClass, _ in
            let instance = (selfClass as! NSObject.Type).init()
            return instance
        }
        let factoryIMP = imp_implementationWithBlock(factoryBlock)
        class_addMethod(metaCls, NSSelectorFromString("faceDetectorWithOptions:"),
                        factoryIMP, "@@:@")

        // -processImage:completion: → fires completion with 3-element array after small delay
        let processBlock: @convention(block) (AnyObject, AnyObject, @escaping ([AnyObject]?, NSError?) -> Void) -> Void = {
            _, _, completion in
            let fakeResults: [AnyObject] = [NSObject(), NSObject(), NSObject()]
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                completion(fakeResults, nil)
            }
        }
        let processIMP = imp_implementationWithBlock(processBlock)
        class_addMethod(cls, NSSelectorFromString("processImage:completion:"),
                        processIMP, "v@:@@")

        // -resultsInImage:error: → returns single-element array synchronously
        let resultsBlock: @convention(block) (AnyObject, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray? = {
            _, _, _ in [NSObject()] as NSArray
        }
        let resultsIMP = imp_implementationWithBlock(resultsBlock)
        class_addMethod(cls, NSSelectorFromString("resultsInImage:error:"),
                        resultsIMP, "@@:@@")

        objc_registerClassPair(cls)
    }
}
