import Foundation
import zlib

// Scenario definitions are now in BlobStoreScenarios.swift (shared with tests)

// MARK: - Result types

public struct BlobAppendResult {
    public let scenario:   BlobAppendScenario
    public let lockedMs:   Double
    public let unlockedMs: Double

    public var speedup: Double       { lockedMs / max(unlockedMs, 0.001) }
    public var throughputMBs: Double { scenario.totalMB / (lockedMs / 1_000) }
}

public struct BlobCompactionResult {
    public let scenario:  BlobCompactionScenario
    public let inPlaceMs: Double
    public let renameMs:  Double

    public var faster: String { inPlaceMs <= renameMs ? "inPlace" : "rename" }
}

// MARK: - Runners

/// Runs append benchmarks using the canonical scenarios.
/// Blocking — call from a background thread or `Task.detached`.
public func blobAppendBenchmark(
    scenarios: [BlobAppendScenario] = blobStoreAppendScenarios,
    progress: @escaping (String) -> Void = { _ in }
) throws -> [BlobAppendResult] {
    try scenarios.map { s in
        progress("\(s.name.trimmingCharacters(in: .whitespaces))  (\(s.recordCount) × \(_fmtBytes(s.payloadSize)))…")
        let locked   = try _appendMs(s, threadSafe: true)
        let unlocked = try _appendMs(s, threadSafe: false)
        return BlobAppendResult(scenario: s, lockedMs: locked, unlockedMs: unlocked)
    }
}

/// Runs compaction benchmarks using the canonical scenarios.
/// Blocking — call from a background thread or `Task.detached`.
public func blobCompactionBenchmark(
    scenarios: [BlobCompactionScenario] = blobStoreCompactionScenarios,
    progress: @escaping (String) -> Void = { _ in }
) throws -> [BlobCompactionResult] {
    try scenarios.map { s in
        progress("\(s.name.trimmingCharacters(in: .whitespaces))  (shift \(String(format:"%.0f", s.shiftMB)) MB)…")
        let inPlace = try _compactionMs(s, strategy: .inPlace)
        let rename  = try _compactionMs(s, strategy: .rename)
        return BlobCompactionResult(scenario: s, inPlaceMs: inPlace, renameMs: rename)
    }
}

// MARK: - Private helpers

private func _monoSec() -> Double { ProcessInfo.processInfo.systemUptime }

private func _appendMs(_ s: BlobAppendScenario, threadSafe: Bool) throws -> Double {
    let payload = Data(repeating: 0xAA, count: s.payloadSize)
    var total = 0.0
    for i in 0 ..< (1 + s.measured) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("we-bench-\(UUID().uuidString).bin").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try BlobStore(path: path, threadSafe: threadSafe)
        let t0 = _monoSec()
        for _ in 0 ..< s.recordCount { try store.append(payload) }
        if i > 0 { total += (_monoSec() - t0) * 1_000 }
    }
    return total / Double(s.measured)
}

private func _compactionMs(_ s: BlobCompactionScenario,
                            strategy: BlobStore.CompactionStrategy) throws -> Double {
    let payload = Data(repeating: 0xBB, count: s.payloadSize)
    var total = 0.0
    for i in 0 ..< (1 + s.measured) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("we-bench-\(UUID().uuidString).bin").path
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".tmp")
        }
        let store = try BlobStore(path: path, compaction: strategy)
        for _ in 0 ..< s.recordCount { try store.append(payload) }
        let t0 = _monoSec()
        try store.dropFirst(s.dropCount)
        if i > 0 { total += (_monoSec() - t0) * 1_000 }
    }
    return total / Double(s.measured)
}

private func _fmtBytes(_ n: Int) -> String {
    switch n {
    case ..<1_024:             return "\(n) B"
    case ..<(1_024 * 1_024):  return "\(n / 1_024) KB"
    default:                  return "\(n / (1_024 * 1_024)) MB"
    }
}

// MARK: - Encoding benchmark (mirrors BlobStoreDictionaryBenchmarkTests)

public struct BlobEncodingResult {
    public let encoding:     String   // "json" / "binary" / "plist" / "cjson"
    public let sizeBytes:    Int
    public let encodeMs:     Double   // mean ms per batchSize events
    public let decodeMs:     Double
    public let batchSize:    Int
    public let measured:     Int

    public var encodeUsPerEvent: Double { encodeMs / Double(batchSize) * 1_000 }
    public var decodeUsPerEvent: Double { decodeMs / Double(batchSize) * 1_000 }
}

/// Runs dictionary encoding benchmarks for all four encodings.
/// Uses the same rich inference event and key map as the Mac test suite.
/// Blocking — call from a background thread or `Task.detached`.
public func blobEncodingBenchmark(
    batchSize: Int = 1_000,
    measured:  Int = 5,
    progress: @escaping (String) -> Void = { _ in }
) throws -> [BlobEncodingResult] {
    let event  = blobStoreRichInferenceEvent
    let cjsEnc = BlobStore.DictionaryEncoding.compressedJSON(keyMap: blobStoreInferenceKeyMap)

    let pairs: [(label: String, enc: BlobStore.DictionaryEncoding)] = [
        ("json",   .json),
        ("binary", .binary),
        ("plist",  .plist),
        ("cjson",  cjsEnc),
    ]

    return try pairs.map { pair in
        progress("encoding \(pair.label)…")
        let encMs = try _encodingMs(pair.enc, event: event,
                                    batchSize: batchSize, measured: measured)
        let decMs = try _decodingMs(pair.enc, event: event,
                                    batchSize: batchSize, measured: measured)
        let bytes = (try? pair.enc.encode(event).count) ?? 0
        return BlobEncodingResult(encoding: pair.label, sizeBytes: bytes,
                                  encodeMs: encMs, decodeMs: decMs,
                                  batchSize: batchSize, measured: measured)
    }
}

private func _encodingMs(_ enc: BlobStore.DictionaryEncoding,
                          event: [String: Any],
                          batchSize: Int, measured: Int) throws -> Double {
    var total = 0.0
    for i in 0 ..< (1 + measured) {
        let t0 = _monoSec()
        for _ in 0 ..< batchSize { _ = try enc.encode(event) }
        if i > 0 { total += (_monoSec() - t0) * 1_000 }
    }
    return total / Double(measured)
}

private func _decodingMs(_ enc: BlobStore.DictionaryEncoding,
                          event: [String: Any],
                          batchSize: Int, measured: Int) throws -> Double {
    let encoded = try enc.encode(event)
    var total   = 0.0
    for i in 0 ..< (1 + measured) {
        let t0 = _monoSec()
        for _ in 0 ..< batchSize { _ = try enc.decode(encoded) }
        if i > 0 { total += (_monoSec() - t0) * 1_000 }
    }
    return total / Double(measured)
}

// Canonical event & key map are now in BlobStoreScenarios.swift (shared with tests)

// MARK: - Gzip benchmark

public struct GzipResult {
    public let scenario:     GzipScenario
    public let inputBytes:   Int
    public let outputBytes:  Int
    public let compressMs:   Double   // mean ms for one compression

    public var ratio: Double        { Double(outputBytes) / Double(max(inputBytes, 1)) }
    public var throughputMBs: Double { Double(inputBytes) / (1_024 * 1_024) / (compressMs / 1_000) }
}

/// Runs gzip compression benchmarks over realistic JSON batch payloads.
/// Blocking — call from a background thread or `Task.detached`.
public func gzipBatchBenchmark(
    scenarios: [GzipScenario] = gzipBatchScenarios,
    progress: @escaping (String) -> Void = { _ in }
) -> [GzipResult] {
    scenarios.compactMap { s in
        progress("\(s.name.trimmingCharacters(in: .whitespaces))…")
        guard let batch = _makeBatch(eventCount: s.eventCount) else { return nil }
        let outputBytes = _gzip(batch)?.count ?? batch.count
        var total = 0.0
        for i in 0 ..< (1 + s.measured) {
            let t0 = _monoSec()
            _ = _gzip(batch)
            if i > 0 { total += (_monoSec() - t0) * 1_000 }
        }
        return GzipResult(
            scenario: s,
            inputBytes: batch.count,
            outputBytes: outputBytes,
            compressMs: total / Double(s.measured)
        )
    }
}

private func _makeBatch(eventCount: Int) -> Data? {
    let event = blobStoreRichInferenceEvent
    guard let singleData = try? JSONSerialization.data(withJSONObject: event) else { return nil }
    let events = Array(repeating: event, count: eventCount)
    let batch: [String: Any] = [
        "protocol_version": "1.0",
        "session_id": "bench-session",
        "batch_id": "bench-batch",
        "created_at": "2026-05-19T00:00:00.000Z",
        "sent_at": "2026-05-19T00:00:01.000Z",
        "device": ["device_id": "bench-device", "device_type": "ios"],
        "models": ["gpt2-medium-q4": ["model_name": "gpt2", "model_source": "local", "model_format": "gguf"]],
        "events": events,
    ]
    _ = singleData
    return try? JSONSerialization.data(withJSONObject: batch)
}

// windowBits = 31 (15 + 16) → gzip format.
private func _gzip(_ input: Data) -> Data? {
    guard !input.isEmpty else { return input }
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { deflateEnd(&stream) }

    let chunkSize = 64 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    var output = Data()
    output.reserveCapacity(input.count / 2)

    input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
        stream.avail_in = uInt(input.count)
        repeat {
            var written = 0
            chunk.withUnsafeMutableBytes { dst in
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkSize)
                deflate(&stream, Z_FINISH)
                written = chunkSize - Int(stream.avail_out)
            }
            output.append(contentsOf: chunk[..<written])
        } while stream.avail_out == 0
    }
    return output
}
