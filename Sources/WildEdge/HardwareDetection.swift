import Foundation

#if os(iOS)
import UIKit
#endif

internal enum HardwareDetection {
    static func deviceModel() -> String {
        #if os(iOS)
        let device = UIDevice.current
        return "\(device.model)"
        #else
        return "Mac"
        #endif
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
        if #available(iOS 13.0, *) {
            accelerators.append(.gpu)
        }
        if #available(iOS 14.0, *) {
            accelerators.append(.npu)
        }
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
