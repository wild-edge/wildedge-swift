import Foundation
import ObjectiveC

// Intercepts all MLKit vision detectors via ObjC runtime swizzling.
// Uses NSClassFromString so no MLKit import is needed — each entry is a
// no-op when that particular detector class is not linked.
// install(client:) is called from WildEdge.init.
internal final class MLKitDetectorInterceptor {

    // MARK: - Config

    struct Config {
        let className: String
        let modelId: String
        let modelName: String
        let outputModality: OutputModality
        // Class method selectors that create detector instances.
        // All must accept 0 or 1 argument (options or none).
        let factorySelectors: [String]
    }

    static let allConfigs: [Config] = [
        Config(
            className: "MLKFaceDetector",
            modelId: "mlkit-face-detector",
            modelName: "Face Detector",
            outputModality: .detection,
            factorySelectors: ["faceDetectorWithOptions:", "faceDetector"]
        ),
        Config(
            className: "MLKObjectDetector",
            modelId: "mlkit-object-detector",
            modelName: "Object Detector",
            outputModality: .detection,
            factorySelectors: ["objectDetectorWithOptions:"]
        ),
        Config(
            className: "MLKImageLabeler",
            modelId: "mlkit-image-labeler",
            modelName: "Image Labeler",
            outputModality: .classification,
            factorySelectors: ["imageLabelerWithOptions:"]
        ),
        Config(
            className: "MLKTextRecognizer",
            modelId: "mlkit-text-recognizer",
            modelName: "Text Recognizer",
            outputModality: .generation,
            factorySelectors: ["textRecognizerWithOptions:"]
        ),
        Config(
            className: "MLKBarcodeScanner",
            modelId: "mlkit-barcode-scanner",
            modelName: "Barcode Scanner",
            outputModality: .detection,
            factorySelectors: ["barcodeScannerWithOptions:", "barcodeScanner"]
        ),
        Config(
            className: "MLKPoseDetector",
            modelId: "mlkit-pose-detector",
            modelName: "Pose Detector",
            outputModality: .detection,
            factorySelectors: ["poseDetectorWithOptions:"]
        ),
    ]

    // MARK: - Shared state

    private static let lock = NSLock()
    private static var installed = false
    private static weak var activeClient: WildEdge?

    // Shared across all detector classes — ObjectIdentifier is globally unique per live object.
    private static var handles: [ObjectIdentifier: ModelHandle] = [:]
    private static var observerKey: UInt8 = 0

    // Original IMPs keyed by "ClassName:selector"
    private static var originalFactoryIMPs: [String: IMP] = [:]
    private static var originalProcessIMPs: [String: IMP] = [:]
    private static var originalResultsIMPs: [String: IMP] = [:]

    // MARK: - Install

    static func install(client: WildEdge) {
        lock.lock()
        activeClient = client
        let alreadyInstalled = installed
        if !installed { installed = true }
        lock.unlock()

        guard !alreadyInstalled else { return }

        let debug = ProcessInfo.processInfo.environment["WILDEDGE_DEBUG"] == "true"
        for config in allConfigs {
            guard let cls = NSClassFromString(config.className) else { continue }
            if debug { print("[wildedge] MLKitDetectorInterceptor: swizzling \(config.className)") }
            installFactory(on: cls, config: config)
            installProcess(on: cls, config: config)
            installResults(on: cls, config: config)
        }
    }

    // MARK: - Factory swizzle

    private static func installFactory(on cls: AnyClass, config: Config) {
        for selName in config.factorySelectors {
            let sel = NSSelectorFromString(selName)
            guard let method = class_getClassMethod(cls, sel) else { continue }

            let impKey = "\(config.className):\(selName)"
            originalFactoryIMPs[impKey] = method_getImplementation(method)

            let hasArg = selName.hasSuffix(":")
            let capturedConfig = config
            let capturedKey = impKey

            if hasArg {
                typealias FactoryIMP = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject
                let capturedSel = sel
                let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject = { selfClass, options in
                    let start = CFAbsoluteTimeGetCurrent()
                    let imp = unsafeBitCast(
                        MLKitDetectorInterceptor.originalFactoryIMPs[capturedKey]!, to: FactoryIMP.self)
                    let result = imp(selfClass, capturedSel, options)
                    let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))
                    MLKitDetectorInterceptor.registerDetector(result, config: capturedConfig, durationMs: durationMs)
                    return result
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            } else {
                typealias FactoryIMP = @convention(c) (AnyObject, Selector) -> AnyObject
                let capturedSel = sel
                let block: @convention(block) (AnyObject) -> AnyObject = { selfClass in
                    let start = CFAbsoluteTimeGetCurrent()
                    let imp = unsafeBitCast(
                        MLKitDetectorInterceptor.originalFactoryIMPs[capturedKey]!, to: FactoryIMP.self)
                    let result = imp(selfClass, capturedSel)
                    let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))
                    MLKitDetectorInterceptor.registerDetector(result, config: capturedConfig, durationMs: durationMs)
                    return result
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
        }
    }

    // MARK: - processImage:completion: swizzle (async)

    private static func installProcess(on cls: AnyClass, config: Config) {
        let sel = NSSelectorFromString("processImage:completion:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }

        let impKey = config.className
        originalProcessIMPs[impKey] = method_getImplementation(method)

        // Completion delivers either NSArray<*>* or a single MLKText* depending on the detector.
        // We use AnyObject? as the unified type and count results uniformly below.
        typealias ProcessIMP = @convention(c) (
            AnyObject, Selector, AnyObject, @escaping (AnyObject?, NSError?) -> Void
        ) -> Void

        let capturedSel = sel
        let capturedKey = impKey
        let capturedModality = config.outputModality

        let block: @convention(block) (
            AnyObject, AnyObject, @escaping (AnyObject?, NSError?) -> Void
        ) -> Void = { selfDetector, image, completion in
            let start = CFAbsoluteTimeGetCurrent()

            let handle: ModelHandle? = {
                MLKitDetectorInterceptor.lock.lock()
                defer { MLKitDetectorInterceptor.lock.unlock() }
                return MLKitDetectorInterceptor.handles[ObjectIdentifier(selfDetector)]
            }()

            let imp = unsafeBitCast(
                MLKitDetectorInterceptor.originalProcessIMPs[capturedKey]!, to: ProcessIMP.self)

            imp(selfDetector, capturedSel, image) { result, error in
                let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))
                if let handle {
                    handle.trackInference(
                        durationMs: durationMs,
                        inputModality: .image,
                        outputModality: capturedModality,
                        success: error == nil,
                        errorCode: error.map { "mlkit_\($0.code)" },
                        outputMeta: error == nil
                            ? MLKitDetectorInterceptor.outputMeta(from: result)
                            : nil
                    )
                }
                completion(result, error)
            }
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - resultsInImage:error: swizzle (synchronous)

    private static func installResults(on cls: AnyClass, config: Config) {
        let sel = NSSelectorFromString("resultsInImage:error:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }

        let impKey = config.className
        originalResultsIMPs[impKey] = method_getImplementation(method)

        typealias ResultsIMP = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject?

        let capturedSel = sel
        let capturedKey = impKey
        let capturedModality = config.outputModality

        let block: @convention(block) (
            AnyObject, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject? = { selfDetector, image, errorPtr in
            let start = CFAbsoluteTimeGetCurrent()
            let imp = unsafeBitCast(
                MLKitDetectorInterceptor.originalResultsIMPs[capturedKey]!, to: ResultsIMP.self)
            let result = imp(selfDetector, capturedSel, image, errorPtr)
            let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))

            let handle: ModelHandle? = {
                MLKitDetectorInterceptor.lock.lock()
                defer { MLKitDetectorInterceptor.lock.unlock() }
                return MLKitDetectorInterceptor.handles[ObjectIdentifier(selfDetector)]
            }()

            if let handle {
                let failed = errorPtr?.pointee != nil
                handle.trackInference(
                    durationMs: durationMs,
                    inputModality: .image,
                    outputModality: capturedModality,
                    success: !failed,
                    errorCode: failed ? errorPtr?.pointee.map { "mlkit_\($0.code)" } : nil,
                    outputMeta: !failed ? MLKitDetectorInterceptor.outputMeta(from: result) : nil
                )
            }
            return result
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Helpers

    // Counts results uniformly: NSArray → element count, single object → 1, nil → 0.
    private static func outputMeta(from result: AnyObject?) -> [String: Any]? {
        guard let result else { return DetectionOutputMeta(numPredictions: 0).toMap() }
        let count = (result as? [AnyObject])?.count ?? 1
        return DetectionOutputMeta(numPredictions: count).toMap()
    }

    private static func registerDetector(_ detector: AnyObject, config: Config, durationMs: Int) {
        let client: WildEdge? = {
            lock.lock()
            defer { lock.unlock() }
            return activeClient
        }()
        guard let client else { return }

        let handle = client.registerModel(
            modelId: config.modelId,
            info: ModelInfo(
                modelName: config.modelName,
                modelSource: "on-device",
                modelFormat: "mlkit"
            )
        )
        handle.trackLoad(durationMs: durationMs)

        let id = ObjectIdentifier(detector)
        lock.lock()
        handles[id] = handle
        lock.unlock()

        let observer = DetectorObserver(detectorId: id, handle: handle)
        objc_setAssociatedObject(detector, &observerKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - Dealloc observer

    private final class DetectorObserver {
        private let detectorId: ObjectIdentifier
        private let handle: ModelHandle
        init(detectorId: ObjectIdentifier, handle: ModelHandle) {
            self.detectorId = detectorId
            self.handle = handle
        }
        deinit {
            MLKitDetectorInterceptor.lock.lock()
            MLKitDetectorInterceptor.handles.removeValue(forKey: detectorId)
            MLKitDetectorInterceptor.lock.unlock()
            handle.trackUnload(reason: "dealloc")
        }
    }
}
