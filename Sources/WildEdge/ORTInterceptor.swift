import Foundation
import ObjectiveC

// Intercepts ORTSession init and run via ObjC runtime method replacement.
// Uses NSClassFromString so no ORT import (and no new dependency) is needed.
// install(client:) must be called before any ORTSession is created — WildEdge.init does this.
internal final class ORTInterceptor {

    // MARK: - State

    private static let lock = NSLock()
    private static var installed = false
    private static var originalInitIMP: IMP?
    private static var originalRunIMP: IMP?
    private static weak var activeClient: WildEdge?

    private static var sessions: [ObjectIdentifier: ModelHandle] = [:]
    private static var sessionObserverKey: UInt8 = 0

    // MARK: - Lifecycle

    static func install(client: WildEdge) {
        lock.lock()
        activeClient = client
        let alreadyInstalled = installed
        if !installed { installed = true }
        lock.unlock()

        guard !alreadyInstalled else { return }
        guard let cls = NSClassFromString("ORTSession") else { return }
        installInitSwizzle(on: cls)
        installRunSwizzle(on: cls)
    }

    // MARK: - Init swizzle

    private static func installInitSwizzle(on cls: AnyClass) {
        let sel = NSSelectorFromString("initWithEnv:modelPath:sessionOptions:error:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        originalInitIMP = method_getImplementation(method)

        typealias InitIMP = @convention(c) (
            AnyObject, Selector, AnyObject, NSString, AnyObject?,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject?

        let capturedSel = sel
        let block: @convention(block) (
            AnyObject, AnyObject, NSString, AnyObject?,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject? = { selfObj, env, modelPath, sessionOptions, errorPtr in
            let start = CFAbsoluteTimeGetCurrent()
            let imp = unsafeBitCast(ORTInterceptor.originalInitIMP!, to: InitIMP.self)
            let result = imp(selfObj, capturedSel, env, modelPath, sessionOptions, errorPtr)
            let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))

            guard let result else { return nil }

            let client: WildEdge? = {
                ORTInterceptor.lock.lock()
                defer { ORTInterceptor.lock.unlock() }
                return ORTInterceptor.activeClient
            }()
            guard let client else { return result }

            let (modelId, info) = ORTInterceptor.modelIdentity(from: modelPath as String)
            let handle = client.registerModel(modelId: modelId, info: info)

            let failed = errorPtr?.pointee != nil
            handle.trackLoad(
                durationMs: durationMs,
                success: !failed,
                errorCode: failed
                    ? (errorPtr?.pointee.map { "ort_\($0.code)" } ?? "ort_init_failed")
                    : nil
            )

            let sessionId = ObjectIdentifier(result)
            ORTInterceptor.lock.lock()
            ORTInterceptor.sessions[sessionId] = handle
            ORTInterceptor.lock.unlock()

            ORTInterceptor.attachObserver(to: result, sessionId: sessionId, handle: handle)
            return result
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Run swizzle

    private static func installRunSwizzle(on cls: AnyClass) {
        let sel = NSSelectorFromString("runWithInputs:outputNames:runOptions:error:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        originalRunIMP = method_getImplementation(method)

        typealias RunIMP = @convention(c) (
            AnyObject, Selector, NSDictionary, NSSet,
            AnyObject?, AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> NSDictionary?

        let capturedSel = sel
        let block: @convention(block) (
            AnyObject, NSDictionary, NSSet,
            AnyObject?, AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> NSDictionary? = { session, inputs, outputNames, runOptions, errorPtr in
            let start = CFAbsoluteTimeGetCurrent()
            let imp = unsafeBitCast(ORTInterceptor.originalRunIMP!, to: RunIMP.self)
            let result = imp(session, capturedSel, inputs, outputNames, runOptions, errorPtr)
            let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))

            let handle: ModelHandle? = {
                ORTInterceptor.lock.lock()
                defer { ORTInterceptor.lock.unlock() }
                return ORTInterceptor.sessions[ObjectIdentifier(session)]
            }()
            guard let handle else { return result }

            let failed = result == nil
            handle.trackInference(
                durationMs: durationMs,
                inputModality: .tensor,
                outputModality: .tensor,
                success: !failed,
                errorCode: failed
                    ? (errorPtr?.pointee.map { "ort_\($0.code)" } ?? "ort_run_failed")
                    : nil,
                inputMeta: ["tensor_count": inputs.count],
                outputMeta: result.map { ["tensor_count": $0.count] }
            )
            return result
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Model identity

    private static func modelIdentity(from path: String) -> (modelId: String, info: ModelInfo) {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let modelId = stem.isEmpty ? path : stem
        return (modelId, ModelInfo(
            modelName: modelId,
            modelSource: "local",
            modelFormat: url.pathExtension.isEmpty ? "onnx" : url.pathExtension
        ))
    }

    // MARK: - Dealloc observer

    private static func attachObserver(to session: AnyObject, sessionId: ObjectIdentifier, handle: ModelHandle) {
        let observer = SessionObserver(sessionId: sessionId, handle: handle)
        objc_setAssociatedObject(
            session,
            &ORTInterceptor.sessionObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private final class SessionObserver {
        private let sessionId: ObjectIdentifier
        private let handle: ModelHandle
        init(sessionId: ObjectIdentifier, handle: ModelHandle) {
            self.sessionId = sessionId
            self.handle = handle
        }
        deinit {
            ORTInterceptor.lock.lock()
            ORTInterceptor.sessions.removeValue(forKey: sessionId)
            ORTInterceptor.lock.unlock()
            handle.trackUnload(reason: "dealloc")
        }
    }
}
