import Foundation
import IOKit

/// 同步开没开、同步文件夹在哪。设计见 docs/icloud-drive-sync.md。
enum SyncConfig {
    /// iCloud 云盘在本机的根目录。没登录 iCloud 或关了 iCloud 云盘时不存在。
    static let iCloudDriveRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

    static var defaultFolder: URL {
        iCloudDriveRoot.appendingPathComponent("Perch", isDirectory: true)
    }

    #if DEBUG
    /// DEBUG:环境变量 `PERCH_SYNC_DIR` 指定同步文件夹并强制开启同步,不读写偏好设置。
    /// 配合 `PERCH_DATA_DIR` 测试同步(见 PerchPaths)。
    static let debugFolderOverride: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["PERCH_SYNC_DIR"], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }()
    #else
    static let debugFolderOverride: URL? = nil
    #endif

    static var isEnabled: Bool {
        debugFolderOverride != nil || UserDefaults.standard.bool(forKey: SettingsKey.syncEnabled)
    }

    static var customFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: SettingsKey.syncFolderPath),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var folder: URL { debugFolderOverride ?? customFolder ?? defaultFolder }

    static var usesICloudDrive: Bool {
        folder.standardizedFileURL.path.hasPrefix(iCloudDriveRoot.standardizedFileURL.path)
    }
}

/// 这台设备在同步里的身份。存在本机数据目录里(`SyncState/device.json`),
/// 不放 UserDefaults —— 用 `PERCH_DATA_DIR` 开的测试实例各有各的身份。
///
/// 同时记下硬件 UUID:用迁移助理或 Time Machine 把整台 Mac 恢复到新机器上时,
/// 数据目录被原样带过去,硬件 UUID 却变了,这时换一个新的设备 ID,否则两台 Mac
/// 会用同一个 ID 写同一个文件夹(方案第 3 节)。
struct SyncDeviceIdentity: Codable, Equatable {
    let deviceID: String
    let hardwareUUID: String

    static func loadOrCreate(in directory: URL) -> SyncDeviceIdentity {
        let url = directory.appendingPathComponent("device.json")
        let hardware = currentHardwareUUID()
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(SyncDeviceIdentity.self, from: data),
           stored.hardwareUUID == hardware {
            return stored
        }
        let fresh = SyncDeviceIdentity(deviceID: UUID().uuidString, hardwareUUID: hardware)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: url, options: .atomic)
        }
        NSLog("Perch sync: new device ID %@", fresh.deviceID)
        return fresh
    }

    static func currentHardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return value as? String ?? "unknown"
    }

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
