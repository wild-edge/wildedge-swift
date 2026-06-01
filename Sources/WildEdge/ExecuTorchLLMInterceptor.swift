import Foundation
import ObjectiveC

// Intercepts ExecuTorchLLMTextRunner via ObjC runtime method replacement.
// Uses NSClassFromString so no ExecuTorch import is needed — install() is
// a no-op when the framework is not linked.
//
// Swizzled selectors:
//   initWithModelPath:tokenizerPath:                  — stores model path for use in loadWithError:
//   initWithModelPath:tokenizerPath:specialTokens:    — same (designated initializer)
//   loadWithError:                                    → trackLoad; stores ModelHandle on runner
//   generateWithPrompt:config:tokenCallback:error:    → trackInference (wraps callback to count tokens)
//   dealloc (via associated RunnerObserver)           → trackUnload
//
// ModelHandle is stored as an associated object on the runner instance so the
// generate swizzle can always retrieve it regardless of threading, without
// needing a separate dictionary.
internal final class ExecuTorchLLMInterceptor {

    // MARK: - Associated-object keys

    private static var modelPathKey: UInt8 = 0   // NSString — model .pte path
    private static var handleKey:    UInt8 = 1   // ModelHandle
    private static var observerKey:  UInt8 = 2   // RunnerObserver (triggers trackUnload on dealloc)

    // MARK: - Swizzle state

    private static let lock = NSLock()
    private static var installed = false

    private static var originalInitIMP:        IMP?   // initWithModelPath:tokenizerPath:
    private static var originalInitSpecialIMP: IMP?   // initWithModelPath:tokenizerPath:specialTokens:
    private static var originalLoadIMP:        IMP?   // loadWithError:
    private static var originalGenerateIMP:    IMP?   // generateWithPrompt:config:tokenCallback:error:

    // Always resolved lazily so the interceptor works even when installed before a DSN is set.
    private static var activeClient: WildEdge? { WildEdge.shared as? WildEdge }

    // MARK: - Install

    static func install(client: WildEdge) {
        lock.lock()
        let alreadyInstalled = installed
        if !installed { installed = true }
        lock.unlock()
        guard !alreadyInstalled else { return }
        guard let cls = NSClassFromString("ExecuTorchLLMTextRunner") else { return }
        installInitSwizzles(on: cls)
        installLoadSwizzle(on: cls)
        installGenerateSwizzle(on: cls)
    }

    // MARK: - Init swizzles (capture model path for use in loadWithError:)

    private static func installInitSwizzles(on cls: AnyClass) {
        // Designated: initWithModelPath:tokenizerPath:specialTokens:
        let selFull = NSSelectorFromString("initWithModelPath:tokenizerPath:specialTokens:")
        if let method = class_getInstanceMethod(cls, selFull) {
            originalInitSpecialIMP = method_getImplementation(method)
            typealias FullIMP = @convention(c) (AnyObject, Selector, NSString, NSString, NSArray) -> AnyObject?
            let capturedSel = selFull
            let capturedOrig = originalInitSpecialIMP!
            let block: @convention(block) (AnyObject, NSString, NSString, NSArray) -> AnyObject? = {
                selfObj, modelPath, tokenizerPath, specialTokens in
                let result = unsafeBitCast(capturedOrig, to: FullIMP.self)(
                    selfObj, capturedSel, modelPath, tokenizerPath, specialTokens)
                if let obj = result {
                    objc_setAssociatedObject(obj, &ExecuTorchLLMInterceptor.modelPathKey,
                                            modelPath, .OBJC_ASSOCIATION_COPY_NONATOMIC)
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        // Convenience: initWithModelPath:tokenizerPath:
        let selSimple = NSSelectorFromString("initWithModelPath:tokenizerPath:")
        if let method = class_getInstanceMethod(cls, selSimple) {
            originalInitIMP = method_getImplementation(method)
            typealias SimpleIMP = @convention(c) (AnyObject, Selector, NSString, NSString) -> AnyObject?
            let capturedSel = selSimple
            let capturedOrig = originalInitIMP!
            let block: @convention(block) (AnyObject, NSString, NSString) -> AnyObject? = {
                selfObj, modelPath, tokenizerPath in
                let result = unsafeBitCast(capturedOrig, to: SimpleIMP.self)(
                    selfObj, capturedSel, modelPath, tokenizerPath)
                if let obj = result {
                    objc_setAssociatedObject(obj, &ExecuTorchLLMInterceptor.modelPathKey,
                                            modelPath, .OBJC_ASSOCIATION_COPY_NONATOMIC)
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    // MARK: - Load swizzle

    private static func installLoadSwizzle(on cls: AnyClass) {
        let sel = NSSelectorFromString("loadWithError:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        originalLoadIMP = method_getImplementation(method)

        typealias LoadIMP = @convention(c) (
            AnyObject, Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

        let capturedSel = sel
        let block: @convention(block) (
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { runner, errorPtr in

            let start = CFAbsoluteTimeGetCurrent()
            let imp = unsafeBitCast(ExecuTorchLLMInterceptor.originalLoadIMP!, to: LoadIMP.self)
            let success = imp(runner, capturedSel, errorPtr)
            let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))

            guard let client = ExecuTorchLLMInterceptor.activeClient else { return success }

            let modelPath = objc_getAssociatedObject(runner, &ExecuTorchLLMInterceptor.modelPathKey)
                as? String ?? ""
            let (modelId, info) = ExecuTorchLLMInterceptor.modelIdentity(from: modelPath)
            let handle = client.registerModel(modelId: modelId, info: info)

            let failed = !success || errorPtr?.pointee != nil
            handle.trackLoad(
                durationMs: durationMs,
                accelerator: .cpu,
                success: !failed,
                errorCode: failed
                    ? (errorPtr?.pointee.map { "et_\($0.code)" } ?? "et_load_failed")
                    : nil
            )

            // Store the handle on the runner so the generate swizzle can retrieve
            // it without a dictionary lookup — avoids threading and lifetime issues.
            objc_setAssociatedObject(runner, &ExecuTorchLLMInterceptor.handleKey,
                                     handle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            // Attach a dealloc observer so we get trackUnload for free.
            objc_setAssociatedObject(runner, &ExecuTorchLLMInterceptor.observerKey,
                                     RunnerObserver(handle: handle),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return success
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Generate swizzle

    private final class TokenCounter { var value: Int = 0 }

    private static func installGenerateSwizzle(on cls: AnyClass) {
        let sel = NSSelectorFromString("generateWithPrompt:config:tokenCallback:error:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        originalGenerateIMP = method_getImplementation(method)

        // ObjC: - (BOOL)generateWithPrompt:(NSString *)prompt
        //                           config:(ExecuTorchLLMConfig *)config
        //                    tokenCallback:(void (^)(NSString *))callback
        //                            error:(NSError **)error
        typealias GenerateIMP = @convention(c) (
            AnyObject, Selector,
            NSString,   // prompt
            AnyObject,  // config
            AnyObject?, // nullable token callback block
            AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

        let capturedSel = sel
        let block: @convention(block) (
            AnyObject,
            NSString,
            AnyObject,
            AnyObject?,
            AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = {
            runner, prompt, config, origCallback, errorPtr in

            // Retrieve the handle stored by the load swizzle.
            let handle = objc_getAssociatedObject(
                runner, &ExecuTorchLLMInterceptor.handleKey) as? ModelHandle

            let start = CFAbsoluteTimeGetCurrent()

            // Wrap the caller's callback to count output tokens exactly.
            let counter = TokenCounter()
            let wrappedCallback: @convention(block) (NSString) -> Void = { token in
                counter.value += 1
                if let orig = origCallback {
                    unsafeBitCast(orig, to: (@convention(block) (NSString) -> Void).self)(token)
                }
            }
            let wrappedObj = unsafeBitCast(wrappedCallback, to: AnyObject.self)

            let imp = unsafeBitCast(ExecuTorchLLMInterceptor.originalGenerateIMP!, to: GenerateIMP.self)
            let success = imp(runner, capturedSel, prompt, config, wrappedObj, errorPtr)
            let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))

            guard let handle else { return success }

            let failed = !success || errorPtr?.pointee != nil
            let tokensOut = counter.value
            let tps = durationMs > 0 ? Double(tokensOut) / (Double(durationMs) / 1000.0) : 0

            handle.trackInference(
                durationMs: durationMs,
                inputModality: .text,
                outputModality: .generation,
                success: !failed,
                errorCode: failed
                    ? (errorPtr?.pointee.map { "et_\($0.code)" } ?? "et_generate_failed")
                    : nil,
                inputMeta: WildEdge.analyzeText(prompt as String).toMap(),
                outputMeta: GenerationOutputMeta(
                    tokensOut: tokensOut,
                    tokensPerSecond: tps,
                    stopReason: failed ? "error" : "max_tokens"
                ).toMap()
            )
            return success
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Helpers

    private static func modelIdentity(from path: String) -> (String, ModelInfo) {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let modelId = stem.isEmpty ? "executorch_model" : stem
        return (modelId, ModelInfo(modelName: modelId, modelSource: "local", modelFormat: "pte"))
    }

    // MARK: - Dealloc observer

    private final class RunnerObserver {
        private let handle: ModelHandle
        init(handle: ModelHandle) { self.handle = handle }
        deinit { handle.trackUnload(reason: "dealloc") }
    }
}
