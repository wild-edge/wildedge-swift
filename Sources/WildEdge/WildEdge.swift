import Foundation

public protocol WildEdgeClient: AnyObject {
    func registerModel(modelId: String, info: ModelInfo) -> ModelHandle
    func trackMemoryWarning(
        level: MemoryWarningLevel,
        memoryAvailableBytes: Int64,
        activeModelIds: [String],
        triggeredUnload: Bool,
        unloadedModelId: String?
    )
    func trace<T>(
        _ name: String,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) throws -> T
    ) rethrows -> T
    func flush(timeoutMs: Int64)
    func close(timeoutMs: Int64)
    var pendingCount: Int { get }
}

public extension WildEdgeClient {
    func trackMemoryWarning(
        level: MemoryWarningLevel,
        memoryAvailableBytes: Int64,
        activeModelIds: [String],
        triggeredUnload: Bool
    ) {
        trackMemoryWarning(
            level: level,
            memoryAvailableBytes: memoryAvailableBytes,
            activeModelIds: activeModelIds,
            triggeredUnload: triggeredUnload,
            unloadedModelId: nil
        )
    }

    func trace<T>(
        _ name: String,
        kind: SpanKind = .custom,
        attributes: [String: Any]? = nil,
        block: (SpanContext) throws -> T
    ) rethrows -> T {
        try trace(name, kind: kind, attributes: attributes, block: block)
    }

    func flush() {
        flush(timeoutMs: 5_000)
    }

    func close() {
        close(timeoutMs: 5_000)
    }
}

public final class WildEdge: WildEdgeClient, SpanOwner {
    private let queue: EventQueue
    private let registry: ModelRegistry
    private let consumer: Consumer?
    private let debug: Bool
    private let hardwareSampler = HardwareSampler()

    private let lock = NSLock()
    private var handles: [String: ModelHandle] = [:]
    private var closed = false

    private static let activeSpanKey = "dev.wildedge.active_span"

    internal init(
        queue: EventQueue,
        registry: ModelRegistry,
        consumer: Consumer?,
        debug: Bool
    ) {
        self.queue = queue
        self.registry = registry
        self.consumer = consumer
        self.debug = debug
        hardwareSampler.start()
        ORTInterceptor.install(client: self)
        MLKitDetectorInterceptor.install(client: self)
        MLKitModelManagerInterceptor.install(client: self)
    }

    public func registerModel(modelId: String, info: ModelInfo) -> ModelHandle {
        lock.lock()
        defer { lock.unlock() }

        if closed {
            return makeNoopHandle(modelId: modelId, info: info)
        }

        if let handle = handles[modelId] {
            return handle
        }

        registry.register(modelId: modelId, info: info)
        let handle = ModelHandle(
            modelId: modelId,
            info: info,
            publish: { [weak self] event in self?.publish(event: event) },
            hardwareSnapshot: { [weak self] in self?.hardwareSampler.snapshot() },
            activeSpanContext: { [weak self] in self?.activeSpan }
        )
        handles[modelId] = handle
        return handle
    }

    public func trackMemoryWarning(
        level: MemoryWarningLevel,
        memoryAvailableBytes: Int64,
        activeModelIds: [String],
        triggeredUnload: Bool,
        unloadedModelId: String?
    ) {
        let event = buildMemoryWarningEvent(
            level: level,
            memoryAvailableBytes: memoryAvailableBytes,
            activeModelIds: activeModelIds,
            triggeredUnload: triggeredUnload,
            unloadedModelId: unloadedModelId
        )
        publish(event: event)
    }

    public func trace<T>(
        _ name: String,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) throws -> T
    ) rethrows -> T {
        try runSpan(
            name: name,
            traceId: UUID().uuidString,
            parentSpanId: nil,
            kind: kind,
            attributes: attributes,
            block: block
        )
    }

    internal func publish(event: [String: Any]) {
        lock.lock()
        let isClosed = closed
        lock.unlock()

        guard !isClosed else { return }

        var enriched = event
        enriched["__we_queued_at"] = Int64(Date().timeIntervalSince1970 * 1000)
        queue.add(enriched)

        if debug {
            let type = (event["event_type"] as? String) ?? "unknown"
            print("[wildedge] queued event type=\(type)")
        }
    }

    public func flush(timeoutMs: Int64) {
        consumer?.flush(timeoutMs: timeoutMs)
    }

    public func close(timeoutMs: Int64) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        hardwareSampler.stop()
        consumer?.close(timeoutMs: timeoutMs)
    }

    public var pendingCount: Int {
        queue.length()
    }

    deinit {
        close(timeoutMs: Config.defaultShutdownFlushTimeoutMs)
    }

    internal var activeSpan: SpanContext? {
        Thread.current.threadDictionary[Self.activeSpanKey] as? SpanContext
    }

    internal func runSpan<T>(
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

        let previous = activeSpan
        Thread.current.threadDictionary[Self.activeSpanKey] = context

        let start = Date()
        defer {
            if let previous {
                Thread.current.threadDictionary[Self.activeSpanKey] = previous
            } else {
                Thread.current.threadDictionary.removeObject(forKey: Self.activeSpanKey)
            }

            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
            let event = buildSpanEvent(
                traceId: context.traceId,
                spanId: context.spanId,
                parentSpanId: context.parentSpanId,
                kind: context.kind,
                status: context.status,
                name: name,
                durationMs: durationMs,
                attributes: attributes
            )
            publish(event: event)
        }

        do {
            return try block(context)
        } catch {
            context.status = .error
            throw error
        }
    }

    private func makeNoopHandle(modelId: String, info: ModelInfo) -> ModelHandle {
        ModelHandle(
            modelId: modelId,
            info: info,
            publish: { _ in },
            hardwareSnapshot: { nil },
            activeSpanContext: { nil }
        )
    }

    public final class Builder {
        public var dsn: String?
        public var appVersion: String?
        public var device: DeviceInfo?
        public var batchSize: Int = Config.defaultBatchSize
        public var maxQueueSize: Int = Config.defaultMaxQueueSize
        public var flushIntervalMs: Int64 = Config.defaultFlushIntervalMs
        public var maxEventAgeMs: Int64 = Config.defaultMaxEventAgeMs
        public var lowConfidenceThreshold: Double = Config.defaultLowConfidenceThreshold
        public var debug: Bool = ProcessInfo.processInfo.environment[Config.envDebug] == "true"

        public init() {
            dsn = ProcessInfo.processInfo.environment[Config.envDsn]
                ?? Bundle.main.object(forInfoDictionaryKey: Config.envDsn) as? String
        }

        public func build() -> WildEdgeClient {
            guard let dsn, !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return NoopWildEdgeClient()
            }

            do {
                let parsed = try Self.parseDsn(dsn)
                let queue = EventQueue(maxSize: maxQueueSize)
                let registry = ModelRegistry()
                let transmitter = Transmitter(host: parsed.host, apiKey: parsed.secret)
                let detectedDevice = device ?? DeviceInfo.detect(appVersion: appVersion, projectSecret: parsed.secret)
                let sessionId = UUID().uuidString
                let createdAt = isoNow()

                let consumer = Consumer(
                    queue: queue,
                    transmitter: transmitter,
                    device: detectedDevice,
                    registry: registry,
                    sessionId: sessionId,
                    createdAt: createdAt,
                    batchSize: batchSize,
                    flushIntervalMs: flushIntervalMs,
                    maxEventAgeMs: maxEventAgeMs,
                    lowConfidenceThreshold: lowConfidenceThreshold,
                    logger: { message in
                        if self.debug {
                            print("[wildedge] \(message)")
                        }
                    }
                )
                consumer.start()

                return WildEdge(
                    queue: queue,
                    registry: registry,
                    consumer: consumer,
                    debug: debug
                )
            } catch {
                if debug {
                    print("[wildedge] invalid DSN, fallback to noop: \(error)")
                }
                return NoopWildEdgeClient()
            }
        }

        internal static func parseDsn(_ dsn: String) throws -> (secret: String, host: String) {
            guard let components = URLComponents(string: dsn), let scheme = components.scheme, let host = components.host else {
                throw ParseError.invalidDsn
            }
            guard let secret = components.user, !secret.isEmpty else {
                throw ParseError.missingSecret
            }

            var normalizedHost = "\(scheme)://\(host)"
            if let port = components.port {
                normalizedHost += ":\(port)"
            }

            return (secret, normalizedHost)
        }

        internal enum ParseError: Error, Equatable {
            case invalidDsn
            case missingSecret
        }
    }

    public private(set) static var shared: WildEdgeClient = NoopWildEdgeClient()

    internal private(set) static var autoInitFired = false

    internal static func autoInit() {
        let debug = ProcessInfo.processInfo.environment[Config.envDebug] == "true"
        if debug { print("[wildedge] auto-init triggered via +load") }
        autoInitFired = true
        let client = Builder().build()
        shared = client
        if debug {
            let active = !(client is NoopWildEdgeClient)
            print("[wildedge] auto-init complete: \(active ? "active" : "noop (no DSN)")")
        }
    }

    @discardableResult
    public static func `init`(_ block: (Builder) -> Void = { _ in }) -> WildEdgeClient {
        let builder = Builder()
        block(builder)
        let client = builder.build()
        shared = client
        return client
    }

    @discardableResult
    public static func initialize(_ block: (Builder) -> Void = { _ in }) -> WildEdgeClient {
        let builder = Builder()
        block(builder)
        let client = builder.build()
        shared = client
        return client
    }

    public static func analyzeText(
        _ text: String,
        promptType: String? = nil,
        turnIndex: Int? = nil,
        hasAttachments: Bool? = nil,
        tokenizer: ((String) -> Int)? = nil
    ) -> TextInputMeta {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        let wordCount = words.count
        let tokenCount = tokenizer?(text) ?? max(1, Int(Double(wordCount) / 0.75))

        let lowercased = text.lowercased()
        let codeHints = ["func ", "class ", "import ", "```", "def ", "function ", "{", "};"]
        let containsCode = codeHints.contains { lowercased.contains($0) }

        return TextInputMeta(
            charCount: text.count,
            wordCount: wordCount,
            tokenCount: tokenCount,
            language: nil,
            languageConfidence: nil,
            containsCode: containsCode,
            promptType: promptType,
            turnIndex: turnIndex,
            hasAttachments: hasAttachments
        )
    }
}

public final class NoopWildEdgeClient: WildEdgeClient {
    public init() {}

    public func registerModel(modelId: String, info: ModelInfo) -> ModelHandle {
        ModelHandle(
            modelId: modelId,
            info: info,
            publish: { _ in },
            hardwareSnapshot: { nil },
            activeSpanContext: { nil }
        )
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

    public func flush(timeoutMs: Int64) {
    }

    public func close(timeoutMs: Int64) {
    }

    public var pendingCount: Int { 0 }
}

private final class NullSpanOwner: SpanOwner {
    func runSpan<T>(
        name: String,
        traceId: String,
        parentSpanId: String?,
        kind: SpanKind,
        attributes: [String : Any]?,
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
