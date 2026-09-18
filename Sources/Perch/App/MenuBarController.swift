import AppKit
import Combine
import CoreData

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let context: NSManagedObjectContext
    private let floating: FloatingNotesRegistry
    private let manager: ManagerWindowController
    private let settings: SettingsWindowController

    private var cancellables: Set<AnyCancellable> = []
    /// 后台检查发现的待处理更新版本号(nil = 没有)。托盘菜单据此显示入口,
    /// 图标据此点角标。订阅 `UpdaterService.shared.$availableVersion` 同步。
    private var availableUpdateVersion: String?

    init(
        context: NSManagedObjectContext,
        floating: FloatingNotesRegistry,
        manager: ManagerWindowController,
        settings: SettingsWindowController
    ) {
        self.context = context
        self.floating = floating
        self.manager = manager
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.statusImage(updateBadge: false, for: button)
            button.target = self
            button.action = #selector(handleClick(_:))
            // 左右键统一一个出口,按 Settings → General 的左/右键设置分发(默认都弹菜单)。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 数字徽标随两类信号刷新:
        //  1. 笔记增删改 —— viewContext 的 objectsDidChange(新建 / trash / restore /
        //     开关浮窗都会写 isPinned/isTrashed 并 save,主线程投递)。total 和
        //     active 两种模式都靠这个,active 用 isPinned(见 MenuBarCountMode)。
        //  2. 用户在 Settings 改了显示模式 —— @AppStorage 落盘触发 didChange。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleBadgeRefresh),
            name: .NSManagedObjectContextObjectsDidChange,
            object: context
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleBadgeRefresh),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        refreshBadge()

        // 后台静默检查发现更新时,UpdaterService 把版本号 publish 出来。
        // 我们据此重画图标角标(托盘菜单的入口在 buildMenu 里按需读取)。
        UpdaterService.shared.$availableVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                guard let self else { return }
                self.availableUpdateVersion = version
                self.refreshUpdateBadge()
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 更新角标变化时重画状态栏图标(有待处理更新 → note.text + 橙点)。
    /// 跟 refreshBadge 的数字徽标正交:那个只动 title / imagePosition。
    private func refreshUpdateBadge() {
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(updateBadge: availableUpdateVersion != nil, for: button)
    }

    /// 托盘图标。`updateBadge == false` 时直接用模板符号(自动适配深浅菜单栏 +
    /// 点击高亮)。有待处理更新时,改用非模板合成图:符号染成 labelColor + 右上
    /// 角一个橙点 —— 模板图会把整张统一染色丢掉橙色,所以这里必须非模板。
    private static func statusImage(updateBadge: Bool, for button: NSStatusBarButton) -> NSImage? {
        guard let base = NSImage(named: "MenubarBird") else {
            return nil
        }
        // 自绘的栖枝小鸟(template image,菜单栏按浅/深色自动染色)。PDF 矢量,
        // 固定到 22pt 见方(基本顶满菜单栏内容区,与邻居图标视觉等高);
        // 橙点角标尺寸也跟着这个 size 走。
        base.isTemplate = true
        base.size = NSSize(width: 22, height: 22)
        guard updateBadge else {
            return base
        }
        let appearance = button.effectiveAppearance
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                base.draw(in: rect)
                // 模板符号画出来是黑色字形,sourceAtop 把它染成当前外观的 labelColor。
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                // 右上角橙点。
                let d = min(rect.width, rect.height) * 0.45
                let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 多个通知(如 showAll 一次性 spawn N 个浮窗)在同一 runloop 周期内合并成
    /// 一次 refreshBadge。`badgeRefreshScheduled` 只在主线程写,跨线程多刷一次
    /// 也只是无害的重复计数。
    private var badgeRefreshScheduled = false

    @objc private func scheduleBadgeRefresh() {
        guard !badgeRefreshScheduled else { return }
        badgeRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.badgeRefreshScheduled = false
            self.refreshBadge()
        }
    }

    /// 按当前 MenuBarCountMode 把数字写到状态栏图标右侧。`.none` 时清掉 title
    /// 并切回 imageOnly,variableLength 的 statusItem 会自动缩回只剩图标。
    private func refreshBadge() {
        guard let button = statusItem.button else { return }
        let mode = MenuBarCountMode.from(
            UserDefaults.standard.string(forKey: SettingsKey.menuBarCount) ?? ""
        )
        guard mode != .none else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }

        let request = NSFetchRequest<Note>(entityName: "Note")
        switch mode {
        case .total:
            // 全部活跃笔记 = 未删除且未归档(归档不计入,跟它不进列表一致)。
            request.predicate = NSPredicate(
                format: "isTrashed == %@ AND isArchived == %@",
                NSNumber(value: false), NSNumber(value: false)
            )
        case .active:
            // isPinned == 浮窗打开中 / 开机自动恢复(见 CLAUDE.md & MenuBarCountMode)。
            // 归档会清 isPinned,这里再显式排除一层防御。
            request.predicate = NSPredicate(
                format: "isPinned == %@ AND isTrashed == %@ AND isArchived == %@",
                NSNumber(value: true), NSNumber(value: false), NSNumber(value: false)
            )
        case .none:
            return  // 上面已 guard,这分支只为穷尽 switch
        }
        let count = (try? context.count(for: request)) ?? 0
        // 图标在左、数字在右;前置一个空格跟图标留点缝。
        button.imagePosition = .imageLeading
        button.title = " \(count)"
    }

    /// 右键 = rightMouseUp,或按住 Control 的左键(macOS 惯例)。两边都配成
    /// manager 时右键强制弹菜单,保证菜单(退出 / 设置)始终有入口。
    @objc private func handleClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        let defaults = UserDefaults.standard
        let left = StatusItemClickAction.from(defaults.string(forKey: SettingsKey.statusItemLeftClick) ?? "")
        var right = StatusItemClickAction.from(defaults.string(forKey: SettingsKey.statusItemRightClick) ?? "")
        if left == .manager && right == .manager { right = .menu }

        switch isRight ? right : left {
        case .menu:    showMenu(sender)
        case .manager: manager.showWindow()
        }
    }

    private func showMenu(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        // popUpContextMenu(with:event:for:) 会跟着鼠标位置弹,菜单飘到指针下面。
        // 把 menu 临时挂到 statusItem 上再 performClick,系统就会按标准位置(图标
        // 正下方,贴菜单栏)弹出。menu 是模态的,closure 同步阻塞到关闭后再解绑。
        statusItem.menu = buildMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 后台发现的待处理更新放最上面,最显眼。点了走 Sparkle 的下载/安装 UI。
        if let version = availableUpdateVersion {
            let updateItem = NSMenuItem(
                title: L.t(.menuUpdateAvailable, version),
                action: #selector(installUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
            updateItem.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        let newItem = NSMenuItem(title: L.t(.menuNewNote), action: #selector(newNote), keyEquivalent: "n")
        newItem.target = self
        newItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        menu.addItem(newItem)

        let request = NSFetchRequest<Note>(entityName: "Note")
        // 拿全量(回收站 + 归档除外),按当前 NoteSort 设置在内存里排;pinned 永远在前。
        request.predicate = NSPredicate(
            format: "isTrashed == %@ AND isArchived == %@",
            NSNumber(value: false), NSNumber(value: false)
        )
        let allNotes = (try? context.fetch(request)) ?? []
        let sort = NoteSort.from(UserDefaults.standard.string(forKey: SettingsKey.noteSort) ?? "")
        let notes = allNotes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch sort {
            case .dateEdited:  return lhs.updatedAt > rhs.updatedAt
            case .dateCreated: return lhs.createdAt > rhs.createdAt
            case .title:
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
        }
        // #1:Manager 右键分组「在菜单栏隐藏」的分组,其笔记不列进托盘菜单列表。
        // 未分组恒显示。注意:这只影响下面的**笔记列表**,与 #4 的「显示」子菜单
        // (浮窗显隐)彼此独立 —— Display 子菜单仍照常列出全部分组。
        let menuHiddenGroups = MenuHiddenGroups.ids()
        let listedNotes = menuHiddenGroups.isEmpty ? notes : notes.filter { note in
            guard let gid = note.group?.id else { return true }
            return !menuHiddenGroups.contains(gid)
        }
        if !listedNotes.isEmpty {
            menu.addItem(.separator())
            // Settings → General「菜单内分组方式」:平铺 / 分段 / 子菜单。
            switch MenuGroupingMode.from(UserDefaults.standard.string(forKey: SettingsKey.menuGrouping) ?? "") {
            case .none:
                for note in listedNotes { menu.addItem(noteMenuItem(note)) }
            case .sections:
                appendSectionedNotes(listedNotes, to: menu)
            case .submenu:
                appendSubmenuNotes(listedNotes, to: menu)
            }
        }

        menu.addItem(.separator())

        // 「显示」子菜单:显示全部 / 隐藏全部,再加上各分组的快速切换入口。
        let displayItem = NSMenuItem(title: L.t(.menuDisplay), action: nil, keyEquivalent: "")
        displayItem.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
        let displaySub = NSMenu(title: "Display")
        displaySub.autoenablesItems = false

        // 显示所有便签:fetch 所有未删笔记,逐条 spawn / bringToFront。
        // 库里没未删笔记时 disabled。
        let showAllStickies = NSMenuItem(
            title: L.t(.menuShowAllStickies),
            action: #selector(showAllStickiesAction),
            keyEquivalent: ""
        )
        showAllStickies.target = self
        showAllStickies.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        showAllStickies.isEnabled = !notes.isEmpty
        // 「显示所有便签」= 清空隐藏集合(全部分组可见)。隐藏集合为空时打勾。
        showAllStickies.state = floating.hiddenGroupIDs.isEmpty ? .on : .off
        displaySub.addItem(showAllStickies)

        // 隐藏所有便签:把当前可见的浮窗 orderOut(不释放 wc、不清 isPinned)。
        // 没有可见浮窗时 disabled。
        let hideAllStickies = NSMenuItem(
            title: L.t(.menuHideAllStickies),
            action: #selector(hideAllStickiesAction),
            keyEquivalent: ""
        )
        hideAllStickies.target = self
        hideAllStickies.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        hideAllStickies.isEnabled = floating.hasVisibleWindow
        displaySub.addItem(hideAllStickies)

        // 各分组:勾选切换该组便签的显示/隐藏(多选,可多组同时显示)。勾上=显示、
        // 取消=隐藏。空分组(没有活跃笔记)disabled —— 无可显示的便签。
        let groups = (try? context.fetch(NoteGroup.sortedFetchRequest())) ?? []
        // 顺手剔除两套隐藏集合里已被删掉的分组 id,免得残留。
        // (#4 浮窗显隐 hiddenGroupIDs;#1 菜单列表隐藏 MenuHiddenGroups。)
        let liveGroupIDs = Set(groups.map(\.id))
        floating.pruneHiddenGroups(existing: liveGroupIDs)
        MenuHiddenGroups.prune(existing: liveGroupIDs)
        let ungroupedCount = notes.filter { $0.group == nil }.count
        if !groups.isEmpty || ungroupedCount > 0 {
            displaySub.addItem(.separator())
            for group in groups {
                let activeCount = group.notes.filter { !$0.isTrashed && !$0.isArchived }.count
                let item = NSMenuItem(
                    title: Self.truncatedMenuTitle(group.name),
                    action: #selector(toggleGroupVisibility(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = group.objectID
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.isEnabled = activeCount > 0
                // 该组当前可见则打勾,隐藏则不打勾(多选,各组独立)。
                item.state = floating.isGroupHidden(group.id) ? .off : .on
                displaySub.addItem(item)
            }
            // 「未分组」也能单独显示/隐藏。representedObject 留空 —— handler 据此
            // 识别为未分组(groupID = nil)。
            if ungroupedCount > 0 {
                let item = NSMenuItem(
                    title: L.t(.managerUngrouped),
                    action: #selector(toggleGroupVisibility(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
                item.state = floating.isGroupHidden(nil) ? .off : .on
                displaySub.addItem(item)
            }
        }

        displayItem.submenu = displaySub
        menu.addItem(displayItem)

        let showAll = NSMenuItem(
            title: L.t(.menuManageAllNotes),
            action: #selector(showManager),
            keyEquivalent: "0"
        )
        showAll.target = self
        showAll.keyEquivalentModifierMask = [.command, .shift]
        showAll.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        menu.addItem(showAll)

        let prefs = NSMenuItem(
            title: L.t(.menuSettings),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        prefs.target = self
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(prefs)

        let floatToggle = NSMenuItem(
            title: L.t(.menuFloatOnTop),
            action: #selector(toggleFloatOnTop),
            keyEquivalent: ""
        )
        floatToggle.target = self
        floatToggle.state = floating.floatOnTop ? .on : .off
        floatToggle.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.addItem(floatToggle)

        // 布局模式:radio 三选一,选中谁就持续维持那个模式。stack 模式下
        // 点击哪张笔记自动滑到 cascade 最下方;tile 模式下拖动后按位置自动重排。
        let layoutItem = NSMenuItem(title: L.t(.menuLayout), action: nil, keyEquivalent: "")
        layoutItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        let layoutSub = NSMenu(title: "Layout")
        for mode in LayoutMode.allCases {
            let item = NSMenuItem(
                title: mode.label,
                action: #selector(setLayoutMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil)
            item.state = (floating.layoutMode == mode) ? .on : .off
            layoutSub.addItem(item)
        }
        layoutItem.submenu = layoutSub
        menu.addItem(layoutItem)

        // 「把所有便签集中到某台显示器」:仅多屏时显示,无浮窗打开时整项 disable
        // (浮窗都没开,没东西可挪)。一次性动作,不持久化,跟便签自身的钉显示器
        // 设置正交。
        let displays = DisplayCatalog.current()
        if displays.count > 1 {
            let moveAllItem = NSMenuItem(
                title: L.t(.menuMoveAllToDisplay),
                action: nil,
                keyEquivalent: ""
            )
            moveAllItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
            let moveSub = NSMenu(title: "Move To Display")
            for display in displays {
                let item = NSMenuItem(
                    title: display.name,
                    action: #selector(moveAllToDisplay(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = display.uuid
                item.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
                item.isEnabled = floating.hasOpenWindows
                moveSub.addItem(item)
            }
            moveAllItem.submenu = moveSub
            moveAllItem.isEnabled = floating.hasOpenWindows
            menu.addItem(moveAllItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: L.t(.menuQuit),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleFloatOnTop() {
        floating.setFloatOnTop(!floating.floatOnTop)
    }

    @objc private func showAllStickiesAction() {
        floating.showAll(in: context)
    }

    @objc private func hideAllStickiesAction() {
        floating.hideAllGroups(in: context)
    }

    @objc private func toggleGroupVisibility(_ sender: NSMenuItem) {
        // representedObject 为 group.objectID → 真实分组;为空 → 未分组(groupID nil)。
        if let id = sender.representedObject as? NSManagedObjectID,
           let group = try? context.existingObject(with: id) as? NoteGroup {
            floating.toggleGroupVisibility(groupID: group.id, in: context)
        } else {
            floating.toggleGroupVisibility(groupID: nil, in: context)
        }
    }

    @objc private func setLayoutMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: raw) else { return }
        floating.setLayoutMode(mode)
    }

    @objc private func moveAllToDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        floating.moveAllToDisplay(uuid: uuid)
    }

    @objc private func showManager() {
        manager.showWindow()
    }

    /// 用户点托盘里的「有可用更新」。交给 Sparkle 走 user-initiated 检查,
    /// 把后台发现的更新带 UI 重新呈现。点完 Sparkle 的 didReceiveUserAttention
    /// 会回调清掉 availableVersion,角标随之消失。
    @objc private func installUpdate() {
        UpdaterService.shared.showAvailableUpdate()
    }

    @objc private func showSettings() {
        // 我们自己的 AppKit SettingsWindowController(NSTabViewController + 动画 resize)。
        // 跟 AppDelegate 装的主菜单 ⌘, 殊途同归。
        settings.showWindow()
    }

    /// 把已排序的 `notes`(pinned 优先 + 当前 NoteSort)按分组分桶。各组内保持
    /// 原相对顺序;分组本身按 NoteGroup.sortOrder 排;空组(无活跃笔记)略过。
    /// 返回 (有笔记的分组 → 其笔记, 未分组笔记)。
    private func partitionByGroup(_ notes: [Note]) -> (groups: [(NoteGroup, [Note])], ungrouped: [Note]) {
        var byGroup: [NSManagedObjectID: [Note]] = [:]
        var ungrouped: [Note] = []
        for note in notes {
            if let group = note.group {
                byGroup[group.objectID, default: []].append(note)
            } else {
                ungrouped.append(note)
            }
        }
        let sortedGroups = (try? context.fetch(NoteGroup.sortedFetchRequest())) ?? []
        let groups: [(NoteGroup, [Note])] = sortedGroups.compactMap { group in
            guard let groupNotes = byGroup[group.objectID], !groupNotes.isEmpty else { return nil }
            return (group, groupNotes)
        }
        return (groups, ungrouped)
    }

    /// 分段模式:同一层级按分组分段,段头用 macOS 14+ 的 `.sectionHeader`
    /// (非交互,系统画成小标题)。未分组的归到末尾「未分组」段。
    private func appendSectionedNotes(_ notes: [Note], to menu: NSMenu) {
        let (groups, ungrouped) = partitionByGroup(notes)
        for (group, groupNotes) in groups {
            menu.addItem(.sectionHeader(title: Self.truncatedMenuTitle(group.name)))
            for note in groupNotes { menu.addItem(noteMenuItem(note)) }
        }
        if !ungrouped.isEmpty {
            menu.addItem(.sectionHeader(title: L.t(.managerUngrouped)))
            for note in ungrouped { menu.addItem(noteMenuItem(note)) }
        }
    }

    /// 子菜单模式:每个分组收成一个子菜单(folder 图标 + 名字),鼠标悬停展开。
    /// 未分组的笔记留在顶层(常用,少展开一层);两边都有时插一条分隔线区分。
    /// 没有任何分组时退化为纯平铺,跟「平铺」模式一致。
    private func appendSubmenuNotes(_ notes: [Note], to menu: NSMenu) {
        let (groups, ungrouped) = partitionByGroup(notes)
        for (group, groupNotes) in groups {
            let parent = NSMenuItem(title: Self.truncatedMenuTitle(group.name), action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu(title: group.name)
            sub.autoenablesItems = false
            for note in groupNotes { sub.addItem(noteMenuItem(note)) }
            parent.submenu = sub
            menu.addItem(parent)
        }
        if !ungrouped.isEmpty {
            if !groups.isEmpty { menu.addItem(.separator()) }
            for note in ungrouped { menu.addItem(noteMenuItem(note)) }
        }
    }

    private func noteMenuItem(_ note: Note) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openNote(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = note.objectID
        item.image = paletteIcon(for: StickyPalette.from(index: note.colorIndex))

        // 用 `cleanTitle`(剥过 markdown 标记的第一非空行,空内容返回 "")。
        // 一个口径同步到浮窗标题条 / 菜单 / 管理列表,不会出现菜单里还带 `#`
        // 浮窗已经剥过的不一致情况。
        let title = note.cleanTitle
        if title.isEmpty {
            // 空笔记用斜体灰色 "Empty Note",跟参考图一致。
            item.attributedTitle = NSAttributedString(
                string: L.t(.emptyNote),
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .obliqueness: 0.18
                ]
            )
        } else {
            // 按实际渲染宽度截断(而不是字数):中文字宽约是英文两倍,按字数截
            // 中文笔记仍会把菜单撑得很宽。放不下就尾部补 "…",完整标题放 tooltip。
            let truncated = Self.truncatedMenuTitle(title)
            item.title = truncated
            if truncated != title { item.toolTip = title }
        }

        // 当前有可见浮窗的笔记打个勾,直观看到当前显示状态。用真实可见性而非
        // isPinned —— hideAll / 分组切换藏起来的窗 isPinned 还是 true,但不该再打勾。
        item.state = floating.isVisible(note: note) ? .on : .off
        return item
    }

    /// 菜单项标题的最大渲染宽度(pt,不含图标/勾选列)。
    private static let maxMenuTitleWidth: CGFloat = 260

    /// 用菜单字体量宽度,超过 `maxMenuTitleWidth` 就二分找出能放下的最长前缀
    /// 并补 "…"。按 Character(字素簇)切,不会把 emoji / 组合字符切坏。
    static func truncatedMenuTitle(_ title: String, maxWidth: CGFloat = maxMenuTitleWidth) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        guard width(title) > maxWidth else { return title }

        let chars = Array(title)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let candidate = String(chars[0..<mid]).trimmingCharacters(in: .whitespaces) + "…"
            if width(candidate) <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        return String(chars[0..<lo]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func paletteIcon(for palette: StickyPalette) -> NSImage {
        let size = NSSize(width: 16, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let body = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            palette.fill(path: path, vivid: true)
            NSColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        // 关键:不能 isTemplate,否则系统会按 label 色调统一染色,丢掉调色板色。
        image.isTemplate = false
        return image
    }

    @objc private func newNote() {
        let note = Note.create(in: context)
        try? context.save()
        floating.show(note: note)
    }

    @objc private func openNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSManagedObjectID,
              let note = try? context.existingObject(with: id) as? Note else { return }
        floating.show(note: note)
    }
}
