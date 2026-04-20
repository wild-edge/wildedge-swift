import Foundation

internal protocol SpanOwner: AnyObject {
    func runSpan<T>(
        name: String,
        traceId: String,
        parentSpanId: String?,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) throws -> T
    ) rethrows -> T
}

public final class SpanContext {
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    public let kind: SpanKind
    public var status: SpanStatus

    private weak var owner: SpanOwner?

    internal init(
        traceId: String,
        spanId: String,
        parentSpanId: String?,
        kind: SpanKind,
        status: SpanStatus,
        owner: SpanOwner
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
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
            kind: kind,
            attributes: attributes,
            block: block
        )
    }
}
