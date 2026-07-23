import Foundation

internal final class AttachmentConsumer {
    private let queue: AttachmentQueue
    private let transmitter: AttachmentTransmitter
    private let flushIntervalMs: Int64
    private let maxAttachmentAge: TimeInterval
    private let logger: (String) -> Void

    private let worker = DispatchQueue(label: "dev.wildedge.attachment_consumer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var closed = false

    private(set) var uploadedCount: Int = 0
    private(set) var dropCount: Int = 0
    private(set) var permanentFailureCount: Int = 0

    init(
        queue: AttachmentQueue,
        transmitter: AttachmentTransmitter,
        flushIntervalMs: Int64 = Config.defaultAttachmentFlushIntervalMs,
        maxAttachmentAge: TimeInterval = Config.defaultMaxAttachmentAgeMs,
        logger: @escaping (String) -> Void
    ) {
        self.queue = queue
        self.transmitter = transmitter
        self.flushIntervalMs = flushIntervalMs
        self.maxAttachmentAge = maxAttachmentAge
        self.logger = logger
    }

    func start() {
        worker.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(
                deadline: .now() + .milliseconds(Int(self.flushIntervalMs)),
                repeating: .milliseconds(Int(self.flushIntervalMs))
            )
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        worker.sync {
            guard !closed else { return }
            closed = true
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Private

    private func tick() {
        guard !closed else { return }

        // Drop stale attachments from the front of the queue.
        let cutoff = Date().addingTimeInterval(-maxAttachmentAge)
        var staleCount = 0
        for attachment in queue.peekMany(50) {
            guard attachment.registeredAt < cutoff else { break }
            deleteFile(attachment)
            staleCount += 1
            dropCount += 1
        }
        if staleCount > 0 {
            queue.removeFirstN(staleCount)
            logger("Attachment consumer evicted=\(staleCount) (age > \(Int(maxAttachmentAge))s)")
        }

        // Process the next batch sequentially, stopping at the first transient failure.
        let pending = queue.peekMany(5)
        guard !pending.isEmpty else { return }

        logger("Attachment consumer tick pending=\(pending.count)")

        var doneCount = 0
        uploadLoop: for attachment in pending {
            logger("Attachment upload id=\(attachment.attachmentId) name=\(attachment.name)")
            switch transmitter.transmit(attachment) {
            case .uploaded:
                deleteFile(attachment)
                uploadedCount += 1
                doneCount += 1
                logger("Attachment uploaded id=\(attachment.attachmentId)")

            case .permanentFailure(let error):
                deleteFile(attachment)
                permanentFailureCount += 1
                dropCount += 1
                doneCount += 1
                logger("Attachment permanent failure id=\(attachment.attachmentId) error=\(error)")

            case .transientFailure:
                logger("Attachment transient failure id=\(attachment.attachmentId), retrying next tick")
                break uploadLoop

            case .disabled:
                deleteFile(attachment)
                dropCount += 1
                doneCount += 1
                logger("Attachment uploads disabled for this session (presign 403), id=\(attachment.attachmentId) dropped")
                queue.disable()
                if doneCount > 0 {
                    queue.removeFirstN(doneCount)
                }
                if !closed {
                    closed = true
                    timer?.cancel()
                    timer = nil
                }
                return
            }
        }

        if doneCount > 0 {
            queue.removeFirstN(doneCount)
            logger("Attachment consumer done uploaded=\(uploadedCount) dropped=\(dropCount)")
        }
    }

    private func deleteFile(_ attachment: PendingAttachment) {
        if case .file(let url, _) = attachment.payload.source {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
