import Foundation

internal enum Config {
    static let sdkVersion = "wildedge-swift-1.0.11"
    static let protocolVersion = "1.0"

    static let envDsn = "WILDEDGE_DSN"
    static let envDebug = "WILDEDGE_DEBUG"
    static let defaultFlushIntervalMs: Int64 = 20_000
    static let defaultBatchSize = 10
    static let defaultMaxQueueSize = 200
    static let defaultMaxEventAgeMs: Int64 = 900_000
    static let defaultShutdownFlushTimeoutMs: Int64 = 5_000
    static let defaultLowConfidenceThreshold: Double = 0.5

    static let backoffMinMs: UInt64 = 1_000
    static let backoffMaxMs: UInt64 = 60_000
    static let backoffMultiplier = 2.0

    static let httpTimeoutMs: TimeInterval = 15_000
    static let errorMsgMaxLen = 200

    static let defaultHardwareSamplingIntervalMs: Int64 = 5_000

    // MARK: - Attachments

    static let defaultEnableAttachments = false
    static let defaultAttachmentStorageStrategy = AttachmentStorageStrategy.file
    static let defaultMaxAttachmentsPerInference = 10
    static let defaultMaxAttachmentSizeBytes = 10 * 1024 * 1024   // 10 MB
    static let defaultMaxAttachmentAgeMs: TimeInterval = 5 * 60   // 5 min in seconds
    static let defaultAttachmentFlushIntervalMs: Int64 = 5_000
    static let attachmentHttpTimeoutMs: TimeInterval = 10_000
}
