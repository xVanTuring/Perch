import AppKit
import CoreData

/// 浮窗布局模式。
/// - normal:用户手动摆位置,registry 不干预。
/// - stack:cascade 排列,选中谁(windowDidBecomeKey)就把那张滑到 cascade 最下方
///         (最前最完整),其它自动重排。新增/关闭也自动 reflow。
/// - tile:平铺排列,用户拖动一张到新位置释放后,按拖到的位置在队列中重新排序
///        并重新平铺。新增/关闭也自动 reflow。
enum LayoutMode: String, CaseIterable {
    case normal, stack, tile

    var label: String {
        switch self {
        case .normal: return L.t(.layoutFree)
        case .stack:  return L.t(.layoutStack)
        case .tile:   return L.t(.layoutTile)
        }
    }

    var icon: String {
        switch self {
        case .normal: return "rectangle.3.group"
        case .stack:  return "square.stack.3d.up"
        case .tile:   return "square.grid.2x2"
        }
    }
}

/// 跟踪所有当前打开的悬浮便签,保证一条笔记最多一个浮窗。
final class FloatingNotesRegistry {
    /// 单实例引用。所有权在 AppDelegate 的 `private let floating`(全程存活),
    /// 这里 weak —— 不延长生命周期。给没有注入路径的地方(Settings →
    /// 「清空全部内容」)拿到 registry 去同步关浮窗用。
    static weak var shared: FloatingNotesRegistry?

    init() { FloatingNotesRegistry.shared = self }

    private var windows: [NSManagedObjectID: FloatingNoteWindowController] = [:]
    /// 当前显示顺序。stack 模式下:[0] = cascade 最上方(最老/最旧选中的),
    /// 末尾 = cascade 最下方(最近选中的,最完整可见)。tile 模式下用作行序优先。
    /// 新窗 spawn 时 append;关闭时 remove;stack 模式下 windowDidBecomeKey
    /// 时移到末尾;tile 模式下用户拖动后按当前 frame 位置重排序。
    private var displayOrder: [NSManagedObjectID] = []
    /// AppDelegate 在 `applicationShouldTerminate` 里设为 true。退出时系统会
    /// 关掉所有 window,触发 windowWillClose → onClose,本来会把 isPinned 清掉,
    /// 下次启动 restore 就全 false。这个 flag 让 onClose 在退出阶段跳过 isPinned 写。
    var isTerminating = false

    /// AppDelegate 启动 restore 期间设为 true。restore 会按持久化的
    /// `Note.displayOrder` 顺序逐条 spawn,这时每次 spawn 不要立刻回写顺序
    /// (会触发 N 次 save,且只是把读出来的序号原样写回);restore 结束后由
    /// `persistDisplayOrder()` 一次性冻结。
    var isRestoring = false

    /// 全局置顶开关。新窗按这个值设 level,toggle 时同步刷所有已开窗。
    /// 持久化在 UserDefaults,key 见 `floatOnTopKey`。
    private static let floatOnTopKey = "Noticky.floatOnTop"
    private(set) var floatOnTop: Bool = {
        // 默认 true,跟之前一直 .floating 的行为一致;旧用户升级感知不到差异。
        // Self 在 stored property initializer 里不可用,直接写类名。
        let key = FloatingNotesRegistry.floatOnTopKey
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }()

    /// 当前布局模式,UserDefaults 持久化。
    private static let layoutModeKey = "Noticky.layoutMode"
    private(set) var layoutMode: LayoutMode = {
        let raw = UserDefaults.standard.string(forKey: FloatingNotesRegistry.layoutModeKey) ?? ""
        return LayoutMode(rawValue: raw) ?? .normal
    }()

    /// 「分组可见性过滤器」——被**隐藏**的分组 id 集合(多选)。空集 = 全部可见
    /// (默认)。存的是 `NoteGroup.id`;未分组便签用 `ungroupedSentinel` 代表。
    /// menubar「显示 → 分组」勾选切换时写,启动 restore 时读 —— 跳过隐藏分组的
    /// pinned 浮窗,实现跨重启记忆。「显示所有便签」清空它。持久化在 UserDefaults
    /// (逗号分隔的 uuid,key 见下)。
    ///
    /// 注:V2.1 之前用单选 key `Noticky.activeGroupFilter`(只显示一组),语义与
    /// 隐藏集合相反,升级不迁移 —— 旧 key 直接废弃,首次启动回到「全部可见」。
    private static let hiddenGroupsKey = "Noticky.hiddenGroups"

    /// 未分组便签在隐藏集合里的代表 id。固定常量,不会撞真实 group.id。
    static let ungroupedSentinel = UUID(uuidString: "00000000-0000-0000-0000-0000000FACE0")!

    private(set) var hiddenGroupIDs: Set<UUID> = {
        let raw = UserDefaults.standard.string(forKey: FloatingNotesRegistry.hiddenGroupsKey) ?? ""
        return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }()

    private func persistHiddenGroups() {
        if hiddenGroupIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.hiddenGroupsKey)
        } else {
            UserDefaults.standard.set(
                hiddenGroupIDs.map(\.uuidString).joined(separator: ","),
                forKey: Self.hiddenGroupsKey
            )
        }
    }

    /// 某分组当前是否隐藏。传 nil = 未分组(用 sentinel 查)。
    func isGroupHidden(_ id: UUID?) -> Bool {
        hiddenGroupIDs.contains(id ?? Self.ungroupedSentinel)
    }

    /// 从隐藏集合里剔除已不存在的分组 id(分组被删后残留)。`ungroupedSentinel`
    /// 恒保留。`existing` = 当前存活的真实 group.id 集合。返回是否有变化。
    @discardableResult
    func pruneHiddenGroups(existing: Set<UUID>) -> Bool {
        let keep = hiddenGroupIDs.filter { $0 == Self.ungroupedSentinel || existing.contains($0) }
        guard keep != hiddenGroupIDs else { return false }
        hiddenGroupIDs = keep
        persistHiddenGroups()
        return true
    }

    /// 勾选切换某分组的可见性(多选)。传 nil = 未分组。
    /// - 隐藏:加入隐藏集合 + orderOut 该组当前可见的浮窗(不释放 wc、不清 isPinned)。
    /// - 显示:移出隐藏集合 + 显示该组的活跃笔记(未删未归档),并按当前模式重排。
    func toggleGroupVisibility(groupID: UUID?, in context: NSManagedObjectContext) {
        let key = groupID ?? Self.ungroupedSentinel
        let notes = activeNotes(groupID: groupID, in: context)
        if hiddenGroupIDs.contains(key) {
            hiddenGroupIDs.remove(key)
            persistHiddenGroups()
            for note in notes { show(note: note) }
            applyLayout()
        } else {
            hiddenGroupIDs.insert(key)
            persistHiddenGroups()
            for note in notes { windows[note.objectID]?.setHidden(true) }
        }
    }

    /// 取某分组(nil = 未分组)下的活跃笔记(未删未归档),pinned 优先、再按
    /// updatedAt 倒序。用于分组可见性切换时批量显/隐。
    private func activeNotes(groupID: UUID?, in context: NSManagedObjectContext) -> [Note] {
        let request = NSFetchRequest<Note>(entityName: "Note")
        var predicates = [
            NSPredicate(format: "isTrashed == %@ AND isArchived == %@",
                        NSNumber(value: false), NSNumber(value: false))
        ]
        if let groupID {
            predicates.append(NSPredicate(format: "group.id == %@", groupID as CVarArg))
        } else {
            predicates.append(NSPredicate(format: "group == nil"))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        return (try? context.fetch(request)) ?? []
    }

    /// menubar 入口:把所有当前打开的浮窗都移到给定 UUID 的显示器,并**记住**每条
    /// 便签的归属显示器 —— 关掉再开、重启后都会回到这块屏(拔屏则回退主屏、屏回来
    /// 再归位)。屏不存在直接 no-op。`floatOnTop=on` 时浮窗跨 Space,但跨屏要主动 setFrame。
    ///
    /// 尊重当前 layout 模式:
    /// - stack / tile:直接在目标屏上重新摆 layout(原模式的视觉规则保留)。
    /// - normal:每窗按其相对源屏 visibleFrame 的偏移映射到目标屏,避免全部
    ///   挤到同一点;源屏推不出来就退化为目标屏居中。
    func moveAllToDisplay(uuid: String) {
        guard let target = DisplayCatalog.screen(forUUID: uuid) else { return }
        // 记住归属显示器(所有打开的浮窗)—— 这是「Move to Display」现在带记忆的核心。
        for wc in windows.values {
            NoteDisplayStore.setDisplayUUID(uuid, for: wc.note.id)
        }
        switch layoutMode {
        case .stack, .tile:
            applyLayout(onScreen: target)
        case .normal:
            for wc in windows.values {
                translateToScreen(wc, target: target)
            }
        }
    }

    /// normal 模式下的"搬家":保留每窗在源屏 visibleFrame 内的相对位置,等比
    /// 映射到目标屏。源屏识别失败 → 居中兜底。**保留尺寸**,目标屏装不下时
    /// 钳到可见区。
    private func translateToScreen(_ wc: FloatingNoteWindowController, target: NSScreen) {
        guard let frame = wc.currentFrame else { return }
        let source = Self.dominantScreen(for: frame)
        let tv = target.visibleFrame
        // 没源屏 / 源屏就是目标屏 → 不动。后者重要:用户已经在目标屏的窗别瞎搬。
        guard let source, source !== target else { return }
        let sv = source.visibleFrame

        let relX = (frame.minX - sv.minX) / max(sv.width, 1)
        let relY = (frame.minY - sv.minY) / max(sv.height, 1)
        var newOrigin = NSPoint(
            x: tv.minX + relX * tv.width,
            y: tv.minY + relY * tv.height
        )
        // 钳到目标屏可见区:窗顶不能跑到屏外,左边不能贴出屏。
        let maxX = tv.maxX - min(frame.width, tv.width)
        let maxY = tv.maxY - min(frame.height, tv.height)
        newOrigin.x = min(max(newOrigin.x, tv.minX), maxX)
        newOrigin.y = min(max(newOrigin.y, tv.minY), maxY)
        wc.animateFrame(NSRect(origin: newOrigin, size: frame.size))
    }

    /// 屏幕拓扑变化(插拔屏 / 排布调整 / 分辨率)的统一入口。AppDelegate 注册
    /// `didChangeScreenParametersNotification` 后转过来。
    ///
    /// 1. 先给所有浮窗设一段抑制窗 —— 系统因拔屏把窗自动挪走会触发 windowDidMove,
    ///    不抑制会被误当用户拖动,把归属显示器改写成兜底屏、并覆盖存档 frame,
    ///    等于把记忆冲掉。
    /// 2. 稍等系统把窗自己挪完(~0.35s),再把每个浮窗尽量拉回它归属的显示器。
    func handleScreenParameterChange() {
        for wc in windows.values {
            wc.suppressAutoPersistForScreenChange(for: 1.5)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.repositionToAssignedDisplays()
        }
    }

    /// 把浮窗拉回各自归属的显示器(归属屏在线且窗当前不在其上时)。
    /// - normal:逐条独立处理。存档 frame 正好落在归属屏(抑制窗保住了拔屏前的
    ///   精确位置)就精确还原,否则居中过去。
    /// - stack / tile:整组一体,按组内首个可见窗的归属屏重排一次。
    private func repositionToAssignedDisplays() {
        switch layoutMode {
        case .normal:
            for wc in windows.values where wc.isWindowVisible {
                guard let assigned = NoteDisplayStore.assignedScreen(for: wc.note.id),
                      let frame = wc.currentFrame,
                      DisplayCatalog.dominantScreen(for: frame) !== assigned else { continue }
                if let saved = wc.note.savedFrame, !wc.note.isCollapsed,
                   DisplayCatalog.dominantScreen(for: saved) === assigned {
                    wc.animateFrame(saved)
                } else {
                    wc.moveToScreen(assigned)
                }
            }
        case .stack, .tile:
            guard let anchorID = displayOrder.first(where: { windows[$0]?.isWindowVisible == true }),
                  let note = windows[anchorID]?.note,
                  let assigned = NoteDisplayStore.assignedScreen(for: note.id) else { return }
            applyLayout(onScreen: assigned)
        }
    }

    func setFloatOnTop(_ value: Bool) {
        guard value != floatOnTop else { return }
        floatOnTop = value
        UserDefaults.standard.set(value, forKey: Self.floatOnTopKey)
        let level: NSWindow.Level = value ? .floating : .normal
        let behavior = Self.collectionBehavior(floatOnTop: value)
        for wc in windows.values {
            wc.setLevel(level)
            wc.setCollectionBehavior(behavior)
        }
    }

    /// 浮窗的 collectionBehavior 跟随 `floatOnTop`:
    /// - on:`[.canJoinAllSpaces, .fullScreenAuxiliary]` —— 跨所有 Space 显示,
    ///   并在其它 App 的全屏空间里也浮在上面。
    /// - off:`[]`(默认)—— 留在创建时所在的 Space,其它 App 进入全屏时
    ///   不会跑到全屏内容上面。
    /// 单独动 `window.level` 不够 —— `.fullScreenAuxiliary` 会让任何 level 的
    /// 窗都浮到全屏 Space 上,所以关置顶必须同时摘掉 collectionBehavior。
    static func collectionBehavior(floatOnTop: Bool) -> NSWindow.CollectionBehavior {
        floatOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    /// 在预设尺寸间循环切换当前 key 的浮窗便签:小 → 中 → 大 → 小。走 controller
    /// 的 `applyPresetSize`(顶左锚定动画 + 折叠态特殊处理 + 动画结束触发 tile/stack
    /// reflow),跟 ⋯ 菜单里点尺寸预设完全一致。焦点不在任何浮窗上(NSApp.keyWindow
    /// 是别的窗或 nil)就 no-op —— 全局热键在别处按下时不该乱动浮窗。
    ///
    /// 当前命中哪个预设按 1pt 容差比;命中第 i 个就切到第 (i+1) 个;尺寸是用户手动
    /// 拖出来的非预设值(谁都不命中)则从第一个(小)开始。
    func cycleKeyWindowSize() {
        guard let key = NSApp.keyWindow,
              let wc = windows.values.first(where: { $0.matches(window: key) })
        else { return }
        let presets = DefaultNoteSize.allCases.map(\.size)
        let current = wc.currentExpandedSize
        let idx = current.flatMap { cur in
            presets.firstIndex { abs($0.width - cur.width) < 1 && abs($0.height - cur.height) < 1 }
        }
        let next = idx.map { ($0 + 1) % presets.count } ?? 0
        wc.applyPresetSize(presets[next])
    }

    /// 切换布局模式,持久化并立刻生效。设到 `.normal` 不会动当前位置,只是停止
    /// 后续 auto reflow,用户从此可以自由拖。
    func setLayoutMode(_ mode: LayoutMode) {
        guard mode != layoutMode else { return }
        layoutMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.layoutModeKey)
        applyLayout()
    }

    /// 按当前模式重排所有浮窗。`.normal` 是 no-op。
    /// AppDelegate 在启动 restore 完毕也会调一次,保证启动时回到上次的模式。
    /// `onScreen` 显式给定时(menubar「移到屏 X」),layout 锚到这块屏;
    /// 否则按 activeScreen() 推断(key 窗 → 鼠标 → main)。
    func applyLayout(onScreen: NSScreen? = nil) {
        switch layoutMode {
        case .normal: return
        case .stack:  applyStackLayout(onScreen: onScreen)
        case .tile:   applyTileLayout(onScreen: onScreen)
        }
    }

    /// macOS 经典 cascade。**保留每张原尺寸**,各张右边对齐;每张顶部比前一张
    /// 顶部低 `stepY`,按 displayOrder 排,index 0 在 cascade 最上方,末尾(最近
    /// 选中的)在最下方完整可见。z-order 按 displayOrder 依次 orderFront,最终
    /// 末尾那张在最前。
    private func applyStackLayout(onScreen: NSScreen? = nil) {
        guard let screen = onScreen ?? activeScreen() else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let stepY: CGFloat = 36
        let rightX = visible.maxX - margin

        // 只排「当前 Space + 可见」的窗:
        // - hideAll / 分组切换藏起来的窗不该占 cascade 槽位。
        // - 别的虚拟桌面(Space)上的窗 isVisible 仍为 true,但不在当前 Space;
        //   对它们 orderFront / animateFrame 会把 macOS 拽去那个桌面,进而 becomeKey
        //   → 再 reflow → 再跳,来回反复跳,所以按 isOnActiveSpace 一并排除。
        let cascadeWCs = displayOrder.compactMap { windows[$0] }
            .filter { $0.isWindowVisible && $0.isOnActiveSpace }
        guard !cascadeWCs.isEmpty else { return }

        let firstTopY = visible.maxY - margin
        for (i, wc) in cascadeWCs.enumerated() {
            guard let frame = wc.currentFrame else { continue }
            let topY = firstTopY - CGFloat(i) * stepY
            let origin = NSPoint(x: rightX - frame.width, y: topY - frame.height)
            wc.animateFrame(NSRect(origin: origin, size: frame.size))
        }

        // z-order 重排:依次 orderFront,最后一个(最近选中的)在最前。
        for wc in cascadeWCs {
            wc.bringToFrontWithoutActivating()
        }
    }

    /// 平铺:**保留每张当前尺寸**,只重排位置。先按 displayOrder 决定迭代顺序;
    /// 但**用户拖动一张后会先把 displayOrder 按当前可视位置重排**,然后再 tile。
    /// 这样拖到哪儿,松手 reflow 后那张就在哪个 slot,其它顺移补位。
    /// shelf packing:左→右一行,装不下换行,行高 = 该行最高的那张。
    private func applyTileLayout(onScreen: NSScreen? = nil) {
        guard let screen = onScreen ?? activeScreen() else { return }
        let visible = screen.visibleFrame
        guard !windows.isEmpty else { return }

        let margin: CGFloat = 16
        let padding: CGFloat = 12
        let leftEdge = visible.minX + margin
        let rightLimit = visible.maxX - margin

        var x = leftEdge
        var rowTopY = visible.maxY - margin
        var rowMaxH: CGFloat = 0
        var anyInRow = false

        // 同 stack:只平铺「当前 Space + 可见」的窗。隐藏的不占位(见「切换分组」);
        // 别的虚拟桌面上的窗也要排除,否则 animateFrame 会把它们从别的桌面搬走、
        // 甚至把 macOS 拽去那个桌面。
        let tileWCs = displayOrder.compactMap { windows[$0] }
            .filter { $0.isWindowVisible && $0.isOnActiveSpace }
        for wc in tileWCs {
            guard let frame = wc.currentFrame else { continue }
            let w = frame.width
            let h = frame.height

            if anyInRow, x + w > rightLimit {
                x = leftEdge
                rowTopY -= rowMaxH + padding
                rowMaxH = 0
                anyInRow = false
            }

            let origin = NSPoint(x: x, y: rowTopY - h)
            wc.animateFrame(NSRect(origin: origin, size: frame.size))

            x += w + padding
            rowMaxH = max(rowMaxH, h)
            anyInRow = true
        }
    }

    /// 找操作目标屏:**已经有浮窗的话,锁定在"最老浮窗所在屏"** —— 用户用
    /// menubar "Move All to Display X" 之后,最老那张也在 X,后续 spawn (New Note)
    /// 触发的 applyLayout 会继续锚在 X,不会因为鼠标当时在 Y 屏菜单上又把所有窗
    /// 拉到 Y。没浮窗时退化回旧 heuristic:key → 鼠标 → main。
    private func activeScreen() -> NSScreen? {
        if let oldestID = displayOrder.first,
           let wc = windows[oldestID],
           let frame = wc.currentFrame,
           let screen = Self.dominantScreen(for: frame) {
            return screen
        }
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 给定一个 NSWindow 的 frame,推断它主要落在哪块屏(取交集面积最大的那块)。
    /// 完全在屏外返回 nil。实现集中在 `DisplayCatalog`,窗口控制器 / 归属显示器
    /// 判定共用同一套语义。
    private static func dominantScreen(for frame: NSRect) -> NSScreen? {
        DisplayCatalog.dominantScreen(for: frame)
    }

    /// 当前是否有任何浮窗(供菜单 enabled 状态用)。
    var hasOpenWindows: Bool { !windows.isEmpty }

    /// 至少有一个窗口当前可见(供菜单标签从 Hide ↔ Show 切换用)。
    var hasVisibleWindow: Bool {
        windows.values.contains { $0.isWindowVisible }
    }

    /// 给定笔记当前是否有「可见」的浮窗(已 spawn 且没被 orderOut)。菜单里的
    /// 笔记列表据此打勾 —— hideAll / 分组切换后藏起来的窗 isPinned 仍为 true,
    /// 但不该再显示成"正在显示",所以用真实可见性而非 isPinned。
    func isVisible(note: Note) -> Bool {
        windows[note.objectID]?.isWindowVisible ?? false
    }

    /// 把所有当前 spawn 的浮窗 orderOut。**不走 close()** —— 不释放 wc、不触发
    /// windowWillClose、不清 isPinned,只是视觉上藏起来。再调 showAll() 一键现身。
    func hideAll() {
        for wc in windows.values {
            wc.setHidden(true)
        }
    }

    /// 「隐藏所有便签」菜单入口:把所有分组(含未分组)一并加入隐藏集合,再
    /// orderOut 全部浮窗。与 `showAll`(清空隐藏集合)对称 —— 让菜单勾选状态跟
    /// 实际可见性始终一致(隐藏后「显示所有便签」不再打勾、各组也不打勾),并
    /// 跨重启记忆(启动不恢复任何 pinned)。再点「显示所有便签」或勾回某组即恢复。
    func hideAllGroups(in context: NSManagedObjectContext) {
        let groups = (try? context.fetch(NoteGroup.sortedFetchRequest())) ?? []
        hiddenGroupIDs = Set(groups.map(\.id))
        hiddenGroupIDs.insert(Self.ungroupedSentinel)
        persistHiddenGroups()
        hideAll()
    }

    /// 显示**所有未删除的笔记**为浮窗 —— 不管之前 pinned 与否、是否已被关闭过。
    /// 已 spawn 的会被 bringToFront(把 hidden 的也带回来);没 spawn 的 spawn。
    /// menubar "Show All Stickies" 的入口,语义是"把库里所有便签都显示出来"。
    func showAll(in context: NSManagedObjectContext) {
        // 「显示所有便签」= 清空隐藏集合(全部分组可见),下次启动恢复全部 pinned。
        hiddenGroupIDs.removeAll()
        persistHiddenGroups()
        let request = NSFetchRequest<Note>(entityName: "Note")
        // 不显示归档笔记 —— "显示所有便签" 只针对活跃笔记。
        request.predicate = NSPredicate(
            format: "isTrashed == %@ AND isArchived == %@",
            NSNumber(value: false), NSNumber(value: false)
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        guard let notes = try? context.fetch(request) else { return }
        for note in notes {
            // show() 内部:已 spawn 则 bringToFront(makeKeyAndOrderFront 把 hidden
            // 的也变可见);新的走 spawn,会自动设 isPinned = true 进入 displayOrder。
            show(note: note)
        }
    }

    // MARK: 模式回调 ---------------------------------------------------------

    /// 浮窗 windowDidBecomeKey 转过来。stack 模式下,把这张挪到 displayOrder 末尾
    /// (= cascade 最下方 = 最完整可见),然后重排。tile 模式不动 —— 单纯点击不算
    /// 重新排序意图。
    fileprivate func notifyWindowBecameKey(id: NSManagedObjectID) {
        guard layoutMode == .stack else { return }
        guard displayOrder.contains(id) else { return }
        displayOrder.removeAll { $0 == id }
        displayOrder.append(id)
        persistDisplayOrder()
        // 用户在哪屏点的窗,cascade 就锚到哪屏 —— 不让 activeScreen 的 oldest 偏好
        // 把刚拖到新屏的窗弹回去。
        applyStackLayout(onScreen: screenForWindow(id: id))
    }

    /// 用户结束拖动/缩放浮窗(非 animateFrame 触发的位移)。tile 模式下按当前
    /// 可视位置重排 displayOrder,再 reflow,实现「拖到哪儿就停在哪儿」。stack
    /// 模式下不重排,直接 reflow 把它弹回 cascade 位置。
    ///
    /// **关键**:layout 锚到"被拖窗当前所在屏",而不是 activeScreen 默认的
    /// "最老窗所在屏" —— 用户拖到新屏就是想让整组跟过去,锁回去等于撤销操作。
    fileprivate func notifyUserMoveEnded(id: NSManagedObjectID) {
        let draggedScreen = screenForWindow(id: id)
        switch layoutMode {
        case .normal:
            // 每条独立:只把被拖那条的归属显示器更新成它现在落到的屏。
            if let note = windows[id]?.note {
                rememberDisplay(draggedScreen, for: note)
            }
        case .stack:
            // 整组跟随拖动落到 draggedScreen → 整组的归属显示器都记成该屏。
            rememberDisplayForVisibleGroup(draggedScreen)
            applyStackLayout(onScreen: draggedScreen)
        case .tile:
            rememberDisplayForVisibleGroup(draggedScreen)
            sortDisplayOrderByCurrentPosition()
            persistDisplayOrder()
            applyTileLayout(onScreen: draggedScreen)
        }
    }

    /// 把某条便签的「归属显示器」记成给定屏(nil / 拿不到 UUID → 不动)。
    private func rememberDisplay(_ screen: NSScreen?, for note: Note) {
        guard let screen, let uuid = DisplayCatalog.uuid(for: screen) else { return }
        NoteDisplayStore.setDisplayUUID(uuid, for: note.id)
    }

    /// stack / tile 模式下整组一起落到某屏 —— 把当前**可见**的浮窗归属显示器都
    /// 记成该屏,保持「组内每条都记得自己在这块屏」的一致性。
    private func rememberDisplayForVisibleGroup(_ screen: NSScreen?) {
        guard let screen, let uuid = DisplayCatalog.uuid(for: screen) else { return }
        for wc in windows.values where wc.isWindowVisible {
            NoteDisplayStore.setDisplayUUID(uuid, for: wc.note.id)
        }
    }

    /// 给定 objectID 查浮窗当前所在屏。窗已关 / 算不出来都返回 nil,layout
    /// 会回退到 activeScreen 默认逻辑。
    private func screenForWindow(id: NSManagedObjectID) -> NSScreen? {
        guard let frame = windows[id]?.currentFrame else { return nil }
        return Self.dominantScreen(for: frame)
    }

    /// 按浮窗当前 frame 的视觉位置(reading order:上→下,左→右)重排 displayOrder。
    /// tile 模式下用户拖动后用,把拖到的位置反映到队列顺序。
    private func sortDisplayOrderByCurrentPosition() {
        let rowThreshold: CGFloat = 40   // 顶边差距 < 40pt 视为同一行
        displayOrder.sort { a, b in
            guard let fa = windows[a]?.currentFrame, let fb = windows[b]?.currentFrame else { return false }
            if abs(fa.maxY - fb.maxY) > rowThreshold {
                return fa.maxY > fb.maxY  // 顶部更高的(maxY 更大)在前
            }
            return fa.minX < fb.minX        // 同行按左边
        }
    }

    /// 把当前 `displayOrder` 的次序写回每条打开窗对应 Note 的 `displayOrder`
    /// 字段(数组下标即序号),一次性 save。重排(stack 选中、tile 拖动)和新窗
    /// spawn 后调,使顺序跨重启保持。`isRestoring` 期间是个 no-op —— restore
    /// 自己读的就是这些值,逐条回写没意义,等 restore 收尾时再调一次冻结。
    ///
    /// 只对**当前打开**的窗重排序号:关掉的窗(isPinned 已 false)留着旧值,
    /// 下次 restore 不会 fetch 到;重新打开会走 spawn append 到末尾再拿到新序号。
    func persistDisplayOrder() {
        guard !isRestoring else { return }
        var context: NSManagedObjectContext?
        for (index, id) in displayOrder.enumerated() {
            guard let note = windows[id]?.note else { continue }
            let newOrder = Int32(index)
            if note.displayOrder != newOrder { note.displayOrder = newOrder }
            context = context ?? note.managedObjectContext
        }
        try? context?.save()
    }

    /// 打开便签;若已打开,则把窗口提到最前。返回 true 表示创建了新窗口。
    @discardableResult
    func show(note: Note) -> Bool {
        let id = note.objectID
        if let wc = windows[id] {
            wc.bringToFront()
            return false
        }
        spawn(note: note, id: id)
        return true
    }

    /// 关闭便签(若已打开),否则打开。供「pin」按钮使用。
    func toggle(note: Note) {
        let id = note.objectID
        if let wc = windows[id] {
            wc.close()
            windows[id] = nil
            displayOrder.removeAll { $0 == id }
            note.isPinned = false
            try? note.managedObjectContext?.save()
            applyLayout()
        } else {
            spawn(note: note, id: id)
        }
    }

    /// 软删除:把笔记打进回收站。有浮窗先无痕关掉,清 isPinned(回收站里的
    /// 笔记不再算"开机自动恢复"对象),写 isTrashed = true + trashedAt = now。
    /// 真正的 context.delete 由 Trash 视图的"彻底删除/清空"或启动时的 30 天
    /// 过期 purge 完成。
    ///
    /// 入口跟之前 hard-delete 完全一致(列表右键、浮窗 ⋯ 菜单、⌘D),所以
    /// 调用方代码没改,只是行为变成"进回收站"。
    func delete(note: Note) {
        let id = note.objectID
        if let wc = windows[id] {
            wc.close()
            windows[id] = nil
            displayOrder.removeAll { $0 == id }
        }
        let context = note.managedObjectContext
        // 进回收站时撤掉提醒。reminderDate 字段保留,用户从回收站恢复时 UI
        // 仍能显示原本设的时间;若那时已过则按"过期"处理。
        ReminderScheduler.shared.cancel(noteID: note.id)
        // 同样推到下一个 runloop tick —— 跟 hard-delete 一样,@ObservedObject
        // 在同 tick 内 mutate isTrashed 也会触发 SwiftUI 重渲染访问 fault 对象;
        // 推一拍让 orderOut 先生效,SwiftUI 树释放后再写库。
        DispatchQueue.main.async {
            note.isPinned = false
            note.isTrashed = true
            note.trashedAt = Date()
            // 回收站优先级高于归档:把归档笔记移入回收站时清掉归档态,
            // 保证三态(活跃 / 归档 / 回收站)始终互斥。
            note.isArchived = false
            note.archivedAt = nil
            try? context?.save()
        }
        applyLayout()
    }

    /// 把回收站里的笔记还原回正常列表。不重新打开浮窗 —— 用户想看就自己点 Open。
    func restore(note: Note) {
        DispatchQueue.main.async {
            note.isTrashed = false
            note.trashedAt = nil
            try? note.managedObjectContext?.save()
        }
    }

    /// 归档:把笔记移出活跃列表但保留(不删除、永不过期自动清)。有浮窗先
    /// 无痕关掉,清 isPinned(归档的不再算开机自动恢复),撤掉提醒(跟进
    /// 回收站一致 —— 收起来就别再弹;reminderDate 字段保留,取消归档后 UI
    /// 仍能看到原设时间)。写 isArchived = true + archivedAt = now。
    /// 入口:浮窗 ⋯ 菜单、Manager 侧边栏右键。
    func archive(note: Note) {
        let id = note.objectID
        if let wc = windows[id] {
            wc.close()
            windows[id] = nil
            displayOrder.removeAll { $0 == id }
        }
        let context = note.managedObjectContext
        ReminderScheduler.shared.cancel(noteID: note.id)
        // 推到下一个 runloop tick —— 跟 delete 同理:@ObservedObject 在同
        // tick 内 mutate isArchived 也会触发 SwiftUI 重渲染访问 fault 对象;
        // 推一拍让 orderOut 先生效,SwiftUI 树释放后再写库。
        DispatchQueue.main.async {
            note.isPinned = false
            note.isArchived = true
            note.archivedAt = Date()
            try? context?.save()
        }
        applyLayout()
    }

    /// 取消归档:回到活跃列表。不重新打开浮窗 —— 用户想看自己点 Open
    /// (跟从回收站 restore 行为一致)。
    func unarchive(note: Note) {
        DispatchQueue.main.async {
            note.isArchived = false
            note.archivedAt = nil
            try? note.managedObjectContext?.save()
        }
    }

    /// 真删一条:回收站里的"彻底删除"按钮走这条。直接 context.delete + save。
    /// 浮窗已经在 trash 时关掉了,这里不需要再处理。
    func deletePermanently(note: Note) {
        let context = note.managedObjectContext
        ReminderScheduler.shared.cancel(noteID: note.id)
        NoteDisplayStore.clear(noteID: note.id)
        DispatchQueue.main.async {
            context?.delete(note)
            try? context?.save()
        }
    }

    /// 清空回收站:fetch 所有 isTrashed == true 的笔记,逐条 delete + save 一次。
    /// 用 batch delete 也行,但要手动 merge changes 进 viewContext —— 量级小,
    /// 走 context.delete 简单稳妥。
    ///
    /// `main.async` 推一拍是为了让 alert 收起动画与删除分到不同 runloop tick,
    /// 与 trash/restore/deletePermanently 保持一致。**真正防 SIGTRAP 的是
    /// TrashDetailView 把 ForEach 的 id 改成 `\.objectID`** —— 删 N 条 + save 同
    /// tick 时,SwiftUI 的 List diff 会用旧列表里每个 Note 的 id keypath,
    /// `\.id` 读非可选 UUID 在已 fault 的对象上会 bridging 崩溃,`objectID`
    /// 是 NSManagedObject 自身的 Swift 属性所以一直可读。
    func emptyTrash(in context: NSManagedObjectContext) {
        let request = Note.trashedFetchRequest()
        guard let trashed = try? context.fetch(request) else { return }
        // delete(note:) 在进回收站时已经 cancel 过了,但用户跨设备同步 / 旧库
        // 残留的提醒可能还挂着,这里再扫一遍兜底。
        for note in trashed {
            ReminderScheduler.shared.cancel(noteID: note.id)
            NoteDisplayStore.clear(noteID: note.id)
        }
        DispatchQueue.main.async {
            for note in trashed {
                context.delete(note)
            }
            try? context.save()
        }
    }

    /// 清空全部内容:删掉**所有** Note(活跃 / 归档 / 回收站全包含)+ 所有
    /// NoteGroup。设置 / 偏好(UserDefaults)一概不动。**不可撤销** —— 调用方
    /// 负责弹强确认(Settings → General 的「清空全部内容」)。
    ///
    /// 防 SIGTRAP 套路同 `emptyTrash` / `delete`:先**同步**关掉所有浮窗(其
    /// SwiftUI `@ObservedObject` 视图树随窗口释放),再把 `context.delete` 推到
    /// 下一个 runloop tick —— 不在 SwiftUI 还持有 note 的同一 tick 里 fault
    /// 已删对象。windows / displayOrder 这里就清空,关窗触发的 onClose 写
    /// isPinned 无所谓(对象马上整体删掉)。
    /// 返回这次清掉的 (便签数, 分组数) —— 同步 fetch 出来,删除本身异步。
    @discardableResult
    func clearAll(in context: NSManagedObjectContext) -> (notes: Int, groups: Int) {
        for wc in windows.values { wc.close() }
        windows.removeAll()
        displayOrder.removeAll()
        // 分组要被一并删光,残留的隐藏集合 id 会变野指针 —— 顺手清掉。
        hiddenGroupIDs.removeAll()
        persistHiddenGroups()

        // note 不带任何 predicate —— 三态(活跃 / 归档 / 回收站)全要。
        let notes = (try? context.fetch(NSFetchRequest<Note>(entityName: "Note"))) ?? []
        let groups = (try? context.fetch(NSFetchRequest<NoteGroup>(entityName: "NoteGroup"))) ?? []
        for note in notes {
            ReminderScheduler.shared.cancel(noteID: note.id)
            NoteDisplayStore.clear(noteID: note.id)
        }

        DispatchQueue.main.async {
            for note in notes { context.delete(note) }
            for group in groups { context.delete(group) }
            try? context.save()
        }
        return (notes.count, groups.count)
    }

    /// 当前库里 (便签数, 分组数);便签含三态全部。给「清空全部内容」确认弹窗
    /// 显示规模用。
    func contentCounts(in context: NSManagedObjectContext) -> (notes: Int, groups: Int) {
        let n = (try? context.count(for: NSFetchRequest<Note>(entityName: "Note"))) ?? 0
        let g = (try? context.count(for: NSFetchRequest<NoteGroup>(entityName: "NoteGroup"))) ?? 0
        return (n, g)
    }

    /// 启动时调一次:把超过保留天数的 trashed 笔记真删。默认 30 天(对齐
    /// 系统 Notes/Mail),用户可以在 Settings → General 改(7-365 范围)。
    /// trashedAt 为 nil 的(理论上不该出现,旧库迁移残留)跳过,等下次 trash
    /// 行为重写时再处理。
    func purgeExpiredTrash(in context: NSManagedObjectContext) {
        let request = Note.trashedFetchRequest()
        let days = TrashRetention.current
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        // 在 fetch 阶段就过滤掉 trashedAt 不达标的,免得 fetch 全量再扫一遍。
        request.predicate = NSPredicate(
            format: "isTrashed == %@ AND trashedAt != nil AND trashedAt < %@",
            NSNumber(value: true), cutoff as NSDate
        )
        guard let expired = try? context.fetch(request), !expired.isEmpty else { return }
        for note in expired {
            ReminderScheduler.shared.cancel(noteID: note.id)
            context.delete(note)
        }
        try? context.save()
        NSLog("Perch: purged %d expired trash note(s)", expired.count)
    }

    private func spawn(note: Note, id: NSManagedObjectID) {
        // 已开浮窗的数量决定偏移量,启动批量恢复时多个浮窗会从中心向右下错开,
        // 避免全部叠在一个点上。模 8 防止越开越远直接出屏。
        let cascade = windows.count % 8
        let wc = FloatingNoteWindowController(
            note: note,
            initialLevel: floatOnTop ? .floating : .normal,
            initialCollectionBehavior: Self.collectionBehavior(floatOnTop: floatOnTop),
            onClose: { [weak self] in
                guard let self else { return }
                self.windows[id] = nil
                self.displayOrder.removeAll { $0 == id }
                guard !self.isTerminating else { return }
                note.isPinned = false
                try? note.managedObjectContext?.save()
                self.applyLayout()
            },
            onRequestDelete: { [weak self] in
                self?.delete(note: note)
            },
            onRequestArchive: { [weak self] in
                self?.archive(note: note)
            },
            onBecameKey: { [weak self] in
                self?.notifyWindowBecameKey(id: id)
            },
            onUserMoveEnded: { [weak self] in
                self?.notifyUserMoveEnded(id: id)
            }
        )
        wc.show(cascadeIndex: cascade)
        windows[id] = wc
        displayOrder.append(id)
        if !note.isPinned {
            note.isPinned = true
            try? note.managedObjectContext?.save()
        }
        // 运行期新开/重开窗:把整组当前次序冻结(新窗排末尾)。restore 期间
        // isRestoring=true,persistDisplayOrder 会自动跳过,留给 restore 收尾统一写。
        persistDisplayOrder()
        applyLayout()
    }
}
