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

    func runSpan<T>(
        name: String,
        traceId: String,
        parentSpanId: String?,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) async throws -> T
    ) async rethrows -> T
}

public final class SpanContext {
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    public let kind: SpanKind
    public var status: SpanStatus

    private weak var owner: SpanOwner?
    private let lock = NSLock()
    private var spanAttributes: [String: Any]

    internal init(
        traceId: String,
        spanId: String,
        parentSpanId: String?,
        kind: SpanKind,
        status: SpanStatus,
        attributes: [String: Any]? = nil,
        owner: SpanOwner
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.kind = kind
        self.status = status
        self.spanAttributes = attributes ?? [:]
        self.owner = owner
    }

    public func setAttribute(_ key: String, value: Any) {
        lock.lock()
        spanAttributes[key] = value
        lock.unlock()
    }

    public func setAttributes(_ attributes: [String: Any]) {
        lock.lock()
        for (key, value) in attributes {
            spanAttributes[key] = value
        }
        lock.unlock()
    }

    internal func attributesSnapshot() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return spanAttributes.isEmpty ? nil : spanAttributes
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
            kind: kind,
            attributes: attributes,
            block: block
        )
    }
}
