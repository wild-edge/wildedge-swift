import Foundation

internal func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
}

internal func newEventId() -> String {
    UUID().uuidString
}

internal func buildInferenceEvent(
    modelId: String,
    durationMs: Int,
    inputModality: InputModality? = nil,
    outputModality: OutputModality? = nil,
    success: Bool = true,
    errorCode: String? = nil,
    inputMeta: [String: Any]? = nil,
    outputMeta: [String: Any]? = nil,
    generationConfig: [String: Any]? = nil,
    hardware: HardwareContext? = nil,
    traceId: String? = nil,
    spanId: String? = nil,
    parentSpanId: String? = nil,
    runId: String? = nil,
    agentId: String? = nil
) -> [String: Any] {
    let inferenceId = newEventId()
    var inference: [String: Any] = [
        "inference_id": inferenceId,
        "duration_ms": durationMs,
        "success": success,
    ]

    if let inputModality {
        inference["input_modality"] = inputModality.rawValue
    }
    if let outputModality {
        inference["output_modality"] = outputModality.rawValue
    }
    if let errorCode {
        inference["error_code"] = errorCode
    }
    if let inputMeta {
        inference["input_meta"] = inputMeta
    }
    if let outputMeta {
        inference["output_meta"] = outputMeta
    }
    if let generationConfig {
        inference["generation_config"] = generationConfig
    }

    let hw = hardware?.toMap() ?? [:]
    if !hw.isEmpty {
        inference["hardware"] = hw
    }

    var event: [String: Any] = [
        "event_id": newEventId(),
        "event_type": "inference",
        "timestamp": isoNow(),
        "model_id": modelId,
        "inference": inference,
        "__we_inference_id": inferenceId,
    ]

    if let traceId {
        event["trace_id"] = traceId
    }
    if let spanId {
        event["span_id"] = spanId
    }
    if let parentSpanId {
        event["parent_span_id"] = parentSpanId
    }
    if let runId {
        event["run_id"] = runId
    }
    if let agentId {
        event["agent_id"] = agentId
    }

    return event
}

internal func buildModelLoadEvent(
    modelId: String,
    durationMs: Int,
    memoryBytes: Int64? = nil,
    accelerator: Accelerator? = nil,
    success: Bool = true,
    errorCode: String? = nil,
    coldStart: Bool? = nil,
    threads: Int? = nil
) -> [String: Any] {
    var load: [String: Any] = [
        "duration_ms": durationMs,
        "success": success,
    ]

    if let memoryBytes { load["memory_bytes"] = memoryBytes }
    load["accelerator"] = (accelerator ?? .cpu).rawValue
    if let errorCode { load["error_code"] = errorCode }
    if let coldStart { load["cold_start"] = coldStart }
    if let threads { load["threads"] = threads }

    return [
        "event_id": newEventId(),
        "event_type": "model_load",
        "timestamp": isoNow(),
        "model_id": modelId,
        "load": load,
    ]
}

internal func buildModelUnloadEvent(
    modelId: String,
    durationMs: Int,
    reason: String,
    memoryFreedBytes: Int64? = nil,
    uptimeMs: Int64? = nil
) -> [String: Any] {
    var unload: [String: Any] = [
        "duration_ms": durationMs,
        "reason": reason,
    ]

    if let memoryFreedBytes { unload["memory_freed_bytes"] = memoryFreedBytes }
    if let uptimeMs { unload["uptime_ms"] = uptimeMs }

    return [
        "event_id": newEventId(),
        "event_type": "model_unload",
        "timestamp": isoNow(),
        "model_id": modelId,
        "unload": unload,
    ]
}

internal func buildModelDownloadEvent(
    modelId: String,
    sourceUrl: String,
    sourceType: String,
    fileSizeBytes: Int64,
    downloadedBytes: Int64,
    durationMs: Int,
    networkType: String,
    resumed: Bool,
    cacheHit: Bool,
    success: Bool,
    errorCode: String? = nil
) -> [String: Any] {
    var download: [String: Any] = [
        "source_url": sourceUrl,
        "source_type": sourceType,
        "file_size_bytes": fileSizeBytes,
        "downloaded_bytes": downloadedBytes,
        "duration_ms": durationMs,
        "network_type": networkType,
        "resumed": resumed,
        "cache_hit": cacheHit,
        "success": success,
    ]

    if let errorCode {
        download["error_code"] = errorCode
    }

    return [
        "event_id": newEventId(),
        "event_type": "model_download",
        "timestamp": isoNow(),
        "model_id": modelId,
        "download": download,
    ]
}

internal func buildFeedbackEvent(
    modelId: String,
    relatedInferenceId: String,
    feedbackType: FeedbackType,
    delayMs: Int? = nil,
    editDistance: Int? = nil
) -> [String: Any] {
    var feedback: [String: Any] = [
        "related_inference_id": relatedInferenceId,
        "feedback_type": feedbackType.value,
    ]
    if let delayMs { feedback["delay_ms"] = delayMs }
    if let editDistance { feedback["edit_distance"] = editDistance }

    return [
        "event_id": newEventId(),
        "event_type": "feedback",
        "timestamp": isoNow(),
        "model_id": modelId,
        "feedback": feedback,
    ]
}

internal func buildErrorEvent(
    modelId: String?,
    errorCode: String,
    errorMessage: String? = nil,
    stackTraceHash: String? = nil,
    relatedEventId: String? = nil
) -> [String: Any] {
    var errorPayload: [String: Any] = [
        "error_code": errorCode,
    ]

    if let errorMessage {
        errorPayload["error_message"] = String(errorMessage.prefix(Config.errorMsgMaxLen))
    }
    if let stackTraceHash { errorPayload["stack_trace_hash"] = stackTraceHash }
    if let relatedEventId { errorPayload["related_event_id"] = relatedEventId }

    var event: [String: Any] = [
        "event_id": newEventId(),
        "event_type": "error",
        "timestamp": isoNow(),
        "error": errorPayload,
    ]

    if let modelId {
        event["model_id"] = modelId
    }

    return event
}

internal func buildSpanEvent(
    traceId: String,
    spanId: String,
    parentSpanId: String?,
    kind: SpanKind,
    status: SpanStatus,
    name: String,
    durationMs: Int64,
    attributes: [String: Any]? = nil
) -> [String: Any] {
    var span: [String: Any] = [
        "kind": kind.rawValue,
        "status": status.rawValue,
        "name": name,
        "duration_ms": durationMs,
    ]
    if let attributes {
        span["attributes"] = attributes
    }

    var event: [String: Any] = [
        "event_id": newEventId(),
        "event_type": "span",
        "timestamp": isoNow(),
        "trace_id": traceId,
        "span_id": spanId,
        "span": span,
    ]

    if let parentSpanId {
        event["parent_span_id"] = parentSpanId
    }

    return event
}

internal func buildMemoryWarningEvent(
    level: MemoryWarningLevel,
    memoryAvailableBytes: Int64,
    activeModelIds: [String],
    triggeredUnload: Bool,
    unloadedModelId: String? = nil
) -> [String: Any] {
    var warning: [String: Any] = [
        "level": level.rawValue,
        "memory_available_bytes": memoryAvailableBytes,
        "active_model_ids": activeModelIds,
        "triggered_unload": triggeredUnload,
    ]
    if let unloadedModelId {
        warning["unloaded_model_id"] = unloadedModelId
    }

    return [
        "event_id": newEventId(),
        "event_type": "memory_warning",
        "timestamp": isoNow(),
        "memory_warning": warning,
    ]
}

internal func jsonData(_ object: Any) -> Data? {
    let sanitized = sanitizeFloats(object)
    guard JSONSerialization.isValidJSONObject(sanitized) else {
        return nil
    }
    return try? JSONSerialization.data(withJSONObject: sanitized)
}

// JSONSerialization serialises Swift Doubles using their full binary representation
// (e.g. 0.9 → "0.90000000000000002"). Converting to NSDecimalNumber via Swift's
// shortest-decimal String representation (Grisu/Dragon4) produces clean output.
private func sanitizeFloats(_ value: Any) -> Any {
    switch value {
    case let dict as [String: Any]:
        return dict.mapValues { sanitizeFloats($0) }
    case let array as [Any]:
        return array.map { sanitizeFloats($0) }
    case let v as Double:
        return NSDecimalNumber(string: String(v))
    case let v as Float:
        return NSDecimalNumber(string: String(v))
    default:
        return value
    }
}

internal func buildBatch(
    device: DeviceInfo,
    models: [String: [String: Any]],
    events: [[String: Any]],
    sessionId: String,
    createdAt: String,
    lowConfidenceThreshold: Double
) -> Data? {
    let strippedEvents = events.map { event in
        event.filter { key, _ in !key.hasPrefix("__we_") }
    }

    var batch: [String: Any] = [
        "protocol_version": Config.protocolVersion,
        "device": device.toMap(),
        "models": models,
        "session_id": sessionId,
        "batch_id": UUID().uuidString,
        "created_at": createdAt,
        "sent_at": isoNow(),
        "events": strippedEvents,
    ]

    if let sampling = buildSampling(events: strippedEvents, threshold: lowConfidenceThreshold) {
        batch["sampling"] = sampling
    }

    return jsonData(batch)
}

private func buildSampling(events: [[String: Any]], threshold: Double) -> [String: Any]? {
    let inferenceEvents = events.filter { ($0["event_type"] as? String) == "inference" }
    guard !inferenceEvents.isEmpty else {
        return nil
    }

    var grouped: [String: [[String: Any]]] = [:]
    for event in inferenceEvents {
        let modelId = (event["model_id"] as? String) ?? "unknown"
        grouped[modelId, default: []].append(event)
    }

    var sampling: [String: Any] = [
        "low_confidence_threshold": threshold,
    ]

    for (modelId, modelEvents) in grouped {
        let lowConfidence = modelEvents.filter { event in
            guard
                let inference = event["inference"] as? [String: Any],
                let outputMeta = inference["output_meta"] as? [String: Any],
                let avgConfidence = outputMeta["avg_confidence"] as? Double
            else {
                return false
            }
            return avgConfidence < threshold
        }.count

        sampling[modelId] = [
            "total_inference_events_seen": modelEvents.count,
            "total_inference_events_sent": modelEvents.count,
            "low_confidence_seen": lowConfidence,
            "low_confidence_sent": lowConfidence,
        ]
    }

    return sampling
}
