import Foundation

@_silgen_name("wildedge_loader_force_link")
private func wildedge_loader_force_link()

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
    func trace<T>(
        _ name: String,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) async throws -> T
    ) async rethrows -> T
    func flush(timeoutMs: Int64)
    var pendingCount: Int { get }
    func diagnostics() -> SDKDiagnostics
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

    func trace<T>(
        _ name: String,
        kind: SpanKind = .custom,
        attributes: [String: Any]? = nil,
        block: (SpanContext) async throws -> T
    ) async rethrows -> T {
        try await trace(name, kind: kind, attributes: attributes, block: block)
    }

    func flush() {
        flush(timeoutMs: Config.defaultShutdownFlushTimeoutMs)
    }
}

public final class WildEdge: WildEdgeClient, SpanOwner {
    private let queue: EventQueue
    private let registry: ModelRegistry
    private let consumer: Consumer?
    private let attachmentQueue: AttachmentQueue?
    private let attachmentConsumer: AttachmentConsumer?
    private let attachmentConfig: AttachmentConfig
    private let debug: Bool
    private let hardwareSampler = HardwareSampler()
    private let publishWorker = DispatchQueue(label: "dev.wildedge.publish", qos: .utility)
    private let attachmentIOQueue = DispatchQueue(label: "dev.wildedge.attachments.io", qos: .utility)

    private let lock = NSLock()
    private var handles: [String: ModelHandle] = [:]
    private var closed = false

    private static let activeSpanKey = "dev.wildedge.active_span"

    @TaskLocal
    private static var activeTaskSpan: SpanContext?

    internal struct AttachmentConfig {
        let enabled: Bool
        let maxPerInference: Int
        let maxSizeBytes: Int
        let storageStrategy: AttachmentStorageStrategy
        let filter: (([InferenceAttachment]) -> [InferenceAttachment])?
    }

    internal init(
        queue: EventQueue,
        registry: ModelRegistry,
        consumer: Consumer?,
        attachmentQueue: AttachmentQueue?,
        attachmentConsumer: AttachmentConsumer?,
        attachmentConfig: AttachmentConfig,
        debug: Bool
    ) {
        self.queue = queue
        self.registry = registry
        self.consumer = consumer
        self.attachmentQueue = attachmentQueue
        self.attachmentConsumer = attachmentConsumer
        self.attachmentConfig = attachmentConfig
        self.debug = debug
        hardwareSampler.start()
        ORTInterceptor.install(client: self)
        MLKitDetectorInterceptor.install(client: self)
        MLKitModelManagerInterceptor.install(client: self)
        TFLInterceptor.install(client: self)
    }

    public func registerModel(modelId: String, info: ModelInfo) -> ModelHandle {
        registerModel(modelId: modelId, info: info, publishSynchronously: false)
    }

    public func registerModel(
        modelId: String,
        info: ModelInfo,
        publishSynchronously: Bool
    ) -> ModelHandle {
        if let handle = handles[modelId] {
            if publishSynchronously {
                handle.setPublishSynchronously(true)
            }
            return handle
        }
        registry.register(modelId: modelId, info: info)
        let handle = ModelHandle(
            modelId: modelId,
            info: info,
            publish: { [weak self] event, sync in self?.publish(event: event, synchronously: sync) },
            hardwareSnapshot: { [weak self] in self?.hardwareSampler.snapshot() },
            activeSpanContext: { [weak self] in self?.activeSpan },
            publishSynchronously: publishSynchronously,
            registerAttachments: { [weak self] attachments, inferenceId, inferenceTimestamp in
                self?.enqueueAttachments(attachments, inferenceId: inferenceId, inferenceTimestamp: inferenceTimestamp)
            }
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

    public func trace<T>(
        _ name: String,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) async throws -> T
    ) async rethrows -> T {
        try await runSpan(
            name: name,
            traceId: UUID().uuidString,
            parentSpanId: nil,
            kind: kind,
            attributes: attributes,
            block: block
        )
    }

    internal func publish(event: [String: Any], synchronously: Bool = false) {
        if synchronously {
            publishWorker.sync { [self] in
                enqueue(event: event)
            }
            return
        }

        publishWorker.async { [weak self] in
            self?.enqueue(event: event)
        }
    }

    private func enqueue(event: [String: Any]) {
        var enriched = event
        enriched["__we_queued_at"] = Int64(Date().timeIntervalSince1970 * 1000)
        queue.add(enriched)

        if debug {
            let type = (event["event_type"] as? String) ?? "unknown"
            print("[wildedge] queued event type=\(type)")
        }
    }

    internal func enqueueAttachments(
        _ attachments: [InferenceAttachment],
        inferenceId: String,
        inferenceTimestamp: Date
    ) {
        guard let aq = attachmentQueue else { return }
        attachmentIOQueue.async { [self] in
            var filtered = attachmentConfig.filter?(attachments) ?? attachments
            if filtered.count > attachmentConfig.maxPerInference {
                filtered = Array(filtered.prefix(attachmentConfig.maxPerInference))
                if debug { print("[wildedge] attachment count exceeds maxAttachmentsPerInference, excess dropped") }
            }

            for attachment in filtered {
                let id = attachment.attachmentId
                let sizedPayload: SizedPayload?
                switch attachment.payload {
                case .data(let data, let mime):
                    guard data.count <= attachmentConfig.maxSizeBytes else {
                        if debug { print("[wildedge] attachment '\(attachment.name)' exceeds maxAttachmentSizeBytes, dropped") }
                        continue
                    }
                    if attachmentConfig.storageStrategy == .inline {
                        sizedPayload = SizedPayload(.data(data, mimeType: mime), byteSize: data.count)
                    } else {
                        guard let written = Self.writeDataToManagedStore(data: data, attachmentId: id) else {
                            if debug { print("[wildedge] attachment '\(attachment.name)' write failed, dropped") }
                            continue
                        }
                        sizedPayload = SizedPayload(.file(written, mimeType: mime), byteSize: data.count)
                    }

                case .file(let sourceURL, let mime):
                    guard let copiedURL = Self.copyToManagedStore(sourceURL: sourceURL, attachmentId: id) else {
                        if debug { print("[wildedge] attachment '\(attachment.name)' file copy failed, dropped") }
                        continue
                    }
                    let size = (try? FileManager.default.attributesOfItem(atPath: copiedURL.path)[.size] as? Int) ?? 0
                    guard size <= attachmentConfig.maxSizeBytes else {
                        try? FileManager.default.removeItem(at: copiedURL)
                        if debug { print("[wildedge] attachment '\(attachment.name)' exceeds maxAttachmentSizeBytes, dropped") }
                        continue
                    }
                    sizedPayload = SizedPayload(.file(copiedURL, mimeType: mime), byteSize: size)
                }

                guard let payload = sizedPayload else { continue }
                let pending = PendingAttachment(
                    attachmentId: id,
                    inferenceId: inferenceId,
                    name: attachment.name,
                    role: attachment.role.rawValue,
                    payload: payload,
                    inferenceTimestamp: inferenceTimestamp,
                    registeredAt: Date()
                )
                aq.append(pending)
            }
        }
    }

    private static func attachmentManagedDir() -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wildedge")
            .appendingPathComponent("attachments")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            var dirURL = dir
            try? dirURL.setResourceValues(rv)
            return dir
        } catch {
            return nil
        }
    }

    private static func writeDataToManagedStore(data: Data, attachmentId: String) -> URL? {
        guard let dir = attachmentManagedDir() else { return nil }
        let dest = dir.appendingPathComponent("\(attachmentId).bin")
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    private static func copyToManagedStore(sourceURL: URL, attachmentId: String) -> URL? {
        guard let dir = attachmentManagedDir() else { return nil }
        let ext = sourceURL.pathExtension
        let filename = ext.isEmpty ? attachmentId : "\(attachmentId).\(ext)"
        let dest = dir.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    public func close(timeoutMs: Int64) {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }

        hardwareSampler.stop()
        attachmentConsumer?.stop()
        consumer?.close(timeoutMs: timeoutMs)
    }

    public func flush(timeoutMs: Int64) {
        // First drain pending async publishes into EventQueue, then flush transport.
        publishWorker.sync { }
        consumer?.flush(timeoutMs: timeoutMs)
    }

    public var pendingCount: Int {
        queue.length()
    }

    public func diagnostics() -> SDKDiagnostics {
        return SDKDiagnostics(
            processMemoryBytes: Self.processPhysicalFootprint(),
            systemAvailableMemoryBytes: hardwareSampler.snapshot().memoryAvailableBytes,
            eventQueueCount: queue.length(),
            attachmentQueueCount: attachmentQueue?.length() ?? 0,
            attachmentUploadedCount: attachmentConsumer?.uploadedCount ?? 0,
            attachmentDropCount: attachmentConsumer?.dropCount ?? 0,
            attachmentPermanentFailureCount: attachmentConsumer?.permanentFailureCount ?? 0
        )
    }

    private static func processPhysicalFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    deinit {
        close(timeoutMs: Config.defaultShutdownFlushTimeoutMs)
    }

    internal var activeSpan: SpanContext? {
        Self.activeTaskSpan ?? Thread.current.threadDictionary[Self.activeSpanKey] as? SpanContext
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
            attributes: attributes,
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
                attributes: context.attributesSnapshot()
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

    internal func runSpan<T>(
        name: String,
        traceId: String,
        parentSpanId: String?,
        kind: SpanKind,
        attributes: [String: Any]?,
        block: (SpanContext) async throws -> T
    ) async rethrows -> T {
        let context = SpanContext(
            traceId: traceId,
            spanId: UUID().uuidString,
            parentSpanId: parentSpanId,
            kind: kind,
            status: .ok,
            attributes: attributes,
            owner: self
        )

        let start = Date()
        do {
            let result = try await Self.$activeTaskSpan.withValue(context) {
                try await block(context)
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
                attributes: context.attributesSnapshot()
            )
            publish(event: event)
            return result
        } catch {
            context.status = .error
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
            let event = buildSpanEvent(
                traceId: context.traceId,
                spanId: context.spanId,
                parentSpanId: context.parentSpanId,
                kind: context.kind,
                status: context.status,
                name: name,
                durationMs: durationMs,
                attributes: context.attributesSnapshot()
            )
            publish(event: event)
            throw error
        }
    }

    private func makeNoopHandle(modelId: String, info: ModelInfo) -> ModelHandle {
        ModelHandle(
            modelId: modelId,
            info: info,
            publish: { _, _ in },
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
        public var debug: Bool = {
            if ProcessInfo.processInfo.environment[Config.envDebug] == "true" { return true }
            let val = Bundle.main.object(forInfoDictionaryKey: Config.envDebug)
            return (val as? Bool) == true || (val as? String)?.lowercased() == "true"
        }()

        // Attachments
        public var enableAttachments: Bool = Config.defaultEnableAttachments
        public var maxAttachmentsPerInference: Int = Config.defaultMaxAttachmentsPerInference
        public var maxAttachmentSizeBytes: Int = Config.defaultMaxAttachmentSizeBytes
        public var maxAttachmentAgeMs: TimeInterval = Config.defaultMaxAttachmentAgeMs
        public var attachmentFlushIntervalMs: Int64 = Config.defaultAttachmentFlushIntervalMs
        public var attachmentTransmitTimeoutMs: TimeInterval = Config.attachmentHttpTimeoutMs
        public var attachmentStorageStrategy: AttachmentStorageStrategy = Config.defaultAttachmentStorageStrategy
        public var attachmentFilter: (([InferenceAttachment]) -> [InferenceAttachment])? = nil

        public init() {
            wildedge_loader_force_link()
            dsn = ProcessInfo.processInfo.environment[Config.envDsn]
                ?? Bundle.main.object(forInfoDictionaryKey: Config.envDsn) as? String
        }

        public func build() -> WildEdgeClient {
            guard let dsn, !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return NoopWildEdgeClient()
            }

            do {
                let parsed = try Self.parseDsn(dsn)
                let queueFileURL = Self.eventQueueFileURL()
                let queue = EventQueue(maxSize: maxQueueSize, fileURL: queueFileURL)
                let registry = ModelRegistry()
                let detectedDevice = device ?? DeviceInfo.detect(appVersion: appVersion, projectSecret: parsed.secret)
                let sessionId = UUID().uuidString
                let createdAt = isoNow()

                let logger: (String) -> Void = { [debug = self.debug] message in
                    if debug { print("[wildedge] \(message)") }
                }

                let transmitter = Transmitter(host: parsed.host, apiKey: parsed.secret, debug: debug, logger: logger)

                var attachmentQueue: AttachmentQueue? = nil
                var attachmentConsumer: AttachmentConsumer? = nil

                if enableAttachments {
                    let aq = AttachmentQueue(fileURL: Self.attachmentQueueFileURL(), strategy: attachmentStorageStrategy)
                    let at = AttachmentTransmitter(
                        host: parsed.host,
                        apiKey: parsed.secret,
                        timeoutMs: attachmentTransmitTimeoutMs,
                        debug: debug,
                        logger: logger
                    )
                    let ac = AttachmentConsumer(
                        queue: aq,
                        transmitter: at,
                        flushIntervalMs: attachmentFlushIntervalMs,
                        maxAttachmentAge: maxAttachmentAgeMs,
                        logger: logger
                    )
                    ac.start()
                    attachmentQueue = aq
                    attachmentConsumer = ac
                }

                let consumerConfig = ConsumerConfig(
                    device: detectedDevice,
                    sessionId: sessionId,
                    createdAt: createdAt,
                    batchSize: batchSize,
                    flushIntervalMs: flushIntervalMs,
                    maxEventAgeMs: maxEventAgeMs,
                    lowConfidenceThreshold: lowConfidenceThreshold
                )

                let consumer = Consumer(
                    queue: queue,
                    transmitter: transmitter,
                    registry: registry,
                    config: consumerConfig,
                    logger: logger
                )
                consumer.start()

                let attachmentConfig = AttachmentConfig(
                    enabled: enableAttachments,
                    maxPerInference: maxAttachmentsPerInference,
                    maxSizeBytes: maxAttachmentSizeBytes,
                    storageStrategy: attachmentStorageStrategy,
                    filter: attachmentFilter
                )

                return WildEdge(
                    queue: queue,
                    registry: registry,
                    consumer: consumer,
                    attachmentQueue: attachmentQueue,
                    attachmentConsumer: attachmentConsumer,
                    attachmentConfig: attachmentConfig,
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

        internal static func eventQueueFileURL() -> URL {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir
                .appendingPathComponent("wildedge")
                .appendingPathComponent("eventqueue.bin")
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? url.setResourceValues(rv)
            return url
        }

        internal static func attachmentQueueFileURL() -> URL {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("wildedge")
                .appendingPathComponent("attachments")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent("queue.bin")
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? url.setResourceValues(rv)
            return url
        }

        internal enum ParseError: Error, Equatable {
            case invalidDsn
            case missingSecret
        }
    }

    public private(set) static var shared: WildEdgeClient = NoopWildEdgeClient()

    internal private(set) static var autoInitFired = false

    internal static func autoInit() {
        print("[wildedge] auto-init triggered via +load")
        autoInitFired = true
        let client = Builder().build()
        shared = client
        let active = !(client is NoopWildEdgeClient)
        print("[wildedge] auto-init complete: \(active ? "active" : "noop (no DSN)")")
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
