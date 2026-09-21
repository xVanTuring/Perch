import Foundation
import Combine

/// 用户在 Settings 里选的语言。`.system` 表示跟随系统;`.english` / `.chinese`
/// 是显式覆盖。持久化在 UserDefaults(key 见 SettingsKey.appLanguage)。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese

    var id: String { rawValue }

    static func from(_ raw: String) -> AppLanguage {
        AppLanguage(rawValue: raw) ?? .system
    }
}

/// 全局语言状态。SwiftUI 视图通过 `@ObservedObject private var loc =
/// LocalizationManager.shared` 订阅 —— 用户切换语言时 published `current` 变
/// → view 重渲染 → `L.t(...)` 取到新语言文案。
///
/// AppKit 部分(MenuBarController 的 NSMenu、AppDelegate 的 main menu)按需
/// rebuild,每次 build 时直接读 `L.t(...)` 即可。
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var current: AppLanguage

    private init() {
        let raw = UserDefaults.standard.string(forKey: "Noticky.appLanguage") ?? ""
        self.current = AppLanguage.from(raw)
    }

    /// `.system` 时按系统当前 locale 推断 —— 我们只支持中英,zh 开头视为中文,
    /// 其它都退回英文。这样新语言系统的用户也有可读的兜底。
    var effective: AppLanguage {
        if current != .system { return current }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code.lowercased().hasPrefix("zh") ? .chinese : .english
    }

    func setLanguage(_ lang: AppLanguage) {
        guard lang != current else { return }
        current = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "Noticky.appLanguage")
    }
}

/// 所有用户可见字符串的 key。raw value 用作 fallback —— 字典里查不到时直接
/// 显示 key 名,容易在 UI 上发现遗漏。
enum LocKey: String {
    // 通用
    case appName, ok, cancel, save, delete, untitled, emptyNote, restore
    case langFollowSystem, langEnglish, langChinese

    // MenuBar
    case menuNewNote, menuShowAllStickies, menuHideAllStickies
    case menuManageAllNotes, menuSettings, menuFloatOnTop, menuLayout, menuQuit
    case menuMoveAllToDisplay
    case menuDisplay
    case menuUpdateAvailable

    // Layout modes
    case layoutFree, layoutStack, layoutTile

    // NoteSort
    case sortDateEdited, sortDateCreated, sortTitle

    // Settings tabs
    case tabGeneral, tabMenuBar, tabCapture, tabShortcuts, tabNotes, tabICloud, tabUpdates, tabMCP

    // Settings Agent (MCP server)
    case mcpEnable, mcpEnableDesc
    case mcpStatusRunning, mcpStatusStopped
    case mcpPort
    case mcpBindAll, mcpBindAllDesc
    case mcpAllowWrite, mcpAllowWriteDesc, mcpReadOnlyHint
    case mcpToken, mcpTokenDesc, mcpCopyToken, mcpRegenerateToken
    case mcpClientConfigSection, mcpCliSnippetLabel, mcpJsonSnippetLabel, mcpCopyCli, mcpCopyJson

    // Settings Updates (Sparkle)
    case updatesAutoCheck, updatesIncludePrereleases, updatesFooter
    case updatesCurrentVersion, updatesLastChecked, updatesNeverChecked
    case updatesCheckNow
    case updatesInterval, updatesIntervalHourly, updatesIntervalDaily, updatesIntervalWeekly

    // Settings General
    case generalLaunchAtLogin, generalSortBy
    case generalFadeWhenInactive, generalFadeWhenInactiveDesc
    case generalDoubleClickCollapse, generalDoubleClickCollapseDesc
    case generalLanguage
    case generalMenuBarCount
    case menuBarCountNone, menuBarCountTotal, menuBarCountActive
    case generalMenuGrouping
    case menuGroupingNone, menuGroupingSections, menuGroupingSubmenu
    case generalTrashRetention, generalTrashRetentionDesc
    case generalNewGroupsInMenu, generalNewGroupsInMenuDesc
    case generalStatusLeftClick, generalStatusRightClick
    case statusClickShowMenu, statusClickOpenManager
    case generalManagerDockIcon, generalManagerDockIconDesc
    // General → 数据(危险区:清空全部内容)
    case generalDataSection, generalClearAll, generalClearAllDesc
    case generalClearAllConfirmTitle, generalClearAllConfirmMsg, generalClearAllConfirmButton
    case generalClearAllDone
    // General → 数据(仅 DEBUG:演示数据填充)
    case generalFillDemo, generalFillDemoDesc, generalFillDemoDone

    // Settings Shortcuts
    case shortcutsCustomizable, shortcutsSystem
    case shortcutQuickCapture, shortcutManageNotes, shortcutOpenSettings
    case shortcutNewNote, shortcutCloseWindow, shortcutDeleteNote
    case shortcutQuit, shortcutsRoadmap
    case shortcutResizeCycle, shortcutToggleFloatOnTop

    // Settings Permissions
    case permissionAccessibilityTitle, permissionAccessibilityDesc
    case permissionGranted, permissionNotGranted, permissionOpenSettings, permissionOpen, permissionFooter

    // Settings Capture
    case captureMethod, captureFooterAxWhitelist, captureFooterClipboardOnly, captureFooterDisabled
    case captureModeAxWhitelist, captureModeClipboardOnly, captureModeDisabled
    case captureWhitelistTitle, captureWhitelistHint

    // Settings Notes
    case notesDefaultColor, notesDefaultColorRandom, notesFontSize, notesDefaultSize
    case noteSizeSmall, noteSizeMedium, noteSizeLarge

    // Settings iCloud Sync
    case iCloudEnable, iCloudEnableDesc
    case iCloudRestartRequired, iCloudRestartHint, iCloudRestartNow
    case iCloudAccountStatusLabel
    case iCloudAccountUnknown, iCloudAccountAvailable, iCloudAccountNone
    case iCloudAccountRestricted, iCloudAccountTempUnavail
    case iCloudOpenAccountSettings
    case iCloudLastSyncLabel, iCloudLastSyncNever
    case iCloudActivityLabel
    case iCloudActivityIdle, iCloudActivityRunning, iCloudActivitySucceeded, iCloudActivityFailed
    case iCloudEventSetup, iCloudEventImport, iCloudEventExport
    case iCloudRefresh
    case iCloudContainerLabel
    case iCloudFooter
    case iCloudDisabledHint
    // Debug-only schema 推送
    case iCloudInitSchema, iCloudInitSchemaHint
    case iCloudInitSchemaSuccess, iCloudInitSchemaFailed
    // Debug-only schema deployment 跟踪 + migration tester
    case iCloudSchemaSection
    case iCloudSchemaCurrent, iCloudSchemaDeployed, iCloudSchemaDeployedNever
    case iCloudSchemaNeedsRedeploy
    case iCloudMigrationTest, iCloudMigrationTestHint
    case iCloudMigrationTestRunning
    case iCloudMigrationTestPass, iCloudMigrationTestFail

    // Quick Capture
    case quickPlaceholder, quickSave, quickNewLine, quickCancel

    // Floating note popover
    case floatCollapse, floatExpand, floatDelete

    // Reminder
    case reminderSetTitle, reminderSet, reminderClear
    case reminderActiveLabel, reminderPastLabel
    case reminderPermissionDeniedTitle, reminderPermissionDeniedBody
    case reminderInvalidTimeTitle, reminderInvalidTimeBody

    // 从旧版 Noticky 一次性导入本地数据后的提示
    case legacyImportDoneTitle, legacyImportDoneBody, legacyImportKeep, legacyImportDelete

    // Manager toolbar / sidebar
    case managerSearch, managerNewGroup, managerNewNote
    case managerOpenAsSticky, managerMoveToGroup, managerMoveNotesToGroup
    case managerUngrouped, managerRename, managerRenameAlertTitle, managerGroupNamePlaceholder
    case managerRenameMessage, managerNewGroupAlertTitle, managerNewGroupMessage, managerCreate
    case managerDeleteGroup
    case managerHideGroupFromMenu, managerShowGroupInMenu
    case managerDeleteNote, managerDeleteCount
    case managerSelectNote, managerSelectNoteDesc
    case managerMultiSelected, managerMultiSelectedDesc
    case managerExport, managerExportCount
    case managerOpenCount, managerPinMenu, managerPinAll, managerUnpinAll, managerColorMenu

    // 色板名(批量改色用)
    case colorYellow, colorPink, colorBlue, colorGreen, colorPurple, colorGray, colorRainbow
    // 浮窗 ⋯ 菜单里颜色选择器的标题
    case noteColor

    // 编辑器右键「格式」菜单(见 NoteFormatMenu)
    case editorFormat, editorBold, editorItalic, editorHighlight
    case editorHeading, editorLists, editorBullet, editorNumbered

    // File menu IO(md/txt 文件 → 新便签)
    case fileImport
    case fileImportDone

    // 整库导出 / 导入(Manager toolbar 数据菜单)
    case managerDataMenu, managerExportAllSQLite, managerExportAllMarkdown, managerImportSQLite
    case exportAllSQLiteDone, exportAllSQLiteFailed
    case exportAllMarkdownDone
    case importSQLiteDone, importSQLiteFailed

    // Accessibility prompt (NSAlert)
    case promptAxTitle, promptAxBody, promptAxOpen, promptAxNotNow

    // Trash
    case trashTitle, trashEmpty, trashEmptyDesc, trashEmptyButton
    case trashEmptyAlert, trashEmptyAlertMsg
    case trashDeleteAlert, trashDeleteAlertMsg, trashCannotUndo
    case trashDeletePermanentlyHelp, trashedRelative

    // Archive
    case archiveTitle, archiveEmpty, archiveEmptyDesc, archivedRelative
    case archiveMoveToTrash
    case managerArchive, managerArchiveCount, managerUnarchive
    case floatArchive

    // All Tasks(跨笔记的未完成任务聚合)
    case tasksTitle, tasksEmpty, tasksEmptyDesc
}

/// 字符串查找器。`L.t(.foo)` 取无参数版本;`L.t(.foo, args)` 取 `String(format:)` 版本。
enum L {
    static func t(_ key: LocKey) -> String {
        let lang = LocalizationManager.shared.effective
        return strings[lang]?[key] ?? key.rawValue
    }

    static func t(_ key: LocKey, _ args: CVarArg...) -> String {
        let template = t(key)
        return String(format: template, arguments: args)
    }

    private static let strings: [AppLanguage: [LocKey: String]] = [
        .english: en,
        .chinese: zh
    ]

    private static let en: [LocKey: String] = [
        .appName: "Perch", .ok: "OK", .cancel: "Cancel", .save: "Save",
        .delete: "Delete", .untitled: "Untitled", .emptyNote: "Empty Note",
        .restore: "Restore",
        .langFollowSystem: "Follow System", .langEnglish: "English", .langChinese: "简体中文",

        .menuNewNote: "New Note", .menuShowAllStickies: "Show All Stickies",
        .menuHideAllStickies: "Hide All Stickies", .menuManageAllNotes: "Manage All Notes",
        .menuSettings: "Settings…", .menuFloatOnTop: "Float on Top",
        .menuLayout: "Layout", .menuQuit: "Quit Perch",
        .menuMoveAllToDisplay: "Move All Stickies to Display",
        .menuDisplay: "Display",
        .menuUpdateAvailable: "Update to %@ available…",

        .layoutFree: "Free Layout", .layoutStack: "Stack", .layoutTile: "Tile",

        .sortDateEdited: "Date Edited", .sortDateCreated: "Date Created", .sortTitle: "Title",

        .tabGeneral: "General", .tabMenuBar: "Menu Bar", .tabCapture: "Capture", .tabShortcuts: "Shortcuts",
        .tabNotes: "Notes", .tabICloud: "iCloud Sync", .tabUpdates: "Updates", .tabMCP: "Agent",

        .mcpEnable: "Enable MCP server",
        .mcpEnableDesc: "Lets a local AI agent (e.g. Claude Code) read and edit your notes over a JSON-RPC HTTP endpoint on this Mac. Starts and stops immediately — no restart needed.",
        .mcpStatusRunning: "Running on port %d",
        .mcpStatusStopped: "Stopped",
        .mcpPort: "Port",
        .mcpBindAll: "Allow connections from other devices",
        .mcpBindAllDesc: "Off (default): only this Mac can connect (127.0.0.1). On: listens on all network interfaces — anyone on your network with the token below could read or edit your notes.",
        .mcpAllowWrite: "Allow agents to write",
        .mcpAllowWriteDesc: "Off (default): agents can only read notes. On: agents can also create, edit, pin, archive, and delete (to Trash) notes.",
        .mcpReadOnlyHint: "Write tools are currently disabled — connected agents can only read your notes.",
        .mcpToken: "Access token",
        .mcpTokenDesc: "Required as a Bearer token on every request. Stored in the Keychain. Regenerating immediately invalidates the old token.",
        .mcpCopyToken: "Copy Token",
        .mcpRegenerateToken: "Regenerate…",
        .mcpClientConfigSection: "Client configuration",
        .mcpCliSnippetLabel: "Claude Code CLI",
        .mcpJsonSnippetLabel: "Generic JSON (mcpServers)",
        .mcpCopyCli: "Copy CLI Command",
        .mcpCopyJson: "Copy JSON",

        .updatesAutoCheck: "Automatically check for updates",
        .updatesIncludePrereleases: "Include pre-release builds (beta channel)",
        .updatesFooter: "Updates are signed with EdDSA, downloaded over HTTPS, and installed by Sparkle's helper. When a background check finds an update, it appears in the menu bar instead of interrupting you — click it to install. Pre-release builds come from the `beta` channel of the appcast.",
        .updatesCurrentVersion: "Current version",
        .updatesLastChecked: "Last checked",
        .updatesNeverChecked: "Never",
        .updatesCheckNow: "Check Now…",
        .updatesInterval: "Check frequency",
        .updatesIntervalHourly: "Every hour",
        .updatesIntervalDaily: "Every day",
        .updatesIntervalWeekly: "Every week",

        .generalLaunchAtLogin: "Launch at login",
        .generalSortBy: "Sort by:",
        .generalFadeWhenInactive: "Fade when inactive",
        .generalFadeWhenInactiveDesc: "Floating notes fade to translucent when not focused, highlighting the active window.",
        .generalDoubleClickCollapse: "Double-click title to collapse",
        .generalDoubleClickCollapseDesc: "Double-click a sticky note's title strip to shrink the window to just the title bar; double-click again to expand. State is remembered per note.",
        .generalLanguage: "Language",
        .generalMenuBarCount: "Menu bar count",
        .menuBarCountNone: "Don't show",
        .menuBarCountTotal: "All notes",
        .menuBarCountActive: "Shown stickies",
        .generalMenuGrouping: "Note grouping in menu",
        .menuGroupingNone: "Flat list",
        .menuGroupingSections: "Sections",
        .menuGroupingSubmenu: "Submenus",
        .generalNewGroupsInMenu: "Show new groups in menu bar",
        .generalNewGroupsInMenuDesc: "When off, groups created in Manage All Notes start hidden from the menu bar note list. Change per group via right-click.",
        .generalStatusLeftClick: "Menu bar icon left-click",
        .generalStatusRightClick: "Menu bar icon right-click",
        .statusClickShowMenu: "Show menu",
        .statusClickOpenManager: "Open Manage All Notes",
        .generalManagerDockIcon: "Show Dock icon for Manage All Notes",
        .generalManagerDockIconDesc: "While the Manage All Notes window is open, Perch appears in the Dock and the app switcher (⌘Tab).",
        .generalTrashRetention: "Keep deleted notes for %d days",
        .generalTrashRetentionDesc: "Notes in Trash are permanently removed after this many days. Range 7-365.",
        .generalDataSection: "Data",
        .generalClearAll: "Clear All Content…",
        .generalClearAllDesc: "Permanently deletes every note (including Archive and Trash) and every group. Settings are kept. This cannot be undone — export a backup first via Manage All Notes → Data.",
        .generalClearAllConfirmTitle: "Clear all content?",
        .generalClearAllConfirmMsg: "This permanently deletes all %d note(s) and %d group(s), including Archive and Trash. This cannot be undone.\n\nConsider exporting a backup first (Manage All Notes → Data).",
        .generalClearAllConfirmButton: "Clear Everything",
        .generalClearAllDone: "Cleared: deleted %d note(s) and %d group(s).",
        .generalFillDemo: "Fill Demo Data",
        .generalFillDemoDesc: "Debug builds only. Inserts a batch of sample notes and groups (English) spanning active, pinned, archived, and trashed states. Press repeatedly to accumulate.",
        .generalFillDemoDone: "Added %d demo note(s) and %d group(s).",

        .shortcutsCustomizable: "Customizable",
        .shortcutsSystem: "System",
        .shortcutQuickCapture: "Quick Capture",
        .shortcutManageNotes: "Manage All Notes",
        .shortcutOpenSettings: "Open Settings",
        .shortcutNewNote: "New Note (Manager / Capture)",
        .shortcutCloseWindow: "Close Window",
        .shortcutDeleteNote: "Delete Floating Note",
        .shortcutQuit: "Quit",
        .shortcutsRoadmap: "Customizing shortcuts is on the roadmap.",
        .shortcutResizeCycle: "Cycle Note Size (S → M → L)",
        .shortcutToggleFloatOnTop: "Toggle Float on Top",

        .permissionAccessibilityTitle: "Accessibility",
        .permissionAccessibilityDesc: "Required so ⌘⇧N can read the selected text from the frontmost app and prefill it into a new sticky.",
        .permissionGranted: "Granted",
        .permissionNotGranted: "Not granted",
        .permissionOpenSettings: "Open Settings",
        .permissionOpen: "Open",
        .permissionFooter: "Permissions are managed in System Settings → Privacy & Security. Open jumps you straight to the relevant pane.",

        .captureMethod: "Capture mode:",
        .captureModeAxWhitelist: "Accessibility + Clipboard whitelist",
        .captureModeClipboardOnly: "Clipboard only",
        .captureModeDisabled: "Disabled",
        .captureFooterAxWhitelist: "By default, capture selected text via Accessibility. Apps in the whitelist use ⌘C / clipboard instead, then restore the previous clipboard contents. Useful for apps like WeChat that don't expose AX selection.",
        .captureFooterClipboardOnly: "Always synthesize ⌘C and read the pasteboard, then restore the previous clipboard contents. macOS 10.14+ also gates synthesized keystrokes behind Accessibility, so the permission is required either way.",
        .captureFooterDisabled: "⌘⇧N opens an empty capture window without trying to read selected text.",
        .captureWhitelistTitle: "Clipboard whitelist (one bundle ID per line)",
        .captureWhitelistHint: "Examples: com.tencent.xinWeChat, com.microsoft.VSCode",

        .notesDefaultColor: "Default color",
        .notesDefaultColorRandom: "Random (a new color each note)",
        .notesFontSize: "Editor font size",
        .notesDefaultSize: "Default window size",
        .noteSizeSmall: "Small (240×240)",
        .noteSizeMedium: "Medium (280×280)",
        .noteSizeLarge: "Large (360×360)",
        .iCloudEnable: "Sync notes via iCloud",
        .iCloudEnableDesc: "Keep notes, groups, and trash in sync across all your Macs signed into the same iCloud account. Toggling this requires restarting Perch to take effect.",
        .iCloudRestartRequired: "Restart required",
        .iCloudRestartHint: "Quit and reopen Perch for the iCloud setting to take effect.",
        .iCloudRestartNow: "Restart Perch now",
        .iCloudAccountStatusLabel: "iCloud account",
        .iCloudAccountUnknown: "Checking…",
        .iCloudAccountAvailable: "Signed in",
        .iCloudAccountNone: "Not signed in",
        .iCloudAccountRestricted: "Restricted",
        .iCloudAccountTempUnavail: "Temporarily unavailable",
        .iCloudOpenAccountSettings: "Open iCloud Settings",
        .iCloudLastSyncLabel: "Last synced",
        .iCloudLastSyncNever: "Never",
        .iCloudActivityLabel: "Activity",
        .iCloudActivityIdle: "Idle",
        .iCloudActivityRunning: "Running…",
        .iCloudActivitySucceeded: "Succeeded",
        .iCloudActivityFailed: "Failed",
        .iCloudEventSetup: "Setup",
        .iCloudEventImport: "Import",
        .iCloudEventExport: "Export",
        .iCloudRefresh: "Refresh status",
        .iCloudContainerLabel: "Container",
        .iCloudFooter: "Sync uses Apple's CloudKit. Notes are encrypted in transit and at rest in your private CloudKit database. Sync runs automatically while Perch is open.",
        .iCloudDisabledHint: "Enable iCloud sync above to view sync status.",
        .iCloudInitSchema: "Initialize Cloud schema (Development)",
        .iCloudInitSchemaHint: "First-time only: pushes the local Core Data schema to your CloudKit Development environment so syncing can begin. Run once after creating the container in Apple Developer portal.",
        .iCloudInitSchemaSuccess: "Schema initialized. Sync should start within a few seconds.",
        .iCloudInitSchemaFailed: "Failed to initialize schema: %@",
        .iCloudSchemaSection: "Schema (Debug)",
        .iCloudSchemaCurrent: "Local schema version",
        .iCloudSchemaDeployed: "Last pushed to CloudKit Dev",
        .iCloudSchemaDeployedNever: "(never on this machine)",
        .iCloudSchemaNeedsRedeploy: "Local schema differs from last push — re-run \"Initialize Cloud schema\" before release, then deploy Dev → Production in CloudKit Console.",
        .iCloudMigrationTest: "Run migration self-test",
        .iCloudMigrationTestHint: "Builds a synthetic previous-version store and migrates it forward with the current model. Run before bumping SchemaVersion.current to verify lightweight migration still works.",
        .iCloudMigrationTestRunning: "Running migration test…",
        .iCloudMigrationTestPass: "✓ %@",
        .iCloudMigrationTestFail: "✗ %@",

        .quickPlaceholder: "Quick note…",
        .quickSave: "Save", .quickNewLine: "New line", .quickCancel: "Cancel",

        .floatCollapse: "Collapse", .floatExpand: "Expand", .floatDelete: "Delete note",

        .reminderSetTitle: "Remind me at",
        .reminderSet: "Set Reminder",
        .reminderClear: "Clear",
        .reminderActiveLabel: "Reminder set for %@",
        .reminderPastLabel: "Reminder passed (%@)",
        .reminderPermissionDeniedTitle: "Notifications are disabled",
        .reminderPermissionDeniedBody: "To deliver reminders, allow notifications for Perch in System Settings → Notifications.",
        .reminderInvalidTimeTitle: "Pick a future time",
        .reminderInvalidTimeBody: "The reminder time has to be later than now.",

        .legacyImportDoneTitle: "Imported from Noticky",
        .legacyImportDoneBody: "Imported %d note(s) and %d group(s) from your previous Noticky data.\n\nDelete the old Noticky data now? Keeping it won't affect Perch.",
        .legacyImportKeep: "Keep Old Data",
        .legacyImportDelete: "Delete Old Data",

        .managerSearch: "Search all notes",
        .managerNewGroup: "New Group",
        .managerNewNote: "New Note",
        .managerOpenAsSticky: "Open as Sticky",
        .managerMoveToGroup: "Move to Group",
        .managerMoveNotesToGroup: "Move %d Notes to Group",
        .managerUngrouped: "Ungrouped",
        .managerRename: "Rename",
        .managerRenameAlertTitle: "Rename Group",
        .managerGroupNamePlaceholder: "Group name",
        .managerRenameMessage: "Enter a new name for the group.",
        .managerNewGroupAlertTitle: "New Group",
        .managerNewGroupMessage: "Enter a name for the new group.",
        .managerCreate: "Create",
        .managerDeleteGroup: "Delete Group",
        .managerHideGroupFromMenu: "Hide from Menu Bar",
        .managerShowGroupInMenu: "Show in Menu Bar",
        .managerDeleteNote: "Delete",
        .managerDeleteCount: "Delete %d Notes",
        .managerSelectNote: "Select a note",
        .managerSelectNoteDesc: "Pick a note from the sidebar, or ⌘N to create one.",
        .managerMultiSelected: "%d notes selected",
        .managerMultiSelectedDesc: "Right-click in the sidebar to delete or move them.",
        .managerExport: "Export…",
        .managerExportCount: "Export %d notes…",
        .managerOpenCount: "Open %d as Stickies",
        .managerPinMenu: "Pin",
        .managerPinAll: "Pin All",
        .managerUnpinAll: "Unpin All",
        .managerColorMenu: "Color",
        .colorYellow: "Yellow",
        .colorPink: "Pink",
        .colorBlue: "Blue",
        .colorGreen: "Green",
        .colorPurple: "Purple",
        .colorGray: "Gray",
        .colorRainbow: "Rainbow",
        .noteColor: "Color",
        .editorFormat: "Format", .editorBold: "Bold", .editorItalic: "Italic",
        .editorHighlight: "Highlight",
        .editorHeading: "Heading", .editorLists: "Lists",
        .editorBullet: "Bullet", .editorNumbered: "Numbered",
        .fileImport: "Import…",
        .fileImportDone: "Imported %d note(s).",
        .managerDataMenu: "Data",
        .managerExportAllSQLite: "Export All Notes (SQLite)…",
        .managerExportAllMarkdown: "Export All Notes (Markdown)…",
        .managerImportSQLite: "Import All Notes (SQLite)…",
        .exportAllSQLiteDone: "Exported %d note(s) to SQLite.",
        .exportAllSQLiteFailed: "SQLite export failed. Check the log for details.",
        .exportAllMarkdownDone: "Exported %d note(s) as Markdown.",
        .importSQLiteDone: "Imported %d note(s) and %d group(s). Existing entries with matching IDs were skipped.",
        .importSQLiteFailed: "SQLite import failed: could not read that file.",

        .promptAxTitle: "Enable Accessibility to auto-fill selected text",
        .promptAxBody: "Perch needs the Accessibility permission to read the selected text from the frontmost app and prefill it when you press ⌘⇧N.\n\nOpen System Settings → Privacy & Security → Accessibility and enable Perch. Then press ⌘⇧N again.",
        .promptAxOpen: "Open System Settings",
        .promptAxNotNow: "Not Now",

        .trashTitle: "Trash",
        .trashEmpty: "Trash is empty",
        .trashEmptyDesc: "Notes you delete will appear here for 30 days.",
        .trashEmptyButton: "Empty Trash",
        .trashEmptyAlert: "Empty Trash?",
        .trashEmptyAlertMsg: "This permanently deletes all notes in Trash. This can't be undone.",
        .trashDeleteAlert: "Delete this note permanently?",
        .trashDeleteAlertMsg: "This can't be undone.",
        .trashCannotUndo: "This can't be undone.",
        .trashDeletePermanentlyHelp: "Delete permanently",
        .trashedRelative: "Trashed %@",

        .archiveTitle: "Archive",
        .archiveEmpty: "Archive is empty",
        .archiveEmptyDesc: "Archived notes are kept here indefinitely and never auto-deleted. Unarchive to bring one back.",
        .archivedRelative: "Archived %@",
        .archiveMoveToTrash: "Move to Trash",
        .managerArchive: "Archive",
        .managerArchiveCount: "Archive %d Notes",
        .managerUnarchive: "Unarchive",
        .floatArchive: "Archive note",

        .tasksTitle: "All Tasks",
        .tasksEmpty: "No open tasks",
        .tasksEmptyDesc: "Unchecked tasks from all your notes show up here. Add a checklist (- [ ] …) to any note and it appears."
    ]

    private static let zh: [LocKey: String] = [
        .appName: "Perch", .ok: "确定", .cancel: "取消", .save: "保存",
        .delete: "删除", .untitled: "未命名", .emptyNote: "空便签",
        .restore: "还原",
        .langFollowSystem: "跟随系统", .langEnglish: "English", .langChinese: "简体中文",

        .menuNewNote: "新建便签", .menuShowAllStickies: "显示所有便签",
        .menuHideAllStickies: "隐藏所有便签", .menuManageAllNotes: "管理所有便签",
        .menuSettings: "设置…", .menuFloatOnTop: "悬浮置顶",
        .menuLayout: "布局", .menuQuit: "退出 Perch",
        .menuMoveAllToDisplay: "将所有便签移到显示器",
        .menuDisplay: "显示",
        .menuUpdateAvailable: "有新版本 %@ 可更新…",

        .layoutFree: "自由布局", .layoutStack: "堆叠", .layoutTile: "平铺",

        .sortDateEdited: "编辑时间", .sortDateCreated: "创建时间", .sortTitle: "标题",

        .tabGeneral: "通用", .tabMenuBar: "菜单栏", .tabCapture: "抓取", .tabShortcuts: "快捷键",
        .tabNotes: "便签", .tabICloud: "iCloud 同步", .tabUpdates: "更新", .tabMCP: "Agent",

        .mcpEnable: "启用 MCP 服务器",
        .mcpEnableDesc: "让本机的 AI Agent(如 Claude Code)通过 HTTP + JSON-RPC 接口读写便签。开关立即生效,不需要重启。",
        .mcpStatusRunning: "运行中,端口 %d",
        .mcpStatusStopped: "已停止",
        .mcpPort: "端口",
        .mcpBindAll: "允许其他设备连接",
        .mcpBindAllDesc: "关闭(默认):仅本机可连接(127.0.0.1)。开启:监听所有网络接口 —— 局域网内拿到下方 token 的任何人都能读写你的便签。",
        .mcpAllowWrite: "允许 Agent 写入",
        .mcpAllowWriteDesc: "关闭(默认):Agent 只能读取便签。开启:Agent 还能新建、编辑、置顶、归档、删除(进回收站)便签。",
        .mcpReadOnlyHint: "写权限当前已关闭 —— 已连接的 Agent 只能读取便签。",
        .mcpToken: "访问令牌",
        .mcpTokenDesc: "每次请求都需要作为 Bearer token 携带。保存在 Keychain 里。重新生成会立即让旧 token 失效。",
        .mcpCopyToken: "复制 Token",
        .mcpRegenerateToken: "重新生成…",
        .mcpClientConfigSection: "客户端配置",
        .mcpCliSnippetLabel: "Claude Code 命令行",
        .mcpJsonSnippetLabel: "通用 JSON(mcpServers)",
        .mcpCopyCli: "复制命令",
        .mcpCopyJson: "复制 JSON",

        .updatesAutoCheck: "自动检查更新",
        .updatesIncludePrereleases: "包含预发布版本(beta 通道)",
        .updatesFooter: "更新通过 EdDSA 签名校验、HTTPS 下载,由 Sparkle 的辅助进程完成安装。后台检查发现新版本时只在菜单栏显示入口,不打断你 —— 点一下即可安装。预发布版本来自 appcast 的 `beta` 通道。",
        .updatesCurrentVersion: "当前版本",
        .updatesLastChecked: "上次检查",
        .updatesNeverChecked: "从未",
        .updatesCheckNow: "立即检查…",
        .updatesInterval: "检查频率",
        .updatesIntervalHourly: "每小时",
        .updatesIntervalDaily: "每天",
        .updatesIntervalWeekly: "每周",

        .generalLaunchAtLogin: "开机自动启动",
        .generalSortBy: "排序方式:",
        .generalFadeWhenInactive: "失焦时半透明",
        .generalFadeWhenInactiveDesc: "失去焦点的便签切换为毛玻璃半透明,凸显当前活跃窗口。",
        .generalDoubleClickCollapse: "双击标题折叠",
        .generalDoubleClickCollapseDesc: "双击便签顶部标题区,把窗口收成只剩标题条;再双击展开。状态会跟着便签一起记。",
        .generalLanguage: "语言",
        .generalMenuBarCount: "菜单栏数字",
        .menuBarCountNone: "不显示",
        .menuBarCountTotal: "全部数量",
        .menuBarCountActive: "激活显示数量",
        .generalMenuGrouping: "菜单内分组方式",
        .menuGroupingNone: "平铺列表",
        .menuGroupingSections: "分段显示",
        .menuGroupingSubmenu: "子菜单",
        .generalNewGroupsInMenu: "新分组显示在菜单栏",
        .generalNewGroupsInMenuDesc: "关闭后,在「管理所有便签」里新建的分组默认不出现在菜单栏的便签列表中。单个分组可右键单独切换。",
        .generalStatusLeftClick: "菜单栏图标左键",
        .generalStatusRightClick: "菜单栏图标右键",
        .statusClickShowMenu: "显示菜单",
        .statusClickOpenManager: "打开管理所有便签",
        .generalManagerDockIcon: "管理窗口显示 Dock 图标",
        .generalManagerDockIconDesc: "「管理所有便签」窗口打开期间,Perch 会出现在 Dock 和 ⌘Tab 应用切换器里。",
        .generalTrashRetention: "回收站保留 %d 天",
        .generalTrashRetentionDesc: "进入回收站的便签超过设定天数后会被永久删除。范围 7-365 天。",
        .generalDataSection: "数据",
        .generalClearAll: "清空全部内容…",
        .generalClearAllDesc: "永久删除全部便签(含归档与回收站)和全部分组,设置/偏好保留。无法撤销 —— 建议先在「管理所有便签 → 数据」导出备份。",
        .generalClearAllConfirmTitle: "清空全部内容?",
        .generalClearAllConfirmMsg: "这将永久删除全部 %d 条便签和 %d 个分组(含归档与回收站),无法撤销。\n\n建议先在「管理所有便签 → 数据」导出备份。",
        .generalClearAllConfirmButton: "清空全部",
        .generalClearAllDone: "已清空:删除了 %d 条便签和 %d 个分组。",
        .generalFillDemo: "填充演示数据",
        .generalFillDemoDesc: "仅 Debug 构建。插入一批示例便签和分组(英文),覆盖活跃、置顶、归档、回收站等状态。可多次点击累积。",
        .generalFillDemoDone: "已添加 %d 条演示便签和 %d 个分组。",

        .shortcutsCustomizable: "可自定义",
        .shortcutsSystem: "系统",
        .shortcutQuickCapture: "快速捕获",
        .shortcutManageNotes: "管理所有便签",
        .shortcutOpenSettings: "打开设置",
        .shortcutNewNote: "新建便签(管理 / 捕获)",
        .shortcutCloseWindow: "关闭窗口",
        .shortcutDeleteNote: "删除当前便签(浮窗)",
        .shortcutQuit: "退出",
        .shortcutsRoadmap: "自定义快捷键将在后续版本支持。",
        .shortcutResizeCycle: "循环切换便签尺寸(小 → 中 → 大)",
        .shortcutToggleFloatOnTop: "切换悬浮置顶",

        .permissionAccessibilityTitle: "辅助功能",
        .permissionAccessibilityDesc: "按 ⌘⇧N 时读取当前 App 选中的文字,自动填入新便签。",
        .permissionGranted: "已授权",
        .permissionNotGranted: "未授权",
        .permissionOpenSettings: "打开系统设置",
        .permissionOpen: "打开",
        .permissionFooter: "权限在「系统设置 → 隐私与安全性」里集中管理。点 Open 直达对应面板。",

        .captureMethod: "抓取方式:",
        .captureModeAxWhitelist: "辅助功能 + 复制粘贴白名单",
        .captureModeClipboardOnly: "纯复制粘贴",
        .captureModeDisabled: "关闭自动抓取",
        .captureFooterAxWhitelist: "默认通过「辅助功能」抓取选中文本;白名单里的 App 改用合成 ⌘C 读剪贴板,然后自动还原原本的剪贴板内容。适合微信等不暴露 AX 选区的 App。",
        .captureFooterClipboardOnly: "永远合成 ⌘C 读剪贴板,读完自动还原原本的剪贴板内容。macOS 10.14+ 合成按键也走 TCC,因此同样需要辅助功能权限。",
        .captureFooterDisabled: "⌘⇧N 直接打开空白 capture 输入框,不抓取任何选中文本。",
        .captureWhitelistTitle: "剪贴板白名单(每行一个 bundle ID)",
        .captureWhitelistHint: "常见示例:com.tencent.xinWeChat、com.microsoft.VSCode",

        .notesDefaultColor: "默认颜色",
        .notesDefaultColorRandom: "随机(每张便签换一个颜色)",
        .notesFontSize: "编辑器字号",
        .notesDefaultSize: "默认窗口尺寸",
        .noteSizeSmall: "小 (240×240)",
        .noteSizeMedium: "中 (280×280)",
        .noteSizeLarge: "大 (360×360)",
        .iCloudEnable: "通过 iCloud 同步便签",
        .iCloudEnableDesc: "在登录同一 iCloud 账户的多台 Mac 之间同步便签、分组和回收站。修改这个开关后需要重启 Perch 才会生效。",
        .iCloudRestartRequired: "需要重启",
        .iCloudRestartHint: "退出并重新打开 Perch,iCloud 设置才会生效。",
        .iCloudRestartNow: "立即重启 Perch",
        .iCloudAccountStatusLabel: "iCloud 账户",
        .iCloudAccountUnknown: "检测中…",
        .iCloudAccountAvailable: "已登录",
        .iCloudAccountNone: "未登录",
        .iCloudAccountRestricted: "受限制",
        .iCloudAccountTempUnavail: "暂不可用",
        .iCloudOpenAccountSettings: "打开 iCloud 设置",
        .iCloudLastSyncLabel: "最近同步",
        .iCloudLastSyncNever: "从未",
        .iCloudActivityLabel: "状态",
        .iCloudActivityIdle: "空闲",
        .iCloudActivityRunning: "进行中…",
        .iCloudActivitySucceeded: "成功",
        .iCloudActivityFailed: "失败",
        .iCloudEventSetup: "初始化",
        .iCloudEventImport: "下载",
        .iCloudEventExport: "上传",
        .iCloudRefresh: "刷新状态",
        .iCloudContainerLabel: "Container",
        .iCloudFooter: "同步基于 Apple CloudKit。数据在传输和存储过程中均加密,存放在你私人 CloudKit 数据库,Perch 打开期间会自动同步。",
        .iCloudDisabledHint: "在上方启用 iCloud 同步后即可查看同步状态。",
        .iCloudInitSchema: "初始化云端 Schema(Development)",
        .iCloudInitSchemaHint: "仅首次需要:把本地 Core Data schema 推送到 CloudKit Development 环境,之后才能开始同步。在 Apple Developer Portal 创建好 container 后跑一次即可。",
        .iCloudInitSchemaSuccess: "Schema 已初始化。几秒内开始同步。",
        .iCloudInitSchemaFailed: "Schema 初始化失败:%@",
        .iCloudSchemaSection: "Schema(开发者)",
        .iCloudSchemaCurrent: "本地 schema 版本",
        .iCloudSchemaDeployed: "上次推到 CloudKit Dev",
        .iCloudSchemaDeployedNever: "(本机从未推过)",
        .iCloudSchemaNeedsRedeploy: "本地 schema 与上次推送不一致 —— 发布前重跑「初始化云端 Schema」,再去 CloudKit Console 把 Dev → Production 部署一遍。",
        .iCloudMigrationTest: "跑一次迁移自检",
        .iCloudMigrationTestHint: "用合成的旧版本 store 走一遍 lightweight migration 升到当前 model。每次改 SchemaVersion.current 之前跑一次,确认升级链路没坏。",
        .iCloudMigrationTestRunning: "迁移测试中…",
        .iCloudMigrationTestPass: "✓ %@",
        .iCloudMigrationTestFail: "✗ %@",

        .quickPlaceholder: "快速便签…",
        .quickSave: "保存", .quickNewLine: "换行", .quickCancel: "取消",

        .floatCollapse: "折叠", .floatExpand: "展开", .floatDelete: "删除便签",

        .reminderSetTitle: "提醒时间",
        .reminderSet: "设置提醒",
        .reminderClear: "清除",
        .reminderActiveLabel: "已设提醒:%@",
        .reminderPastLabel: "提醒已过(%@)",
        .reminderPermissionDeniedTitle: "通知已关闭",
        .reminderPermissionDeniedBody: "请到「系统设置 → 通知」里允许 Perch 显示通知,否则无法发送提醒。",
        .reminderInvalidTimeTitle: "请选一个未来时间",
        .reminderInvalidTimeBody: "提醒时间必须晚于当前时间。",

        .legacyImportDoneTitle: "已从 Noticky 导入",
        .legacyImportDoneBody: "已从旧版 Noticky 导入 %d 条便签、%d 个分组。\n\n是否现在删除旧版 Noticky 的本地数据?保留它不会影响 Perch。",
        .legacyImportKeep: "保留旧数据",
        .legacyImportDelete: "删除旧数据",

        .managerSearch: "搜索所有便签",
        .managerNewGroup: "新建分组",
        .managerNewNote: "新建便签",
        .managerOpenAsSticky: "打开为浮窗",
        .managerMoveToGroup: "移动到分组",
        .managerMoveNotesToGroup: "将 %d 条便签移到分组",
        .managerUngrouped: "未分组",
        .managerRename: "重命名",
        .managerRenameAlertTitle: "重命名分组",
        .managerGroupNamePlaceholder: "分组名",
        .managerRenameMessage: "为分组输入一个新名字。",
        .managerNewGroupAlertTitle: "新建分组",
        .managerNewGroupMessage: "为新分组输入一个名字。",
        .managerCreate: "创建",
        .managerDeleteGroup: "删除分组",
        .managerHideGroupFromMenu: "在菜单栏隐藏此分组",
        .managerShowGroupInMenu: "在菜单栏显示此分组",
        .managerDeleteNote: "删除",
        .managerDeleteCount: "删除 %d 条便签",
        .managerSelectNote: "选择一条便签",
        .managerSelectNoteDesc: "从侧边栏选一条便签,或者按 ⌘N 新建。",
        .managerMultiSelected: "已选中 %d 条便签",
        .managerMultiSelectedDesc: "在侧边栏右键以删除或移动它们。",
        .managerExport: "导出…",
        .managerExportCount: "导出 %d 条…",
        .managerOpenCount: "打开为 %d 个浮窗",
        .managerPinMenu: "钉住",
        .managerPinAll: "全部钉住",
        .managerUnpinAll: "全部取消钉",
        .managerColorMenu: "颜色",
        .colorYellow: "黄色",
        .colorPink: "粉色",
        .colorBlue: "蓝色",
        .colorGreen: "绿色",
        .colorPurple: "紫色",
        .colorGray: "灰色",
        .colorRainbow: "炫彩",
        .noteColor: "颜色",
        .editorFormat: "格式", .editorBold: "加粗", .editorItalic: "斜体",
        .editorHighlight: "高亮",
        .editorHeading: "标题", .editorLists: "列表",
        .editorBullet: "无序列表", .editorNumbered: "有序列表",
        .fileImport: "导入…",
        .fileImportDone: "已导入 %d 条便签。",
        .managerDataMenu: "数据",
        .managerExportAllSQLite: "导出全部便签 (SQLite)…",
        .managerExportAllMarkdown: "导出全部便签 (Markdown)…",
        .managerImportSQLite: "导入全部便签 (SQLite)…",
        .exportAllSQLiteDone: "已导出 %d 条便签到 SQLite。",
        .exportAllSQLiteFailed: "SQLite 导出失败,详见日志。",
        .exportAllMarkdownDone: "已导出 %d 条便签为 Markdown。",
        .importSQLiteDone: "导入了 %d 条便签和 %d 个分组。UUID 已存在的条目被跳过。",
        .importSQLiteFailed: "SQLite 导入失败:无法读取该文件。",

        .promptAxTitle: "开启辅助功能以自动填入选中文本",
        .promptAxBody: "Perch 需要「辅助功能」权限才能在你按下 ⌘⇧N 时,读取当前 App 里选中的文字并自动填入。\n\n打开「系统设置 → 隐私与安全性 → 辅助功能」,把 Perch 勾上即可。授权后再按 ⌘⇧N 就能用了。",
        .promptAxOpen: "打开系统设置",
        .promptAxNotNow: "暂不开启",

        .trashTitle: "回收站",
        .trashEmpty: "回收站为空",
        .trashEmptyDesc: "删除的便签会保留 30 天。",
        .trashEmptyButton: "清空回收站",
        .trashEmptyAlert: "清空回收站?",
        .trashEmptyAlertMsg: "这会永久删除回收站里的所有便签,操作无法撤销。",
        .trashDeleteAlert: "彻底删除这条便签?",
        .trashDeleteAlertMsg: "操作无法撤销。",
        .trashCannotUndo: "操作无法撤销。",
        .trashDeletePermanentlyHelp: "彻底删除",
        .trashedRelative: "%@删除",

        .archiveTitle: "归档",
        .archiveEmpty: "归档为空",
        .archiveEmptyDesc: "归档的便签会一直保留在这里,永不自动删除。点「取消归档」可放回。",
        .archivedRelative: "%@归档",
        .archiveMoveToTrash: "移入回收站",
        .managerArchive: "归档",
        .managerArchiveCount: "归档 %d 条便签",
        .managerUnarchive: "取消归档",
        .floatArchive: "归档便签",

        .tasksTitle: "全部任务",
        .tasksEmpty: "没有未完成的任务",
        .tasksEmptyDesc: "所有笔记里未勾选的任务都会汇总到这里。在任意笔记里写个清单(- [ ] …)就会出现。"
    ]
}
