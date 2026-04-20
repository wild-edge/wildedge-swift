import Foundation

public final class ModelHandle {
    public let modelId: String
    public let info: ModelInfo

    private let publish: ([String: Any]) -> Void
    private let hardwareSnapshot: () -> HardwareContext?
    private let activeSpanContext: () -> SpanContext?
    private let lock = NSLock()
    private var loadedAt: Int64 = 0

    public private(set) var lastInferenceId: String?
    public var acceleratorActual: Accelerator?

    internal init(
        modelId: String,
        info: ModelInfo,
        publish: @escaping ([String: Any]) -> Void,
        hardwareSnapshot: @escaping () -> HardwareContext?,
        activeSpanContext: @escaping () -> SpanContext?
    ) {
        self.modelId = modelId
        self.info = info
        self.publish = publish
        self.hardwareSnapshot = hardwareSnapshot
        self.activeSpanContext = activeSpanContext
    }

    public func trackLoad(
        durationMs: Int,
        memoryBytes: Int64? = nil,
        accelerator: Accelerator? = nil,
        success: Bool = true,
        errorCode: String? = nil,
        coldStart: Bool? = nil,
        threads: Int? = nil
    ) {
        lock.lock()
        loadedAt = nowMs()
        lock.unlock()

        publish(buildModelLoadEvent(
            modelId: modelId,
            durationMs: durationMs,
            memoryBytes: memoryBytes,
            accelerator: accelerator,
            success: success,
            errorCode: errorCode,
            coldStart: coldStart,
            threads: threads
        ))
    }

    public func trackUnload(
        durationMs: Int = 0,
        reason: String = "explicit",
        memoryFreedBytes: Int64? = nil
    ) {
        lock.lock()
        let localLoadedAt = loadedAt
        lock.unlock()

        let uptimeMs: Int64?
        if localLoadedAt > 0 {
            uptimeMs = nowMs() - localLoadedAt
        } else {
            uptimeMs = nil
        }

        publish(buildModelUnloadEvent(
            modelId: modelId,
            durationMs: durationMs,
            reason: reason,
            memoryFreedBytes: memoryFreedBytes,
            uptimeMs: uptimeMs
        ))
    }

    public func trackDownload(
        sourceUrl: String,
        sourceType: String,
        fileSizeBytes: Int64,
        downloadedBytes: Int64,
        durationMs: Int,
        networkType: String = "unknown",
        resumed: Bool = false,
        cacheHit: Bool = false,
        success: Bool = true,
        errorCode: String? = nil
    ) {
        publish(buildModelDownloadEvent(
            modelId: modelId,
            sourceUrl: sourceUrl,
            sourceType: sourceType,
            fileSizeBytes: fileSizeBytes,
            downloadedBytes: downloadedBytes,
            durationMs: durationMs,
            networkType: networkType,
            resumed: resumed,
            cacheHit: cacheHit,
            success: success,
            errorCode: errorCode
        ))
    }

    @discardableResult
    public func trackInference(
        durationMs: Int,
        inputModality: InputModality? = nil,
        outputModality: OutputModality? = nil,
        success: Bool = true,
        errorCode: String? = nil,
        inputMeta: [String: Any]? = nil,
        outputMeta: [String: Any]? = nil,
        generationConfig: [String: Any]? = nil,
        hardware: HardwareContext? = nil,
        traceId: String? = nil,
        spanId: String? = nil,
        parentSpanId: String? = nil,
        runId: String? = nil,
        agentId: String? = nil
    ) -> String {
        let activeCtx = activeSpanContext()
        var mergedHardware = hardware ?? hardwareSnapshot()
        if let acceleratorActual {
            var hw = mergedHardware ?? HardwareContext()
            hw.acceleratorActual = acceleratorActual
            mergedHardware = hw
        }

        let event = buildInferenceEvent(
            modelId: modelId,
            durationMs: durationMs,
            inputModality: inputModality,
            outputModality: outputModality,
            success: success,
            errorCode: errorCode,
            inputMeta: inputMeta,
            outputMeta: outputMeta,
            generationConfig: generationConfig,
            hardware: mergedHardware,
            traceId: traceId ?? activeCtx?.traceId,
            spanId: spanId,
            parentSpanId: parentSpanId ?? activeCtx?.spanId,
            runId: runId,
            agentId: agentId
        )

        let inferenceId = event["__we_inference_id"] as? String ?? newEventId()
        lock.lock()
        lastInferenceId = inferenceId
        lock.unlock()

        publish(event)
        return inferenceId
    }

    public func trackFeedback(
        _ feedbackType: FeedbackType,
        relatedInferenceId: String? = nil,
        delayMs: Int? = nil,
        editDistance: Int? = nil
    ) {
        lock.lock()
        let fallbackInferenceId = lastInferenceId
        lock.unlock()

        guard let inferenceId = relatedInferenceId ?? fallbackInferenceId else {
            return
        }

        publish(buildFeedbackEvent(
            modelId: modelId,
            relatedInferenceId: inferenceId,
            feedbackType: feedbackType,
            delayMs: delayMs,
            editDistance: editDistance
        ))
    }

    public func trackError(
        errorCode: String,
        errorMessage: String? = nil,
        stackTraceHash: String? = nil,
        relatedEventId: String? = nil
    ) {
        publish(buildErrorEvent(
            modelId: modelId,
            errorCode: errorCode,
            errorMessage: errorMessage,
            stackTraceHash: stackTraceHash,
            relatedEventId: relatedEventId
        ))
    }

    public func close() {
        trackUnload(reason: "explicit")
    }
}

private func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
