import Foundation
import ObjectiveC

// Intercepts MLKModelManager to track remote custom model downloads.
//
// Swizzles -downloadModel:conditions: to capture the model name and start time.
// Because MLKit signals completion via NSNotificationCenter (not a completion block),
// the interceptor also observes MLKModelDownloadDidSucceed / MLKModelDownloadDidFail
// notifications to record final duration and success/failure.
//
// No MLKit import required — works via NSClassFromString and KVC.
internal final class MLKitModelManagerInterceptor {

    // MARK: - State

    private static let lock = NSLock()
    private static var installed = false
    private static var originalDownloadIMP: IMP?
    private static weak var activeClient: WildEdge?

    // model name → (handle, download start time)
    private static var pendingDownloads: [String: (ModelHandle, CFAbsoluteTime)] = [:]

    private static let downloadDidSucceedName = Notification.Name("com.google.mlkit.ModelDownloadDidSucceed")
    private static let downloadDidFailName = Notification.Name("com.google.mlkit.ModelDownloadDidFail")
    private static let modelNameKey = "MLKModelDownloadUserInfoKeyRemoteModel"

    // MARK: - Install

    static func install(client: WildEdge) {
        lock.lock()
        activeClient = client
        let alreadyInstalled = installed
        if !installed { installed = true }
        lock.unlock()

        guard !alreadyInstalled else { return }
        guard let cls = NSClassFromString("MLKModelManager") else { return }

        let debug = ProcessInfo.processInfo.environment["WILDEDGE_DEBUG"] == "true"
        if debug { print("[wildedge] MLKitModelManagerInterceptor: swizzling MLKModelManager") }

        installDownloadSwizzle(on: cls)
        observeDownloadNotifications()
    }

    // MARK: - downloadModel:conditions: swizzle

    private static func installDownloadSwizzle(on cls: AnyClass) {
        let sel = NSSelectorFromString("downloadModel:conditions:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        originalDownloadIMP = method_getImplementation(method)

        // Returns NSProgress*
        typealias DownloadIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> AnyObject

        let capturedSel = sel
        let block: @convention(block) (AnyObject, AnyObject, AnyObject) -> AnyObject = {
            selfManager, remoteModel, conditions in
            let imp = unsafeBitCast(MLKitModelManagerInterceptor.originalDownloadIMP!, to: DownloadIMP.self)
            let start = CFAbsoluteTimeGetCurrent()
            let progress = imp(selfManager, capturedSel, remoteModel, conditions)

            // Extract model name via KVC (MLKRemoteModel has a `name` property)
            let modelName = (remoteModel as AnyObject).value(forKey: "name") as? String
                ?? "mlkit-remote-model"

            let client: WildEdge? = {
                MLKitModelManagerInterceptor.lock.lock()
                defer { MLKitModelManagerInterceptor.lock.unlock() }
                return MLKitModelManagerInterceptor.activeClient
            }()

            if let client {
                let handle = client.registerModel(
                    modelId: "mlkit-\(modelName)",
                    info: ModelInfo(
                        modelName: modelName,
                        modelSource: "remote",
                        modelFormat: "mlkit"
                    )
                )
                MLKitModelManagerInterceptor.lock.lock()
                MLKitModelManagerInterceptor.pendingDownloads[modelName] = (handle, start)
                MLKitModelManagerInterceptor.lock.unlock()
            }

            return progress
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Notification observers for download completion

    private static func observeDownloadNotifications() {
        NotificationCenter.default.addObserver(
            forName: downloadDidSucceedName,
            object: nil,
            queue: nil
        ) { notification in
            finishDownload(from: notification, success: true)
        }

        NotificationCenter.default.addObserver(
            forName: downloadDidFailName,
            object: nil,
            queue: nil
        ) { notification in
            finishDownload(from: notification, success: false)
        }
    }

    private static func finishDownload(from notification: Notification, success: Bool) {
        // The notification userInfo contains the MLKRemoteModel under a known key.
        let remoteModel = notification.userInfo?[modelNameKey] as AnyObject?
        let modelName = remoteModel?.value(forKey: "name") as? String ?? ""
        let error = notification.userInfo?[NSUnderlyingErrorKey] as? NSError

        lock.lock()
        let entry = pendingDownloads.removeValue(forKey: modelName)
        lock.unlock()

        guard let (handle, start) = entry else { return }

        let durationMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        handle.trackLoad(
            durationMs: durationMs,
            success: success,
            errorCode: error.map { "mlkit_download_\($0.code)" }
        )
    }
}
