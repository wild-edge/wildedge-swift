import Foundation
import CryptoKit

public struct DeviceInfo {
    public var deviceId: String
    public var deviceType: String
    public var deviceModel: String
    public var osName: String
    public var osVersion: String
    public var appVersion: String?
    public var sdkVersion: String
    public var locale: String
    public var timezone: String
    public var cpuArch: String?
    public var cpuCores: Int?
    public var ramTotalBytes: Int64?
    public var gpuModel: String?
    public var accelerators: [Accelerator]

    public init(
        deviceId: String,
        deviceType: String = "ios",
        deviceModel: String,
        osName: String,
        osVersion: String,
        appVersion: String? = nil,
        sdkVersion: String,
        locale: String,
        timezone: String,
        cpuArch: String? = nil,
        cpuCores: Int? = nil,
        ramTotalBytes: Int64? = nil,
        gpuModel: String? = nil,
        accelerators: [Accelerator] = [.cpu]
    ) {
        self.deviceId = deviceId
        self.deviceType = deviceType
        self.deviceModel = deviceModel
        self.osName = osName
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
        self.locale = locale
        self.timezone = timezone
        self.cpuArch = cpuArch
        self.cpuCores = cpuCores
        self.ramTotalBytes = ramTotalBytes
        self.gpuModel = gpuModel
        self.accelerators = accelerators
    }

    public static func detect(appVersion: String? = nil, projectSecret: String = "") -> DeviceInfo {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersion

        let rawId = UUID().uuidString
        let deviceId = projectSecret.isEmpty ? rawId : hmac(key: projectSecret, message: rawId)

        return DeviceInfo(
            deviceId: deviceId,
            deviceType: "ios",
            deviceModel: HardwareDetection.deviceModel(),
            osName: processInfo.operatingSystemVersionString,
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            appVersion: appVersion,
            sdkVersion: Config.sdkVersion,
            locale: Locale.current.languageCode.map { "\($0)-\(Locale.current.regionCode ?? "")" } ?? Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            cpuArch: HardwareDetection.cpuArchitecture(),
            cpuCores: HardwareDetection.cpuCoreCount(),
            ramTotalBytes: HardwareDetection.totalRAM(),
            gpuModel: HardwareDetection.gpuModel(),
            accelerators: HardwareDetection.availableAccelerators()
        )
    }

    internal func toMap() -> [String: Any] {
        var map: [String: Any] = [
            "device_id": deviceId,
            "device_type": deviceType,
            "device_model": deviceModel,
            "os_name": osName,
            "os_version": osVersion,
            "sdk_version": sdkVersion,
            "locale": locale,
            "timezone": timezone,
            "accelerators": accelerators.map { $0.rawValue.lowercased() },
        ]
        if let appVersion {
            map["app_version"] = appVersion
        }
        if let cpuArch {
            map["cpu_arch"] = cpuArch
        }
        if let cpuCores {
            map["cpu_cores"] = cpuCores
        }
        if let ramTotalBytes {
            map["ram_total_bytes"] = ramTotalBytes
        }
        if let gpuModel {
            map["gpu_model"] = gpuModel
        }
        return map
    }

    private static func hmac(key: String, message: String) -> String {
        let key = key.data(using: .utf8) ?? Data()
        let message = message.data(using: .utf8) ?? Data()
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
