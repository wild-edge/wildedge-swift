import Foundation
#if os(iOS)
import UIKit
#endif

// Periodically samples device hardware state on a background queue and
// exposes the latest snapshot via snapshot(). Mirrors the Android HardwareSampler.
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
