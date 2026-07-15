import AppKit
import SwiftUI
import CoreData
import CoreSpotlight
import KeyboardShortcuts

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 自己写 entry point。**不用 SwiftUI `@main struct ... : App`** —— 那条路要求
    /// body 至少一个 Scene,而 `Settings { ... }` scene 会抢 ⌘, 快捷键(SwiftUI 用
    /// 私有机制绑,优先级高于我们 NSApp.mainMenu 里的菜单项,replace mainMenu 也
    /// 拦不下来)。其它 Scene(`WindowGroup`、`Window`) 又会自动开真窗口。
    /// 干脆不用 SwiftUI scene 系统,纯 AppKit 起 NSApplication。
    ///
    /// 内容仍然 SwiftUI(在 NSHostingController 里),只是窗口/菜单/快捷键归 AppKit。
    static func main() {
        // 单实例守卫。抢不到锁说明已有 Perch 在跑 —— 喊它把窗口浮上来,自己
        // 直接退出,**绝不**往下走到 PersistenceController(两进程同开一个 sqlite
        // 会损库)。必须在 NSApplication / Core Data 任何初始化之前。
        guard SingleInstanceLock.acquire() else {
            SingleInstanceLock.notifyExistingInstance()
            return
        }
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        // app.delegate 是 weak,但 static main 期间 delegate 这个局部变量还在栈里,
        // app.run() 阻塞到 terminate 为止 —— 全程被 retain。
        app.run()
    }

    private var menuBar: MenuBarController!
    private var capture: CaptureWindowController!
    private let floating = FloatingNotesRegistry()
    private var manager: ManagerWindowController!
    private let settings = SettingsWindowController()
    /// 本次启动是否已经弹过「请开启辅助功能」对话框 —— 同一进程里只引导一次,
    /// 之后没授权就静默用空 capture,避免每按一次热键骚扰一次。
    private var hasShownAccessibilityPrompt = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let context = PersistenceController.shared.container.viewContext

        // 通知点击 → 按 UUID 找笔记 → 弹浮窗。**在干别的之前先注册**:
        // ReminderScheduler 第一次 .shared 访问时会把自己设成
        // UNUserNotificationCenter.delegate;若用户是从「点通知」启动的 App,
        // 系统会在 applicationDidFinishLaunching 之后第一拍主线程把 didReceive
        // 投递过来,所以 delegate + tapHandler 必须在 return 之前装好。
        ReminderScheduler.shared.tapHandler = { [weak self] uuid in
            // 通知点击的笔记可能在用户其它 device 上已经删了 —— CloudKit 同步
            // 还没拉到本机时这里 fetch 不到,静默跳过。归档/回收站里的笔记点
            // 通知不弹浮窗(归档时已 cancel 提醒,这里再挡一层防御 —— 跨设备
            // 同步残留的提醒可能仍会触发)。逻辑在 openNote(uuid:) 里。
            self?.openNote(uuid: uuid)
        }

        // 启动头一件事:把进回收站超过 30 天的笔记真删。放在 manager/menu
        // 构造和 restorePinnedNotes 之前,这样后续视图初始化看到的就是"已清"
        // 的状态,FetchRequest 不会瞬间显示又消失。
        floating.purgeExpiredTrash(in: context)

        // 从旧版 Noticky 一次性导入本地数据(Perch 是新 bundle id,两者对系统是
        // 不同 app,数据不会自动延续)。**在 restorePinnedNotes 之前导入**,这样
        // 导入的 pinned 笔记随后被 restore 一起恢复成浮窗。删除旧库的询问放到
        // 窗口都起来之后再弹(见下方 legacyImport)。
        let legacyImport = LegacyNotickyImport.importIfNeeded(into: context)

        manager = ManagerWindowController(context: context, floating: floating)
        menuBar = MenuBarController(context: context, floating: floating, manager: manager, settings: settings)
        capture = CaptureWindowController(context: context, floating: floating)
        installMainMenu()

        // 全局快捷键由 sindresorhus/KeyboardShortcuts 库管理:用户在 Settings →
        // Shortcuts 里改的快捷键库自己 persist 到 UserDefaults 并即时 re-register,
        // 我们这里只关心"按下时干啥"。默认绑定见 ShortcutNames.swift。
        KeyboardShortcuts.onKeyDown(for: .quickCapture) { [weak self] in
            self?.handleCaptureHotKey()
        }

        // 一个键在 小 → 中 → 大 → 小 间循环切换当前 key 浮窗尺寸(默认未绑定,
        // 用户在 Settings 里录)。复用 ⋯ 菜单的 DefaultNoteSize 预设,行为一致。
        KeyboardShortcuts.onKeyDown(for: .resizeNoteCycle) { [weak self] in
            self?.floating.cycleKeyWindowSize()
        }

        // 一键翻转全局「悬浮置顶」(默认未绑定,用户在 Settings 里录)。等同
        // 菜单栏 Float on Top —— setFloatOnTop 内部会同步所有已开浮窗的层级,
        // 菜单项的勾选态下次打开菜单时自然刷新。
        KeyboardShortcuts.onKeyDown(for: .toggleFloatOnTop) { [weak self] in
            guard let self else { return }
            self.floating.setFloatOnTop(!self.floating.floatOnTop)
        }

        restorePinnedNotes(in: context)
        // pinned 全部恢复完再 applyLayout —— 这样上次保存的布局模式(stack/tile)
        // 在启动时一气呵成,而不是一边 spawn 一边 reflow 一边再 reflow。
        floating.applyLayout()

        // 显示器插拔 / 排布 / 分辨率变化:把浮窗按各自「归属显示器」记忆归位,
        // 并在系统自动搬窗期间抑制误存(见 FloatingNotesRegistry.handleScreenParameterChange)。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 旧版数据导入完成 → 弹框问用户是否删除旧 Noticky 本地库(默认保留)。
        // 放在窗口恢复 + applyLayout 之后,modal 不挡启动恢复流程。
        if let legacyImport {
            LegacyNotickyImport.promptDeleteOldData(legacyImport)
        }

        // Sparkle 静默检查:第一次访问 `.shared` 触发 controller init,
        // 后续整个进程生命周期里都活着。`checkInBackground` 只有真有
        // 新版本时才弹 UI,"已是最新" 不打扰用户。
        //
        // 用户在 Settings → Updates 关掉 auto-check 时,这次 call 仍然会
        // 走一遍 Sparkle 内部的 schedule 逻辑 —— Sparkle 自己看到偏好
        // 是关的会跳过实际网络请求。我们这里不做额外判断,免得跟 Sparkle
        // 的状态机两边不一致。
        if UserDefaults.standard.object(forKey: "Noticky.updater.autoCheck") as? Bool ?? true {
            UpdaterService.shared.checkInBackground()
        }

        // 第二个实例启动时会 post 这个 distributed notification(随即自己退出)。
        // 收到就把 Manager 窗口浮上来,给「又点了一次」的用户一个可见反馈。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSecondLaunchAttempt),
            name: SingleInstanceLock.secondLaunchNotification,
            object: nil
        )
    }

    /// 已有实例在跑时,新进程抢不到单实例锁就喊这一声 —— 把 Manager 浮上来。
    @objc private func handleSecondLaunchAttempt() {
        manager.showWindow()
    }

    /// 整体覆盖 SwiftUI 自动生成的 main menu。LSUIElement App 的 menu bar
    /// **不会显示**,但 NSApplication 派发 keyDown 事件时仍会走
    /// `NSMenu.performKeyEquivalent`,所以 ⌘, 这种快捷键照常生效。
    ///
    /// 这是纯标准 AppKit 路线 —— 不用 NSEvent monitor,不用任何私有 API,
    /// 也不依赖 SwiftUI `Settings { ... }` scene 的 ⌘, 绑定(那条会触发空窗,
    /// AppDelegate 拦不到)。SwiftUI 在 launch 时注入的 Settings 菜单项被这里
    /// 整个替换掉,只剩我们的 → openSettings。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单 ----
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Perch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        // File 菜单 ----
        // **关键**:menubar tray 那份 NSMenu 只在用户点击图标的瞬间挂到
        // statusItem 上,关掉就 statusItem.menu = nil。所以光靠 tray menu 的
        // keyEquivalent,⌘N / ⌘⇧0 平时根本不在 NSApp.mainMenu 派发链里。
        // 这里把它们也装到 main menu(永久 installed),任何 Perch 窗口
        // active 时都能用。Close 同理 + target=nil 走 first responder。
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let newNoteMenuItem = NSMenuItem(
            title: L.t(.menuNewNote),
            action: #selector(newNoteAction(_:)),
            keyEquivalent: "n"
        )
        newNoteMenuItem.target = self
        fileMenu.addItem(newNoteMenuItem)

        let manageMenuItem = NSMenuItem(
            title: L.t(.menuManageAllNotes),
            action: #selector(manageAllNotesAction(_:)),
            keyEquivalent: "0"
        )
        manageMenuItem.target = self
        manageMenuItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(manageMenuItem)

        fileMenu.addItem(.separator())

        // md/txt 文件 → 新便签的快速导入。整库 SQLite/Markdown 导出 + SQLite
        // 导入在 Manager toolbar 的「数据」菜单 —— LSUIElement 隐藏了菜单栏,
        // 这里的 File 菜单项只有装了 keyEquivalent 才点得到,纯整库操作没必要
        // 占快捷键,放 Manager 里用户能直接看见。
        let importItem = NSMenuItem(
            title: L.t(.fileImport),
            action: #selector(importNotesAction(_:)),
            keyEquivalent: ""
        )
        importItem.target = self
        fileMenu.addItem(importItem)

        fileMenu.addItem(.separator())

        fileMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit 菜单 ----
        // LSUIElement 隐藏 menu bar,但 NSApp.mainMenu 上的 keyEquivalent 仍参与
        // 派发。没有这一组 items,⌘V/⌘C/⌘X/⌘Z/⌘A 在 NSTextView 里全部失效 ——
        // first responder chain 只在系统知道有个对应 menu item 要触发 paste:/copy:
        // 这类 action 时才会走。target=nil 让 selector 沿 responder chain 找
        // 实现者(NSTextView 实现了 NSText 这一组方法)。
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = makeEditMenu()
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        // Undo / Redo:NSResponder 上的 undo:/redo: 是 first-responder action,
        // 没有 Swift @objc class 直接持有这俩 selector。用字符串 selector 是这种
        // 场景的标准做法,跟 Apple 自己 MainMenu.xib 模板里的写法一致。
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(undoItem)
        menu.addItem(redoItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Cut",       action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy",      action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste",     action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        return menu
    }

    @objc private func openSettings() {
        settings.showWindow()
    }

    /// ⌘N 全局入口。无论当前 key window 是浮窗 / Manager / Capture / Settings,
    /// 都新建一条便签并弹浮窗(等同 menubar New Note)。
    @objc private func newNoteAction(_ sender: Any?) {
        let context = PersistenceController.shared.container.viewContext
        let note = Note.create(in: context)
        try? context.save()
        floating.show(note: note)
    }

    /// ⌘⇧0 全局入口。打开 Manager 窗口(已存在则 bringToFront)。
    @objc private func manageAllNotesAction(_ sender: Any?) {
        manager.showWindow()
    }

    @objc private func importNotesAction(_ sender: Any?) {
        let urls = NoteIOPanels.chooseFilesToImport()
        guard !urls.isEmpty else { return }
        let context = PersistenceController.shared.container.viewContext
        let count = NoteIO.importFiles(urls, into: context)
        showCompletionAlert(L.t(.fileImportDone, count))
    }

    /// 通用的完成提示 alert,让用户清楚导入/导出真的发生了。所有 IO 动作都用,
    /// 跟 NSSavePanel/NSOpenPanel 的 modal 是同一线程,不会嵌套问题。
    private func showCompletionAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L.t(.appName)
        alert.informativeText = message
        alert.addButton(withTitle: L.t(.ok))
        alert.runModal()
    }

    /// ⌘⇧N 主入口。根据用户在 Settings → Capture 选的模式分发抓取策略,
    /// 之后再 toggle capture 窗口预填。
    ///
    /// 关键时序:**任何抓取调用都必须在 `capture.toggle` 之前**。
    /// 一旦 capture 窗口抢焦点,`frontmostApplication` 就是 Perch 自己,
    /// AX 读到我们自己的输入框,合成 ⌘C 也是按到 Perch 上 —— 全错。
    /// 这函数把 frontmost app 信息(pid/bundleID)在头一两行就抓出来,
    /// 后面分支都基于这个快照,不再二次访问 NSWorkspace。
    private func handleCaptureHotKey() {
        let mode = CaptureMode.from(
            UserDefaults.standard.string(forKey: SettingsKey.captureMode) ?? ""
        )

        if mode == .disabled {
            capture.toggle()
            return
        }

        // 抢焦点前抓 frontmost。后面所有路径都用这个快照,不再访问 NSWorkspace。
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier
        let frontBundle = front?.bundleIdentifier ?? ""

        switch mode {
        case .clipboardOnly:
            let prefill = frontPID.flatMap { ClipboardFetcher.fetch(from: $0) }
            capture.toggle(prefill: prefill)

        case .axWithWhitelist:
            let whitelist = UserDefaults.standard.string(forKey: SettingsKey.clipboardWhitelist) ?? ""
            let useClipboard = !frontBundle.isEmpty
                && ClipboardWhitelist.contains(whitelist, bundleID: frontBundle)

            if useClipboard {
                let prefill = frontPID.flatMap { ClipboardFetcher.fetch(from: $0) }
                capture.toggle(prefill: prefill)
                return
            }

            // 走 AX —— 沿用旧分支:已授权直接抓,没授权当次启动弹一次引导。
            if SelectionFetcher.isTrusted {
                let prefill = SelectionFetcher.currentSelection()
                capture.toggle(prefill: prefill)
                return
            }
            if hasShownAccessibilityPrompt {
                capture.toggle()
                return
            }
            hasShownAccessibilityPrompt = true
            promptForAccessibilityAccess()

        case .disabled:
            // 上面已 return,这分支只为穷尽 switch。
            capture.toggle()
        }
    }

    private func promptForAccessibilityAccess() {
        let alert = NSAlert()
        alert.messageText = L.t(.promptAxTitle)
        alert.informativeText = L.t(.promptAxBody)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L.t(.promptAxOpen))
        alert.addButton(withTitle: L.t(.promptAxNotNow))

        // LSUIElement 的 App 没 Dock 图标,弹 modal 前先 activate 一下,
        // alert 才会成为 key window 抢到键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SelectionFetcher.requestAndOpenAccessibilitySettings()
            // 不顺手开 capture —— 用户准备去授权,这时候弹个空输入框反而碍事。
            // 授权完成后他会再按一次 ⌘⇧N,届时已经 trusted。
        } else {
            capture.toggle()
        }
    }

    /// 点击 Spotlight 结果回到 App。系统通过 continue user activity 投递,
    /// activityType 是 `CSSearchableItemActionType`,userInfo 里带的标识就是
    /// `SpotlightIndexer` 索引时用的 uniqueIdentifier —— 即 Note.id 的 UUID 字符串。
    /// 已运行则直接投递,从冷启动唤起则在 didFinishLaunching 之后投递。
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let idStr = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let uuid = UUID(uuidString: idStr) else { return false }
        openNote(uuid: uuid)
        return true
    }

    /// 按 UUID 弹浮窗。提醒点击、Spotlight 续传共用;非活跃 / fetch 不到的
    /// 笔记静默跳过(索引里可能残留已归档 / 删除 / 别设备删掉的条目)。
    private func openNote(uuid: UUID) {
        let ctx = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let note = (try? ctx.fetch(request))?.first,
              !note.isTrashed, !note.isArchived else { return }
        NSApp.activate(ignoringOtherApps: true)
        floating.show(note: note)
    }

    /// 启动时把上次还在浮窗状态的笔记自动恢复出来。`isPinned` 一字段同时表达
    /// 「当前是否有浮窗」和「下次启动是否自动显示」—— 用户手动 × 关掉就置 false,
    /// 从列表点开/新建就置 true。
    /// 屏幕拓扑变化(插拔屏 / 排布 / 分辨率)。转给 registry 做抑制 + 归位。
    @objc private func screenParametersChanged() {
        floating.handleScreenParameterChange()
    }

    private func restorePinnedNotes(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<Note>(entityName: "Note")
        // Swift 的 NSPredicate(format:) 不认 ObjC 字面量 YES,SQLite 里 bool 是
        // INTEGER 0/1。用 NSNumber 显式包装最稳。
        // isTrashed 过滤是防御性的:trash 流程已经把 isPinned 清成 false,
        // 但跨版本启动时旧库里可能存在 pinned + trashed 的脏数据,这里挡一下。
        // 归档会清 isPinned,理论上不会被 fetch 到;显式加 isArchived == false
        // 兜旧库/跨设备同步残留的脏数据(pinned + archived)。
        var predicates = [
            NSPredicate(
                format: "isPinned == %@ AND isTrashed == %@ AND isArchived == %@",
                NSNumber(value: true), NSNumber(value: false), NSNumber(value: false)
            )
        ]
        // 上次在「显示 → 分组」里隐藏了某些分组的话,启动跳过它们的 pinned 浮窗
        // (跨重启记忆多选可见性)。先剔除隐藏集合里已被删掉的分组 id。
        let liveGroups = (try? context.fetch(NoteGroup.sortedFetchRequest())) ?? []
        floating.pruneHiddenGroups(existing: Set(liveGroups.map(\.id)))
        let hidden = floating.hiddenGroupIDs
        if !hidden.isEmpty {
            let hiddenGroups = liveGroups.filter { hidden.contains($0.id) }
            if !hiddenGroups.isEmpty {
                // 未分组(group == nil)便签:nil IN {groups} 为 false → NOT 为 true → 保留。
                predicates.append(NSPredicate(format: "NOT (group IN %@)", hiddenGroups))
            }
            if hidden.contains(FloatingNotesRegistry.ungroupedSentinel) {
                predicates.append(NSPredicate(format: "group != nil"))
            }
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        // V4 起按持久化的 displayOrder 升序恢复浮窗顺序(stack 层叠 / tile 排列
        // 次序跨重启保持)。displayOrder 全 0 的库(V3→V4 迁移后首启动、或从未
        // 重排过)退化为 updatedAt 倒序 —— 与旧行为一致,观感不变。
        request.sortDescriptors = [
            NSSortDescriptor(key: "displayOrder", ascending: true),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        guard let pinned = try? context.fetch(request) else { return }
        // restore 期间 spawn 不逐条回写顺序;收尾后一次性冻结(把首启动的
        // updatedAt 退化序固化下来,后续编辑改 updatedAt 不再打乱排序)。
        floating.isRestoring = true
        for note in pinned {
            floating.show(note: note)
        }
        floating.isRestoring = false
        floating.persistDisplayOrder()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出 hook 必须比 windowWillClose 早 —— `applicationShouldTerminate` 在
    /// 系统开始关 windows 之前调,这时打 isTerminating flag,后续每个浮窗的
    /// windowWillClose → onClose 会跳过把 isPinned 清成 false 的写库逻辑,
    /// 下次启动 restorePinnedNotes 才能 fetch 到这些笔记。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        floating.isTerminating = true
        return .terminateNow
    }
}
