import SwiftUI
import AppKit
import ServiceManagement
import KeyboardShortcuts

/// 偏好的 UserDefaults key 集中在这里,避免散落各处拼错。
enum SettingsKey {
    static let fadeWhenInactive = "Noticky.fadeWhenInactive"
    static let noteSort = "Noticky.noteSort"
    static let captureMode = "Noticky.captureMode"
    /// 换行分隔的 bundle ID 列表。换行而非 JSON,UserDefaults plist 里直接可读,
    /// SwiftUI 用一个 TextEditor 就能编辑,没必要为此引入 codable 中间层。
    static let clipboardWhitelist = "Noticky.clipboardWhitelist"
    static let doubleClickTitleToCollapse = "Noticky.doubleClickTitleToCollapse"
    static let appLanguage = "Noticky.appLanguage"

    /// 菜单栏图标右侧数字徽标的显示模式(String raw,MenuBarCountMode enum)。
    static let menuBarCount = "Noticky.menuBarCount"

    /// 托盘菜单笔记列表的分组方式(String raw,MenuGroupingMode enum,默认 none)。
    static let menuGrouping = "Noticky.menuGrouping"

    /// 新建分组是否默认出现在托盘菜单笔记列表(Bool,默认 true)。见 MenuHiddenGroups。
    static let newGroupsShowInMenu = "Perch.newGroupsShowInMenu"

    /// 状态栏图标左键 / 右键点击行为(String raw,StatusItemClickAction,默认 menu)。
    static let statusItemLeftClick = "Perch.statusItemLeftClick"
    static let statusItemRightClick = "Perch.statusItemRightClick"

    /// 「管理所有便签」窗口打开期间是否显示 Dock 图标(Bool,默认 false)。
    static let managerShowsDockIcon = "Perch.managerShowsDockIcon"

    // 新建便签默认行为
    static let defaultColorIndex = "Noticky.defaultColorIndex"   // Int (0..5,对应 StickyPalette)
    static let noteFontSize = "Noticky.noteFontSize"             // Int (12..24,编辑态 NSTextView 字号)
    static let defaultNoteSize = "Noticky.defaultNoteSize"       // String raw,DefaultNoteSize enum

    /// iCloud 同步开关。改这个值后必须重启 Perch —— PersistenceController
    /// 在 init 时一次性读 + 决定走 NSPersistentContainer 还是
    /// NSPersistentCloudKitContainer,运行时无法热切换。
    static let iCloudSyncEnabled = "Noticky.iCloudSyncEnabled"   // Bool

    /// 回收站保留天数。超过这个天数的 trashed 笔记会在启动时被
    /// `purgeExpiredTrash` 真删。范围 7-365,未设默认 30(对齐 Notes/Mail)。
    static let trashRetentionDays = "Noticky.trashRetentionDays" // Int

    /// 上次成功推到 CloudKit Development 环境的 schema 版本号(SchemaVersion.rawValue)。
    /// **仅 DEBUG 用** —— 给开发者在 Settings → iCloud Sync 里看"本机推过的版本
    /// vs 当前 SchemaVersion.current"是否一致,提醒发布前要重新 push schema
    /// 并到 CloudKit Console 把 Dev → Prod 部署一遍。终端用户 release build 看不到这块。
    static let cloudKitDeployedSchemaVersion = "Noticky.cloudKitDeployedSchemaVersion" // String
}

/// 回收站保留天数的取值范围 + 默认值。集中在这里,SettingsView Stepper 和
/// `purgeExpiredTrash` 都引用,避免散落。
enum TrashRetention {
    static let defaultDays = 30
    static let range = 7...365
    /// UserDefaults 没设时返回默认值;`.integer(forKey:)` 默认会返回 0,要显式
    /// 拦截一下。
    static var current: Int {
        let raw = UserDefaults.standard.integer(forKey: SettingsKey.trashRetentionDays)
        guard range.contains(raw) else { return defaultDays }
        return raw
    }
}

/// 新建便签时浮窗的默认尺寸预设。Settings 用 picker 选,FloatingNoteWindowController.show
/// 在 note 没有 savedFrame 时用这个值作为初始 contentSize。
enum DefaultNoteSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var size: NSSize {
        switch self {
        case .small:  return NSSize(width: 240, height: 240)
        case .medium: return NSSize(width: 280, height: 280)
        case .large:  return NSSize(width: 360, height: 360)
        }
    }
    var label: String {
        switch self {
        case .small:  return L.t(.noteSizeSmall)
        case .medium: return L.t(.noteSizeMedium)
        case .large:  return L.t(.noteSizeLarge)
        }
    }
    static func from(_ raw: String) -> DefaultNoteSize {
        DefaultNoteSize(rawValue: raw) ?? .medium
    }
}

/// ⌘⇧N 抓选中文本的策略。两种自动模式都依赖辅助功能权限:
/// AX 模式直接 read selected text;剪贴板模式合成 ⌘C —— macOS 10.14+
/// 起合成按键同样走 TCC,没 AX 权限事件被静默丢弃,只是失败方式更隐蔽。
/// - `axWithWhitelist`:默认走 Accessibility;白名单里的 bundle ID 改走剪贴板合成。
/// - `clipboardOnly`:统统合成 ⌘C,适合微信等不暴露 AX 选区的 App。
/// - `disabled`:不抓,⌘⇧N 直接开空 capture(不需要任何权限)。
enum CaptureMode: String, CaseIterable, Identifiable {
    case axWithWhitelist
    case clipboardOnly
    case disabled

    var id: String { rawValue }
    var label: String {
        switch self {
        case .axWithWhitelist: return L.t(.captureModeAxWhitelist)
        case .clipboardOnly:   return L.t(.captureModeClipboardOnly)
        case .disabled:        return L.t(.captureModeDisabled)
        }
    }

    static func from(_ raw: String) -> CaptureMode {
        // 默认 .disabled —— 新用户不会被静默触发 AX 提示;要自动抓选区
        // 得在 Settings → Capture 里主动选 AX / 剪贴板模式。
        CaptureMode(rawValue: raw) ?? .disabled
    }
}

/// 解析 / 写回 `SettingsKey.clipboardWhitelist`(换行分隔的 bundle ID)。
/// trim 空行 + whitespace,大小写敏感(macOS bundle ID 实际就是大小写敏感)。
enum ClipboardWhitelist {
    static func parse(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func contains(_ raw: String, bundleID: String) -> Bool {
        parse(raw).contains(bundleID)
    }
}

/// 笔记列表的排序方式 —— 影响 ManagerView 和菜单栏。
enum NoteSort: String, CaseIterable, Identifiable {
    case dateEdited
    case dateCreated
    case title

    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateEdited: return L.t(.sortDateEdited)
        case .dateCreated: return L.t(.sortDateCreated)
        case .title:       return L.t(.sortTitle)
        }
    }

    static func from(_ raw: String) -> NoteSort {
        NoteSort(rawValue: raw) ?? .dateEdited
    }
}

/// 菜单栏图标右侧数字徽标的显示模式。
/// - `none`:不显示,状态栏只剩图标(默认)。
/// - `total`:全部未删除便签的数量。
/// - `active`:当前显示中的便签数 —— 用 `isPinned`(它同时表达「浮窗打开中 /
///   下次启动自动恢复」,见 CLAUDE.md),所以纯靠 Core Data 就能算,
///   开关浮窗时 isPinned 写库会触发 MenuBarController 刷新。
enum MenuBarCountMode: String, CaseIterable, Identifiable {
    case none
    case total
    case active

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:   return L.t(.menuBarCountNone)
        case .total:  return L.t(.menuBarCountTotal)
        case .active: return L.t(.menuBarCountActive)
        }
    }

    static func from(_ raw: String) -> MenuBarCountMode {
        MenuBarCountMode(rawValue: raw) ?? .none
    }
}

/// 状态栏图标被点击时做什么。左右键各自独立配置;两边不能同时为 `manager`,
/// 否则托盘菜单(含退出、设置)就没有入口了 —— Settings 里改一边时会把另一边拨回 menu,
/// MenuBarController 里也兜一层。
enum StatusItemClickAction: String, CaseIterable, Identifiable {
    case menu
    case manager

    var id: String { rawValue }
    var label: String {
        switch self {
        case .menu:    return L.t(.statusClickShowMenu)
        case .manager: return L.t(.statusClickOpenManager)
        }
    }

    static func from(_ raw: String) -> StatusItemClickAction {
        StatusItemClickAction(rawValue: raw) ?? .menu
    }
}

/// 托盘菜单笔记列表的分组方式。
/// - `none`:一个平铺列表,不分组(默认)。
/// - `sections`:按分组分段,段头用 `NSMenuItem.sectionHeader`(非交互小标题),
///   笔记仍在同一层级,适合分组少、想一眼扫完的场景。
/// - `submenu`:每个分组收成一个子菜单,鼠标悬停展开;未分组的笔记留在顶层,
///   适合分组多、想保持菜单短的场景。
enum MenuGroupingMode: String, CaseIterable, Identifiable {
    case none
    case sections
    case submenu

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:     return L.t(.menuGroupingNone)
        case .sections: return L.t(.menuGroupingSections)
        case .submenu:  return L.t(.menuGroupingSubmenu)
        }
    }

    static func from(_ raw: String) -> MenuGroupingMode {
        MenuGroupingMode(rawValue: raw) ?? .none
    }
}

// MARK: - Menu Bar ------------------------------------------------------------

/// 菜单栏图标 / 托盘菜单 / 管理窗口 Dock 图标相关设置。从 General 拆出来,
/// 免得 General 过长(scrollDisabled 下会被截断)。
struct MenuBarTab: View {
    @AppStorage(SettingsKey.menuBarCount) private var menuBarCountRaw: String = MenuBarCountMode.none.rawValue
    @AppStorage(SettingsKey.menuGrouping) private var menuGroupingRaw: String = MenuGroupingMode.none.rawValue
    @AppStorage(SettingsKey.newGroupsShowInMenu) private var newGroupsShowInMenu: Bool = true
    @AppStorage(SettingsKey.statusItemLeftClick) private var leftClickRaw: String = StatusItemClickAction.menu.rawValue
    @AppStorage(SettingsKey.statusItemRightClick) private var rightClickRaw: String = StatusItemClickAction.menu.rawValue
    @AppStorage(SettingsKey.managerShowsDockIcon) private var managerShowsDockIcon: Bool = false
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                // 状态栏图标左 / 右键行为。两边不能都是「打开管理窗口」(托盘菜单会没入口),
                // 设一边为 manager 时若另一边也是 manager,就把另一边拨回 menu。
                Picker(L.t(.generalStatusLeftClick), selection: Binding(
                    get: { leftClickRaw },
                    set: { newValue in
                        leftClickRaw = newValue
                        if newValue == StatusItemClickAction.manager.rawValue,
                           rightClickRaw == StatusItemClickAction.manager.rawValue {
                            rightClickRaw = StatusItemClickAction.menu.rawValue
                        }
                    }
                )) {
                    ForEach(StatusItemClickAction.allCases) { action in
                        Text(action.label).tag(action.rawValue)
                    }
                }
                .pickerStyle(.menu)
                // 同 General 的 Picker:唯一前缀 + 语言后缀,语言切换时重建。
                .id("leftClickPicker.\(loc.current.rawValue)")

                Picker(L.t(.generalStatusRightClick), selection: Binding(
                    get: { rightClickRaw },
                    set: { newValue in
                        rightClickRaw = newValue
                        if newValue == StatusItemClickAction.manager.rawValue,
                           leftClickRaw == StatusItemClickAction.manager.rawValue {
                            leftClickRaw = StatusItemClickAction.menu.rawValue
                        }
                    }
                )) {
                    ForEach(StatusItemClickAction.allCases) { action in
                        Text(action.label).tag(action.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id("rightClickPicker.\(loc.current.rawValue)")

                // 菜单栏图标右侧数字徽标。改这个值后 @AppStorage 落 UserDefaults,
                // MenuBarController 监听 UserDefaults.didChangeNotification 立即刷新。
                Picker(L.t(.generalMenuBarCount), selection: $menuBarCountRaw) {
                    ForEach(MenuBarCountMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id("menuBarCountPicker.\(loc.current.rawValue)")
            }

            Section {
                // 托盘菜单笔记列表的分组方式:平铺 / 分段 / 子菜单。默认平铺。
                // @AppStorage 落 UserDefaults,MenuBarController 下次 buildMenu 即读新值。
                Picker(L.t(.generalMenuGrouping), selection: $menuGroupingRaw) {
                    ForEach(MenuGroupingMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id("menuGroupingPicker.\(loc.current.rawValue)")

                Toggle(isOn: $newGroupsShowInMenu) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t(.generalNewGroupsInMenu))
                        Text(L.t(.generalNewGroupsInMenuDesc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                // ManagerWindowController 监听 UserDefaults 变化,窗口开着时切换即时生效。
                Toggle(isOn: $managerShowsDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t(.generalManagerDockIcon))
                        Text(L.t(.generalManagerDockIconDesc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 440)
    }
}

// MARK: - General -------------------------------------------------------------

struct GeneralTab: View {
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @AppStorage(SettingsKey.noteSort) private var noteSortRaw: String = NoteSort.dateEdited.rawValue
    @AppStorage(SettingsKey.fadeWhenInactive) private var fadeWhenInactive: Bool = true
    @AppStorage(SettingsKey.doubleClickTitleToCollapse) private var doubleClickToCollapse: Bool = false
    @AppStorage(SettingsKey.trashRetentionDays) private var trashRetentionDays: Int = TrashRetention.defaultDays
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            Toggle(L.t(.generalLaunchAtLogin), isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }
            ))

            Picker(L.t(.generalSortBy), selection: $noteSortRaw) {
                ForEach(NoteSort.allCases) { sort in
                    Text(sort.label).tag(sort.rawValue)
                }
            }
            .pickerStyle(.menu)
            // ForEach 的 id 是 enum rawValue,不会随语言变;SwiftUI 因此跳过
            // Text(sort.label) 的内容更新,菜单项和选中显示都停留在首次语言。
            // id 绑到 loc.current 上,语言切换瞬间整个 Picker 重建。
            // **必须带各自前缀**:同一容器里多个兄弟 Picker 若 .id() 值相同,
            // SwiftUI 身份冲突会把后者渲染成前者。
            .id("sortPicker.\(loc.current.rawValue)")

            // 语言:跟随系统 / English / 简体中文。setLanguage 是 @Published,
            // 切换瞬间所有订阅 LocalizationManager 的 view 重渲染,无需重启。
            Picker(L.t(.generalLanguage), selection: Binding(
                get: { loc.current },
                set: { loc.setLanguage($0) }
            )) {
                Text(L.t(.langFollowSystem)).tag(AppLanguage.system)
                Text(L.t(.langEnglish)).tag(AppLanguage.english)
                Text(L.t(.langChinese)).tag(AppLanguage.chinese)
            }
            .pickerStyle(.menu)

            Toggle(isOn: $fadeWhenInactive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(.generalFadeWhenInactive))
                    Text(L.t(.generalFadeWhenInactiveDesc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $doubleClickToCollapse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(.generalDoubleClickCollapse))
                    Text(L.t(.generalDoubleClickCollapseDesc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 回收站保留天数。Stepper bind 到 @AppStorage,改一下立即落 UserDefaults,
            // 下次启动 purgeExpiredTrash 用新值。当前已在回收站里超期的下次启动才清。
            Stepper(value: Binding(
                get: { trashRetentionDays > 0 ? trashRetentionDays : TrashRetention.defaultDays },
                set: { trashRetentionDays = $0 }
            ), in: TrashRetention.range, step: 1) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(.generalTrashRetention, trashRetentionDays > 0 ? trashRetentionDays : TrashRetention.defaultDays))
                    Text(L.t(.generalTrashRetentionDesc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 危险区:整库一次性清空。单独 Section + destructive 角色,跟上面
            // 的偏好项视觉分开;真正的二次确认在 clearAllContent 的 NSAlert 里
            //(critical + 回车默认落在「取消」上,防误删)。
            Section {
                #if DEBUG
                // 仅 DEBUG:一键造演示数据。additive、dev-only,不弹确认。
                Button(action: fillDemoData) {
                    Text(L.t(.generalFillDemo))
                }
                Text(L.t(.generalFillDemoDesc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Button(role: .destructive, action: clearAllContent) {
                    Text(L.t(.generalClearAll))
                }
            } header: {
                Text(L.t(.generalDataSection))
            } footer: {
                Text(L.t(.generalClearAllDesc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: Self.tabHeight)
    }

    /// 窗口按选中 tab 的 preferredContentSize 定高(见 SettingsWindowController),
    /// 且 `.scrollDisabled(true)` —— 高度不够内容会被截断,不会出滚动条。
    /// DEBUG 构建多出「填充演示数据」按钮 + 一段较长说明,560 装不下;Release
    /// 没这段。菜单栏相关的两个 Picker 已挪到 MenuBarTab,各减 ~80。
    private static var tabHeight: CGFloat {
        #if DEBUG
        600
        #else
        480
        #endif
    }

    /// 清空全部内容。强二次确认 —— `.critical` NSAlert,清空键标 destructive
    /// 外观且不绑回车,回车落在「取消」(安全默认),贴合 macOS 破坏性操作规范。
    /// 确认后走 FloatingNotesRegistry.clearAll(同步关浮窗 + 下一 tick 删库),
    /// 再弹完成提示。registry 还没建好(理论上不会,Settings 在启动后才开)
    /// 时静默 no-op。
    private func clearAllContent() {
        let context = PersistenceController.shared.container.viewContext
        guard let registry = FloatingNotesRegistry.shared else { return }
        let counts = registry.contentCounts(in: context)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L.t(.generalClearAllConfirmTitle)
        alert.informativeText = L.t(.generalClearAllConfirmMsg, counts.notes, counts.groups)
        let clear = alert.addButton(withTitle: L.t(.generalClearAllConfirmButton))
        clear.hasDestructiveAction = true
        clear.keyEquivalent = ""          // 不做回车默认,防误删
        let cancel = alert.addButton(withTitle: L.t(.cancel))
        cancel.keyEquivalent = "\r"       // 回车 = 取消(安全默认)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let deleted = registry.clearAll(in: context)

        let done = NSAlert()
        done.messageText = L.t(.appName)
        done.informativeText = L.t(.generalClearAllDone, deleted.notes, deleted.groups)
        done.addButton(withTitle: L.t(.ok))
        done.runModal()
    }

    #if DEBUG
    /// 仅 DEBUG:填充演示数据。无确认 —— 纯 additive、只有 dev 看得到这个按钮。
    private func fillDemoData() {
        let context = PersistenceController.shared.container.viewContext
        let added = DemoData.fill(into: context)
        let done = NSAlert()
        done.messageText = L.t(.appName)
        done.informativeText = L.t(.generalFillDemoDone, added.notes, added.groups)
        done.addButton(withTitle: L.t(.ok))
        done.runModal()
    }
    #endif

    /// SMAppService.mainApp 要求 App 已正确签名 + 在 /Applications 之类标准位置。
    /// Debug 构建可能注册失败 —— catch 之后用 service.status 反查真实状态,UI 跟着走。
    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("Perch: launch at login toggle failed: %@", "\(error)")
        }
        launchAtLoginEnabled = service.status == .enabled
    }
}

// MARK: - Capture -------------------------------------------------------------

/// ⌘⇧N 抓取策略 + 剪贴板白名单 + AX 权限卡片。默认 `.disabled`,用户选其他模式才
/// 显示对应配置;`.axWithWhitelist` 还会展示 Accessibility 授权状态(原 Permissions
/// tab 已合并进来 —— 这是目前唯一需要的系统权限,放抓取页里语境最贴)。
struct CaptureTab: View {
    @AppStorage(SettingsKey.captureMode) private var captureModeRaw: String = CaptureMode.disabled.rawValue
    @AppStorage(SettingsKey.clipboardWhitelist) private var whitelistRaw: String = ""
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var accessibilityGranted: Bool = SelectionFetcher.isTrusted

    private var mode: CaptureMode { CaptureMode.from(captureModeRaw) }
    // 两种自动模式都需要 AX:.axWithWhitelist 读 selected text、
    // .clipboardOnly 合成 ⌘C —— 两者在 macOS 10.14+ 都受 TCC 管。
    private var needsAccessibility: Bool { mode != .disabled }
    private var showsWhitelist: Bool { mode == .axWithWhitelist }

    var body: some View {
        Form {
            Section {
                Picker(L.t(.captureMethod), selection: $captureModeRaw) {
                    ForEach(CaptureMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id(loc.current)  // 见 GeneralTab 的 sort picker 同样原因
            } footer: {
                Text(modeFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if needsAccessibility {
                Section {
                    permissionRow(
                        title: L.t(.permissionAccessibilityTitle),
                        description: L.t(.permissionAccessibilityDesc),
                        granted: accessibilityGranted,
                        openSettings: SelectionFetcher.requestAndOpenAccessibilitySettings
                    )
                } footer: {
                    Text(L.t(.permissionFooter))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsWhitelist {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t(.captureWhitelistTitle))
                            .font(.callout.weight(.medium))
                        TextEditor(text: $whitelistRaw)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                        Text(L.t(.captureWhitelistHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: heightForMode)
        // 用户切到任意自动模式且尚未授权 —— 跑一次 requestTrust 触发系统原生
        // prompt,把 Perch 注册进 TCC 让它出现在「辅助功能」列表里。
        // .clipboardOnly 同样要 AX:合成的 ⌘C 走 CGEvent,macOS 10.14+ 起没
        // 权限就被静默丢弃。已授权时是 no-op。
        .onChange(of: captureModeRaw) { _, newValue in
            if CaptureMode.from(newValue) != .disabled && !SelectionFetcher.isTrusted {
                SelectionFetcher.requestTrust()
            }
        }
        // 用户去系统设置勾完授权切回 Perch 时刷新一次。AX 状态进程内是
        // 实时生效的,只是 SwiftUI 的 @State 不会自动复算 —— 必须显式 poke。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            accessibilityGranted = SelectionFetcher.isTrusted
        }
        .onAppear {
            accessibilityGranted = SelectionFetcher.isTrusted
        }
    }

    private var modeFooter: String {
        switch mode {
        case .axWithWhitelist: return L.t(.captureFooterAxWhitelist)
        case .clipboardOnly:   return L.t(.captureFooterClipboardOnly)
        case .disabled:        return L.t(.captureFooterDisabled)
        }
    }

    private var heightForMode: CGFloat {
        switch mode {
        case .axWithWhitelist: return 540  // mode + permission + whitelist
        case .clipboardOnly:   return 320  // mode + permission
        case .disabled:        return 180  // mode only
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title2)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(granted ? L.t(.permissionGranted) : L.t(.permissionNotGranted))
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
                    .padding(.top, 2)
            }

            Spacer(minLength: 8)

            Button(granted ? L.t(.permissionOpen) : L.t(.permissionOpenSettings)) {
                openSettings()
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shortcuts -----------------------------------------------------------

struct ShortcutsTab: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            // 可自定义。库自己读写 UserDefaults,改完立刻 re-register 全局热键 ——
            // AppDelegate 那侧 onKeyDown 不需要重新订阅。
            Section(L.t(.shortcutsCustomizable)) {
                HStack {
                    Text(L.t(.shortcutQuickCapture))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .quickCapture)
                }
                // 浮窗尺寸:一个键循环 小 → 中 → 大,默认未绑定,作用于当前 key 浮窗。
                HStack {
                    Text(L.t(.shortcutResizeCycle))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .resizeNoteCycle)
                }
                // 悬浮置顶:一键翻转全局 Float on Top,默认未绑定。
                HStack {
                    Text(L.t(.shortcutToggleFloatOnTop))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleFloatOnTop)
                }
            }

            // menu / window 派发的快捷键。短期内不打算让用户改 —— 它们是 macOS
            // 标准约定,改了反而增加困惑。后续如果有需求再单独迁这一组。
            Section(L.t(.shortcutsSystem)) {
                row(action: L.t(.shortcutManageNotes),   shortcut: "⌘⇧0")
                row(action: L.t(.shortcutOpenSettings),  shortcut: "⌘,")
                row(action: L.t(.shortcutNewNote),       shortcut: "⌘N")
                row(action: L.t(.shortcutCloseWindow),   shortcut: "⌘W")
                row(action: L.t(.shortcutDeleteNote),    shortcut: "⌘D")
                row(action: L.t(.shortcutQuit),          shortcut: "⌘Q")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 470)
    }

    private func row(action: String, shortcut: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notes ---------------------------------------------------------------

struct NotesTab: View {
    @AppStorage(SettingsKey.defaultColorIndex) private var defaultColorIndex: Int = 0
    @AppStorage(SettingsKey.noteFontSize) private var noteFontSize: Int = 14
    @AppStorage(SettingsKey.defaultNoteSize) private var defaultNoteSizeRaw: String = DefaultNoteSize.medium.rawValue
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            // 颜色:6 圆点 HStack。点中带 accent ring,跟浮窗 ⋯ 菜单的颜色 picker 一致。
            // 末尾多一个「随机」选项 —— 彩色渐变圆 + shuffle 图标,选中时每张新建
            // 便签现摇一个颜色。
            LabeledContent(L.t(.notesDefaultColor)) {
                HStack(spacing: 8) {
                    ForEach(StickyPalette.allCases) { palette in
                        Button {
                            defaultColorIndex = Int(palette.rawValue)
                        } label: {
                            Circle()
                                .fill(palette.swatchFill)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(
                                        defaultColorIndex == Int(palette.rawValue)
                                            ? Color.accentColor
                                            : Color.black.opacity(0.15),
                                        lineWidth: defaultColorIndex == Int(palette.rawValue) ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    let isRandom = defaultColorIndex == StickyPalette.randomSentinel
                    Button {
                        defaultColorIndex = StickyPalette.randomSentinel
                    } label: {
                        Circle()
                            .fill(AngularGradient(
                                colors: StickyPalette.allCases.map(\.color) + [StickyPalette.allCases[0].color],
                                center: .center
                            ))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Image(systemName: "shuffle")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 1)
                            )
                            .overlay(
                                Circle().stroke(
                                    isRandom ? Color.accentColor : Color.black.opacity(0.15),
                                    lineWidth: isRandom ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(L.t(.notesDefaultColorRandom))
                }
            }

            // 字号:Stepper 12..24。新建 / 已打开的编辑器都会通过 MarkdownEngineNoteEditor
            // 的 @AppStorage + updateNSView 同步刷新。
            Stepper(value: $noteFontSize, in: 12...24, step: 1) {
                LabeledContent(L.t(.notesFontSize)) {
                    Text("\(noteFontSize) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Picker(L.t(.notesDefaultSize), selection: $defaultNoteSizeRaw) {
                ForEach(DefaultNoteSize.allCases) { size in
                    Text(size.label).tag(size.rawValue)
                }
            }
            .pickerStyle(.menu)
            .id(loc.current)  // 见 GeneralTab 的 sort picker 同样原因
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 300)
    }
}

// MARK: - Updates (Sparkle) ---------------------------------------------------

/// Sparkle 自动更新偏好。Sparkle 的 controller 是 main-thread 单例
/// (`UpdaterService.shared`),@ObservedObject 订阅 canCheck / lastChecked
/// 的 @Published 镜像,改了立即重渲染。
///
/// `autoCheck` 在两处持有:Sparkle 自己的 defaults domain(它内部读)+ 我们
/// 的 `@AppStorage("Noticky.updater.autoCheck")` 镜像(AppDelegate 启动时读,
/// 用户首次安装默认 true 不需要 Sparkle 第一次初始化才设)。toggle 时两边同写。
struct UpdatesTab: View {
    @ObservedObject private var updater = UpdaterService.shared
    @ObservedObject private var loc = LocalizationManager.shared
    @AppStorage("Noticky.updater.autoCheck") private var autoCheckMirror: Bool = true
    @AppStorage("Noticky.updater.includePrereleases") private var includePrereleases: Bool = false

    /// 频率选项(秒)。Sparkle 下限 1 小时,所以最小给到每小时。
    private let intervalOptions: [(key: LocKey, seconds: TimeInterval)] = [
        (.updatesIntervalHourly, 3600),
        (.updatesIntervalDaily, 86400),
        (.updatesIntervalWeekly, 604800),
    ]

    var body: some View {
        Form {
            Section {
                Toggle(L.t(.updatesAutoCheck), isOn: Binding(
                    get: { autoCheckMirror },
                    set: { newValue in
                        autoCheckMirror = newValue
                        updater.autoCheck = newValue
                    }
                ))
                Picker(L.t(.updatesInterval), selection: Binding(
                    get: { snappedInterval },
                    set: { updater.setUpdateInterval($0) }
                )) {
                    ForEach(intervalOptions, id: \.seconds) { option in
                        Text(L.t(option.key)).tag(option.seconds)
                    }
                }
                .disabled(!autoCheckMirror)
                Toggle(L.t(.updatesIncludePrereleases), isOn: $includePrereleases)
            } footer: {
                Text(L.t(.updatesFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent(L.t(.updatesCurrentVersion)) {
                    Text("\(updater.currentVersion) (\(updater.currentBuild))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent(L.t(.updatesLastChecked)) {
                    Text(lastCheckedLabel)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(L.t(.updatesCheckNow)) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheck)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 360)
    }

    private var lastCheckedLabel: String {
        guard let date = updater.lastChecked else { return L.t(.updatesNeverChecked) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 把 Sparkle 当前的 updateCheckInterval 吸附到最近的预设选项,保证 Picker
    /// 永远有一个匹配的 tag(否则非预设值会让 Picker 显示空白)。
    private var snappedInterval: TimeInterval {
        let current = updater.checkInterval
        return intervalOptions
            .min { abs($0.seconds - current) < abs($1.seconds - current) }?
            .seconds ?? 86400
    }
}

// MARK: - iCloud --------------------------------------------------------------

/// iCloud Sync 偏好。结构:
///   1. 顶部 Toggle 开关 + 说明 + 重启提示(toggle 改了但还没重启时显示)。
///   2. 状态区(只在已经按开启 + 进程当前实际是 CloudKit 模式时显示):
///      账户状态 / Activity / 上次同步 / Container / Refresh 按钮。
///   3. 没启用时显示一段 hint。
///
/// "开关 toggle 状态" 与 "进程当前是否是 CloudKit 模式" 是两个独立信号:用户刚
/// 勾上但没重启,前者 true、后者 false —— 这种情况下只显示重启提示,状态区不渲染。
struct ICloudTab: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject private var monitor = CloudKitSyncMonitor.shared
    @AppStorage(SettingsKey.iCloudSyncEnabled) private var enabledPref: Bool = false
    @AppStorage(SettingsKey.cloudKitDeployedSchemaVersion) private var deployedSchemaVersion: String = ""
    @State private var schemaInitMessage: String?
    @State private var schemaInitFailed: Bool = false
    @State private var migrationTestMessage: String?
    @State private var migrationTestFailed: Bool = false
    @State private var migrationTestRunning: Bool = false

    /// 进程启动时 PersistenceController 决定的 mode。这个值不会随 toggle 改变,
    /// 与 enabledPref 不一致时说明用户改了开关但还没重启。
    private var actuallyRunningCloudKit: Bool {
        PersistenceController.shared.cloudKitEnabled
    }

    var body: some View {
        Form {
            Section {
                Toggle(L.t(.iCloudEnable), isOn: $enabledPref)
            } footer: {
                Text(L.t(.iCloudEnableDesc))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if enabledPref != actuallyRunningCloudKit {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t(.iCloudRestartRequired)).fontWeight(.medium)
                            Text(L.t(.iCloudRestartHint))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button(L.t(.iCloudRestartNow)) {
                            relaunchApp()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }

            if actuallyRunningCloudKit {
                Section {
                    LabeledContent(L.t(.iCloudAccountStatusLabel)) {
                        HStack(spacing: 6) {
                            Image(systemName: accountIcon)
                                .foregroundStyle(accountTint)
                            Text(monitor.accountStatus.localizedLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(L.t(.iCloudActivityLabel)) {
                        Text(activitySummary)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(L.t(.iCloudLastSyncLabel)) {
                        Text(lastSyncText)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(L.t(.iCloudContainerLabel)) {
                        Text(CloudKitConfig.containerIdentifier)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Spacer()
                        Button(L.t(.iCloudRefresh)) {
                            monitor.refreshAccountStatus()
                        }
                        if monitor.accountStatus != .available {
                            Button(L.t(.iCloudOpenAccountSettings)) {
                                openIcloudSettings()
                            }
                        }
                    }
                } footer: {
                    Text(L.t(.iCloudFooter))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                schemaDebugSection
                migrationTesterSection
                #endif
            } else if !enabledPref {
                Section {
                    Label(L.t(.iCloudDisabledHint), systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: dynamicHeight)
    }

    /// 内容多寡浮动:开关+只读 hint 时矮一些,启用+状态区时高一些。
    /// DEBUG 构建时多两段(schema 跟踪 + migration tester)。
    private var dynamicHeight: CGFloat {
        #if DEBUG
        if actuallyRunningCloudKit { return 800 }
        #else
        if actuallyRunningCloudKit { return 460 }
        #endif
        if enabledPref != actuallyRunningCloudKit { return 320 }
        return 220
    }

    /// 一键重启:fork 一个 shell trampoline,等当前 PID 退出后再 `open` app bundle,
    /// 然后走标准 `NSApp.terminate(nil)` 路径,让 applicationShouldTerminate 跑完
    /// (它把 floating.isTerminating 置 true,保住 isPinned 状态不被 windowWillClose 清掉)。
    /// 必须等当前进程退出再 open,否则 LaunchServices 看到同 bundle id 已在跑会忽略。
    private func relaunchApp() {
        // @AppStorage 写盘是 runloop 末尾,terminate 前同步一次确保新值落盘,
        // 否则新进程 init PersistenceController 时还读到旧值。
        UserDefaults.standard.synchronize()

        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let escaped = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open '\(escaped)'"

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            NSLog("Perch relaunch trampoline failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    #if DEBUG
    /// CloudKit Development 环境的 schema 推送 + 部署版本跟踪。
    /// 每次 SchemaVersion.current 升级后必须重跑,否则新字段在云上不存在,
    /// sync 会忽略它们。Push 成功后还要去 CloudKit Console 把 Dev 部署到 Production。
    @ViewBuilder
    private var schemaDebugSection: some View {
        Section {
            LabeledContent(L.t(.iCloudSchemaCurrent)) {
                Text(SchemaVersion.current.rawValue)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L.t(.iCloudSchemaDeployed)) {
                Text(deployedSchemaVersion.isEmpty
                     ? L.t(.iCloudSchemaDeployedNever)
                     : deployedSchemaVersion)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(deployedSchemaVersion == SchemaVersion.current.rawValue
                                     ? Color.secondary : Color.orange)
            }
            if !deployedSchemaVersion.isEmpty,
               deployedSchemaVersion != SchemaVersion.current.rawValue {
                Label {
                    Text(L.t(.iCloudSchemaNeedsRedeploy))
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Button(L.t(.iCloudInitSchema)) {
                initializeSchema()
            }
            if let msg = schemaInitMessage {
                Label(msg, systemImage: schemaInitFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(schemaInitFailed ? Color.red : Color.green)
                    .font(.callout)
            }
        } header: {
            Text(L.t(.iCloudSchemaSection))
        } footer: {
            Text(L.t(.iCloudInitSchemaHint))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Lightweight migration 端到端自检。每次 bumping SchemaVersion.current 之前
    /// 跑一次确认升级链路能跑通(SchemaMigrationTester 会拿合成的旧版 store 走
    /// 一遍真实迁移)。
    @ViewBuilder
    private var migrationTesterSection: some View {
        Section {
            Button(L.t(.iCloudMigrationTest)) {
                runMigrationTest()
            }
            .disabled(migrationTestRunning)
            if migrationTestRunning {
                Label(L.t(.iCloudMigrationTestRunning), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if let msg = migrationTestMessage {
                Label(msg, systemImage: migrationTestFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(migrationTestFailed ? Color.red : Color.green)
                    .font(.callout)
            }
        } footer: {
            Text(L.t(.iCloudMigrationTestHint))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    #if DEBUG
    /// 后台 thread 推 schema —— 这个调用是同步 + 网络阻塞,主线程跑会卡 UI。
    /// 成功后 Cloud Console 里能看到 record types(`CD_Note`、`CD_NoteGroup`)+
    /// 默认 zone (`com.apple.coredata.cloudkit.zone`) 出现。
    /// 成功后把 SchemaVersion.current.rawValue 写进 UserDefaults,
    /// 下次进 Settings 能看到 "deployed=X | current=Y" 的对比。
    /// 整体 #if DEBUG 包,因为依赖的 PersistenceController.initializeCloudKitSchema()
    /// 也是 DEBUG-only(release 构建里 release 用户不应该能 push schema)。
    private func initializeSchema() {
        schemaInitMessage = nil
        schemaInitFailed = false
        let pushedVersion = SchemaVersion.current.rawValue
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PersistenceController.shared.initializeCloudKitSchema()
                DispatchQueue.main.async {
                    schemaInitMessage = L.t(.iCloudInitSchemaSuccess)
                    schemaInitFailed = false
                    deployedSchemaVersion = pushedVersion
                    monitor.refreshAccountStatus()
                }
            } catch {
                // "a Core Data error occurred" 是外层泛化 message,真正的 CloudKit
                // 原因藏在 NSError 的 userInfo / NSUnderlyingError 链里。完整打到
                // stderr(/tmp/perch.log)方便定位(例如 Bad Container / 未登录 iCloud)。
                var ns = error as NSError
                NSLog("Perch initSchema FAILED: %@ (%@ #%d) userInfo=%@",
                      ns.localizedDescription, ns.domain, ns.code, ns.userInfo as NSDictionary)
                while let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                    NSLog("Perch initSchema  ↳ underlying: %@ (%@ #%d) userInfo=%@",
                          under.localizedDescription, under.domain, under.code, under.userInfo as NSDictionary)
                    ns = under
                }
                let desc = (error as NSError).localizedDescription
                DispatchQueue.main.async {
                    schemaInitMessage = L.t(.iCloudInitSchemaFailed, desc)
                    schemaInitFailed = true
                }
            }
        }
    }

    /// 同步执行 SchemaMigrationTester.run() —— Core Data 操作放到后台 queue,
    /// 防止短暂阻塞 UI(实际开销 < 1s,但保险起见还是不在 main 上跑)。
    private func runMigrationTest() {
        migrationTestRunning = true
        migrationTestMessage = nil
        migrationTestFailed = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SchemaMigrationTester.run()
            DispatchQueue.main.async {
                migrationTestRunning = false
                switch result {
                case .passed(let msg):
                    migrationTestMessage = L.t(.iCloudMigrationTestPass, msg)
                    migrationTestFailed = false
                case .failed(let msg):
                    migrationTestMessage = L.t(.iCloudMigrationTestFail, msg)
                    migrationTestFailed = true
                }
            }
        }
    }
    #endif

    private var accountIcon: String {
        switch monitor.accountStatus {
        case .available:               return "checkmark.icloud"
        case .noAccount, .restricted:  return "icloud.slash"
        default:                       return "icloud"
        }
    }

    private var accountTint: Color {
        switch monitor.accountStatus {
        case .available:                                   return .green
        case .noAccount, .restricted, .temporarilyUnavailable: return .orange
        default:                                           return .secondary
        }
    }

    /// 把三类事件(setup/import/export)拼成一行人话。最近发生的优先显示,
    /// import / export 是日常状态,setup 只在初始化阶段出现一次。
    private var activitySummary: String {
        let parts: [(String, CloudKitSyncMonitor.EventState)] = [
            (L.t(.iCloudEventImport), monitor.importState),
            (L.t(.iCloudEventExport), monitor.exportState),
            (L.t(.iCloudEventSetup),  monitor.setupState)
        ]
        let active = parts.compactMap { name, state -> String? in
            switch state {
            case .idle: return nil
            case .running:           return "\(name): \(L.t(.iCloudActivityRunning))"
            case .succeeded:         return "\(name): \(L.t(.iCloudActivitySucceeded))"
            case .failed(let msg):   return "\(name): \(L.t(.iCloudActivityFailed)) — \(msg)"
            }
        }
        return active.isEmpty ? L.t(.iCloudActivityIdle) : active.joined(separator: "\n")
    }

    private var lastSyncText: String {
        guard let date = monitor.lastSyncDate else { return L.t(.iCloudLastSyncNever) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 打开 System Settings → Apple ID 面板。新版 macOS Settings.app 的
    /// deep link;失败时退化到普通 System Settings。
    private func openIcloudSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")
            ?? URL(string: "x-apple.systempreferences:")!
        NSWorkspace.shared.open(url)
    }
}
