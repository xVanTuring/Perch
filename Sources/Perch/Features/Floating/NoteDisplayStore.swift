import AppKit

/// 每条便签「归属显示器」的**本地**记忆。key = `Note.id.uuidString`,value =
/// 该屏的 `CGDisplayCreateUUIDFromDisplayID` 字符串(见 `DisplayCatalog`)。
/// 查不到 = 未指定 = 默认内置/主屏。
///
/// **为什么存 UserDefaults 而不是 Note 实体**:显示器 UUID 只在本机有意义 ——
/// 换一台 Mac(或同一账号下另一台设备)上这个 UUID 谁都不对应。若把它挂到
/// Note 上,`NSPersistentCloudKitContainer` 会把这个"在别处毫无意义"的屏标识
/// 同步过去,还得为此 bump 一版 schema 并去 CloudKit Console 部署。归属显示器
/// 本就是 per-machine 的偏好,放本地 UserDefaults 语义正确也最省事。
enum NoteDisplayStore {
    private static let key = "Perch.noteDisplayAssignments"

    private static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func save(_ map: [String: String]) {
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(map, forKey: key)
        }
    }

    /// 某便签归属的显示器 UUID;nil = 未指定(默认内置/主屏)。
    static func displayUUID(for noteID: UUID) -> String? {
        load()[noteID.uuidString]
    }

    /// 记住/清除某便签的归属显示器。传 nil 清除(回到默认)。已是同值时不写,
    /// 避免每次拖动结束都碰一下 UserDefaults。
    static func setDisplayUUID(_ uuid: String?, for noteID: UUID) {
        var map = load()
        let k = noteID.uuidString
        if map[k] == uuid { return }
        if let uuid {
            map[k] = uuid
        } else {
            map.removeValue(forKey: k)
        }
        save(map)
    }

    /// 便签被彻底删除时清掉残留条目,避免字典无限增长。
    static func clear(noteID: UUID) {
        setDisplayUUID(nil, for: noteID)
    }

    /// 解析归属显示器当前对应的**在线** NSScreen;未指定或该屏已拔掉都返回
    /// nil —— 调用方据此回退到默认(内置/主屏)。
    static func assignedScreen(for noteID: UUID) -> NSScreen? {
        guard let uuid = displayUUID(for: noteID) else { return nil }
        return DisplayCatalog.screen(forUUID: uuid)
    }
}
