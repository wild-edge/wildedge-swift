#if canImport(Darwin)
import Darwin
import XCTest
@testable import WildEdge

// MARK: - Memory footprint helper

/// Returns the process physical memory footprint in bytes using task_vm_info.
/// phys_footprint is the OS-attributed dirty memory — the right metric for
/// "how much RAM does this process actually own right now."
/// Returns -1 if the kernel call fails.
private func footprint() -> Int64 {
    var info  = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

private func fmt(_ bytes: Int64) -> String {
    switch bytes {
    case ..<0:             return "?"
    case ..<1_024:         return "\(bytes) B"
    case ..<(1_024*1_024): return String(format: "%.1f KB", Double(bytes)/1_024)
    default:               return String(format: "%.2f MB", Double(bytes)/(1_024*1_024))
    }
}

private func fmtDelta(_ delta: Int64) -> String {
    let sign = delta >= 0 ? "+" : ""
    return "\(sign)\(fmt(delta))"
}

// MARK: - Tests

final class BlobStoreMemoryTests: XCTestCase {

    private var storePath: String!

    override func setUp() {
        super.setUp()
        storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobstore-mem-\(UUID().uuidString).bin").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: storePath)
        super.tearDown()
    }

    // MARK: - BlobStore is memory-bounded

    /// Core property: the store writes directly to disk via write(2).
    /// No in-memory record buffer accumulates — footprint after N appends
    /// must not scale with N.
    func testAppendDoesNotAccumulateMemory() throws {
        let payload   = Data(repeating: 0xAB, count: 1_024)  // 1 KB per record
        let baseline  = footprint()
        let store     = try BlobStore(path: storePath)
        let afterOpen = footprint()

        for _ in 0 ..< 10_000 { try store.append(payload) }
        let after10k  = footprint()

        // Append 10× more records — footprint must not grow proportionally.
        for _ in 0 ..< 90_000 { try store.append(payload) }
        let after100k = footprint()

        let openDelta   = afterOpen - baseline
        let per10k      = after10k  - afterOpen
        let per100k     = after100k - afterOpen

        print("""

          testAppendDoesNotAccumulateMemory (1 KB × 100 000 records = 100 MB on disk)
            baseline      \(fmt(baseline))
            after open    \(fmt(afterOpen))    (\(fmtDelta(openDelta)) for store object)
            after  10 000 \(fmt(after10k))    (\(fmtDelta(per10k)) vs open)
            after 100 000 \(fmt(after100k))    (\(fmtDelta(per100k)) vs open)

        """)

        // 100k appends of 1 KB each = 100 MB written to disk.
        // In-memory overhead must stay under 2 MB regardless.
        XCTAssertLessThan(per100k, 2 * 1_024 * 1_024,
                          "footprint grew proportionally with records — data is being buffered in RAM")
    }

    // MARK: - Per-operation allocation

    /// Each append allocates a temporary record buffer (header + payload) and
    /// releases it immediately. Each reader.next() allocates header + payload
    /// buffers and releases them after the call. Measures the peak held
    /// across a batch of operations.
    func testPerOperationAllocation() throws {
        let scenarios: [(name: String, payloadSize: Int)] = [
            ("1 KB  ", 1_024),
            ("64 KB ", 65_536),
            ("1 MB  ", 1_048_576),
        ]

        var rows: [(String, Int64, Int64)] = []   // (name, appendDelta, readDelta)

        for s in scenarios {
            let payload = Data(repeating: 0xCC, count: s.payloadSize)

            // Append 100 records, measure net footprint change.
            let store = try BlobStore(path: storePath)
            let f0 = footprint()
            for _ in 0 ..< 100 { try store.append(payload) }
            let fAfterAppend = footprint()

            // Read them all back, measure net footprint change.
            let reader = try store.makeReader()
            let f1 = footprint()
            while let _ = try reader.next() {}
            let fAfterRead = footprint()

            rows.append((s.name, fAfterAppend - f0, fAfterRead - f1))

            // Clean up for next scenario.
            try? FileManager.default.removeItem(atPath: storePath)
        }

        let sep = "  " + String(repeating: "─", count: 52)
        print("\n")
        print("  per-operation footprint delta (100 records each)")
        print(sep)
        print("  Payload     append net         read net")
        print(sep)
        for (name, aDelta, rDelta) in rows {
            print(String(format: "  %@     %@          %@",
                         name, fmtDelta(aDelta).padding(toLength: 10, withPad: " ", startingAt: 0),
                         fmtDelta(rDelta)))
        }
        print(sep)
        print()
    }

    // MARK: - Reader independence

    /// Two concurrent readers each allocate their own payload buffer per
    /// next() call. Total held memory should be 2× one buffer, not 2×N.
    func testConcurrentReadersDoNotMultiplyMemory() throws {
        let payload = Data(repeating: 0xDD, count: 64 * 1_024)  // 64 KB
        let store   = try BlobStore(path: storePath)
        for _ in 0 ..< 1_000 { try store.append(payload) }

        let r1 = try store.makeReader()
        let r2 = try store.makeReader()

        let before = footprint()
        // Interleave reads from both readers — each call allocates one payload buffer.
        for _ in 0 ..< 1_000 {
            _ = try r1.next()
            _ = try r2.next()
        }
        let after = footprint()
        let delta = after - before

        print("\n  concurrent readers (2 × 1000 × 64 KB reads): delta = \(fmtDelta(delta))\n")

        // 128 MB of data read in total; net footprint must not approach that.
        XCTAssertLessThan(delta, 4 * 1_024 * 1_024,
                          "concurrent readers are retaining payload buffers")
    }

    // MARK: - BlobStore object overhead

    /// Reports the baseline RAM cost of a single BlobStore instance:
    /// two open fds, one NSLock, one String path — expected to be well under 1 KB.
    func testStoreObjectOverhead() throws {
        let before = footprint()
        let store  = try BlobStore(path: storePath)
        let after  = footprint()
        _ = store   // keep alive

        let delta = after - before
        print("\n  BlobStore object overhead: \(fmtDelta(delta))\n")

        XCTAssertLessThan(delta, 64 * 1_024,
                          "BlobStore object uses unexpectedly large amount of RAM")
    }
}
#endif
