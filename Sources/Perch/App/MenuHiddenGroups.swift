import Foundation

/// #1:控制哪些分组**不出现在托盘菜单的笔记列表**里。
///
/// 与浮窗显隐(`FloatingNotesRegistry.hiddenGroupIDs`,#4)**完全独立** —— 这里只
/// 影响 menubar 下拉列表要不要列出该组的笔记,不碰桌面上的浮窗;#4 只影响浮窗、
/// 不碰菜单列表。存被隐藏的 `NoteGroup.id` 集合到 UserDefaults(逗号分隔的 uuid),
/// 空 = 全部在菜单显示。开关在 Manager 右键分组菜单(见 `groupContextNSMenu`)。
/// 未分组恒显示,不可隐藏。
enum MenuHiddenGroups {
    private static let key = "Noticky.menuHiddenGroups"

    static func ids() -> Set<UUID> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    static func isHidden(_ id: UUID) -> Bool { ids().contains(id) }

    /// Settings → General:在 Manager 新建的分组默认是否出现在托盘菜单(默认 true)。
    /// 只作用于新建那一刻,不回溯已有分组。
    static var newGroupsShownByDefault: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.newGroupsShowInMenu) as? Bool ?? true
    }

    static func setHidden(_ id: UUID, _ hidden: Bool) {
        var set = ids()
        if hidden { set.insert(id) } else { set.remove(id) }
        persist(set)
    }

    static func toggle(_ id: UUID) { setHidden(id, !isHidden(id)) }

    /// 剔除已不存在的分组 id(分组被删后残留)。`existing` = 当前存活的 group.id。
    static func prune(existing: Set<UUID>) {
        let set = ids()
        let keep = set.intersection(existing)
        if keep != set { persist(keep) }
    }

    private static func persist(_ set: Set<UUID>) {
        if set.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(set.map(\.uuidString).joined(separator: ","), forKey: key)
        }
    }
}
