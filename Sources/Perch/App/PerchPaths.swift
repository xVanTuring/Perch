import CoreData

/// Perch 在本机的数据目录:Core Data 库、单实例锁、同步状态都在这里。
///
/// 正常就是 Core Data 的默认位置 `~/Library/Application Support/Perch/`。
/// **DEBUG 构建**可以用环境变量 `PERCH_DATA_DIR` 换成别的目录 —— 测试同步时在同一台
/// Mac 上开两个互不相干的 Perch,或在另一台 Mac 上和正式版并存,都不碰真实数据。
/// 注意 UserDefaults 不跟着换(同一个 bundle id 共用),测试实例别去改偏好设置。
enum PerchPaths {
    #if DEBUG
    static let overriddenDataDirectory: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["PERCH_DATA_DIR"], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }()
    #else
    static let overriddenDataDirectory: URL? = nil
    #endif

    static var dataDirectory: URL {
        overriddenDataDirectory ?? NSPersistentContainer.defaultDirectoryURL()
    }

    /// 同步的本机状态(设备 ID、各记录的合并基准、远端文件缓存)。
    static var syncStateDirectory: URL {
        dataDirectory.appendingPathComponent("SyncState", isDirectory: true)
    }
}
