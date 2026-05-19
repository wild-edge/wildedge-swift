import Foundation

public final class ModelHandle {
    public let modelId: String
    public let info: ModelInfo

    private let publish: ([String: Any], Bool) -> Void
    private let hardwareSnapshot: () -> HardwareContext?
    private let activeSpanContext: () -> SpanContext?
    private let registerAttachments: ([InferenceAttachment], String, Date) -> Void
    private let lock = NSLock()
    private var loadedAt: Int64 = 0
    private var publishSynchronously: Bool

    public private(set) var lastInferenceId: String?
    public var acceleratorActual: Accelerator?

    internal init(
        modelId: String,
        info: ModelInfo,
        publish: @escaping ([String: Any], Bool) -> Void,
        hardwareSnapshot: @escaping () -> HardwareContext?,
        activeSpanContext: @escaping () -> SpanContext?,
        publishSynchronously: Bool = false,
        registerAttachments: @escaping ([InferenceAttachment], String, Date) -> Void = { _, _, _ in }
    ) {
        self.modelId = modelId
        self.info = info
        self.publish = publish
        self.hardwareSnapshot = hardwareSnapshot
        self.activeSpanContext = activeSpanContext
        self.publishSynchronously = publishSynchronously
        self.registerAttachments = registerAttachments
    }

    internal func setPublishSynchronously(_ enabled: Bool) {
        lock.lock()
        publishSynchronously = enabled || publishSynchronously
        lock.unlock()
    }

    private func emit(_ event: [String: Any]) {
        lock.lock()
        let sync = publishSynchronously
        lock.unlock()
        publish(event, sync)
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

        emit(buildModelLoadEvent(
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

        emit(buildModelUnloadEvent(
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
        emit(buildModelDownloadEvent(
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
        apiMeta: ApiMeta? = nil,
        attachments: [InferenceAttachment] = [],
        traceId: String? = nil,
        spanId: String? = nil,
        parentSpanId: String? = nil,
        runId: String? = nil,
        agentId: String? = nil
    ) -> String {
        let inferenceTimestamp = Date()
        let activeCtx = activeSpanContext()
        var mergedHardware = hardware ?? hardwareSnapshot()
        if let acceleratorActual {
            var hw = mergedHardware ?? HardwareContext()
            hw.acceleratorActual = acceleratorActual
            mergedHardware = hw
        }

        let attachmentRefs = attachments.map {
            let mimeType: String
            switch $0.payload {
            case .data(_, let m): mimeType = m
            case .file(_, let m): mimeType = m
            }
            return AttachmentEventRef(attachmentId: $0.attachmentId, role: $0.role.rawValue, contentType: mimeType)
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
            apiMeta: apiMeta,
            attachmentRefs: attachmentRefs,
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

        emit(event)
        if !attachments.isEmpty {
            registerAttachments(attachments, inferenceId, inferenceTimestamp)
        }
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

        emit(buildFeedbackEvent(
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
        emit(buildErrorEvent(
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
