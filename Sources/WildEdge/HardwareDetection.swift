import Foundation

#if os(iOS)
import UIKit
#endif

internal enum HardwareDetection {
    static func deviceModel() -> String {
        let id = deviceModelIdentifier()
        return deviceModelNames[id] ?? id
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

// Source: https://deviceguru.com
private let deviceModelNames: [String: String] = [
    // iPhone
    "iPhone1,1":  "iPhone",
    "iPhone1,2":  "iPhone 3G",
    "iPhone2,1":  "iPhone 3GS",
    "iPhone3,1":  "iPhone 4",
    "iPhone3,2":  "iPhone 4 GSM Rev A",
    "iPhone3,3":  "iPhone 4 CDMA",
    "iPhone4,1":  "iPhone 4S",
    "iPhone5,1":  "iPhone 5 (GSM)",
    "iPhone5,2":  "iPhone 5 (GSM+CDMA)",
    "iPhone5,3":  "iPhone 5C (GSM)",
    "iPhone5,4":  "iPhone 5C (Global)",
    "iPhone6,1":  "iPhone 5S (GSM)",
    "iPhone6,2":  "iPhone 5S (Global)",
    "iPhone7,1":  "iPhone 6 Plus",
    "iPhone7,2":  "iPhone 6",
    "iPhone8,1":  "iPhone 6s",
    "iPhone8,2":  "iPhone 6s Plus",
    "iPhone8,4":  "iPhone SE",
    "iPhone9,1":  "iPhone 7",
    "iPhone9,2":  "iPhone 7 Plus",
    "iPhone9,3":  "iPhone 7",
    "iPhone9,4":  "iPhone 7 Plus",
    "iPhone10,1": "iPhone 8",
    "iPhone10,2": "iPhone 8 Plus",
    "iPhone10,3": "iPhone X Global",
    "iPhone10,4": "iPhone 8",
    "iPhone10,5": "iPhone 8 Plus",
    "iPhone10,6": "iPhone X GSM",
    "iPhone11,2": "iPhone XS",
    "iPhone11,4": "iPhone XS Max",
    "iPhone11,6": "iPhone XS Max Global",
    "iPhone11,8": "iPhone XR",
    "iPhone12,1": "iPhone 11",
    "iPhone12,3": "iPhone 11 Pro",
    "iPhone12,5": "iPhone 11 Pro Max",
    "iPhone12,8": "iPhone SE 2nd Gen",
    "iPhone13,1": "iPhone 12 Mini",
    "iPhone13,2": "iPhone 12",
    "iPhone13,3": "iPhone 12 Pro",
    "iPhone13,4": "iPhone 12 Pro Max",
    "iPhone14,2": "iPhone 13 Pro",
    "iPhone14,3": "iPhone 13 Pro Max",
    "iPhone14,4": "iPhone 13 Mini",
    "iPhone14,5": "iPhone 13",
    "iPhone14,6": "iPhone SE 3rd Gen",
    "iPhone14,7": "iPhone 14",
    "iPhone14,8": "iPhone 14 Plus",
    "iPhone15,2": "iPhone 14 Pro",
    "iPhone15,3": "iPhone 14 Pro Max",
    "iPhone15,4": "iPhone 15",
    "iPhone15,5": "iPhone 15 Plus",
    "iPhone16,1": "iPhone 15 Pro",
    "iPhone16,2": "iPhone 15 Pro Max",
    "iPhone17,1": "iPhone 16 Pro",
    "iPhone17,2": "iPhone 16 Pro Max",
    "iPhone17,3": "iPhone 16",
    "iPhone17,4": "iPhone 16 Plus",

    // iPad
    "iPad1,1":   "iPad",
    "iPad1,2":   "iPad 3G",
    "iPad2,1":   "iPad 2 (WiFi)",
    "iPad2,2":   "iPad 2 (GSM)",
    "iPad2,3":   "iPad 2 (CDMA)",
    "iPad2,4":   "iPad 2 (WiFi, revised)",
    "iPad2,5":   "iPad mini",
    "iPad2,6":   "iPad mini (GSM+LTE)",
    "iPad2,7":   "iPad mini (CDMA+LTE)",
    "iPad3,1":   "iPad 3rd Gen (WiFi)",
    "iPad3,2":   "iPad 3rd Gen (CDMA)",
    "iPad3,3":   "iPad 3rd Gen (GSM)",
    "iPad3,4":   "iPad 4th Gen (WiFi)",
    "iPad3,5":   "iPad 4th Gen (GSM+LTE)",
    "iPad3,6":   "iPad 4th Gen (CDMA+LTE)",
    "iPad4,1":   "iPad Air (WiFi)",
    "iPad4,2":   "iPad Air (GSM+CDMA)",
    "iPad4,3":   "iPad Air (China)",
    "iPad4,4":   "iPad mini Retina (WiFi)",
    "iPad4,5":   "iPad mini Retina (GSM+CDMA)",
    "iPad4,6":   "iPad mini Retina (China)",
    "iPad4,7":   "iPad mini 3 (WiFi)",
    "iPad4,8":   "iPad mini 3 (GSM+CDMA)",
    "iPad4,9":   "iPad mini 3 (China)",
    "iPad5,1":   "iPad mini 4 (WiFi)",
    "iPad5,2":   "iPad mini 4 (WiFi+Cellular)",
    "iPad5,3":   "iPad Air 2 (WiFi)",
    "iPad5,4":   "iPad Air 2 (Cellular)",
    "iPad6,3":   "iPad Pro 9.7-inch (WiFi)",
    "iPad6,4":   "iPad Pro 9.7-inch (WiFi+LTE)",
    "iPad6,7":   "iPad Pro 12.9-inch (WiFi)",
    "iPad6,8":   "iPad Pro 12.9-inch (WiFi+LTE)",
    "iPad6,11":  "iPad 5th Gen (WiFi)",
    "iPad6,12":  "iPad 5th Gen (Cellular)",
    "iPad7,1":   "iPad Pro 12.9-inch 2nd Gen (WiFi)",
    "iPad7,2":   "iPad Pro 12.9-inch 2nd Gen (WiFi+Cellular)",
    "iPad7,3":   "iPad Pro 10.5-inch (WiFi)",
    "iPad7,4":   "iPad Pro 10.5-inch (WiFi+Cellular)",
    "iPad7,5":   "iPad 6th Gen (WiFi)",
    "iPad7,6":   "iPad 6th Gen (Cellular)",
    "iPad7,11":  "iPad 7th Gen (WiFi)",
    "iPad7,12":  "iPad 7th Gen (Cellular)",
    "iPad8,1":   "iPad Pro 11-inch (WiFi)",
    "iPad8,2":   "iPad Pro 11-inch (WiFi, 1TB)",
    "iPad8,3":   "iPad Pro 11-inch (WiFi+Cellular)",
    "iPad8,4":   "iPad Pro 11-inch (WiFi+Cellular, 1TB)",
    "iPad8,5":   "iPad Pro 12.9-inch 3rd Gen (WiFi)",
    "iPad8,6":   "iPad Pro 12.9-inch 3rd Gen (WiFi, 1TB)",
    "iPad8,7":   "iPad Pro 12.9-inch 3rd Gen (WiFi+Cellular)",
    "iPad8,8":   "iPad Pro 12.9-inch 3rd Gen (WiFi+Cellular, 1TB)",
    "iPad8,9":   "iPad Pro 11-inch 2nd Gen (WiFi)",
    "iPad8,10":  "iPad Pro 11-inch 2nd Gen (WiFi+Cellular)",
    "iPad8,11":  "iPad Pro 12.9-inch 4th Gen (WiFi)",
    "iPad8,12":  "iPad Pro 12.9-inch 4th Gen (WiFi+Cellular)",
    "iPad11,1":  "iPad mini 5th Gen (WiFi)",
    "iPad11,2":  "iPad mini 5th Gen (WiFi+Cellular)",
    "iPad11,3":  "iPad Air 3rd Gen (WiFi)",
    "iPad11,4":  "iPad Air 3rd Gen (WiFi+Cellular)",
    "iPad11,6":  "iPad 8th Gen (WiFi)",
    "iPad11,7":  "iPad 8th Gen (Cellular)",
    "iPad12,1":  "iPad 9th Gen (WiFi)",
    "iPad12,2":  "iPad 9th Gen (Cellular)",
    "iPad13,1":  "iPad Air 4th Gen (WiFi)",
    "iPad13,2":  "iPad Air 4th Gen (WiFi+Cellular)",
    "iPad13,4":  "iPad Pro 11-inch 3rd Gen (WiFi)",
    "iPad13,5":  "iPad Pro 11-inch 3rd Gen (WiFi)",
    "iPad13,6":  "iPad Pro 11-inch 3rd Gen (WiFi+Cellular)",
    "iPad13,7":  "iPad Pro 11-inch 3rd Gen (WiFi+Cellular)",
    "iPad13,8":  "iPad Pro 12.9-inch 5th Gen (WiFi)",
    "iPad13,9":  "iPad Pro 12.9-inch 5th Gen (WiFi)",
    "iPad13,10": "iPad Pro 12.9-inch 5th Gen (WiFi+Cellular)",
    "iPad13,11": "iPad Pro 12.9-inch 5th Gen (WiFi+Cellular)",
    "iPad13,16": "iPad Air 5th Gen (WiFi)",
    "iPad13,17": "iPad Air 5th Gen (WiFi+Cellular)",
    "iPad13,18": "iPad 10th Gen (WiFi)",
    "iPad13,19": "iPad 10th Gen (Cellular)",
    "iPad14,1":  "iPad mini 6th Gen (WiFi)",
    "iPad14,2":  "iPad mini 6th Gen (WiFi+Cellular)",
    "iPad14,3":  "iPad Pro 11-inch 4th Gen (WiFi)",
    "iPad14,4":  "iPad Pro 11-inch 4th Gen (WiFi+Cellular)",
    "iPad14,5":  "iPad Pro 12.9-inch 6th Gen (WiFi)",
    "iPad14,6":  "iPad Pro 12.9-inch 6th Gen (WiFi+Cellular)",
    "iPad14,8":  "iPad Air 11-inch 6th Gen (WiFi)",
    "iPad14,9":  "iPad Air 11-inch 6th Gen (WiFi+Cellular)",
    "iPad14,10": "iPad Air 13-inch 6th Gen (WiFi)",
    "iPad14,11": "iPad Air 13-inch 6th Gen (WiFi+Cellular)",
    "iPad15,3":  "iPad Air 11-inch 7th Gen (WiFi)",
    "iPad15,4":  "iPad Air 11-inch 7th Gen (WiFi+Cellular)",
    "iPad15,5":  "iPad Air 13-inch 7th Gen (WiFi)",
    "iPad15,6":  "iPad Air 13-inch 7th Gen (WiFi+Cellular)",
    "iPad15,7":  "iPad 11th Gen (WiFi)",
    "iPad15,8":  "iPad 11th Gen (Cellular)",
    "iPad16,1":  "iPad mini 7th Gen (WiFi)",
    "iPad16,2":  "iPad mini 7th Gen (WiFi+Cellular)",
    "iPad16,3":  "iPad Pro 11-inch 5th Gen (WiFi)",
    "iPad16,4":  "iPad Pro 11-inch 5th Gen (WiFi+Cellular)",
    "iPad16,5":  "iPad Pro 13-inch 7th Gen (WiFi)",
    "iPad16,6":  "iPad Pro 13-inch 7th Gen (WiFi+Cellular)",

    // iPod touch
    "iPod1,1": "iPod touch 1st Gen",
    "iPod2,1": "iPod touch 2nd Gen",
    "iPod3,1": "iPod touch 3rd Gen",
    "iPod4,1": "iPod touch 4th Gen",
    "iPod5,1": "iPod touch 5th Gen",
    "iPod7,1": "iPod touch 6th Gen",
    "iPod9,1": "iPod touch 7th Gen",

    // MacBook (12-inch)
    "MacBook8,1":  "MacBook (Retina, 12-inch, Early 2015)",
    "MacBook9,1":  "MacBook (Retina, 12-inch, Early 2016)",
    "MacBook10,1": "MacBook (Retina, 12-inch, 2017)",

    // MacBook Air
    "MacBookAir1,1":  "MacBook Air (13-inch, 2008)",
    "MacBookAir2,1":  "MacBook Air (13-inch, Late 2008)",
    "MacBookAir3,1":  "MacBook Air (11-inch, Mid 2010)",
    "MacBookAir3,2":  "MacBook Air (13-inch, Mid 2010)",
    "MacBookAir4,1":  "MacBook Air (11-inch, Mid 2011)",
    "MacBookAir4,2":  "MacBook Air (13-inch, Mid 2011)",
    "MacBookAir5,1":  "MacBook Air (11-inch, Mid 2012)",
    "MacBookAir5,2":  "MacBook Air (13-inch, Mid 2012)",
    "MacBookAir6,1":  "MacBook Air (11-inch, Mid 2013)",
    "MacBookAir6,2":  "MacBook Air (13-inch, Mid 2013)",
    "MacBookAir7,1":  "MacBook Air (11-inch, Early 2015)",
    "MacBookAir7,2":  "MacBook Air (13-inch, Early 2015)",
    "MacBookAir8,1":  "MacBook Air (13-inch, Retina, 2018)",
    "MacBookAir8,2":  "MacBook Air (13-inch, Retina, 2019)",
    "MacBookAir9,1":  "MacBook Air (13-inch, 2020)",
    "MacBookAir10,1": "MacBook Air (13-inch, M1, 2020)",
    "Mac14,2":  "MacBook Air (13-inch, M2, 2022)",
    "Mac14,15": "MacBook Air (15-inch, M2, 2023)",
    "Mac15,12": "MacBook Air (13-inch, M3, 2024)",
    "Mac15,13": "MacBook Air (15-inch, M3, 2024)",
    "Mac16,12": "MacBook Air (13-inch, M4, 2025)",
    "Mac16,13": "MacBook Air (15-inch, M4, 2025)",

    // MacBook Pro
    "MacBookPro8,1":  "MacBook Pro (13-inch, Early 2011)",
    "MacBookPro8,2":  "MacBook Pro (15-inch, Early 2011)",
    "MacBookPro8,3":  "MacBook Pro (17-inch, Early 2011)",
    "MacBookPro9,1":  "MacBook Pro (15-inch, Mid 2012)",
    "MacBookPro9,2":  "MacBook Pro (13-inch, Mid 2012)",
    "MacBookPro10,1": "MacBook Pro (Retina, 15-inch, 2012)",
    "MacBookPro10,2": "MacBook Pro (Retina, 13-inch, 2012)",
    "MacBookPro11,1": "MacBook Pro (Retina, 13-inch, Late 2013)",
    "MacBookPro11,2": "MacBook Pro (Retina, 15-inch, Late 2013)",
    "MacBookPro11,3": "MacBook Pro (Retina, 15-inch, Late 2013)",
    "MacBookPro11,4": "MacBook Pro (Retina, 15-inch, Mid 2015)",
    "MacBookPro11,5": "MacBook Pro (Retina, 15-inch, Mid 2015)",
    "MacBookPro12,1": "MacBook Pro (Retina, 13-inch, Early 2015)",
    "MacBookPro13,1": "MacBook Pro (13-inch, 2016, Two Thunderbolt 3)",
    "MacBookPro13,2": "MacBook Pro (13-inch, 2016, Four Thunderbolt 3)",
    "MacBookPro13,3": "MacBook Pro (15-inch, 2016)",
    "MacBookPro14,1": "MacBook Pro (13-inch, 2017, Two Thunderbolt 3)",
    "MacBookPro14,2": "MacBook Pro (13-inch, 2017, Four Thunderbolt 3)",
    "MacBookPro14,3": "MacBook Pro (15-inch, 2017)",
    "MacBookPro15,1": "MacBook Pro (15-inch, 2018)",
    "MacBookPro15,2": "MacBook Pro (13-inch, 2018)",
    "MacBookPro15,3": "MacBook Pro (15-inch, 2019)",
    "MacBookPro15,4": "MacBook Pro (13-inch, 2019)",
    "MacBookPro16,1": "MacBook Pro (16-inch, 2019)",
    "MacBookPro16,2": "MacBook Pro (13-inch, 2020)",
    "MacBookPro16,3": "MacBook Pro (13-inch, 2020)",
    "MacBookPro16,4": "MacBook Pro (16-inch, 2019)",
    "MacBookPro17,1": "MacBook Pro (13-inch, M1, 2020)",
    "MacBookPro18,1": "MacBook Pro (16-inch, M1 Pro/Max, 2021)",
    "MacBookPro18,2": "MacBook Pro (16-inch, M1 Pro/Max, 2021)",
    "MacBookPro18,3": "MacBook Pro (14-inch, M1 Pro/Max, 2021)",
    "MacBookPro18,4": "MacBook Pro (14-inch, M1 Pro/Max, 2021)",
    "Mac13,3":  "MacBook Pro (13-inch, M2, 2022)",
    "Mac14,5":  "MacBook Pro (14-inch, M2 Pro/Max, 2023)",
    "Mac14,6":  "MacBook Pro (16-inch, M2 Pro/Max, 2023)",
    "Mac14,9":  "MacBook Pro (14-inch, M2 Pro, 2023)",
    "Mac14,10": "MacBook Pro (16-inch, M2 Pro, 2023)",
    "Mac15,3":  "MacBook Pro (14-inch, M3, 2023)",
    "Mac15,6":  "MacBook Pro (14-inch, M3 Pro, 2023)",
    "Mac15,7":  "MacBook Pro (16-inch, M3 Pro, 2023)",
    "Mac15,8":  "MacBook Pro (14-inch, M3 Max, 2023)",
    "Mac15,9":  "MacBook Pro (16-inch, M3 Max, 2023)",
    "Mac16,1":  "MacBook Pro (14-inch, M4, 2024)",
    "Mac16,6":  "MacBook Pro (14-inch, M4 Pro, 2024)",
    "Mac16,7":  "MacBook Pro (16-inch, M4 Pro, 2024)",
    "Mac16,8":  "MacBook Pro (14-inch, M4 Max, 2024)",
    "Mac16,10": "MacBook Pro (16-inch, M4 Max, 2024)",

    // iMac
    "iMac12,1": "iMac (21.5-inch, Mid 2011)",
    "iMac12,2": "iMac (27-inch, Mid 2011)",
    "iMac13,1": "iMac (21.5-inch, Late 2012)",
    "iMac13,2": "iMac (27-inch, Late 2012)",
    "iMac14,1": "iMac (21.5-inch, Late 2013)",
    "iMac14,2": "iMac (27-inch, Late 2013)",
    "iMac14,3": "iMac (21.5-inch, Late 2013)",
    "iMac14,4": "iMac (21.5-inch, Mid 2014)",
    "iMac15,1": "iMac (27-inch, Retina 5K, Late 2014)",
    "iMac16,1": "iMac (21.5-inch, Late 2015)",
    "iMac16,2": "iMac (21.5-inch, Retina 4K, Late 2015)",
    "iMac17,1": "iMac (27-inch, Retina 5K, Late 2015)",
    "iMac18,1": "iMac (21.5-inch, 2017)",
    "iMac18,2": "iMac (21.5-inch, Retina 4K, 2017)",
    "iMac18,3": "iMac (27-inch, Retina 5K, 2017)",
    "iMac19,1": "iMac (27-inch, 2019)",
    "iMac19,2": "iMac (21.5-inch, 2019)",
    "iMac20,1": "iMac (27-inch, 2020)",
    "iMac20,2": "iMac (27-inch, Nano-texture, 2020)",
    "iMac21,1": "iMac (24-inch, M1, 2021)",
    "iMac21,2": "iMac (24-inch, M1, 2021)",
    "Mac15,4":  "iMac (24-inch, M3, 2023)",
    "Mac15,5":  "iMac (24-inch, M3, 2023)",
    "Mac16,2":  "iMac (24-inch, M4, 2024)",
    "Mac16,3":  "iMac (24-inch, M4, 2024)",

    // iMac Pro
    "iMacPro1,1": "iMac Pro (27-inch, 2017)",

    // Mac mini
    "Macmini5,1": "Mac mini (Mid 2011)",
    "Macmini5,2": "Mac mini (Mid 2011)",
    "Macmini5,3": "Mac mini (Mid 2011, Server)",
    "Macmini6,1": "Mac mini (Late 2012)",
    "Macmini6,2": "Mac mini (Late 2012, Server)",
    "Macmini7,1": "Mac mini (Late 2014)",
    "Macmini8,1": "Mac mini (2018)",
    "Macmini9,1": "Mac mini (M1, 2020)",
    "Mac14,3":  "Mac mini (M2, 2023)",
    "Mac14,12": "Mac mini (M2 Pro, 2023)",
    "Mac16,5":  "Mac mini (M4, 2024)",
    "Mac16,11": "Mac mini (M4 Pro, 2024)",

    // Mac Studio
    "Mac13,1": "Mac Studio (M1 Max, 2022)",
    "Mac13,2": "Mac Studio (M1 Ultra, 2022)",
    "Mac14,13": "Mac Studio (M2 Max, 2023)",
    "Mac14,14": "Mac Studio (M2 Ultra, 2023)",
    "Mac15,14": "Mac Studio (M3 Ultra, 2025)",
    "Mac16,9":  "Mac Studio (M4 Max, 2025)",

    // Mac Pro
    "MacPro5,1": "Mac Pro (Mid 2010)",
    "MacPro6,1": "Mac Pro (Late 2013)",
    "MacPro7,1": "Mac Pro (2019)",
    "Mac14,8":  "Mac Pro (2023)",
]
