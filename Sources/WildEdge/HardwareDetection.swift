import Foundation

#if os(iOS)
import UIKit
#endif

internal enum HardwareDetection {
    static func deviceModel() -> String {
        deviceModelIdentifier()
    }

    static func deviceModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
        #elseif os(iOS)
        // hw.machine → "iPhone17,1", "iPad16,3", etc.
        return sysctl("hw.machine")
        #else
        // hw.model → "MacBookPro18,3", "Mac14,7", etc. (hw.machine returns arch on macOS)
        return sysctl("hw.model")
        #endif
    }

    private static func sysctl(_ key: String) -> String {
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func cpuArchitecture() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let arch = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(cString: buffer.assumingMemoryBound(to: CChar.self).baseAddress!)
        }
        return arch.isEmpty ? nil : arch
    }

    static func cpuCoreCount() -> Int? {
        let count = ProcessInfo.processInfo.processorCount
        return count > 0 ? count : nil
    }

    static func totalRAM() -> Int64? {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        return totalMemory > 0 ? Int64(totalMemory) : nil
    }

    static func availableAccelerators() -> [Accelerator] {
        var accelerators: [Accelerator] = [.cpu]
        #if os(iOS)
        if #available(iOS 13.0, *) { accelerators.append(.gpu) }
        if #available(iOS 14.0, *) { accelerators.append(.npu) }
        #else
        accelerators.append(.gpu)
        accelerators.append(.npu)
        #endif
        return accelerators
    }

    static func gpuModel() -> String? {
        #if os(iOS)
        let device = UIDevice.current
        // iOS doesn't expose GPU model name directly; return device model as proxy
        return device.model
        #else
        return nil
        #endif
    }
}
