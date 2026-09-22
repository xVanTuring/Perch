import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// 管理窗口的 SwiftUI 根视图。两栏 NavigationSplitView:
///   sidebar  → 「All Notes」+ 各分组 + 「Ungrouped」,各自可展开/折叠的笔记列表
///   detail   → 选中笔记的所见即所得编辑器,空选中态显示提示
struct ManagerView: View {
    let floating: FloatingNotesRegistry

    @Environment(\.managedObjectContext) private var context
    // **不要给这三个 FetchRequest 加 `animation:`**:拖拽改 group 后,row 会
    // 跨 section 移到目标分组的 sort 头部(被 updatedAt bump 推上去)。带
    // `animation: .default` 时 SwiftUI 会给这种跨段移动一个连续动画,中间
    // 每一行都要重算 frame,从底拖到顶看到的就是肉眼可见的卡顿。无动画下
    // 是瞬时跳到新位置,没有过渡帧 —— 跟 Finder/Notes sidebar 行为一致。
    @FetchRequest(fetchRequest: NoteGroup.sortedFetchRequest())
    private var groups: FetchedResults<NoteGroup>
    @FetchRequest(fetchRequest: Note.sortedFetchRequest())
    private var allNotes: FetchedResults<Note>
    /// 回收站项数。展示在 sidebar 底部的徽章,数据源跟 TrashDetailView 共享
    /// 同一个 store —— 同一个 viewContext 改动后两边都会自动刷新。
    @FetchRequest(fetchRequest: Note.trashedFetchRequest())
    private var trashedNotes: FetchedResults<Note>
    /// 归档项数。展示在 sidebar 底部的徽章,跟 ArchiveDetailView 共享同一个
    /// store —— 同一 viewContext 改动后两边自动刷新。
    @FetchRequest(fetchRequest: Note.archivedFetchRequest())
    private var archivedNotes: FetchedResults<Note>

    /// **多选**:`List(selection:)` 给 `Binding<Set<Hashable>>` 时,系统自动支持
    /// Cmd-click(切换单条入/出选区)和 Shift-click(范围选)—— 跟 Finder/Notes
    /// 一致,不需要自己拦事件。空集合表示没选;单选时取唯一元素显示详情。
    /// 初值取上次单选的笔记(跨窗口关闭 / 重启),找不到的在 onAppear 里清掉。
    @State private var selection: Set<Note.ID> = ManagerView.restoredSelection()
    /// 进 Trash 视图。Trash 不在 List selection 里(不跟 note 混选),用一个独立
    /// state 切。点击其它任何 note 会把这个清回 false(由 onChange 处理)。
    @State private var viewingTrash: Bool = false
    /// 进 Archive 视图。跟 viewingTrash 一样独立于 List selection,且与
    /// viewingTrash 互斥(视图状态:选中笔记 / 全部任务 / 回收站 / 归档)。
    @State private var viewingArchive: Bool = false
    /// 进 All Tasks 视图(跨笔记的未完成待办聚合)。同样独立于 List selection,
    /// 与上面几个互斥。
    @State private var viewingTasks: Bool = false
    @State private var search: String = ""
    @AppStorage(SettingsKey.noteSort) private var noteSortRaw: String = NoteSort.dateEdited.rawValue
    /// 重命名分组用的状态:点 "Rename" 后存住目标 group + 当前名,alert 用 TextField
    /// 让用户改;Save 写回并清空,Cancel 直接清空。
    @State private var renamingGroup: NoteGroup?
    @State private var renameText: String = ""
    /// 新建分组用的状态:toolbar New Group 按钮把它打开,alert 让用户先输入名字
    /// 再写库 —— 不再插一条占位 "New Group" 等用户进 sidebar 右键改名。
    @State private var creatingGroup: Bool = false
    @State private var newGroupName: String = ""
    /// 切换分组「在菜单栏显示/隐藏」(#1)后 +1,逼 body 重算 → SidebarOutlineView
    /// 的 updateNSViewController 跑一次 reloadData,让分组行的 eye.slash 标记即时刷新。
    /// (MenuHiddenGroups 存在 UserDefaults,不是 @Published,不会自己触发重绘。)
    @State private var menuVisibilityToken = 0
    /// 图片面板 popover 的开关(toolbar 上的相机按钮)。
    @State private var showNoteImages = false
    @ObservedObject private var loc = LocalizationManager.shared

    /// 当前单选中的笔记。多选 / 无选 / 在回收站等视图里都是 nil ——
    /// toolbar 上那些「针对一条笔记」的入口据此决定要不要出现。
    private var selectedNote: Note? {
        guard !viewingTasks, !viewingTrash, !viewingArchive,
              selection.count == 1, let id = selection.first else { return nil }
        return allNotes.first { $0.id == id && !$0.isDeleted }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("")
        // .searchable 用系统原生 search field,自动塞到 toolbar 合适位置,
        // 样式跟 Notes/Mail 一致(灰色圆角胶囊 + 放大镜 + 占位符 + ⌘ + 取消圈)。
        .searchable(text: $search, prompt: L.t(.managerSearch))
        .alert(
            L.t(.managerRenameAlertTitle),
            isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            ),
            presenting: renamingGroup
        ) { group in
            TextField(L.t(.managerGroupNamePlaceholder), text: $renameText)
            Button(L.t(.cancel), role: .cancel) { renamingGroup = nil }
            Button(L.t(.save)) {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    group.name = trimmed
                    try? context.save()
                }
                renamingGroup = nil
            }
        } message: { _ in
            Text(L.t(.managerRenameMessage))
        }
        .alert(L.t(.managerNewGroupAlertTitle), isPresented: $creatingGroup) {
            TextField(L.t(.managerGroupNamePlaceholder), text: $newGroupName)
            Button(L.t(.cancel), role: .cancel) {}
            Button(L.t(.managerCreate)) {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let group = NoteGroup.create(in: context, name: trimmed)
                try? context.save()
                // Settings → General「新分组显示在菜单栏」关闭时,新建即隐藏。
                if !MenuHiddenGroups.newGroupsShownByDefault {
                    MenuHiddenGroups.setHidden(group.id, true)
                    menuVisibilityToken &+= 1
                }
            }
        } message: {
            Text(L.t(.managerNewGroupMessage))
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: createGroup) {
                    Label(L.t(.managerNewGroup), systemImage: "folder.badge.plus")
                }
                .help(L.t(.managerNewGroup))
            }
            // 选中笔记的图片面板。图片和正文里的引用是两回事 —— 引用删掉、
            // 改坏、被 undo 吃掉,图片本身都还在库里(清理只发生在便签被永久
            // 删除时)。这个 popover 是把它放回去的唯一入口,见 NoteImagesPopover。
            // 只在单选一条笔记、且这条笔记确实关联了图片时出现。
            if let note = selectedNote, NoteImagesPopover.hasImages(note) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNoteImages.toggle()
                    } label: {
                        Label(L.t(.noteImagesButton), systemImage: "photo.on.rectangle.angled")
                    }
                    .help(L.t(.noteImagesButton))
                    .popover(isPresented: $showNoteImages, arrowEdge: .bottom) {
                        NoteImagesPopover(note: note)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNote) {
                    Label(L.t(.managerNewNote), systemImage: "square.and.pencil")
                }
                .help(L.t(.managerNewNote) + " (⌘N)")
                // ⌘N 由 AppDelegate 装在 NSApp.mainMenu 上的 File → New Note 派
                // 发,行为是 spawn floating(全局一致)。这里 toolbar button 的
                // 行为略不同(只在 manager 里 select 不弹浮窗),所以**不再绑
                // .keyboardShortcut**,免得跟 main menu 抢。点按钮走 createNote;
                // ⌘N 走 main menu 的 spawn-floating 路径。
            }
            // 整库导出 / 导入。放 toolbar 而非右键 —— 右键是「针对选中便签」的
            // 上下文,整库操作跟选中无关。这是用户唯一能真正点到的入口
            //(LSUIElement 隐藏了菜单栏,AppDelegate 的 File 菜单点不到)。
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L.t(.managerExportAllSQLite)) { exportAllSQLite() }
                    Button(L.t(.managerExportAllMarkdown)) { exportAllMarkdown() }
                    Divider()
                    Button(L.t(.managerImportSQLite)) { importAllSQLite() }
                } label: {
                    Label(L.t(.managerDataMenu), systemImage: "ellipsis.circle")
                }
                .help(L.t(.managerDataMenu))
            }
        }
    }

    // MARK: Sidebar -------------------------------------------------------------

    private var sidebar: some View {
        // 每次 body 评估一次性算好分桶,后面 ForEach 直接 O(1) 取。详见
        // computeNotesSnapshot 注释。
        let snapshot = computeNotesSnapshot()
        let bridgeSnapshot = SidebarSnapshot(
            groups: Array(groups),
            notesByGroup: snapshot.byGroup,
            ungroupedNotes: snapshot.ungrouped,
            flatNotes: groups.isEmpty ? snapshot.all : nil
        )
        return VStack(spacing: 0) {
            // 笔记 + 分组 sidebar 走 NSOutlineView 桥(SidebarOutlineView)
            // 实现拖拽 —— SwiftUI List 在 macOS 上对 onDrag/onDrop 的处理
            // 跟 Finder/Notes 风格不兼容,详见 SidebarOutlineView 顶部注释。
            // selection / search / sort / 右键菜单 都从这里下发。
            SidebarOutlineView(
                snapshot: bridgeSnapshot,
                selection: $selection,
                onMove: { ids, group in moveNotes(ids: ids, to: group) },
                noteMenu: { note in noteContextNSMenu(note) },
                groupMenu: { group in groupContextNSMenu(group) }
            )
            // NSScrollView 没有 intrinsic content size,在 SwiftUI VStack 里
            // 会塌成 0,显式撑满。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: selection) { _, new in
                // 选中任何 note 时立刻退出 Tasks / Trash / Archive 视图。
                // (All Tasks 里点分组头跳笔记也走这条路径退出该视图。)
                if !new.isEmpty {
                    viewingTasks = false
                    viewingTrash = false
                    viewingArchive = false
                }
                // 只记单选;清空选择(切到回收站等)或多选时保留上一次的记录。
                if new.count == 1, let id = new.first {
                    UserDefaults.standard.set(id.uuidString, forKey: SettingsKey.managerLastSelectedNote)
                }
            }
            .onAppear {
                // 上次选中的笔记已被删除 / 归档 / 进回收站:不在 allNotes 里,清掉选择。
                if let id = selection.first, !allNotes.contains(where: { $0.id == id }) {
                    selection = []
                }
            }

            Divider()
            // 全部任务入口 —— 放在归档上面。跨笔记聚合所有未完成待办。
            BottomSidebarRow(
                icon: "checklist",
                title: L.t(.tasksTitle),
                count: TaskAggregator.openTaskCount(from: allNotes),
                active: viewingTasks,
                onTap: {
                    viewingTasks = true
                    viewingArchive = false
                    viewingTrash = false
                    selection = []
                }
            )
            // 归档入口 —— 跟回收站并列在底部。各视图状态互斥。
            BottomSidebarRow(
                icon: "archivebox",
                title: L.t(.archiveTitle),
                count: archivedNotes.count,
                active: viewingArchive,
                onTap: {
                    viewingArchive = true
                    viewingTasks = false
                    viewingTrash = false
                    selection = []
                }
            )
            BottomSidebarRow(
                icon: "trash",
                title: L.t(.trashTitle),
                count: trashedNotes.count,
                active: viewingTrash,
                onTap: {
                    viewingTrash = true
                    viewingTasks = false
                    viewingArchive = false
                    selection = []
                }
            )
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
    }

    // MARK: Detail --------------------------------------------------------------

    private var detail: some View {
        Group {
            if viewingTasks {
                // 点分组头 → 设 selection 跳到那条笔记;selection 的 onChange
                // 会把 viewingTasks 清回 false,自动切到笔记详情。
                TasksDetailView(onSelectNote: { note in selection = [note.id] })
            } else if viewingTrash {
                TrashDetailView(floating: floating)
            } else if viewingArchive {
                ArchiveDetailView(floating: floating)
            } else if selection.count == 1,
               let id = selection.first,
               let note = allNotes.first(where: { $0.id == id && !$0.isDeleted }) {
                NoteDetailView(note: note, floating: floating)
                    // 关键:强制按 note.id 绑定详情子树 identity。
                    // 管理页全程复用同一棵 SwiftUI 树 + 同一个编辑器实例,
                    // 底层 swift-markdown-engine 的 NSTextView Coordinator 只在
                    // makeCoordinator 时捕获一次回写 binding、updateNSView 从不刷新它。
                    // 少了这个 .id,切到笔记 B 后打字会经「仍指向笔记 A」的旧 binding
                    // 写回 → 覆盖 A 的正文(串笔记 + A 丢失)。加上 .id 后切 note 会重建
                    // 子树 → 重新 makeCoordinator → 回写 binding 对准当前笔记。
                    .id(note.id)
            } else if selection.count > 1 {
                ContentUnavailableView(
                    L.t(.managerMultiSelected, selection.count),
                    systemImage: "square.stack",
                    description: Text(L.t(.managerMultiSelectedDesc))
                )
            } else {
                ContentUnavailableView(
                    L.t(.managerSelectNote),
                    systemImage: "note.text",
                    description: Text(L.t(.managerSelectNoteDesc))
                )
            }
        }
    }

    // MARK: Filtering -----------------------------------------------------------

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **按 group 预分桶 + 排序的 snapshot**,sidebar body 一次评估只算一次。
    ///
    /// 早先版本是 `filteredNotes(in: group)` 在 ForEach 里每个 section 各自
    /// `allNotes.filter { ... }` + `.sorted(...)`,M 个分组就 M·N 次扫 + M 次
    /// 排。拖拽时 body 重跑频繁,直接卡。这里改成走一次 allNotes:先 search
    /// + 排序,再 group by `note.group?.objectID`。同结果 O(N log N),不再随
    /// 分组数线性放大。
    ///
    /// 返回 `(byGroup, ungrouped, all)` 三元组,sidebar 三种渲染分支各取所需。
    /// `byGroup` 的 key 是 `NSManagedObjectID`(NoteGroup 的);ungrouped 是
    /// `note.group == nil` 的那些。
    private struct NotesSnapshot {
        var byGroup: [NSManagedObjectID: [Note]]
        var ungrouped: [Note]
        var all: [Note]
    }

    private func computeNotesSnapshot() -> NotesSnapshot {
        let trimmed = trimmedSearch
        let sort = NoteSort.from(noteSortRaw)

        // 单趟 sort + filter,后面所有 section 直接拿结果分桶。
        var working: [Note] = []
        working.reserveCapacity(allNotes.count)
        for note in allNotes {
            if trimmed.isEmpty || note.content.localizedCaseInsensitiveContains(trimmed) {
                working.append(note)
            }
        }
        working.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch sort {
            case .dateEdited:  return lhs.updatedAt > rhs.updatedAt
            case .dateCreated: return lhs.createdAt > rhs.createdAt
            case .title:
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
        }

        var byGroup: [NSManagedObjectID: [Note]] = [:]
        var ungrouped: [Note] = []
        for note in working {
            if let oid = note.group?.objectID {
                byGroup[oid, default: []].append(note)
            } else {
                ungrouped.append(note)
            }
        }
        return NotesSnapshot(byGroup: byGroup, ungrouped: ungrouped, all: working)
    }

    // MARK: Actions -------------------------------------------------------------

    private static func restoredSelection() -> Set<Note.ID> {
        guard let raw = UserDefaults.standard.string(forKey: SettingsKey.managerLastSelectedNote),
              let id = UUID(uuidString: raw) else { return [] }
        return [id]
    }

    private func createNote() {
        let note = Note.create(in: context)
        try? context.save()
        selection = [note.id]
    }

    private func createGroup() {
        // 不再直接插占位条;弹 alert 先要用户输入名字,跟 Rename 体验一致。
        newGroupName = ""
        creatingGroup = true
    }

    // MARK: 整库导出 / 导入 -----------------------------------------------------
    //
    // 三个动作都是「同步阻塞 NSOpen/NSSavePanel → NoteIO → NSAlert 报结果」。
    // panel 与 alert 都是主线程 modal,跟 createNote 一样在 Button action 里直接
    // 跑没问题。整库 Core Data 拷贝对便签应用这种小库量级足够快,不另开后台。

    private func exportAllSQLite() {
        guard let url = NoteIOPanels.chooseExportAllSQLite() else { return }
        if let count = NoteIO.exportAllSQLite(from: context, to: url) {
            ioAlert(L.t(.exportAllSQLiteDone, count))
        } else {
            ioAlert(L.t(.exportAllSQLiteFailed))
        }
    }

    private func exportAllMarkdown() {
        guard let folder = NoteIOPanels.chooseExportFolder() else { return }
        let count = NoteIO.exportAllMarkdown(in: context, toFolder: folder)
        ioAlert(L.t(.exportAllMarkdownDone, count))
    }

    private func importAllSQLite() {
        guard let url = NoteIOPanels.chooseSQLiteToImport() else { return }
        if let result = NoteIO.importSQLite(url, into: context) {
            // 备份里在浮窗状态的笔记导入后立刻现身 —— 等同重启时 restorePinnedNotes,
            // 用户不必重启。show() 内部已 applyLayout,这里逐条 spawn 即可
            // (跟下方右键 "Open as Sticky" 多选 spawn 同一路径)。
            for note in result.pinned { floating.show(note: note) }
            ioAlert(L.t(.importSQLiteDone, result.notes, result.groups))
        } else {
            ioAlert(L.t(.importSQLiteFailed))
        }
    }

    /// 整库 IO 完成提示。跟 AppDelegate.showCompletionAlert 同款,让用户确知
    /// 导出/导入真的发生了(尤其导出后文件在别处,没视觉反馈会让人没底)。
    private func ioAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L.t(.appName)
        alert.informativeText = message
        alert.addButton(withTitle: L.t(.ok))
        alert.runModal()
    }

    /// 右键命中**选中**项里的某个 → 作用于整组当前选中(Finder/Notes 标准行为);
    /// 命中**未选**的项 → 只作用于这一条。返回数组保证至少一项。
    private func contextTargets(for note: Note) -> [Note] {
        if selection.contains(note.id), selection.count > 1 {
            return allNotes.filter { selection.contains($0.id) }
        }
        return [note]
    }

    /// 把指定 ids 的笔记 reassign 到 targetGroup(nil = Ungrouped),并 bump
    /// updatedAt。**必须 bump updatedAt**:Note.sortedFetchRequest 排序键是
    /// `(isPinned, updatedAt)`,只动 group relationship 时
    /// NSFetchedResultsController 不发 update 事件,SwiftUI @FetchRequest 不刷
    /// 新,sidebar 不动。bump 后既能可靠触发刷新,也符合"用户改动了 note"的
    /// 语义(在 dateEdited 排序下被推到 section 头部,跟 Notes/Mail 一致)。
    private func moveNotes(ids: [UUID], to targetGroup: NoteGroup?) {
        guard !ids.isEmpty else { return }
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(
            format: "id IN %@ AND isTrashed == %@",
            ids, NSNumber(value: false)
        )
        guard let notes = try? context.fetch(request) else { return }
        var changed = false
        let now = Date()
        for note in notes where note.group?.objectID != targetGroup?.objectID {
            note.group = targetGroup
            // 顺手 bump updatedAt:NSFetchedResultsController 只追踪 sort
            // descriptors / predicate 里的字段,relationship-only 改动不会
            // 派发 update 事件 —— SwiftUI @FetchRequest 也就收不到通知,
            // sidebar 不会刷新。Note.sortedFetchRequest 用的是
            // (isPinned, updatedAt) 排序,bump updatedAt 既能可靠触发
            // FetchRequest 重发,语义也合理(用户主动改动了这条 note)。
            note.updatedAt = now
            changed = true
        }
        if changed { try? context.save() }
    }

    @ViewBuilder
    private func noteContextMenu(_ note: Note) -> some View {
        let targets = contextTargets(for: note)
        let multi = targets.count > 1

        // Open as Sticky:单条直接打开;多条放到一个子菜单里(8 条以内才显示
        // 入口,免得用户误点把 30 个浮窗瞬间糊到屏幕上)。
        if multi {
            if targets.count <= 8 {
                Button(L.t(.managerOpenCount, targets.count)) {
                    for n in targets { floating.show(note: n) }
                }
            }
        } else {
            Button(L.t(.managerOpenAsSticky)) { floating.show(note: note) }
        }

        // Pin / Unpin:总是给两个动作,让用户明确地选「全部钉住」或「全部取消钉」。
        // 不做"toggle 当前选中是否全部 pinned"的智能猜测 —— 多选状态混合时怎么
        // 解读 toggle 都会误伤。两按钮 + 显式语义 跟 Finder 「Add Tag / Remove Tag」 一致。
        Menu(L.t(.managerPinMenu)) {
            Button(L.t(.managerPinAll)) {
                for n in targets where !n.isPinned { n.isPinned = true }
                try? context.save()
            }
            Button(L.t(.managerUnpinAll)) {
                for n in targets where n.isPinned { n.isPinned = false }
                try? context.save()
            }
        }

        // 颜色:6 色调色板,选哪个就把 targets 全部染过去。Label + circle.fill
        // 系统图标 + foregroundStyle —— Menu 里能看到色块,体验比纯文字好。
        Menu(L.t(.managerColorMenu)) {
            ForEach(StickyPalette.allCases) { palette in
                Button {
                    for n in targets where n.colorIndex != palette.rawValue {
                        n.colorIndex = palette.rawValue
                    }
                    try? context.save()
                } label: {
                    Label(L.t(palette.locKey), systemImage: "circle.fill")
                        .foregroundStyle(palette.swatchFill)
                }
            }
        }

        // Move to group:走 moveNotes 而不是直接 `n.group = ...`,因为
        // `moveNotes` 会在 reassign 时同时 bump updatedAt —— relationship-only
        // 改动 NSFetchedResultsController 不发 update,sidebar 不会刷新。详见
        // moveNotes 内注释。
        Menu(multi ? L.t(.managerMoveNotesToGroup, targets.count) : L.t(.managerMoveToGroup)) {
            Button(L.t(.managerUngrouped)) {
                moveNotes(ids: targets.map { $0.id }, to: nil)
            }
            ForEach(groups, id: \.id) { g in
                Button(g.name.isEmpty ? L.t(.untitled) : g.name) {
                    moveNotes(ids: targets.map { $0.id }, to: g)
                }
            }
        }

        // Export:单条走 NSSavePanel 保存 .md;多条走 NSOpenPanel 选目录,
        // 每条便签写一个 .md。NoteIOPanels 是同步阻塞 modal,跑主线程没问题。
        Button(multi ? L.t(.managerExportCount, targets.count) : L.t(.managerExport)) {
            if multi {
                guard let folder = NoteIOPanels.chooseExportFolder() else { return }
                _ = NoteIO.exportNotes(targets, toFolder: folder)
            } else {
                guard let url = NoteIOPanels.chooseExportSingleNote(suggestedTitle: note.displayTitle) else { return }
                _ = NoteIO.exportNote(note, to: url)
            }
        }

        Divider()
        Button(multi ? L.t(.managerArchiveCount, targets.count) : L.t(.managerArchive)) {
            for n in targets {
                selection.remove(n.id)
                floating.archive(note: n)
            }
        }
        Button(multi ? L.t(.managerDeleteCount, targets.count) : L.t(.managerDeleteNote), role: .destructive) {
            for n in targets {
                selection.remove(n.id)
                floating.delete(note: n)
            }
        }
    }

    // MARK: NSMenu builders for the AppKit sidebar -------------------------------
    //
    // Mirrors the SwiftUI `noteContextMenu`/`groupContextMenu` View builders
    // above but emits NSMenu trees, because SidebarOutlineView (NSOutlineView
    // bridge) drives right-click via `menu(for:)`, not `.contextMenu`. Two
    // copies feels redundant but is unavoidable until SwiftUI exposes a way to
    // host SwiftUI menus inside an NSView's `menu(for:)` callback.
    //
    // Closures capture the SwiftUI struct value at menu-construction time —
    // which is exactly when the user right-clicks, so the snapshot of
    // `selection` / `groups` / `floating` etc. is current. Writes to @State
    // (selection, renamingGroup, …) inside closures go through the property
    // wrapper just like in body, so they update view state correctly.

    private func noteContextNSMenu(_ note: Note) -> NSMenu {
        let targets = contextTargets(for: note)
        let multi = targets.count > 1
        let menu = NSMenu()

        if multi {
            if targets.count <= 8 {
                menu.addItem(ClosureMenuItem(title: L.t(.managerOpenCount, targets.count)) {
                    for n in targets { floating.show(note: n) }
                })
            }
        } else {
            menu.addItem(ClosureMenuItem(title: L.t(.managerOpenAsSticky)) {
                floating.show(note: note)
            })
        }

        let pinMenu = NSMenu(title: L.t(.managerPinMenu))
        pinMenu.addItem(ClosureMenuItem(title: L.t(.managerPinAll)) {
            for n in targets where !n.isPinned { n.isPinned = true }
            try? context.save()
        })
        pinMenu.addItem(ClosureMenuItem(title: L.t(.managerUnpinAll)) {
            for n in targets where n.isPinned { n.isPinned = false }
            try? context.save()
        })
        let pinItem = NSMenuItem(title: L.t(.managerPinMenu), action: nil, keyEquivalent: "")
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)

        let colorMenu = NSMenu(title: L.t(.managerColorMenu))
        for palette in StickyPalette.allCases {
            let item = ClosureMenuItem(title: L.t(palette.locKey)) {
                for n in targets where n.colorIndex != palette.rawValue {
                    n.colorIndex = palette.rawValue
                }
                try? context.save()
            }
            // Color swatch as menu icon — a 12pt filled circle in the palette tint
            // (炫彩走渐变填充)。
            let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                palette.fill(path: NSBezierPath(ovalIn: rect), vivid: true)
                return true
            }
            item.image = swatch
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: L.t(.managerColorMenu), action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        let moveTitle = multi ? L.t(.managerMoveNotesToGroup, targets.count) : L.t(.managerMoveToGroup)
        let moveMenu = NSMenu(title: moveTitle)
        moveMenu.addItem(ClosureMenuItem(title: L.t(.managerUngrouped)) {
            moveNotes(ids: targets.map { $0.id }, to: nil)
        })
        for g in groups {
            moveMenu.addItem(ClosureMenuItem(title: g.name.isEmpty ? L.t(.untitled) : g.name) {
                moveNotes(ids: targets.map { $0.id }, to: g)
            })
        }
        let moveItem = NSMenuItem(title: moveTitle, action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)

        menu.addItem(ClosureMenuItem(title: multi ? L.t(.managerExportCount, targets.count) : L.t(.managerExport)) {
            if multi {
                guard let folder = NoteIOPanels.chooseExportFolder() else { return }
                _ = NoteIO.exportNotes(targets, toFolder: folder)
            } else {
                guard let url = NoteIOPanels.chooseExportSingleNote(suggestedTitle: note.displayTitle) else { return }
                _ = NoteIO.exportNote(note, to: url)
            }
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: multi ? L.t(.managerArchiveCount, targets.count) : L.t(.managerArchive)) {
            for n in targets {
                selection.remove(n.id)
                floating.archive(note: n)
            }
        })
        menu.addItem(ClosureMenuItem(title: multi ? L.t(.managerDeleteCount, targets.count) : L.t(.managerDeleteNote)) {
            for n in targets {
                selection.remove(n.id)
                floating.delete(note: n)
            }
        })

        return menu
    }

    private func groupContextNSMenu(_ group: NoteGroup) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L.t(.managerRename)) {
            renameText = group.name
            renamingGroup = group
        })
        // #1:在托盘菜单的笔记列表里显示/隐藏此分组(不影响桌面浮窗,那是 #4)。
        let hiddenFromMenu = MenuHiddenGroups.isHidden(group.id)
        menu.addItem(ClosureMenuItem(
            title: hiddenFromMenu ? L.t(.managerShowGroupInMenu) : L.t(.managerHideGroupFromMenu)
        ) {
            MenuHiddenGroups.toggle(group.id)
            menuVisibilityToken &+= 1
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L.t(.managerDeleteGroup)) {
            // 关系是 nullify:删 group 后,组里的 note 自动 ungrouped。
            context.delete(group)
            try? context.save()
        })
        return menu
    }

    @ViewBuilder
    private func groupContextMenu(_ group: NoteGroup) -> some View {
        Button(L.t(.managerRename)) {
            renameText = group.name
            renamingGroup = group
        }
        // #1:在托盘菜单的笔记列表里显示/隐藏此分组(不影响桌面浮窗,那是 #4)。
        Button(MenuHiddenGroups.isHidden(group.id)
               ? L.t(.managerShowGroupInMenu) : L.t(.managerHideGroupFromMenu)) {
            MenuHiddenGroups.toggle(group.id)
            menuVisibilityToken &+= 1
        }
        Divider()
        Button(L.t(.managerDeleteGroup), role: .destructive) {
            // 关系是 nullify:删 group 后,组里的 note 自动 ungrouped。
            context.delete(group)
            try? context.save()
        }
    }
}

// MARK: Sidebar row -----------------------------------------------------------

private struct NoteSidebarRow: View {
    @ObservedObject var note: Note
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(StickyPalette.from(index: note.colorIndex).swatchFill)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .cornerRadius(1.5)
                let title = note.displayTitle
                let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Text(isEmpty ? L.t(.emptyNote) : title)
                    .lineLimit(1)
                    .italic(isEmpty)
                    .foregroundStyle(isEmpty ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
        }
    }
}

// MARK: Detail view -----------------------------------------------------------

// MARK: Trash sidebar row -----------------------------------------------------

/// Sidebar 底部的固定入口(Archive / Trash 共用)。手动绘制成"高亮态/默认态"
/// 两种,不进 List selection 队列,这样不和 note 多选混在一起。徽章显示数量。
private struct BottomSidebarRow: View {
    let icon: String
    let title: String
    let count: Int
    let active: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.18))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.18) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

// MARK: Trash detail ---------------------------------------------------------

/// 回收站列表 + Empty Trash 按钮。每行显示标题 + trashedAt 相对时间,行尾
/// Restore / Delete Permanently。点 Empty Trash 弹一个 alert 二次确认 ——
/// 整体真删,这步不能误触。
private struct TrashDetailView: View {
    let floating: FloatingNotesRegistry
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: Note.trashedFetchRequest(), animation: .default)
    private var trashed: FetchedResults<Note>
    @State private var confirmingEmpty = false
    @State private var confirmingDelete: Note?
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if trashed.isEmpty {
                ContentUnavailableView(
                    L.t(.trashEmpty),
                    systemImage: "trash",
                    description: Text(L.t(.trashEmptyDesc))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // 用 objectID 而不是 \.id 做身份:Empty Trash 一次删 N 条 + save,
                    // FetchedResults 通知与 SwiftUI List 的 OutlineListCoordinator
                    // diff 同 tick 发生,diff 会读旧列表里每个 Note 的 keypath
                    // \.id —— 此时 Note 已 fault/invalidated,@NSManaged 的
                    // `id: UUID` ObjC accessor 返回 nil,bridging 到非可选 UUID
                    // 直接 SIGTRAP(见 crash 2026-05-07)。`objectID` 是
                    // NSManagedObject 自身的 Swift 属性,对象作废后仍可读。
                    ForEach(trashed, id: \.objectID) { note in
                        TrashRow(
                            note: note,
                            onRestore: { floating.restore(note: note) },
                            onDelete: { confirmingDelete = note }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert(
            L.t(.trashEmptyAlert),
            isPresented: $confirmingEmpty
        ) {
            Button(L.t(.trashEmptyButton), role: .destructive) {
                floating.emptyTrash(in: context)
            }
            Button(L.t(.cancel), role: .cancel) {}
        } message: {
            Text(L.t(.trashEmptyAlertMsg))
        }
        .alert(
            L.t(.trashDeleteAlert),
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            presenting: confirmingDelete
        ) { note in
            Button(L.t(.delete), role: .destructive) {
                floating.deletePermanently(note: note)
                confirmingDelete = nil
            }
            Button(L.t(.cancel), role: .cancel) { confirmingDelete = nil }
        } message: { _ in
            Text(L.t(.trashDeleteAlertMsg))
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "trash")
            Text(L.t(.trashTitle))
                .font(.title3.weight(.semibold))
            Text("(\(trashed.count))")
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                confirmingEmpty = true
            } label: {
                Label(L.t(.trashEmptyButton), systemImage: "trash.slash")
            }
            .disabled(trashed.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct TrashRow: View {
    @ObservedObject var note: Note
    @ObservedObject private var loc = LocalizationManager.shared
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(StickyPalette.from(index: note.colorIndex).swatchFill)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .cornerRadius(1.5)

                VStack(alignment: .leading, spacing: 2) {
                    let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Text(isEmpty ? L.t(.emptyNote) : note.displayTitle)
                        .lineLimit(1)
                        .italic(isEmpty)
                        .foregroundStyle(isEmpty ? .secondary : .primary)
                    Text(trashedAtLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L.t(.restore), action: onRestore)
                    .buttonStyle(.bordered)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help(L.t(.trashDeletePermanentlyHelp))
            }
            .padding(.vertical, 4)
        }
    }

    /// "丢进回收站 X 之前"。30 天后启动时自动清,所以最大也就是 30 多天。
    private var trashedAtLabel: String {
        guard let when = note.trashedAt else { return L.t(.trashTitle) }
        let formatter = RelativeDateTimeFormatter()
        // RelativeDateTimeFormatter 跟 LocalizationManager 选的语言对齐 ——
        // .system 退回 Locale.current,显式选英/中则强制用对应 locale。
        switch LocalizationManager.shared.effective {
        case .english: formatter.locale = Locale(identifier: "en")
        case .chinese: formatter.locale = Locale(identifier: "zh-Hans")
        case .system:  break
        }
        formatter.unitsStyle = .full
        return L.t(.trashedRelative, formatter.localizedString(for: when, relativeTo: Date()) as NSString)
    }
}

// MARK: Archive detail -------------------------------------------------------

/// 归档列表。仿回收站,但**没有**「清空」/「彻底删除」—— 归档永不自动过期、
/// 也不在这里真删;每行只给「取消归档」(回到活跃列表)和「移入回收站」
/// (走 floating.delete,会清掉归档态并进回收站的 N 天过期流程)。
private struct ArchiveDetailView: View {
    let floating: FloatingNotesRegistry
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: Note.archivedFetchRequest(), animation: .default)
    private var archived: FetchedResults<Note>
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if archived.isEmpty {
                ContentUnavailableView(
                    L.t(.archiveEmpty),
                    systemImage: "archivebox",
                    description: Text(L.t(.archiveEmptyDesc))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // 同 TrashDetailView:用 objectID 而不是 \.id 做身份,避免
                    // 批量状态变更 + save 同 tick 时 SwiftUI diff 读到已 fault
                    // 对象的非可选 UUID 触发 SIGTRAP。
                    ForEach(archived, id: \.objectID) { note in
                        ArchiveRow(
                            note: note,
                            onUnarchive: { floating.unarchive(note: note) },
                            onTrash: { floating.delete(note: note) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "archivebox")
            Text(L.t(.archiveTitle))
                .font(.title3.weight(.semibold))
            Text("(\(archived.count))")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct ArchiveRow: View {
    @ObservedObject var note: Note
    @ObservedObject private var loc = LocalizationManager.shared
    let onUnarchive: () -> Void
    let onTrash: () -> Void

    var body: some View {
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(StickyPalette.from(index: note.colorIndex).swatchFill)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .cornerRadius(1.5)

                VStack(alignment: .leading, spacing: 2) {
                    let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Text(isEmpty ? L.t(.emptyNote) : note.displayTitle)
                        .lineLimit(1)
                        .italic(isEmpty)
                        .foregroundStyle(isEmpty ? .secondary : .primary)
                    Text(archivedAtLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L.t(.managerUnarchive), action: onUnarchive)
                    .buttonStyle(.bordered)
                Button(role: .destructive, action: onTrash) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help(L.t(.archiveMoveToTrash))
            }
            .padding(.vertical, 4)
        }
    }

    /// "归档于 X 之前"。归档没有过期一说,可能是很久以前。
    private var archivedAtLabel: String {
        guard let when = note.archivedAt else { return L.t(.archiveTitle) }
        let formatter = RelativeDateTimeFormatter()
        switch LocalizationManager.shared.effective {
        case .english: formatter.locale = Locale(identifier: "en")
        case .chinese: formatter.locale = Locale(identifier: "zh-Hans")
        case .system:  break
        }
        formatter.unitsStyle = .full
        return L.t(.archivedRelative, formatter.localizedString(for: when, relativeTo: Date()) as NSString)
    }
}

// MARK: Note detail ----------------------------------------------------------

private struct NoteDetailView: View {
    @ObservedObject var note: Note
    let floating: FloatingNotesRegistry
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            ZStack {
                Rectangle()
                    .fill(StickyPalette.from(index: note.colorIndex).backgroundFill)
                    .ignoresSafeArea()
                // 复用浮窗同一个所见即所得编辑器,管理窗口里既能看也能改,
                // 体验跟浮窗一致。Open as Sticky 行为通过 sidebar 行右键菜单走,
                // 不再用大按钮占地方。
                MarkdownEngineNoteEditor(
                    text: Binding(
                        get: { note.content },
                        set: { newValue in
                            guard newValue != note.content else { return }
                            note.content = newValue
                            note.updatedAt = Date()
                            try? context.save()
                        }
                    ),
                    documentId: note.id.uuidString
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}
