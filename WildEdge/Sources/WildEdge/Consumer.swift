import Foundation

internal final class Consumer {
    private let queue: EventQueue
    private let transmitter: Transmitting
    private let device: DeviceInfo
    private let registry: ModelRegistry
    private let sessionId: String
    private let createdAt: String
    private let batchSize: Int
    private let flushIntervalMs: Int64
    private let maxEventAgeMs: Int64
    private let lowConfidenceThreshold: Double
    private let logger: (String) -> Void

    private let worker = DispatchQueue(label: "dev.wildedge.consumer")
    private var timer: DispatchSourceTimer?
    private var closed = false

    init(
        queue: EventQueue,
        transmitter: Transmitting,
        device: DeviceInfo,
        registry: ModelRegistry,
        sessionId: String,
        createdAt: String,
        batchSize: Int,
        flushIntervalMs: Int64,
        maxEventAgeMs: Int64,
        lowConfidenceThreshold: Double,
        logger: @escaping (String) -> Void
    ) {
        self.queue = queue
        self.transmitter = transmitter
        self.device = device
        self.registry = registry
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.batchSize = batchSize
        self.flushIntervalMs = flushIntervalMs
        self.maxEventAgeMs = maxEventAgeMs
        self.lowConfidenceThreshold = lowConfidenceThreshold
        self.logger = logger
    }

    func start() {
        worker.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .milliseconds(Int(self.flushIntervalMs)))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func flush(timeoutMs: Int64 = Config.defaultShutdownFlushTimeoutMs) {
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        let group = DispatchGroup()
        group.enter()
        worker.async {
            self.flushLoop(deadline: Date().addingTimeInterval(timeoutSeconds))
            group.leave()
        }
        _ = group.wait(timeout: .now() + timeoutSeconds)
    }

    func close(timeoutMs: Int64 = Config.defaultShutdownFlushTimeoutMs) {
        worker.sync {
            guard !closed else { return }
            closed = true
            flushLoop(deadline: Date().addingTimeInterval(Double(timeoutMs) / 1000.0))
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        guard !closed else { return }
        _ = drainOnce()
    }

    private func flushLoop(deadline: Date) {
        var backoffMs = Config.backoffMinMs
        while queue.length() > 0 && Date() < deadline {
            let didSend = drainOnce()
            if didSend {
                backoffMs = Config.backoffMinMs
            } else {
                let sleepNs = backoffMs * 1_000_000
                Thread.sleep(forTimeInterval: Double(sleepNs) / 1_000_000_000)
                backoffMs = min(UInt64(Double(backoffMs) * Config.backoffMultiplier), Config.backoffMaxMs)
            }
        }
    }

    private func drainOnce() -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let events = queue.peekMany(batchSize)
        guard !events.isEmpty else { return false }

        let stale = events.prefix { event in
            let queuedAt = event["__we_queued_at"] as? Int64 ?? now
            return (now - queuedAt) > maxEventAgeMs
        }
        if !stale.isEmpty {
            queue.removeFirstN(stale.count)
            logger("Dropped \(stale.count) stale event(s)")
            return true
        }

        guard let payload = buildBatch(
            device: device,
            models: registry.snapshot(),
            events: events,
            sessionId: sessionId,
            createdAt: createdAt,
            lowConfidenceThreshold: lowConfidenceThreshold
        ) else {
            queue.removeFirstN(events.count)
            logger("Dropped \(events.count) event(s) because payload serialization failed")
            return true
        }

        do {
            let response = try transmitter.send(batchData: payload)
            logger(
                "Ingest response status=\(response.status) batch_id=\(response.batchId) " +
                "accepted=\(response.eventsAccepted) rejected=\(response.eventsRejected)"
            )
            switch response.status {
            case "accepted", "partial":
                queue.removeFirstN(events.count)
                logger("Accepted \(events.count) event(s)")
                return true
            case "rejected", "unauthorized", "error":
                queue.removeFirstN(events.count)
                logger("Dropped \(events.count) event(s), status=\(response.status)")
                return true
            default:
                return false
            }
        } catch {
            logger("Transmit failed: \(error.localizedDescription)")
            return false
        }
    }
}
