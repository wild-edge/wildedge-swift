import XCTest
@testable import WildEdge
import WildEdgeBenchmarks

final class BlobStoreAppendBenchmarkTests: XCTestCase {

    // Use shared scenarios from WildEdgeBenchmarks
    private let scenarios = blobStoreAppendScenarios

    // MARK: - Entry point

    /// Measures the time to append all records for each scenario.
    /// Writes are buffered (no fsync); this reflects the hot path latency
    /// the caller observes, not durable-write throughput.
    func testAppendBenchmark() throws {
        var rows: [AppendRow] = []

        for scenario in scenarios {
            let locked   = try benchmark(scenario: scenario, threadSafe: true)
            let unlocked = try benchmark(scenario: scenario, threadSafe: false)
            rows.append(AppendRow(scenario: scenario, locked: locked, unlocked: unlocked))
        }

        printTable(rows)
    }

    // MARK: - Measurement

    /// Returns the mean wall-clock time (ms) to append all records in one
    /// iteration, averaged over `scenario.measured` runs.
    private func benchmark(scenario: BlobAppendScenario, threadSafe: Bool) throws -> Double {
        let payload = Data(repeating: 0xBB, count: scenario.payloadSize)
        var totalSec: Double = 0
        let warmup = 1  // always 1 warmup run

        for iteration in 0 ..< (warmup + scenario.measured) {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("blobstore-append-bench-\(UUID().uuidString).bin").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let store = try BlobStore(path: path, threadSafe: threadSafe)

            let t0 = monoSec()
            for _ in 0 ..< scenario.recordCount { try store.append(payload) }
            let elapsed = monoSec() - t0

            if iteration >= warmup { totalSec += elapsed }
        }

        return (totalSec / Double(scenario.measured)) * 1_000   // → ms
    }

    // MARK: - Output

    private struct AppendRow {
        let scenario: BlobAppendScenario; let locked: Double; let unlocked: Double
    }
    
    private func scenarioLabel(_ scenario: BlobAppendScenario) -> String {
        let rStr: String
        if      scenario.recordCount >= 1_000_000 { rStr = "\(scenario.recordCount / 1_000_000)M" }
        else if scenario.recordCount >= 1_000     { rStr = "\(scenario.recordCount / 1_000)k" }
        else                                      { rStr = "\(scenario.recordCount)" }
        return "\(scenario.name) (\(rStr) × \(blobFmtBytes(scenario.payloadSize)))"
    }

    private func printTable(_ results: [AppendRow]) {
        let col0 = 30, col1 = 10, col2 = 12, col3 = 12, col4 = 10, col5 = 8

        let sep = "  " + String(repeating: "─", count: col0+col1+col2+col3+col4+col5+5)

        print("\n")
        print("  append benchmark  (buffered, no fsync, +1 warmup per cell)")
        print(sep)
        print("  "
              + "Scenario".bPad(col0) + "Total".bPad(col1)
              + "locked".bPad(col2)   + "unlocked".bPad(col3)
              + "speedup".bPad(col4)  + "n".bPad(col5))
        print(sep)

        for r in results {
            let speedup = r.locked / r.unlocked

            print("  "
                  + scenarioLabel(r.scenario).bPad(col0)
                  + blobFmtBytes(r.scenario.totalBytes).bPad(col1)
                  + String(format: "%7.3f ms", r.locked).bPad(col2)
                  + String(format: "%7.3f ms", r.unlocked).bPad(col3)
                  + String(format: "%6.2f×", speedup).bPad(col4)
                  + "\(r.scenario.measured)".bPad(col5))
        }

        print(sep)
        print()
    }

    // MARK: - Helpers

    private func monoSec() -> Double { ProcessInfo.processInfo.systemUptime }
}

// MARK: - File-private formatting

private func blobFmtBytes(_ n: Int) -> String {
    switch n {
    case ..<1_024:             return "\(n) B"
    case ..<(1_024 * 1_024):  return String(format: "%.0f KB", Double(n) / 1_024)
    default:                  return String(format: "%.1f MB", Double(n) / (1_024 * 1_024))
    }
}

private extension String {
    func bPad(_ width: Int) -> String {
        count < width ? self + String(repeating: " ", count: width - count) : self + "  "
    }
}
