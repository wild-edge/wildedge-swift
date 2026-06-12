import Foundation
import ObjectiveC

// Intercepts TFLInterpreter (TensorFlowLiteObjC) init and invoke via ObjC
// runtime method replacement. Uses NSClassFromString so no TFLite import is
// needed — install() is a no-op when TFLInterpreter is not linked.
// install(client:) is called from WildEdge.init alongside the ORT and MLKit
// interceptors.
internal final class TFLInterceptor {

    // MARK: - State

    private static let lock = NSLock()
    private static var installed = false
    private static var originalInitWithPathIMP: IMP?
    private static var originalInitWithPathOptionsIMP: IMP?
    private static var originalInvokeIMP: IMP?

    // Always resolved dynamically so swizzles work even when installed before a DSN is set.
    private static var activeClient: WildEdge? { WildEdge.shared as? WildEdge }

    private static var interpreters: [ObjectIdentifier: ModelHandle] = [:]
    private static var observerKey: UInt8 = 0

    // MARK: - Lifecycle

    static func install(client: WildEdge) {
        installSwizzles()
    }

    static func installSwizzles() {
        lock.lock()
        let alreadyInstalled = installed
        if !installed { installed = true }
        lock.unlock()

        guard !alreadyInstalled else { return }
        guard let cls = NSClassFromString("TFLInterpreter") else { return }
        installInitSwizzle(on: cls)
        installInvokeSwizzle(on: cls)
    }

    // MARK: - Init swizzle

    private static func installInitSwizzle(on cls: AnyClass) {
        // initWithModelPath:options:error: — 3 args after self
        let selWithOptions = NSSelectorFromString("initWithModelPath:options:error:")
        if let method = class_getInstanceMethod(cls, selWithOptions) {
            originalInitWithPathOptionsIMP = method_getImplementation(method)

            typealias IMP3 = @convention(c) (
                AnyObject, Selector, NSString, AnyObject?,
                AutoreleasingUnsafeMutablePointer<NSError?>?
            ) -> AnyObject?

            let capturedSel = selWithOptions
            let capturedOrig = originalInitWithPathOptionsIMP!
            let block: @convention(block) (
                AnyObject, NSString, AnyObject?,
                AutoreleasingUnsafeMutablePointer<NSError?>?
            ) -> AnyObject? = { selfObj, modelPath, options, errorPtr in
                let start = CFAbsoluteTimeGetCurrent()
                let result = unsafeBitCast(capturedOrig, to: IMP3.self)(selfObj, capturedSel, modelPath, options, errorPtr)
                let ms = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))
                TFLInterceptor.didInit(result: result, modelPath: modelPath as String, durationMs: ms, errorPtr: errorPtr)
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        // initWithModelPath:error: — 2 args after self (different signature!)
        let selNoOptions = NSSelectorFromString("initWithModelPath:error:")
        if let method = class_getInstanceMethod(cls, selNoOptions) {
            originalInitWithPathIMP = method_getImplementation(method)

            typealias IMP2 = @convention(c) (
                AnyObject, Selector, NSString,
                AutoreleasingUnsafeMutablePointer<NSError?>?
            ) -> AnyObject?

            let capturedSel = selNoOptions
            let capturedOrig = originalInitWithPathIMP!
            let block: @convention(block) (
                AnyObject, NSString,
                AutoreleasingUnsafeMutablePointer<NSError?>?
            ) -> AnyObject? = { selfObj, modelPath, errorPtr in
                let start = CFAbsoluteTimeGetCurrent()
                let result = unsafeBitCast(capturedOrig, to: IMP2.self)(selfObj, capturedSel, modelPath, errorPtr)
                let ms = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))
                TFLInterceptor.didInit(result: result, modelPath: modelPath as String, durationMs: ms, errorPtr: errorPtr)
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    private static func didInit(
        result: AnyObject?,
        modelPath: String,
        durationMs: Int,
        errorPtr: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) {
        guard let result else { return }
        guard let client = activeClient else { return }

        let failed = errorPtr?.pointee != nil
        let (modelId, info) = modelIdentity(from: modelPath)
        let handle = client.registerModel(modelId: modelId, info: info)
        handle.trackLoad(
            durationMs: durationMs,
            success: !failed,
            errorCode: failed ? (errorPtr?.pointee.map { "tfl_\($0.code)" } ?? "tfl_init_failed") : nil
        )

        let interpreterId = ObjectIdentifier(result)
        lock.lock()
        interpreters[interpreterId] = handle
        lock.unlock()

        attachObserver(to: result, interpreterId: interpreterId, handle: handle)
    }

    // MARK: - Invoke swizzle

    private static func installInvokeSwizzle(on cls: AnyClass) {
        let sel = NSSelectorFromString("invokeWithError:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        originalInvokeIMP = method_getImplementation(method)

        typealias InvokeIMP = @convention(c) (
            AnyObject, Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Bool

        let capturedSel = sel
        let block: @convention(block) (
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Bool = { interpreter, errorPtr in
            let start = CFAbsoluteTimeGetCurrent()
            let imp = unsafeBitCast(TFLInterceptor.originalInvokeIMP!, to: InvokeIMP.self)
            let success = imp(interpreter, capturedSel, errorPtr)
            let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))

            let handle: ModelHandle? = {
                TFLInterceptor.lock.lock()
                defer { TFLInterceptor.lock.unlock() }
                return TFLInterceptor.interpreters[ObjectIdentifier(interpreter)]
            }()
            guard let handle else { return success }

            handle.trackInference(
                durationMs: durationMs,
                inputModality: .tensor,
                outputModality: .tensor,
                success: success,
                errorCode: success
                    ? nil
                    : (errorPtr?.pointee.map { "tfl_\($0.code)" } ?? "tfl_invoke_failed")
            )
            return success
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Model identity

    private static func modelIdentity(from path: String) -> (modelId: String, info: ModelInfo) {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let modelId = stem.isEmpty ? path : stem
        let ext = url.pathExtension
        return (modelId, ModelInfo(
            modelName: modelId,
            modelSource: "local",
            modelFormat: ext.isEmpty ? "tflite" : ext,
            quantization: inferQuantization(from: path)
        ))
    }

    // MARK: - Dealloc observer

    private static func attachObserver(to interpreter: AnyObject, interpreterId: ObjectIdentifier, handle: ModelHandle) {
        let observer = InterpreterObserver(interpreterId: interpreterId, handle: handle)
        objc_setAssociatedObject(
            interpreter,
            &TFLInterceptor.observerKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private final class InterpreterObserver {
        private let interpreterId: ObjectIdentifier
        private let handle: ModelHandle
        init(interpreterId: ObjectIdentifier, handle: ModelHandle) {
            self.interpreterId = interpreterId
            self.handle = handle
        }
        deinit {
            TFLInterceptor.lock.lock()
            TFLInterceptor.interpreters.removeValue(forKey: interpreterId)
            TFLInterceptor.lock.unlock()
            handle.trackUnload(reason: "dealloc")
        }
    }
}
