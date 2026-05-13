import Foundation

public final class NoopWildEdgeClient: WildEdgeClient {
    public init() {}

    public func registerModel(modelId: String, info: ModelInfo) -> ModelHandle {
        ModelHandle(
            modelId: modelId,
            info: info,
            publish: { _, _ in },
            hardwareSnapshot: { nil },
            activeSpanContext: { nil }
        )
    }

    public func registerModel(
        modelId: String,
        info: ModelInfo,
        publishSynchronously: Bool
    ) -> ModelHandle {
        registerModel(modelId: modelId, info: info)
    }

    public func trackMemoryWarning(
        level: MemoryWarningLevel,
        memoryAvailableBytes: Int64,
        activeModelIds: [String],
        triggeredUnload: Bool,
        unloadedModelId: String?
    ) {
    }

    public func trace<T>(
        _ name: String,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) throws -> T
    ) rethrows -> T {
        let context = SpanContext(
            traceId: UUID().uuidString,
            spanId: UUID().uuidString,
            parentSpanId: nil,
            kind: kind,
            status: .ok,
            owner: NullSpanOwner()
        )
        return try block(context)
    }

    public var pendingCount: Int { 0 }

    public func flush(timeoutMs: Int64) {
    }

    public func diagnostics() -> SDKDiagnostics {
        SDKDiagnostics(
            processMemoryBytes: 0,
            systemAvailableMemoryBytes: nil,
            eventQueueCount: 0,
            attachmentQueueCount: 0,
            attachmentUploadedCount: 0,
            attachmentDropCount: 0,
            attachmentPermanentFailureCount: 0
        )
    }
}

private final class NullSpanOwner: SpanOwner {
    func runSpan<T>(
        name: String,
        traceId: String,
        parentSpanId: String?,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) throws -> T
    ) rethrows -> T {
        let context = SpanContext(
            traceId: traceId,
            spanId: UUID().uuidString,
            parentSpanId: parentSpanId,
            kind: kind,
            status: .ok,
            owner: self
        )
        return try block(context)
    }
}
