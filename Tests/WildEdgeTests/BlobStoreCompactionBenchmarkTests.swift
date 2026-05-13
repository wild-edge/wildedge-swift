import XCTest
@testable import WildEdge
import WildEdgeBenchmarks

final class BlobStoreCompactionBenchmarkTests: XCTestCase {

    // Use shared scenarios from WildEdgeBenchmarks
    private let scenarios = blobStoreCompactionScenarios

    // MARK: - Benchmark entry point

    func testCompactionBenchmark() throws {
        var results: [(scenario: BlobCompactionScenario, inPlace: Double, rename: Double)] = []

        for scenario in scenarios {
            let inPlaceMs = try benchmark(scenario: scenario, compaction: .inPlace)
            let renameMs  = try benchmark(scenario: scenario, compaction: .rename)
            results.append((scenario, inPlaceMs, renameMs))
        }

        printTable(results)
    }

    // MARK: - Measurement

    /// Returns the mean wall-clock time (ms) for `dropFirst` over
    /// `scenario.measured` runs, preceded by 1 warmup run.
    private func benchmark(scenario: BlobCompactionScenario,
                           compaction: BlobStore.CompactionStrategy) throws -> Double {
        let payload = Data(repeating: 0xAA, count: scenario.payloadSize)
        var totalSec: Double = 0
        let warmup = 1  // always 1 warmup run

        for iteration in 0 ..< (warmup + scenario.measured) {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("blobstore-bench-\(UUID().uuidString).bin").path
            defer {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + ".tmp")
            }

            let store = try BlobStore(path: path, compaction: compaction)
            for _ in 0 ..< scenario.recordCount { try store.append(payload) }

            let t0 = monoSec()
            try store.dropFirst(scenario.dropCount)
            let elapsed = monoSec() - t0

            if iteration >= warmup {
                totalSec += elapsed
            }
        }

        return (totalSec / Double(scenario.measured)) * 1_000   // → ms
    }

    // MARK: - Output

    private func printTable(
        _ results: [(scenario: BlobCompactionScenario, inPlace: Double, rename: Double)]
    ) {
        let col0 = 44, col1 = 12, col2 = 12, col3 = 10, col4 = 6

        let sep = "  " + String(repeating: "─", count: col0 + col1 + col2 + col3 + col4 + 6)

        print("\n")
        print("  dropFirst compaction benchmark  (+1 warmup per cell)")
        print(sep)
        print("  "
              + "Scenario".pad(col0)
              + "inPlace".pad(col1)
              + "rename".pad(col2)
              + "faster".pad(col3)
              + "n".pad(col4))
        print(sep)

        for r in results {
            let winner: String
            let diff = abs(r.inPlace - r.rename)
            let pct  = diff / max(r.inPlace, r.rename) * 100
            if pct < 3 {
                winner = "≈ tie"
            } else if r.inPlace < r.rename {
                winner = "inPlace"
            } else {
                winner = "rename"
            }

            let label = scenarioLabel(r.scenario)
            print("  "
                  + label.pad(col0)
                  + String(format: "%7.3f ms", r.inPlace).pad(col1)
                  + String(format: "%7.3f ms", r.rename).pad(col2)
                  + winner.pad(col3)
                  + "\(r.scenario.measured)".pad(col4))
        }

        print(sep)
        print()
    }

    private func scenarioLabel(_ scenario: BlobCompactionScenario) -> String {
        let r = scenario.records >= 1_000 ? "\(scenario.records / 1_000)k" : "\(scenario.records)"
        return "\(scenario.name) (\(r)×\(formatBytes(scenario.payloadSize)), shift \(formatBytes(scenario.bytesShifted)))"
    }

    // MARK: - Helpers

    private func monoSec() -> Double {
        // ProcessInfo.systemUptime is backed by a monotonic clock on both
        // Darwin and Linux (no NTP jumps, no leap-second corrections).
        ProcessInfo.processInfo.systemUptime
    }
}

// MARK: - Formatting

private func formatBytes(_ n: Int) -> String {
    switch n {
    case ..<1_024:               return "\(n) B"
    case ..<(1_024 * 1_024):    return String(format: "%.0f KB", Double(n) / 1_024)
    default:                    return String(format: "%.1f MB", Double(n) / (1_024 * 1_024))
    }
}

private extension String {
    func pad(_ width: Int) -> String {
        guard count < width else { return self + "  " }
        return self + String(repeating: " ", count: width - count)
    }
}

// Mirror the file-private constant from BlobStore.swift so the scenario
// can compute bytesShifted without exposing it from the module.
private let _headerSize = 20
