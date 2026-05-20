import XCTest
import zlib
@testable import WildEdge

final class TransmitterGzipTests: XCTestCase {

    // MARK: - Correctness

    func testGzipMagicBytes() throws {
        let compressed = try XCTUnwrap(gzipCompress(Data("hello".utf8)))
        XCTAssertEqual(compressed[0], 0x1f)
        XCTAssertEqual(compressed[1], 0x8b)
    }

    func testGzipEmptyDataPassesThrough() {
        XCTAssertEqual(gzipCompress(Data()), Data())
    }

    func testGzipRoundTripText() throws {
        let original = Data("The quick brown fox jumps over the lazy dog".utf8)
        let compressed = try XCTUnwrap(gzipCompress(original))
        let restored   = try XCTUnwrap(gzipDecompress(compressed))
        XCTAssertEqual(restored, original)
    }

    func testGzipRoundTripRepetitive() throws {
        let original   = Data(repeating: 0x41, count: 100_000)
        let compressed = try XCTUnwrap(gzipCompress(original))
        XCTAssertLessThan(compressed.count, original.count / 10, "highly repetitive data should compress >10×")
        let restored = try XCTUnwrap(gzipDecompress(compressed))
        XCTAssertEqual(restored, original)
    }

    func testGzipRoundTripJSONBatch() throws {
        let batchData = try XCTUnwrap(makeSmallBatch())
        let compressed = try XCTUnwrap(gzipCompress(batchData))
        XCTAssertLessThan(compressed.count, batchData.count, "JSON should compress smaller than original")
        let restored = try XCTUnwrap(gzipDecompress(compressed))
        XCTAssertEqual(restored, batchData)
    }

    func testGzipRoundTripLargeBatch() throws {
        let batchData = try XCTUnwrap(makeLargeBatch(eventCount: 50))
        let compressed = try XCTUnwrap(gzipCompress(batchData))
        let restored   = try XCTUnwrap(gzipDecompress(compressed))
        XCTAssertEqual(restored, batchData)
    }

    // MARK: - Benchmark

    func testGzipBenchmarkSmall() throws {
        let data = try XCTUnwrap(makeSmallBatch())
        printRatio(label: "small  (1 event) ", data: data)
        measure {
            for _ in 0..<200 { _ = gzipCompress(data) }
        }
    }

    func testGzipBenchmarkMedium() throws {
        let data = try XCTUnwrap(makeLargeBatch(eventCount: 10))
        printRatio(label: "medium (10 events)", data: data)
        measure {
            for _ in 0..<100 { _ = gzipCompress(data) }
        }
    }

    func testGzipBenchmarkLarge() throws {
        let data = try XCTUnwrap(makeLargeBatch(eventCount: 100))
        printRatio(label: "large  (100 events)", data: data)
        measure {
            for _ in 0..<20 { _ = gzipCompress(data) }
        }
    }

    private func printRatio(label: String, data: Data) {
        let compressed = gzipCompress(data) ?? data
        let ratio = Double(compressed.count) / Double(data.count)
        print(String(format: "  gzip %-20@  %6d B → %5d B  (%.1f%%)",
                     label as NSString, data.count, compressed.count, ratio * 100))
    }

    // MARK: - Helpers

    private func makeSmallBatch() -> Data? {
        let event = buildInferenceEvent(
            modelId: "bench-model",
            durationMs: 42,
            inputModality: .text,
            outputModality: .generation,
            success: true,
            inputMeta: TextInputMeta(charCount: 512, wordCount: 87, tokenCount: 128, language: "en").toMap(),
            outputMeta: GenerationOutputMeta(tokensIn: 128, tokensOut: 256, stopReason: "eos").toMap()
        )
        return buildBatch(
            device: testDevice(),
            models: ["bench-model": testModelMap()],
            events: [event],
            sessionId: UUID().uuidString,
            createdAt: isoNow(),
            lowConfidenceThreshold: 0.5
        )
    }

    private func makeLargeBatch(eventCount: Int) -> Data? {
        let events = (0..<eventCount).map { i in
            buildInferenceEvent(
                modelId: "bench-model",
                durationMs: 40 + i,
                inputModality: .text,
                outputModality: .generation,
                success: true,
                inputMeta: TextInputMeta(charCount: 512, wordCount: 87, tokenCount: 128,
                                         language: "en", languageConfidence: 0.98).toMap(),
                outputMeta: GenerationOutputMeta(tokensIn: 128, tokensOut: 256,
                                                 cachedInputTokens: 64, stopReason: "eos").toMap(),
                hardware: HardwareContext(thermalState: "nominal", batteryLevel: 0.8,
                                          memoryAvailableBytes: 2_000_000_000)
            )
        }
        return buildBatch(
            device: testDevice(),
            models: ["bench-model": testModelMap()],
            events: events,
            sessionId: UUID().uuidString,
            createdAt: isoNow(),
            lowConfidenceThreshold: 0.5
        )
    }

    private func testDevice() -> DeviceInfo {
        DeviceInfo(
            deviceId: "test-device",
            deviceType: "ios",
            deviceModel: "iPhone 16 Pro",
            osVersion: "18.2",
            appVersion: "1.0",
            sdkVersion: "test",
            locale: "en-US",
            timezone: "UTC"
        )
    }

    private func testModelMap() -> [String: Any] {
        ["model_name": "bench-model", "model_source": "local",
         "model_format": "coreml", "model_version": "1.0"]
    }

    // windowBits = 47 (15 + 32) → auto-detect gzip or zlib header.
    private func gzipDecompress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return input }
        var stream = z_stream()
        guard inflateInit2_(&stream, 47, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()

        input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            var status = Z_OK
            repeat {
                var written = 0
                chunk.withUnsafeMutableBytes { dst in
                    stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    written = chunkSize - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk[..<written])
            } while status == Z_OK && stream.avail_out == 0
        }
        return output
    }
}
