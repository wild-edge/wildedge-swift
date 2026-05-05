import Foundation

public enum Accelerator: String {
    case cpu
    case gpu
    case npu
    case dsp
    case tpu
}

public enum MemoryWarningLevel: String {
    case warning
    case serious
    case critical
}

public enum InputModality: String {
    case image
    case audio
    case text
    case tensor
    case video
    case multimodal
}

public enum OutputModality: String {
    case detection
    case generation
    case embedding
    case tensor
    case classification
    case segmentation
}

public enum SpanKind: String {
    case agentStep = "agent_step"
    case tool
    case retrieval
    case memory
    case router
    case guardrail
    case cache
    case eval
    case custom
}

public enum SpanStatus: String {
    case ok
    case error
}

public enum FeedbackType {
    case thumbsUp
    case thumbsDown
    case accepted
    case edited
    case rejected
    case custom(String)

    var value: String {
        switch self {
        case .thumbsUp: return "thumbs_up"
        case .thumbsDown: return "thumbs_down"
        case .accepted: return "accepted"
        case .edited: return "edited"
        case .rejected: return "rejected"
        case .custom(let value): return value
        }
    }
}

public struct ModelInfo {
    public var modelName: String
    public var modelVersion: String?
    public var modelSource: String
    public var modelFormat: String
    public var modelFamily: String?
    public var quantization: String?

    public init(
        modelName: String,
        modelVersion: String? = nil,
        modelSource: String,
        modelFormat: String,
        modelFamily: String? = nil,
        quantization: String? = nil
    ) {
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.modelSource = modelSource
        self.modelFormat = modelFormat
        self.modelFamily = modelFamily
        self.quantization = quantization
    }

    internal func toMap() -> [String: Any] {
        var map: [String: Any] = [
            "model_name": modelName,
            "model_source": modelSource,
            "model_format": modelFormat,
        ]
        if let modelVersion {
            map["model_version"] = modelVersion
        }
        if let modelFamily {
            map["model_family"] = modelFamily
        }
        if let quantization {
            map["quantization"] = quantization
        }
        return map
    }
}

public struct TopPrediction {
    public var label: String
    public var confidence: Double?

    public init(label: String, confidence: Double? = nil) {
        self.label = label
        self.confidence = confidence
    }
}

public struct DetectionOutputMeta {
    public var numPredictions: Int?
    public var topK: [TopPrediction]?
    public var avgConfidence: Double?

    public init(numPredictions: Int? = nil, topK: [TopPrediction]? = nil, avgConfidence: Double? = nil) {
        self.numPredictions = numPredictions
        self.topK = topK
        self.avgConfidence = avgConfidence
    }

    public func toMap() -> [String: Any] {
        var map: [String: Any] = ["task": "detection"]
        if let numPredictions {
            map["num_predictions"] = numPredictions
        }
        if let topK {
            map["top_k"] = topK.map { item in
                var value: [String: Any] = ["label": item.label]
                if let confidence = item.confidence {
                    value["confidence"] = confidence
                }
                return value
            }
        }
        if let avgConfidence {
            map["avg_confidence"] = avgConfidence
        }
        return map
    }
}

public struct GenerationOutputMeta {
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var cachedInputTokens: Int?
    public var timeToFirstTokenMs: Int?
    public var tokensPerSecond: Double?
    public var stopReason: String?
    public var contextUsed: Int?
    public var avgTokenEntropy: Double?
    public var safetyTriggered: Bool?

    public init(
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        cachedInputTokens: Int? = nil,
        timeToFirstTokenMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        stopReason: String? = nil,
        contextUsed: Int? = nil,
        avgTokenEntropy: Double? = nil,
        safetyTriggered: Bool? = nil
    ) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cachedInputTokens = cachedInputTokens
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.tokensPerSecond = tokensPerSecond
        self.stopReason = stopReason
        self.contextUsed = contextUsed
        self.avgTokenEntropy = avgTokenEntropy
        self.safetyTriggered = safetyTriggered
    }

    public func toMap() -> [String: Any] {
        var map: [String: Any] = ["task": "generation"]
        if let tokensIn { map["tokens_in"] = tokensIn }
        if let tokensOut { map["tokens_out"] = tokensOut }
        if let cachedInputTokens { map["cached_input_tokens"] = cachedInputTokens }
        if let timeToFirstTokenMs { map["time_to_first_token_ms"] = timeToFirstTokenMs }
        if let tokensPerSecond { map["tokens_per_second"] = tokensPerSecond }
        if let stopReason { map["stop_reason"] = stopReason }
        if let contextUsed { map["context_used"] = contextUsed }
        if let avgTokenEntropy { map["avg_token_entropy"] = avgTokenEntropy }
        if let safetyTriggered { map["safety_triggered"] = safetyTriggered }
        return map
    }
}

public struct EmbeddingOutputMeta {
    public var dimensions: Int

    public init(dimensions: Int) {
        self.dimensions = dimensions
    }

    public func toMap() -> [String: Any] {
        ["task": "embedding", "dimensions": dimensions]
    }
}

public struct TextInputMeta {
    public var charCount: Int?
    public var wordCount: Int?
    public var tokenCount: Int?
    public var language: String?
    public var languageConfidence: Double?
    public var containsCode: Bool?
    public var promptType: String?
    public var turnIndex: Int?
    public var hasAttachments: Bool?

    public init(
        charCount: Int? = nil,
        wordCount: Int? = nil,
        tokenCount: Int? = nil,
        language: String? = nil,
        languageConfidence: Double? = nil,
        containsCode: Bool? = nil,
        promptType: String? = nil,
        turnIndex: Int? = nil,
        hasAttachments: Bool? = nil
    ) {
        self.charCount = charCount
        self.wordCount = wordCount
        self.tokenCount = tokenCount
        self.language = language
        self.languageConfidence = languageConfidence
        self.containsCode = containsCode
        self.promptType = promptType
        self.turnIndex = turnIndex
        self.hasAttachments = hasAttachments
    }

    public func toMap() -> [String: Any] {
        var map: [String: Any] = [:]
        if let charCount { map["char_count"] = charCount }
        if let wordCount { map["word_count"] = wordCount }
        if let tokenCount { map["token_count"] = tokenCount }
        if let language { map["language"] = language }
        if let languageConfidence { map["language_confidence"] = languageConfidence }
        if let containsCode { map["contains_code"] = containsCode }
        if let promptType { map["prompt_type"] = promptType }
        if let turnIndex { map["turn_index"] = turnIndex }
        if let hasAttachments { map["has_attachments"] = hasAttachments }
        return map
    }
}

public struct SDKDiagnostics {
    /// Physical memory footprint of the current process (phys_footprint from task_vm_info).
    public let processMemoryBytes: Int64
    /// System-wide available memory (free + inactive VM pages). Nil if the kernel call fails.
    public let systemAvailableMemoryBytes: Int64?
    /// Number of events currently buffered in the queue.
    public let eventQueueCount: Int
    /// In-memory data size of all buffered events, in bytes.
    public let eventQueueBytes: Int
    /// JSON-serialised size of all buffered events, in bytes.
    public let eventQueueSerialisedBytes: Int
}

public struct HardwareContext {
    public var thermalState: String?
    public var thermalStateRaw: String?
    public var cpuTempCelsius: Double?
    public var batteryLevel: Double?
    public var batteryCharging: Bool?
    public var memoryAvailableBytes: Int64?
    public var cpuFreqMhz: Int?
    public var cpuFreqMaxMhz: Int?
    public var acceleratorActual: Accelerator?
    public var gpuBusyPercent: Int?

    public init(
        thermalState: String? = nil,
        thermalStateRaw: String? = nil,
        cpuTempCelsius: Double? = nil,
        batteryLevel: Double? = nil,
        batteryCharging: Bool? = nil,
        memoryAvailableBytes: Int64? = nil,
        cpuFreqMhz: Int? = nil,
        cpuFreqMaxMhz: Int? = nil,
        acceleratorActual: Accelerator? = nil,
        gpuBusyPercent: Int? = nil
    ) {
        self.thermalState = thermalState
        self.thermalStateRaw = thermalStateRaw
        self.cpuTempCelsius = cpuTempCelsius
        self.batteryLevel = batteryLevel
        self.batteryCharging = batteryCharging
        self.memoryAvailableBytes = memoryAvailableBytes
        self.cpuFreqMhz = cpuFreqMhz
        self.cpuFreqMaxMhz = cpuFreqMaxMhz
        self.acceleratorActual = acceleratorActual
        self.gpuBusyPercent = gpuBusyPercent
    }

    internal func toMap() -> [String: Any] {
        var map: [String: Any] = [:]
        var thermal: [String: Any] = [:]

        if let thermalState {
            thermal["state"] = thermalState
        }
        if let thermalStateRaw {
            thermal["state_raw"] = thermalStateRaw
        }
        if let cpuTempCelsius {
            thermal["cpu_temp_celsius"] = cpuTempCelsius
        }
        if !thermal.isEmpty {
            map["thermal"] = thermal
        }

        if let batteryLevel { map["battery_level"] = batteryLevel }
        if let batteryCharging { map["battery_charging"] = batteryCharging }
        if let memoryAvailableBytes { map["memory_available_bytes"] = memoryAvailableBytes }
        if let cpuFreqMhz { map["cpu_freq_mhz"] = cpuFreqMhz }
        if let cpuFreqMaxMhz { map["cpu_freq_max_mhz"] = cpuFreqMaxMhz }
        if let acceleratorActual { map["accelerator_actual"] = acceleratorActual.rawValue }
        if let gpuBusyPercent { map["gpu_busy_percent"] = gpuBusyPercent }

        return map
    }
}
