import XCTest
@testable import WildEdge

final class HardwareSamplerTests: XCTestCase {

    // Long interval so the timer never fires mid-test; start() samples once immediately.
    private var sampler: HardwareSampler!

    override func setUp() {
        super.setUp()
        sampler = HardwareSampler(intervalMs: 60_000)
        sampler.start()
    }

    override func tearDown() {
        sampler.stop()
        sampler = nil
        super.tearDown()
    }

    // MARK: - Snapshot dump

    #if os(macOS)
    func testPrintSnapshot() {
        let ctx = sampler.snapshot()
        print("""

        ── HardwareContext snapshot ─────────────────────
          thermalState:       \(ctx.thermalState ?? "nil")
          thermalStateRaw:    \(ctx.thermalStateRaw ?? "nil")
          cpuTempCelsius:     \(ctx.cpuTempCelsius.map { String(format: "%.1f °C", $0) } ?? "nil")
          cpuFreqMhz:         \(ctx.cpuFreqMhz.map { "\($0) MHz" } ?? "nil")
          cpuFreqMaxMhz:      \(ctx.cpuFreqMaxMhz.map { "\($0) MHz" } ?? "nil")
          memoryAvailable:    \(ctx.memoryAvailableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "nil")
          batteryLevel:       \(ctx.batteryLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "nil")
          batteryCharging:    \(ctx.batteryCharging.map { "\($0)" } ?? "nil")
          acceleratorActual:  \(ctx.acceleratorActual?.rawValue ?? "nil")
          gpuBusyPercent:     \(ctx.gpuBusyPercent.map { "\($0)%" } ?? "nil")
        ─────────────────────────────────────────────────
        """)
    }
    #endif

    // MARK: - Thermal

    func testThermalStateIsPopulated() {
        let ctx = sampler.snapshot()
        XCTAssertNotNil(ctx.thermalState)
        XCTAssertNotNil(ctx.thermalStateRaw)
        let valid = ["nominal", "fair", "serious", "critical"]
        XCTAssertTrue(valid.contains(ctx.thermalState ?? ""))
    }

    // MARK: - Memory
    // host_statistics64 is always available — no skip guard, XCTUnwrap fails the test if nil.

    func testMemoryAvailableBytesIsPositive() throws {
        let bytes = try XCTUnwrap(sampler.snapshot().memoryAvailableBytes)
        XCTAssertGreaterThan(bytes, 0)
    }

    // MARK: - Accelerator

    func testAcceleratorActualIsAlwaysSet() {
        XCTAssertNotNil(sampler.snapshot().acceleratorActual)
    }

    func testAcceleratorActualIsValidCase() throws {
        let acc = try XCTUnwrap(sampler.snapshot().acceleratorActual)
        let valid: [Accelerator] = [.cpu, .gpu, .npu, .dsp, .tpu]
        XCTAssertTrue(valid.contains(acc))
    }

    // MARK: - CPU Frequency
    // hw.cpufrequency* are not exposed on Apple Silicon; skip explicitly rather than silently pass.

    func testCpuFreqMhzIsReasonable() throws {
        let ctx = sampler.snapshot()
        try XCTSkipIf(ctx.cpuFreqMhz == nil, "hw.cpufrequency not available on this CPU (Apple Silicon?)")
        let freq = try XCTUnwrap(ctx.cpuFreqMhz)
        XCTAssertGreaterThan(freq, 100,  "CPU freq should be > 100 MHz")
        XCTAssertLessThan(freq, 100_000, "CPU freq should be < 100 GHz")
    }

    func testCpuFreqMaxMhzIsReasonable() throws {
        let ctx = sampler.snapshot()
        try XCTSkipIf(ctx.cpuFreqMaxMhz == nil, "hw.cpufrequency_max not available on this CPU (Apple Silicon?)")
        let max = try XCTUnwrap(ctx.cpuFreqMaxMhz)
        XCTAssertGreaterThan(max, 100,  "Max CPU freq should be > 100 MHz")
        XCTAssertLessThan(max, 100_000, "Max CPU freq should be < 100 GHz")
    }

    func testCpuMaxFreqAtLeastCurrent() throws {
        let ctx = sampler.snapshot()
        try XCTSkipIf(ctx.cpuFreqMhz == nil || ctx.cpuFreqMaxMhz == nil, "CPU freq sysctls not available on this CPU")
        let current = try XCTUnwrap(ctx.cpuFreqMhz)
        let max = try XCTUnwrap(ctx.cpuFreqMaxMhz)
        XCTAssertLessThanOrEqual(current, max)
    }

    // MARK: - Battery
    // Desktop Macs and battery-less devices return nil; skip explicitly.

    func testBatteryLevelInRange() throws {
        let ctx = sampler.snapshot()
        try XCTSkipIf(ctx.batteryLevel == nil, "No battery on this device")
        let level = try XCTUnwrap(ctx.batteryLevel)
        XCTAssertGreaterThanOrEqual(level, 0.0)
        XCTAssertLessThanOrEqual(level, 1.0)
    }

    func testBatteryChargingPresentWhenLevelPresent() throws {
        let ctx = sampler.snapshot()
        try XCTSkipIf(ctx.batteryLevel == nil, "No battery on this device")
        XCTAssertNotNil(ctx.batteryCharging, "batteryCharging must be set whenever batteryLevel is")
    }

    // MARK: - GPU Busy Percent (macOS only)
    // IOAccelerator may be unavailable in sandboxed test runners; skip explicitly.

    #if os(macOS)
    func testGpuBusyPercentInRangeWhenPresent() throws {
        let ctx = sampler.snapshot()
        try XCTSkipIf(ctx.gpuBusyPercent == nil, "IOAccelerator not accessible on this machine")
        let pct = try XCTUnwrap(ctx.gpuBusyPercent)
        XCTAssertGreaterThanOrEqual(pct, 0)
        XCTAssertLessThanOrEqual(pct, 100)
    }
    #endif

    // MARK: - CPU Temperature (macOS only)
    // SMC may be unavailable in VMs or sandboxes; skip explicitly.

    #if os(macOS)
    func testCpuTempCelsiusIsReasonable() throws {
        let ctx = sampler.snapshot()
        try XCTSkipIf(ctx.cpuTempCelsius == nil, "SMC not accessible on this machine (VM or sandbox?)")
        let temp = try XCTUnwrap(ctx.cpuTempCelsius)
        XCTAssertGreaterThan(temp, 0,  "CPU temp should be above 0 °C")
        XCTAssertLessThan(temp, 150,   "CPU temp should be below 150 °C")
    }
    #endif

    // MARK: - Lifecycle

    func testSnapshotIsStableAfterStop() {
        let ctx1 = sampler.snapshot()
        sampler.stop()
        let ctx2 = sampler.snapshot()
        XCTAssertEqual(ctx1.thermalState, ctx2.thermalState)
    }

    func testRestartedSamplerProducesSnapshot() {
        sampler.stop()
        sampler = HardwareSampler(intervalMs: 60_000)
        sampler.start()
        XCTAssertNotNil(sampler.snapshot().thermalState)
    }
}
