import XCTest
@testable import WildEdge
import WildEdgeBenchmarks

/// Compares JSON / binary / plist / compressedJSON encoding speed and encoded
/// size for a richly-populated inference event (all optional fields filled in).
final class BlobStoreDictionaryBenchmarkTests: XCTestCase {

    // Use shared key map and event from WildEdgeBenchmarks
    private let keyMap = blobStoreInferenceKeyMap
    private let richInferenceEvent = blobStoreRichInferenceEvent

    // MARK: - Benchmark

    private let measured  = 5
    private let warmup    = 1
    private let batchSize = 1_000   // events encoded per iteration

    func testEncodingBenchmark() throws {
        let event   = richInferenceEvent
        let cjsEnc  = BlobStore.DictionaryEncoding.compressedJSON(keyMap: keyMap)

        let jsonEncMs  = try bench(encoding: .json,   event: event)
        let binEncMs   = try bench(encoding: .binary, event: event)
        let plistEncMs = try bench(encoding: .plist,  event: event)
        let cjsEncMs   = try bench(encoding: cjsEnc,  event: event)

        let jsonDecMs  = try benchDecode(encoding: .json,   event: event)
        let binDecMs   = try benchDecode(encoding: .binary, event: event)
        let plistDecMs = try benchDecode(encoding: .plist,  event: event)
        let cjsDecMs   = try benchDecode(encoding: cjsEnc,  event: event)

        let jsonBytes  = try BlobStore.DictionaryEncoding.json.encode(event).count
        let binBytes   = try BlobStore.DictionaryEncoding.binary.encode(event).count
        let plistBytes = try BlobStore.DictionaryEncoding.plist.encode(event).count
        let cjsBytes   = try cjsEnc.encode(event).count

        printTable(
            jsonBytes: jsonBytes, binBytes: binBytes, plistBytes: plistBytes, cjsBytes: cjsBytes,
            jsonEncMs: jsonEncMs, binEncMs: binEncMs, plistEncMs: plistEncMs, cjsEncMs: cjsEncMs,
            jsonDecMs: jsonDecMs, binDecMs: binDecMs, plistDecMs: plistDecMs, cjsDecMs: cjsDecMs
        )
    }

    // MARK: - Measurement helpers

    /// Returns mean time (ms) to encode `batchSize` copies of `event`.
    private func bench(encoding: BlobStore.DictionaryEncoding,
                       event: [String: Any]) throws -> Double {
        var total: Double = 0
        for i in 0 ..< (warmup + measured) {
            let t0 = monoSec()
            for _ in 0 ..< batchSize { _ = try encoding.encode(event) }
            let dt = monoSec() - t0
            if i >= warmup { total += dt }
        }
        return (total / Double(measured)) * 1_000   // → ms for the full batch
    }

    /// Returns mean time (ms) to decode `batchSize` copies of the pre-encoded blob.
    private func benchDecode(encoding: BlobStore.DictionaryEncoding,
                              event: [String: Any]) throws -> Double {
        let encoded = try encoding.encode(event)
        var total: Double = 0
        for i in 0 ..< (warmup + measured) {
            let t0 = monoSec()
            for _ in 0 ..< batchSize { _ = try encoding.decode(encoded) }
            let dt = monoSec() - t0
            if i >= warmup { total += dt }
        }
        return (total / Double(measured)) * 1_000
    }

    private func monoSec() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - Output

    private func printTable(
        jsonBytes: Int,   binBytes: Int,   plistBytes: Int,   cjsBytes: Int,
        jsonEncMs: Double, binEncMs: Double, plistEncMs: Double, cjsEncMs: Double,
        jsonDecMs: Double, binDecMs: Double, plistDecMs: Double, cjsDecMs: Double
    ) {
        func winner4(_ vals: [Double], _ labels: [String]) -> String {
            let m = vals.min()!
            return labels[vals.firstIndex(of: m)!]
        }
        let sizeLabels = ["json  ", "binary", "plist ", "cjson "]
        let sizeW = winner4([Double(jsonBytes), Double(binBytes),
                             Double(plistBytes), Double(cjsBytes)], sizeLabels)
        let encW  = winner4([jsonEncMs, binEncMs, plistEncMs, cjsEncMs], sizeLabels)
        let decW  = winner4([jsonDecMs, binDecMs, plistDecMs, cjsDecMs], sizeLabels)

        let s = Double(batchSize)
        let (pej, peb, pep, pec) = (jsonEncMs/s*1000, binEncMs/s*1000, plistEncMs/s*1000, cjsEncMs/s*1000)
        let (pdj, pdb, pdp, pdc) = (jsonDecMs/s*1000, binDecMs/s*1000, plistDecMs/s*1000, cjsDecMs/s*1000)

        let sep = "  " + String(repeating: "─", count: 84)
        print("\n")
        print("  dictionary encoding benchmark — rich inference event")
        print("  \(batchSize) events per iteration, \(measured) measured + \(warmup) warmup")
        print(sep)
        print("                        json          binary        plist         cjson         winner")
        print(sep)
        print(String(format: "  encoded size      %6d B       %6d B       %6d B       %6d B       %@",
                     jsonBytes, binBytes, plistBytes, cjsBytes, sizeW))
        print(sep)
        print(String(format: "  encode %4d×    %7.2f ms    %7.2f ms    %7.2f ms    %7.2f ms    %@",
                     batchSize, jsonEncMs, binEncMs, plistEncMs, cjsEncMs, encW))
        print(String(format: "  encode per event  %7.2f µs    %7.2f µs    %7.2f µs    %7.2f µs",
                     pej, peb, pep, pec))
        print(sep)
        print(String(format: "  decode %4d×    %7.2f ms    %7.2f ms    %7.2f ms    %7.2f ms    %@",
                     batchSize, jsonDecMs, binDecMs, plistDecMs, cjsDecMs, decW))
        print(String(format: "  decode per event  %7.2f µs    %7.2f µs    %7.2f µs    %7.2f µs",
                     pdj, pdb, pdp, pdc))
        print(sep)
        print()
    }
}
