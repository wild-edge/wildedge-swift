import Foundation

// MARK: - Append Benchmark Scenarios

public struct BlobAppendScenario {
    public let name: String
    public let payloadSize: Int
    public let recordCount: Int
    public let measured: Int        // timed iterations (warmup is always +1)

    public init(name: String, payloadSize: Int, recordCount: Int, measured: Int = 3) {
        self.name = name
        self.payloadSize = payloadSize
        self.recordCount = recordCount
        self.measured = measured
    }

    public var totalMB: Double { Double(payloadSize * recordCount) / (1_024 * 1_024) }
    public var totalBytes: Int { recordCount * payloadSize }
}

/// 100 MB total per scenario — identical to `BlobStoreAppendBenchmarkTests`.
public let blobStoreAppendScenarios: [BlobAppendScenario] = [
    BlobAppendScenario(name: "100b  ", payloadSize:         100, recordCount: 1_048_576, measured: 1),
    BlobAppendScenario(name: "1kb   ", payloadSize:       1_024, recordCount:   102_400, measured: 3),
    BlobAppendScenario(name: "10kb  ", payloadSize:      10_240, recordCount:    10_240, measured: 3),
    BlobAppendScenario(name: "200kb ", payloadSize:     204_800, recordCount:       512, measured: 3),
    BlobAppendScenario(name: "1mb   ", payloadSize:   1_048_576, recordCount:       100, measured: 3),
    BlobAppendScenario(name: "100mb ", payloadSize: 104_857_600, recordCount:         1, measured: 3),
]

// MARK: - Compaction Benchmark Scenarios

public struct BlobCompactionScenario {
    public let name: String
    public let payloadSize: Int
    public let recordCount: Int
    public let dropCount: Int
    public let measured: Int

    public init(name: String, payloadSize: Int, recordCount: Int, dropCount: Int, measured: Int = 3) {
        self.name = name
        self.payloadSize = payloadSize
        self.recordCount = recordCount
        self.dropCount = dropCount
        self.measured = measured
    }

    public var totalMB: Double { Double(payloadSize * recordCount) / (1_024 * 1_024) }
    public var shiftMB: Double { Double(payloadSize * (recordCount - dropCount)) / (1_024 * 1_024) }
    
    // For compatibility with tests that use `records` instead of `recordCount`
    public var records: Int { recordCount }
    public var bytesShifted: Int { (recordCount - dropCount) * (20 + payloadSize) }  // 20 = headerSize
}

/// 100 MB file, drop first half (~50 MB shifted) — identical to `BlobStoreCompactionBenchmarkTests`.
public let blobStoreCompactionScenarios: [BlobCompactionScenario] = [
    BlobCompactionScenario(name: "1kb    ", payloadSize:       1_024, recordCount: 102_400, dropCount:  51_200, measured: 2),
    BlobCompactionScenario(name: "10kb   ", payloadSize:      10_240, recordCount:  10_240, dropCount:   5_120, measured: 3),
    BlobCompactionScenario(name: "200kb  ", payloadSize:     204_800, recordCount:     512, dropCount:     256, measured: 3),
    BlobCompactionScenario(name: "1mb    ", payloadSize:   1_048_576, recordCount:     100, dropCount:      50, measured: 3),
    BlobCompactionScenario(name: "10mb   ", payloadSize:  10_485_760, recordCount:      10, dropCount:       5, measured: 3),
    BlobCompactionScenario(name: "single ", payloadSize: 104_857_600, recordCount:       1, dropCount:       1, measured: 3),
]

// MARK: - Gzip Benchmark Scenarios

public struct GzipScenario {
    public let name: String
    /// Number of inference events in the batch (determines uncompressed size).
    public let eventCount: Int
    public let measured: Int

    public init(name: String, eventCount: Int, measured: Int = 5) {
        self.name = name
        self.eventCount = eventCount
        self.measured = measured
    }
}

/// Realistic JSON batch payloads — 1 to 1 000 events.
public let gzipBatchScenarios: [GzipScenario] = [
    GzipScenario(name: "1 event   ", eventCount:    1, measured: 5),
    GzipScenario(name: "10 events ", eventCount:   10, measured: 5),
    GzipScenario(name: "50 events ", eventCount:   50, measured: 3),
    GzipScenario(name: "200 events", eventCount:  200, measured: 3),
    GzipScenario(name: "1000events", eventCount: 1000, measured: 3),
]

// MARK: - Encoding Benchmark Scenario

public struct BlobEncodingScenario {
    public let batchSize: Int
    public let measured: Int

    public init(batchSize: Int = 1_000, measured: Int = 5) {
        self.batchSize = batchSize
        self.measured = measured
    }
}

// MARK: - Canonical Event & Key Map

public let blobStoreInferenceKeyMap: [String: String] = [
    "event_id": "eid", "event_type": "et",  "timestamp":      "ts",
    "model_id":  "mid", "trace_id":   "tid", "span_id":        "sid",
    "parent_span_id": "psid", "run_id": "rid", "agent_id":     "aid",
    "inference":  "inf", "inference_id": "iid", "duration_ms": "dur",
    "success": "ok", "input_modality": "im", "output_modality": "om",
    "error_code": "ec", "input_meta": "imeta", "output_meta":  "ometa",
    "generation_config": "gcfg", "hardware": "hw",
    "char_count": "cc", "word_count": "wc", "token_count":     "tc",
    "language": "lg", "language_confidence": "lc",
    "contains_code": "cod", "prompt_type": "pt",
    "turn_index": "ti", "has_attachments": "att",
    "task": "t",  "tokens_in": "tin", "tokens_out":            "to",
    "cached_input_tokens": "cit", "time_to_first_token_ms":    "ttft",
    "tokens_per_second": "tps", "stop_reason": "sr",
    "context_used": "cu", "avg_token_entropy": "ate",
    "safety_triggered": "st", "temperature": "temp",
    "top_p": "tp", "max_tokens": "mt",
    "thermal": "th", "state": "s", "state_raw": "sraw",
    "cpu_temp_celsius": "ctc", "battery_level": "bl",
    "battery_charging": "bc", "memory_available_bytes": "mab",
    "cpu_freq_mhz": "cf", "cpu_freq_max_mhz": "cfm",
    "accelerator_actual": "aa", "gpu_busy_percent": "gbp",
]

public var blobStoreRichInferenceEvent: [String: Any] {[
    "event_id":       "550e8400-e29b-41d4-a716-446655440000",
    "event_type":     "inference",
    "timestamp":      "2026-05-10T12:00:00.000Z",
    "model_id":       "gpt2-medium-q4",
    "trace_id":       "trace-abc123def456",
    "span_id":        "span-def456abc123",
    "parent_span_id": "span-parent789xyz",
    "run_id":         "run-xyz001",
    "agent_id":       "agent-007",
    "inference": [
        "inference_id":    "550e8400-e29b-41d4-a716-446655440001",
        "duration_ms":     342,
        "success":         true,
        "input_modality":  "text",
        "output_modality": "generation",
        "error_code":      "NONE",
        "input_meta": [
            "char_count": 512, "word_count": 87, "token_count": 128,
            "language": "en", "language_confidence": 0.9823456789012345,
            "contains_code": false, "prompt_type": "chat",
            "turn_index": 3, "has_attachments": false,
        ] as [String: Any],
        "output_meta": [
            "task": "generation", "tokens_in": 128, "tokens_out": 256,
            "cached_input_tokens": 64, "time_to_first_token_ms": 45,
            "tokens_per_second": 32.567890123456789, "stop_reason": "end_of_sequence",
            "context_used": 384, "avg_token_entropy": 2.345678901234567,
            "safety_triggered": false,
        ] as [String: Any],
        "generation_config": [
            "temperature": 0.7123456789012345, "top_p": 0.9234567890123456,
            "max_tokens": 512,
        ] as [String: Any],
        "hardware": [
            "thermal": [
                "state": "nominal", "state_raw": "0",
                "cpu_temp_celsius": 42.567890123456789,
            ] as [String: Any],
            "battery_level": 0.8512345678901234, "battery_charging": true,
            "memory_available_bytes": 2_147_483_648,
            "cpu_freq_mhz": 3200, "cpu_freq_max_mhz": 4000,
            "accelerator_actual": "npu", "gpu_busy_percent": 23,
        ] as [String: Any],
    ] as [String: Any],
]}

// MARK: - Formatting Helpers

public func formatBytes(_ n: Int) -> String {
    switch n {
    case ..<1_024:             return "\(n) B"
    case ..<(1_024 * 1_024):  return "\(n / 1_024) KB"
    default:                  return "\(n / (1_024 * 1_024)) MB"
    }
}

public func blobFmtBytes(_ n: Int) -> String {
    switch n {
    case ..<1_024:             return "\(n) B"
    case ..<(1_024 * 1_024):  return "\(n / 1_024) KB"
    default:                  return "\(n / (1_024 * 1_024)) MB"
    }
}

// MARK: - String Padding Helpers

public extension String {
    func pad(_ width: Int) -> String {
        let diff = width - count
        guard diff > 0 else { return self }
        return self + String(repeating: " ", count: diff)
    }

    func bPad(_ width: Int) -> String {
        let diff = width - count
        guard diff > 0 else { return self }
        return String(repeating: " ", count: diff) + self
    }
}
