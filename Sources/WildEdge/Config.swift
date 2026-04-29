import Foundation

internal enum Config {
    static let sdkVersion = "wildedge-swift-1.0.10"
    static let protocolVersion = "1.0"

    static let envDsn = "WILDEDGE_DSN"
    static let envDebug = "WILDEDGE_DEBUG"

    static let defaultFlushIntervalMs: Int64 = 60_000
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
}
