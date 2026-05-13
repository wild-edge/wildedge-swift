#if canImport(Darwin)
import Darwin
import XCTest
@testable import WildEdge

// MARK: - CPU time snapshot

/// Captures cumulative process CPU time via getrusage(RUSAGE_SELF).
/// - `user`: time spent in user-space (Swift code, ARC, Data ops).
/// - `system`: time spent in the kernel on behalf of this process
///             (write, pread, open, ftruncate, rename syscalls).
private struct CPUSnapshot {
    let userUs:   Int64   // microseconds
    let systemUs: Int64

    static func now() -> CPUSnapshot {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return CPUSnapshot(
            userUs:   Int64(r.ru_utime.tv_sec) * 1_000_000 + Int64(r.ru_utime.tv_usec),
            systemUs: Int64(r.ru_stime.tv_sec) * 1_000_000 + Int64(r.ru_stime.tv_usec)
        )
    }

    static func - (lhs: CPUSnapshot, rhs: CPUSnapshot) -> CPUSnapshot {
        CPUSnapshot(userUs: lhs.userUs - rhs.userUs, systemUs: lhs.systemUs - rhs.systemUs)
    }

    var totalUs: Int64 { userUs + systemUs }
}

// MARK: - Helpers

private func fmtMs(_ us: Int64) -> String { String(format: "%7.2f ms", Double(us) / 1_000) }
private func fmtMB(_ bytes: Int) -> String {
    bytes >= 1_024*1_024
        ? String(format: "%.0f MB", Double(bytes) / (1_024*1_024))
        : String(format: "%.0f KB", Double(bytes) / 1_024)
}

// MARK: - Shared row type

private struct CPURow {
    let name:   String
    let wallUs: Int64
    let cpu:    CPUSnapshot
    let bytes:  Int
}

// MARK: - Tests

final class BlobStoreCPUTests: XCTestCase {

    private var storePath: String!

    override func setUp() {
        super.setUp()
        storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobstore-cpu-\(UUID().uuidString).bin").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: storePath)
        super.tearDown()
    }

    // MARK: - Append: user vs system time across payload sizes
    //
    // Hypothesis:
    //   tiny records → system time dominates (many write(2) syscalls)
    //   large records → user time grows (building the Data record buffer)
    //   util ≈ 100% for all → buffered writes never block; time is kernel execution
    //   not disk I/O wait.

    func testAppendCPUProfile() throws {
        // All scenarios write exactly 100 MB.
        let scenarios: [(name: String, count: Int, size: Int)] = [
            ("100b ", 1_048_576,         100),
            ("1kb  ",   102_400,       1_024),
            ("10kb ",    10_240,      10_240),
            ("1mb  ",       100,   1_048_576),
            ("100mb",         1, 104_857_600),
        ]

        typealias Row = CPURow
        var rows: [Row] = []

        for s in scenarios {
            let payload = Data(repeating: 0xAA, count: s.size)
            let store   = try BlobStore(path: storePath)
            // warmup
            for _ in 0 ..< min(s.count / 10, 1_000) { try store.append(payload) }
            try? FileManager.default.removeItem(atPath: storePath)
            let store2 = try BlobStore(path: storePath)

            let t0  = ProcessInfo.processInfo.systemUptime
            let c0  = CPUSnapshot.now()
            for _ in 0 ..< s.count { try store2.append(payload) }
            let cpu  = CPUSnapshot.now() - c0
            let wall = Int64((ProcessInfo.processInfo.systemUptime - t0) * 1_000_000)

            rows.append(Row(name: s.name, wallUs: wall, cpu: cpu, bytes: s.count * s.size))
            try? FileManager.default.removeItem(atPath: storePath)
        }

        printTable("append — 100 MB per scenario", rows: rows)
    }

    // MARK: - dropFirst: user (scan) vs system (copy/truncate)
    //
    // Hypothesis:
    //   small records → user time dominates (many header parses in Swift)
    //   large records → system time dominates (pwrite/ftruncate of large ranges)

    func testDropFirstCPUProfile() throws {
        let scenarios: [(name: String, records: Int, size: Int)] = [
            ("1kb  ", 102_400,       1_024),
            ("10kb ",  10_240,      10_240),
            ("1mb  ",     100,   1_048_576),
        ]

        typealias Row = CPURow
        var rows: [Row] = []

        for s in scenarios {
            let payload = Data(repeating: 0xBB, count: s.size)
            let store   = try BlobStore(path: storePath)
            for _ in 0 ..< s.records { try store.append(payload) }

            let t0   = ProcessInfo.processInfo.systemUptime
            let c0   = CPUSnapshot.now()
            try store.dropFirst(s.records / 2)
            let cpu  = CPUSnapshot.now() - c0
            let wall = Int64((ProcessInfo.processInfo.systemUptime - t0) * 1_000_000)

            rows.append(Row(name: s.name, wallUs: wall, cpu: cpu,
                            bytes: (s.records / 2) * s.size))  // bytes shifted
            try? FileManager.default.removeItem(atPath: storePath)
        }

        printTable("dropFirst inPlace — 50 MB shifted per scenario", rows: rows)
    }

    // MARK: - BlobReader: pure pread cost

    func testReaderCPUProfile() throws {
        let scenarios: [(name: String, count: Int, size: Int)] = [
            ("1kb  ", 102_400,     1_024),
            ("10kb ",  10_240,    10_240),
            ("1mb  ",     100, 1_048_576),
        ]

        typealias Row = CPURow
        var rows: [Row] = []

        for s in scenarios {
            let payload = Data(repeating: 0xCC, count: s.size)
            let store   = try BlobStore(path: storePath)
            for _ in 0 ..< s.count { try store.append(payload) }

            let reader = try store.makeReader()
            let t0  = ProcessInfo.processInfo.systemUptime
            let c0  = CPUSnapshot.now()
            while let _ = try reader.next() {}
            let cpu  = CPUSnapshot.now() - c0
            let wall = Int64((ProcessInfo.processInfo.systemUptime - t0) * 1_000_000)

            rows.append(Row(name: s.name, wallUs: wall, cpu: cpu,
                            bytes: s.count * s.size))
            try? FileManager.default.removeItem(atPath: storePath)
        }

        printTable("BlobReader.next() — 100 MB per scenario", rows: rows)
    }

    // MARK: - Output

    private func printTable(_ title: String, rows: [CPURow]) {
        let sep = "  " + String(repeating: "─", count: 74)
        print("\n")
        print("  \(title)")
        print(sep)
        print("  Scenario    Data        Wall        User        System      Util%   Usr/Sys")
        print(sep)
        for r in rows {
            let util = r.wallUs > 0 ? Double(r.cpu.totalUs) / Double(r.wallUs) * 100 : 0
            let ratio = r.cpu.systemUs > 0
                ? String(format: "%.2f×", Double(r.cpu.userUs) / Double(r.cpu.systemUs))
                : "∞"
            print(String(format: "  %@  %-8@  %@  %@  %@  %5.1f%%  %@",
                         r.name,
                         fmtMB(r.bytes) as NSString,
                         fmtMs(r.wallUs),
                         fmtMs(r.cpu.userUs),
                         fmtMs(r.cpu.systemUs),
                         util,
                         ratio))
        }
        print(sep)
        print()
    }
}
#endif
