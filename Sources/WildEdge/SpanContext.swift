import Foundation

internal protocol SpanOwner: AnyObject {
    func runSpan<T>(
        name: String,
        traceId: String,
        parentSpanId: String?,
        runId: String?,
        agentId: String?,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) throws -> T
    ) rethrows -> T

    func runSpan<T>(
        name: String,
        traceId: String,
        parentSpanId: String?,
        runId: String?,
        agentId: String?,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) async throws -> T
    ) async rethrows -> T
}

/// The span that events fall back to for their correlation fields.
internal enum ActiveSpan {
    @TaskLocal static var current: SpanContext?
}

public final class SpanContext {
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    /// The run this span belongs to. Child spans inherit it, and events
    /// emitted while the span is active fall back to it.
    public let runId: String?
    /// The agent this span belongs to. Inherited the same way as `runId`.
    public let agentId: String?
    public let kind: SpanKind
    public var status: SpanStatus

    private weak var owner: SpanOwner?

    internal init(
        traceId: String,
        spanId: String,
        parentSpanId: String?,
        runId: String? = nil,
        agentId: String? = nil,
        kind: SpanKind,
        status: SpanStatus,
        owner: SpanOwner
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.runId = runId
        self.agentId = agentId
        self.kind = kind
        self.status = status
        self.owner = owner
    }

    public func span<T>(
        _ name: String,
        kind: SpanKind = .custom,
        attributes: [String: Any]? = nil,
        block: (SpanContext) throws -> T
    ) rethrows -> T {
        guard let owner else {
            return try block(self)
        }
        return try owner.runSpan(
            name: name,
            traceId: traceId,
            parentSpanId: spanId,
            runId: runId,
            agentId: agentId,
            kind: kind,
            attributes: attributes,
            block: block
        )
    }

    /// The async form of `span`. The child span stays active across `await`.
    public func span<T>(
        _ name: String,
        kind: SpanKind = .custom,
        attributes: [String: Any]? = nil,
        block: (SpanContext) async throws -> T
    ) async rethrows -> T {
        guard let owner else {
            return try await block(self)
        }
        return try await owner.runSpan(
            name: name,
            traceId: traceId,
            parentSpanId: spanId,
            runId: runId,
            agentId: agentId,
            kind: kind,
            attributes: attributes,
            block: block
        )
    }

    internal func isOwned(by candidate: SpanOwner) -> Bool {
        owner === candidate
    }
}
