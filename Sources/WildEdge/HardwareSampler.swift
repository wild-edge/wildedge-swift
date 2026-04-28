import Foundation
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import IOKit
import IOKit.ps
#endif

// Periodically samples device hardware state on a background queue and
// exposes the latest snapshot via snapshot().
internal final class HardwareSampler {

    // MARK: - State

    private let intervalMs: Int64
    private let queue = DispatchQueue(label: "dev.wildedge.hw-sampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let snapshotLock = NSLock()
    private var current = HardwareContext()

    #if os(iOS)
    private let batteryLock = NSLock()
    private var cachedBatteryLevel: Double?
    private var cachedBatteryCharging: Bool?
    private var batteryObservers: [NSObjectProtocol] = []
    #endif

    // MARK: - Lifecycle

    init(intervalMs: Int64 = Config.defaultHardwareSamplingIntervalMs) {
        self.intervalMs = intervalMs
    }

    func start() {
        #if os(iOS)
        setupBatteryMonitoring()
        #endif

        snapshotLock.lock()
        current = sample()
        snapshotLock.unlock()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(Int(intervalMs)),
            repeating: .milliseconds(Int(intervalMs))
        )
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let s = self.sample()
            self.snapshotLock.lock()
            self.current = s
            self.snapshotLock.unlock()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil

        #if os(iOS)
        let observers: [NSObjectProtocol] = {
            batteryLock.lock()
            defer { batteryLock.unlock() }
            return batteryObservers
        }()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        DispatchQueue.main.async { UIDevice.current.isBatteryMonitoringEnabled = false }
        #endif
    }

    func snapshot() -> HardwareContext {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return current
    }

    // MARK: - Sample

    private func sample() -> HardwareContext {
        var ctx = HardwareContext()

        let thermal = ProcessInfo.processInfo.thermalState
        ctx.thermalState = thermalLabel(thermal)
        ctx.thermalStateRaw = thermalRaw(thermal)

        #if os(iOS)
        batteryLock.lock()
        ctx.batteryLevel = cachedBatteryLevel
        ctx.batteryCharging = cachedBatteryCharging
        batteryLock.unlock()
        #endif

        ctx.memoryAvailableBytes = availableMemoryBytes()
        ctx.acceleratorActual = bestAccelerator()

        let freq = cpuFrequencies()
        ctx.cpuFreqMhz = freq.current
        ctx.cpuFreqMaxMhz = freq.max

        #if os(macOS)
        ctx.cpuTempCelsius = SMCClient.shared.readCPUTemperature()
        ctx.gpuBusyPercent = readGPUBusyPercent()
        if let batt = macOSBattery() {
            ctx.batteryLevel = batt.level
            ctx.batteryCharging = batt.charging
        }
        #endif

        return ctx
    }

    // MARK: - Thermal

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:    return "nominal"
        case .fair:       return "fair"
        case .serious:    return "serious"
        case .critical:   return "critical"
        @unknown default: return "nominal"
        }
    }

    private func thermalRaw(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:    return "NSProcessInfoThermalStateNominal"
        case .fair:       return "NSProcessInfoThermalStateFair"
        case .serious:    return "NSProcessInfoThermalStateSerious"
        case .critical:   return "NSProcessInfoThermalStateCritical"
        @unknown default: return "NSProcessInfoThermalStateNominal"
        }
    }

    // MARK: - Battery (iOS only)

    #if os(iOS)
    private func setupBatteryMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.updateBattery()

            let levelObs = NotificationCenter.default.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.updateBattery() }

            let stateObs = NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.updateBattery() }

            self.batteryLock.lock()
            self.batteryObservers = [levelObs, stateObs]
            self.batteryLock.unlock()
        }
    }

    // Must be called on the main thread.
    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        batteryLock.lock()
        cachedBatteryLevel = level >= 0 ? Double(level) : nil
        cachedBatteryCharging = state == .charging || state == .full
        batteryLock.unlock()
    }
    #endif

    // MARK: - Accelerator

    private func bestAccelerator() -> Accelerator {
        let available = HardwareDetection.availableAccelerators()
        if available.contains(.npu) { return .npu }
        if available.contains(.gpu) { return .gpu }
        return .cpu
    }

    // MARK: - GPU Utilization (macOS only)

    #if os(macOS)
    private func readGPUBusyPercent() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(0, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            // Intel: "Device Utilization %", Apple Silicon: "GPU Activity(Device)"
            let pct = intPct(stats, "Device Utilization %") ?? intPct(stats, "GPU Activity(Device)")
            if let p = pct, p > (best ?? -1) { best = p }
        }
        return best
    }

    private func intPct(_ dict: [String: Any], _ key: String) -> Int? {
        if let i = dict[key] as? Int    { return i }
        if let d = dict[key] as? Double { return Int(d) }
        return nil
    }
    #endif

    // MARK: - Battery + CPU Temperature (macOS only)

    #if os(macOS)
    private func macOSBattery() -> (level: Double, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc["Type"] as? String) == "InternalBattery" else { continue }
            guard let current = desc["Current Capacity"] as? Int,
                  let max = desc["Max Capacity"] as? Int, max > 0 else { continue }
            let charging = (desc["Is Charging"] as? Bool) ?? false
            return (level: Double(current) / Double(max), charging: charging)
        }
        return nil
    }
    #endif

    // MARK: - CPU Frequency

    private func cpuFrequencies() -> (current: Int?, max: Int?) {
        func mhz(_ key: String) -> Int? {
            var value: Int64 = 0
            var size = MemoryLayout<Int64>.size
            guard sysctlbyname(key, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return Int(value / 1_000_000)
        }
        return (current: mhz("hw.cpufrequency"), max: mhz("hw.cpufrequency_max"))
    }

    // MARK: - Memory

    private func availableMemoryBytes() -> Int64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = Int64(vm_kernel_page_size)
        let available = (Int64(stats.free_count) + Int64(stats.inactive_count)) * pageSize
        return available > 0 ? available : nil
    }
}

// MARK: - SMC (macOS only)

#if os(macOS)

// Reads CPU temperature from the System Management Controller.
// Tries Intel keys (TC0P, TC0D) then Apple Silicon keys (Tp09, Tp01) in order.
// No public API exists for CPU temperature on iOS, so this is macOS-only.
private final class SMCClient {
    static let shared = SMCClient()

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    private init() {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private let cpuKeys = ["TC0P", "TC0D", "Tp09", "Tp01", "TCXC"]

    func readCPUTemperature() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard connection != 0 else { return nil }
        for key in cpuKeys {
            if let t = readTemp(key: key) { return t }
        }
        return nil
    }

    private func readTemp(key: String) -> Double? {
        var input = SMCParamStruct(), output = SMCParamStruct()
        let size = MemoryLayout<SMCParamStruct>.size

        input.key = fourCC(key)
        input.data8 = 9  // kSMCGetKeyInfo
        guard callSMC(&input, &output, size) == KERN_SUCCESS else { return nil }

        let type = output.keyInfo.dataType
        let dataSize = output.keyInfo.dataSize

        input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = dataSize
        input.data8 = 5  // kSMCReadKey
        guard callSMC(&input, &output, size) == KERN_SUCCESS, output.result == 0 else { return nil }

        return decodeTemp(output.bytes, type: type)
    }

    private func callSMC(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct, _ size: Int) -> kern_return_t {
        var outSize = size
        return IOConnectCallStructMethod(connection, 2, &input, size, &output, &outSize)
    }

    private func fourCC(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func decodeTemp(_ bytes: SMCParamStruct.Bytes, type: UInt32) -> Double? {
        let b0 = bytes.0, b1 = bytes.1
        let temp: Double
        switch type {
        case fourCC("sp78"):
            // Signed 7.8 fixed-point: value / 256
            temp = Double(Int16(bitPattern: UInt16(b0) << 8 | UInt16(b1))) / 256.0
        case fourCC("fpe2"):
            // Unsigned 14.2 fixed-point: value / 4
            temp = Double(UInt16(b0) << 8 | UInt16(b1)) / 4.0
        default:
            return nil
        }
        return temp > 0 && temp < 150 ? temp : nil
    }
}

private struct SMCVersion {
    var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0
    var reserved: UInt8 = 0; var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0; var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    var key: UInt32 = 0
    var vers: SMCVersion = .init()
    var pLimitData: SMCPLimitData = .init()
    var keyInfo: SMCKeyInfo = .init()
    var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

#endif
