import KeyboardShortcuts

/// 所有"用户可自定义"的全局快捷键集中在这里。命名后由
/// `KeyboardShortcuts.Recorder` 在 Settings 里编辑、`KeyboardShortcuts.onKeyDown`
/// 在 AppDelegate 里订阅。库自己负责持久化(UserDefaults)和系统级注册。
///
/// **不归这里管**:menu / window 派发的快捷键 —— ⌘N、⌘W、⌘Q、⌘,、⌘⇧0、⌘D
/// 等。它们走 NSMenuItem.keyEquivalent 或 StickyPanel.performKeyEquivalent,
/// 不是全局热键,无需进 KeyboardShortcuts 的体系。
extension KeyboardShortcuts.Name {
    /// 默认 ⌘⇧N。第一次启动时新用户保留旧体验;改过的用户库自动从 UserDefaults
    /// 读他们存的那一份,默认值不生效。
    static let quickCapture = Self(
        "quickCapture",
        initial: .init(.n, modifiers: [.command, .shift])
    )

    /// 在预设尺寸间循环切换当前 key 浮窗便签:小 → 中 → 大 → 小(见 `DefaultNoteSize`)。
    /// 一个键搞定三档,不占三个全局热键槽。**默认不绑定** —— 全局热键稀缺且容易
    /// 跟别的 App 撞,让用户在 Settings → Shortcuts 里自己录。按下时的处理在
    /// AppDelegate,实际循环走 `FloatingNotesRegistry.cycleKeyWindowSize()`
    /// (焦点不在浮窗上则 no-op)。
    static let resizeNoteCycle = Self("resizeNoteCycle")

    /// 切换全局「悬浮置顶」开关(等同菜单栏的 Float on Top / ⋯ 菜单)。一键
    /// 翻转所有浮窗的窗口层级 + 跨 Space 行为。**默认不绑定** —— 同样为了不跟
    /// 别的 App 抢稀缺的全局热键,让用户自己在 Settings → Shortcuts 里录。按下
    /// 时的处理在 AppDelegate,实际翻转走 `FloatingNotesRegistry.setFloatOnTop`。
    static let toggleFloatOnTop = Self("toggleFloatOnTop")
}
