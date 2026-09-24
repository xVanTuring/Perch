import AppKit
import SwiftUI
import CoreData

/// Pasteboard type carrying note UUIDs during sidebar drag. Local-only; we
/// don't share notes between processes.
private let kNotePasteboardType = NSPasteboard.PasteboardType("tech.xvanturing.Perch.note")

/// NSMenuItem that runs a Swift closure on click. AppKit menu items want
/// target/action; this hides the Objective-C dance behind a closure so the
/// NSMenu builders in ManagerView read like the SwiftUI ones.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    @objc private func invoke() { handler() }
}

/// What the outline view shows. Each top-level item is either a `NoteGroup`,
/// the synthetic `Ungrouped` header, or — when `flatNotes` is non-nil (no
/// groups exist at all) — a flat list of notes. Children of group items are
/// `note` items.
enum SidebarItem: Hashable {
    case group(NSManagedObjectID)
    case ungroupedHeader
    case note(NSManagedObjectID)

    /// 分组 / 未分组标题:有子条目的节点。
    var isContainer: Bool {
        if case .note = self { return false }
        return true
    }
}

/// 交给 NSOutlineView 的 item。按 SidebarItem 缓存在 coordinator 里,同一个条目永远是同一个对象。
/// 不直接传 SidebarItem:Swift 枚举作为 `Any` 传进 AppKit 每次都会装箱成新对象,
/// 展开状态、`row(forItem:)`、`reloadItem` 都靠对象身份,可能对不上。
final class SidebarNode: NSObject {
    let item: SidebarItem
    init(_ item: SidebarItem) { self.item = item }
}

/// outline 回调里的 item → SidebarItem。
private func sidebarItem(_ any: Any?) -> SidebarItem? {
    (any as? SidebarNode)?.item
}

/// Snapshot passed from SwiftUI parent to the bridge each render. Built once
/// per body run by `ManagerView.computeNotesSnapshot()`.
struct SidebarSnapshot: Equatable {
    var groups: [NoteGroup]
    var notesByGroup: [NSManagedObjectID: [Note]]
    var ungroupedNotes: [Note]
    /// Set when no groups exist — sidebar is flat. Otherwise nil and we use
    /// the grouped layout.
    var flatNotes: [Note]?

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Equatable so SwiftUI can skip updateNSViewController when nothing changed.
        // Compare by ObjectIdentifiers — these are NSManagedObject instances, identity
        // is what matters.
        guard lhs.groups.map(\.objectID) == rhs.groups.map(\.objectID) else { return false }
        guard lhs.ungroupedNotes.map(\.objectID) == rhs.ungroupedNotes.map(\.objectID) else { return false }
        if (lhs.flatNotes?.map(\.objectID)) != (rhs.flatNotes?.map(\.objectID)) { return false }
        for key in Set(lhs.notesByGroup.keys).union(rhs.notesByGroup.keys) {
            if lhs.notesByGroup[key]?.map(\.objectID) != rhs.notesByGroup[key]?.map(\.objectID) {
                return false
            }
        }
        return true
    }
}

/// SwiftUI bridge for the manager sidebar's groups + notes section.
///
/// **Why AppKit**: SwiftUI's `List + Section + .listStyle(.sidebar)` on macOS
/// doesn't route mouse events for `.onDrag` / `.dropDestination` cleanly with
/// `List(selection:)`. After multiple rounds of fixes the drop UX still
/// stuttered (per-row drop targets churning under FetchRequest invalidation,
/// cross-section move animations). NSOutlineView solves all of this natively
/// because mouse-down disambiguation between click-vs-drag happens at the
/// table level with a movement threshold, drop targets are addressed by row
/// index (not view), and the data source / delegate methods are what every
/// production macOS sidebar app (NetNewsWire, MiaoYan, CodeEdit, etc.) uses.
struct SidebarOutlineView: NSViewControllerRepresentable {
    var snapshot: SidebarSnapshot
    @Binding var selection: Set<UUID>

    /// Called from drag-drop accept. Routes through ManagerView.moveNotes so
    /// `updatedAt` bumps and `@FetchRequest` reliably re-fires.
    var onMove: (_ ids: [UUID], _ to: NoteGroup?) -> Void

    /// Right-click on a note row → return an NSMenu. Caller uses
    /// `selection`-aware logic to decide single-vs-multi targets.
    var noteMenu: (Note) -> NSMenu?
    /// Right-click on a group header → return an NSMenu (rename, delete, …).
    var groupMenu: (NoteGroup) -> NSMenu?

    func makeNSViewController(context: Context) -> SidebarOutlineController {
        let vc = SidebarOutlineController()
        let coord = context.coordinator
        coord.controller = vc
        vc.outlineView.dataSource = coord
        vc.outlineView.delegate = coord
        vc.outlineView.coordinator = coord
        coord.applySnapshot(snapshot, expandAll: true)
        coord.applyBindingSelection()
        // 恢复的上次选中笔记可能在列表下方,首次建立时滚到可见。
        if let row = vc.outlineView.selectedRowIndexes.first {
            vc.outlineView.scrollRowToVisible(row)
        }
        return vc
    }

    func updateNSViewController(_ vc: SidebarOutlineController, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.applySnapshot(snapshot, expandAll: false)
        coord.applyBindingSelection()
    }

    func makeCoordinator() -> SidebarOutlineCoordinator {
        SidebarOutlineCoordinator(self)
    }
}

/// NSOutlineView subclass that routes right-clicks to the coordinator. The
/// stock `menu(for:)` doesn't pick up per-item context menus by itself —
/// override here so we can compute the row under the cursor and ask the
/// coordinator for the appropriate menu.
final class SidebarOutlineNSView: NSOutlineView {
    weak var coordinator: SidebarOutlineCoordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let item = self.item(atRow: row) else { return nil }
        // Right-click that lands on an unselected note → don't change selection
        // here (Apple's HIG: right-click only changes selection when the click
        // lands outside the current selection). The menu builder uses the
        // current SwiftUI selection set as its "targets" set.
        if let clicked = sidebarItem(item), case .note = clicked,
           !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator?.menuForSidebarItem(item)
    }

    /// 快速上下乱点时容易被误判成拖拽：先按 `SidebarDragThreshold`（距离 + 按住时间）
    /// 判定点击还是拖拽，再交给 NSTableView 自己的处理。
    override func mouseDown(with event: NSEvent) {
        SidebarDragThreshold.holdUntilDecided(after: event)
        super.mouseDown(with: event)
    }
}

/// Hosts the NSOutlineView inside an NSScrollView. Configured for source-list
/// style to match the SwiftUI `.listStyle(.sidebar)` look.
final class SidebarOutlineController: NSViewController {
    let outlineView = SidebarOutlineNSView()
    let scrollView = NSScrollView()

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = [.autoresizingMask]
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // Source list style gives the rounded selection pill + group headers
        // that match Notes/Mail/Finder sidebars.
        outlineView.style = .sourceList
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.indentationPerLevel = 8
        outlineView.autosaveExpandedItems = false
        outlineView.usesAutomaticRowHeights = false
        outlineView.rowHeight = 22
        outlineView.floatsGroupRows = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)

        // Drag-and-drop registration. Local-only move operation.
        outlineView.registerForDraggedTypes([kNotePasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .regular

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        view = scrollView
    }
}

/// All NSOutlineView wiring lives here so the SwiftUI struct stays a thin
/// representable. Holds the snapshot model, lookup tables, and selection
/// suppression flag.
@MainActor
final class SidebarOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var parent: SidebarOutlineView
    weak var controller: SidebarOutlineController?

    /// outline 当前显示内容的镜像:顶层条目 + 每个分组的子条目,按显示顺序。
    /// 数据源方法只读这两个;增量更新时和 insert / remove / move 调用同步修改,
    /// 保证 AppKit 看到的行永远和它自己记录的一致。
    private var topLevel: [SidebarItem] = []
    private var childrenForParent: [SidebarItem: [SidebarItem]] = [:]
    /// note objectID → Note. Used to hydrate the lightweight SidebarItem cases.
    private var noteByID: [NSManagedObjectID: Note] = [:]
    private var groupByID: [NSManagedObjectID: NoteGroup] = [:]
    /// note objectID → its parent SidebarItem (group | ungrouped header).
    /// Outline view passes Any? for items; we need parent lookup for drop coercion.
    private var parentItemForNote: [NSManagedObjectID: SidebarItem] = [:]

    /// SidebarItem → 交给 NSOutlineView 的节点对象,见 `SidebarNode`。
    private var nodes: [SidebarItem: SidebarNode] = [:]
    private var didInitialLoad = false

    /// Suppress feedback when SwiftUI is pushing a selection change down to
    /// AppKit — otherwise selectionDidChange would write the same value back
    /// to the binding and we'd loop.
    private var suppressSelectionWriteback = false

    init(_ parent: SidebarOutlineView) {
        self.parent = parent
    }

    // MARK: - Snapshot application

    /// 每次 SwiftUI 推新快照都会调用。不再 `reloadData()`(以前靠 50ms 去抖把
    /// "同一拍里来两次"的整表重建合并成一次来压选中闪烁):现在对比新旧结构,用
    /// insert / remove / move 增量更新,选中和展开状态不会被拆掉重建,行是动画移过去的。
    /// 结构不变时就只剩刷新行内容一步,来几次都不闪。
    func applySnapshot(_ s: SidebarSnapshot, expandAll: Bool) {
        // Lookup tables — cheap, rebuilt every time.
        groupByID.removeAll(keepingCapacity: true)
        noteByID.removeAll(keepingCapacity: true)
        parentItemForNote.removeAll(keepingCapacity: true)

        for g in s.groups { groupByID[g.objectID] = g }
        for (_, list) in s.notesByGroup {
            for n in list { noteByID[n.objectID] = n }
        }
        for n in s.ungroupedNotes { noteByID[n.objectID] = n }
        if let flat = s.flatNotes {
            for n in flat { noteByID[n.objectID] = n }
        }

        // Target structure: top-level + parent/child maps.
        var targetTop: [SidebarItem] = []
        var targetChildren: [SidebarItem: [SidebarItem]] = [:]
        if let flat = s.flatNotes {
            // No groups at all — flat list, no headers.
            targetTop = flat.map { .note($0.objectID) }
        } else {
            for g in s.groups {
                let groupItem = SidebarItem.group(g.objectID)
                targetTop.append(groupItem)
                targetChildren[groupItem] = (s.notesByGroup[g.objectID] ?? []).map { note -> SidebarItem in
                    parentItemForNote[note.objectID] = groupItem
                    return .note(note.objectID)
                }
            }
            targetTop.append(.ungroupedHeader)
            targetChildren[.ungroupedHeader] = s.ungroupedNotes.map { note -> SidebarItem in
                parentItemForNote[note.objectID] = .ungroupedHeader
                return .note(note.objectID)
            }
        }

        guard let outlineView = controller?.outlineView else {
            topLevel = targetTop
            childrenForParent = targetChildren
            return
        }

        let preselected = parent.selection
        suppressSelectionWriteback = true
        if expandAll || !didInitialLoad {
            // Initial setup (makeNSViewController) — must run synchronously:
            // the caller reads outlineView.selectedRowIndexes right after
            // this returns to scroll the restored selection into view.
            topLevel = targetTop
            childrenForParent = targetChildren
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
            didInitialLoad = true
        } else {
            animateChanges(in: outlineView, toTop: targetTop, children: targetChildren)
            // 结构对上了,但笔记正文 / 分组名可能变了(打字时 ID 集合不变,标题要跟着刷)。
            // 只让现有行重新取 cell 内容,不动结构和选中,不会闪。
            if outlineView.numberOfRows > 0 {
                outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outlineView.numberOfRows),
                                       columnIndexes: IndexSet(integer: 0))
            }
        }
        // Re-apply selection by item identity, not row index.
        applySelection(preselected, on: outlineView)
        suppressSelectionWriteback = false

        // 丢掉已经不存在的条目的节点缓存
        let alive = Set(targetTop + targetChildren.values.flatMap { $0 })
        nodes = nodes.filter { alive.contains($0.key) }
    }

    // MARK: - Incremental updates

    /// 对比镜像(`topLevel` / `childrenForParent`)和目标结构,用增量操作把 outline 变成目标的样子。
    /// 顺序:先删,再按目标顺序逐个"放到位"(已有的 move,新的 insert)。按下标从小到大处理,
    /// 处理到 i 时前面 0..<i 已经是最终状态,所以要找的条目一定在 i 或之后(或者在别的父节点下)。
    private func animateChanges(in outlineView: NSOutlineView,
                                toTop targetTop: [SidebarItem],
                                children targetChildren: [SidebarItem: [SidebarItem]]) {
        let targetSet = Set(targetTop + targetChildren.values.flatMap { $0 })
        var newContainers: [SidebarItem] = []

        outlineView.beginUpdates()

        // 1. 分组里不再存在的笔记
        for (container, kids) in childrenForParent {
            let gone = IndexSet(kids.indices.filter { !targetSet.contains(kids[$0]) })
            guard !gone.isEmpty else { continue }
            childrenForParent[container]?.remove(atOffsets: gone)
            outlineView.removeItems(at: gone, inParent: node(for: container), withAnimation: .effectFade)
        }
        // 2. 顶层不再存在的条目(删掉的分组连同镜像里剩下的子条目一起丢)
        let goneTop = IndexSet(topLevel.indices.filter { !targetSet.contains(topLevel[$0]) })
        if !goneTop.isEmpty {
            for i in goneTop { childrenForParent[topLevel[i]] = nil }
            topLevel.remove(atOffsets: goneTop)
            outlineView.removeItems(at: goneTop, inParent: nil, withAnimation: .effectFade)
        }
        // 3. 顶层就位
        for (i, item) in targetTop.enumerated() {
            if place(item, at: i, under: nil, in: outlineView) { newContainers.append(item) }
        }
        // 4. 每个分组的笔记就位(可能来自别的分组,或者从平铺切到分组时来自顶层)
        for container in targetTop {
            for (i, item) in (targetChildren[container] ?? []).enumerated() {
                _ = place(item, at: i, under: container, in: outlineView)
            }
        }

        outlineView.endUpdates()

        // 新出现的分组默认展开(跟首次加载时 expandAll 一致)
        for container in newContainers {
            outlineView.expandItem(node(for: container))
        }
    }

    /// 把 `item` 放到 `parent`(nil = 顶层)下第 `index` 位。返回是否新插入了一个分组。
    private func place(_ item: SidebarItem, at index: Int, under parentItem: SidebarItem?,
                       in outlineView: NSOutlineView) -> Bool {
        let list = children(of: parentItem)
        if index < list.count, list[index] == item { return false }

        if let (from, j) = locate(item) {
            var source = children(of: from)
            source.remove(at: j)
            setChildren(source, of: from)
            var dest = children(of: parentItem)
            dest.insert(item, at: index)
            setChildren(dest, of: parentItem)
            outlineView.moveItem(at: j, inParent: from.map { node(for: $0) },
                                 to: index, inParent: parentItem.map { node(for: $0) })
            return false
        }

        var dest = children(of: parentItem)
        dest.insert(item, at: index)
        setChildren(dest, of: parentItem)
        let isContainer = item.isContainer
        if isContainer { childrenForParent[item] = [] }  // 子条目在第 4 步插入
        outlineView.insertItems(at: IndexSet(integer: index), inParent: parentItem.map { node(for: $0) },
                                withAnimation: .effectFade)
        return isContainer
    }

    private func children(of parentItem: SidebarItem?) -> [SidebarItem] {
        guard let parentItem else { return topLevel }
        return childrenForParent[parentItem] ?? []
    }

    private func setChildren(_ list: [SidebarItem], of parentItem: SidebarItem?) {
        if let parentItem { childrenForParent[parentItem] = list } else { topLevel = list }
    }

    /// 条目在镜像里的位置:(父节点, 下标),父节点 nil = 顶层。
    private func locate(_ item: SidebarItem) -> (SidebarItem?, Int)? {
        if let i = topLevel.firstIndex(of: item) { return (nil, i) }
        for (container, kids) in childrenForParent {
            if let i = kids.firstIndex(of: item) { return (container, i) }
        }
        return nil
    }

    // MARK: - Nodes

    /// 同一个 SidebarItem 永远返回同一个节点对象。
    private func node(for item: SidebarItem) -> SidebarNode {
        if let existing = nodes[item] { return existing }
        let created = SidebarNode(item)
        nodes[item] = created
        return created
    }

    // MARK: - Selection bridging

    /// Push the SwiftUI binding's selection set down to the outline view.
    /// Runs after every snapshot apply and whenever the binding changes.
    func applyBindingSelection() {
        guard let outlineView = controller?.outlineView else { return }
        let current = currentSelectionUUIDs(in: outlineView)
        if current == parent.selection { return }
        suppressSelectionWriteback = true
        applySelection(parent.selection, on: outlineView)
        suppressSelectionWriteback = false
    }

    private func applySelection(_ ids: Set<UUID>, on outlineView: NSOutlineView) {
        var rows = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let item = sidebarItem(outlineView.item(atRow: row)),
               case .note(let oid) = item,
               let note = noteByID[oid],
               !note.isDeleted,
               ids.contains(note.id) {
                rows.insert(row)
            }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    private func currentSelectionUUIDs(in outlineView: NSOutlineView) -> Set<UUID> {
        var ids: Set<UUID> = []
        for row in outlineView.selectedRowIndexes {
            if let item = sidebarItem(outlineView.item(atRow: row)),
               case .note(let oid) = item,
               let note = noteByID[oid],
               !note.isDeleted {
                ids.insert(note.id)
            }
        }
        return ids
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return topLevel.count }
        guard let parent = sidebarItem(item) else { return 0 }
        switch parent {
        case .group, .ungroupedHeader:
            return childrenForParent[parent]?.count ?? 0
        case .note:
            return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let parent = sidebarItem(item) else { return node(for: topLevel[index]) }
        return node(for: childrenForParent[parent]?[index] ?? .ungroupedHeader)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = sidebarItem(item) else { return false }
        switch item {
        case .group, .ungroupedHeader: return true
        case .note: return false
        }
    }

    // MARK: - NSOutlineViewDelegate (visuals)

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        // Source-list style: top-level items render as gray section headers.
        guard let item = sidebarItem(item) else { return false }
        switch item {
        case .group, .ungroupedHeader: return true
        case .note: return false
        }
    }

    /// 折叠/展开只改变子行是否显示,分组头行本身是同一个 cell 实例不会被
    /// 重新 vend —— 手动 reloadItem 让它的 count 徽标跟着切换可见性。
    func outlineViewItemDidExpand(_ notification: Notification) {
        reloadHeaderRow(from: notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        reloadHeaderRow(from: notification)
    }

    private func reloadHeaderRow(from notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] else { return }
        controller?.outlineView.reloadItem(item)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = sidebarItem(item) else { return false }
        // Group/header rows aren't selectable as notes — only note rows feed
        // the SwiftUI selection set.
        switch item {
        case .note: return true
        case .group, .ungroupedHeader: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = sidebarItem(item) else { return nil }
        switch item {
        case .group(let oid):
            let name = groupByID[oid]?.name ?? ""
            let hiddenFromMenu = groupByID[oid].map { MenuHiddenGroups.isHidden($0.id) } ?? false
            return makeGroupHeaderView(text: name.isEmpty ? L.t(.untitled) : name,
                                       hiddenFromMenu: hiddenFromMenu, item: item, outlineView: outlineView)
        case .ungroupedHeader:
            return makeGroupHeaderView(text: L.t(.managerUngrouped),
                                       hiddenFromMenu: false, item: item, outlineView: outlineView)
        case .note(let oid):
            guard let note = noteByID[oid] else { return nil }
            return makeNoteRowView(note: note, outlineView: outlineView)
        }
    }

    private static let groupHeaderID = NSUserInterfaceItemIdentifier("Perch.SidebarGroupHeader")
    private static let noteRowID = NSUserInterfaceItemIdentifier("Perch.SidebarNoteRow")

    private func makeGroupHeaderView(text: String, hiddenFromMenu: Bool, item: SidebarItem, outlineView: NSOutlineView) -> NSView {
        let view: GroupHeaderCellView
        if let recycled = outlineView.makeView(withIdentifier: Self.groupHeaderID, owner: nil) as? GroupHeaderCellView {
            view = recycled
        } else {
            view = GroupHeaderCellView()
            view.identifier = Self.groupHeaderID
        }
        let count = childrenForParent[item]?.count ?? 0
        view.configure(text: text, hiddenFromMenu: hiddenFromMenu, count: count, isExpanded: outlineView.isItemExpanded(node(for: item)))
        return view
    }

    private func makeNoteRowView(note: Note, outlineView: NSOutlineView) -> NSView {
        let view: NoteRowCellView
        if let recycled = outlineView.makeView(withIdentifier: Self.noteRowID, owner: nil) as? NoteRowCellView {
            view = recycled
        } else {
            view = NoteRowCellView()
            view.identifier = Self.noteRowID
        }
        view.configure(with: note)
        return view
    }

    // MARK: - Selection callback

    func outlineViewSelectionDidChange(_ notification: Notification) {
        #if DEBUG
        NSLog("Perch Sidebar: selectionDidChange suppressed=%@", String(suppressSelectionWriteback))
        #endif
        guard !suppressSelectionWriteback else { return }
        guard let outlineView = controller?.outlineView else { return }
        let new = currentSelectionUUIDs(in: outlineView)
        if new != parent.selection {
            #if DEBUG
            NSLog("Perch Sidebar: selection binding push old=%@ new=%@",
                  parent.selection.map(\.uuidString).joined(separator: ","),
                  new.map(\.uuidString).joined(separator: ","))
            #endif
            // SwiftUI bindings should be hopped to the next runloop tick to
            // avoid "Modifying state during view update" warnings when selection
            // is changed inside a body invocation.
            DispatchQueue.main.async { [weak self] in
                self?.parent.selection = new
            }
        }
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = sidebarItem(item),
              case .note(let oid) = item,
              let note = noteByID[oid] else { return nil }
        #if DEBUG
        NSLog("Perch Sidebar: drag started note=%@", note.id.uuidString)
        #endif
        let pb = NSPasteboardItem()
        // Multi-drag source: if the dragged note is part of the current
        // selection, the table view will call this for each selected note
        // independently, so we just encode this single one and let AppKit
        // build the multi-row drag.
        pb.setString(note.id.uuidString, forType: kNotePasteboardType)
        return pb
    }

    /// 拖拽图换成完整的一行:圆角底板 + cell 截图(色条 + 标题 + 进度饼)。
    /// 默认实现只从 cell 的 imageView / textField 拼图,所以以前只剩标题文字。
    ///
    /// 之前(61eba30 起,已回滚)试过在 NoteRowCellView 上重写 draggingImageComponents,
    /// 回滚原因是拖拽图半透明——那是系统对所有拖拽图统一加的效果,公开 API 改不了,这里也一样。
    /// 这里在会话开始时统一设置;cell 截图用 cacheDisplay 同步画完,底板在 lockFocus 里按行的外观立即画,
    /// 不用懒执行的 drawingHandler(深色模式下颜色会按错的外观解析,d5e33ce 踩过)。
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        if draggedItems.count > 1 { session.draggingFormation = .stack }
        session.enumerateDraggingItems(options: [], for: outlineView,
                                       classes: [NSPasteboardItem.self], searchOptions: [:]) { dragItem, index, _ in
            guard index < draggedItems.count else { return }
            let row = outlineView.row(forItem: draggedItems[index])
            guard row >= 0, let image = Self.rowDragImage(outlineView, row: row) else { return }
            dragItem.setDraggingFrame(outlineView.rect(ofRow: row), contents: image)
        }
    }

    private static func rowDragImage(_ outlineView: NSOutlineView, row: Int) -> NSImage? {
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { return nil }
        // 选中行的 cell 是反白样式,截图时临时改回普通样式,否则白字画在底板上看不清
        let savedStyle = cell.backgroundStyle
        cell.backgroundStyle = .normal
        cell.cacheDisplay(in: cell.bounds, to: rep)
        cell.backgroundStyle = savedStyle

        let rowRect = outlineView.rect(ofRow: row)
        let cellRect = outlineView.convert(cell.bounds, from: cell)
        let cellOrigin = NSPoint(x: cellRect.minX - rowRect.minX, y: cellRect.minY - rowRect.minY)

        let image = NSImage(size: rowRect.size)
        outlineView.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocusFlipped(true)
            let card = NSRect(x: max(0, cellOrigin.x - 6), y: 1,
                              width: rowRect.width - max(0, cellOrigin.x - 6) - 2, height: rowRect.height - 2)
            let path = NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            rep.draw(in: NSRect(origin: cellOrigin, size: cellRect.size),
                     from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
            image.unlockFocus()
        }
        return image
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Only valid drop = onto a group / ungrouped header / a note (which
        // we coerce to its parent group). Reject drops "between" rows
        // (index != NSOutlineViewDropOnItemIndex above the parent itself).
        guard let item = sidebarItem(item) else { return [] }
        #if DEBUG
        NSLog("Perch Sidebar: validateDrop item=%@ index=%d", String(describing: item), index)
        #endif

        switch item {
        case .group, .ungroupedHeader:
            // Force "drop on" semantics — no reordering UI inside groups.
            outlineView.setDropItem(node(for: item), dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        case .note:
            // User dragged onto a sibling note — coerce to its parent group.
            guard case .note(let oid) = item, let parentItem = parentItemForNote[oid] else {
                return []
            }
            outlineView.setDropItem(node(for: parentItem), dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let item = sidebarItem(item) else { return false }
        let target: NoteGroup?
        switch item {
        case .group(let oid):       target = groupByID[oid]
        case .ungroupedHeader:      target = nil
        case .note:                 return false  // validateDrop coerced
        }

        var ids: [UUID] = []
        info.enumerateDraggingItems(options: [], for: outlineView,
                                    classes: [NSPasteboardItem.self], searchOptions: [:]) { dragItem, _, _ in
            if let pbItem = dragItem.item as? NSPasteboardItem,
               let s = pbItem.string(forType: kNotePasteboardType),
               let uuid = UUID(uuidString: s) {
                ids.append(uuid)
            }
        }
        guard !ids.isEmpty else { return false }
        #if DEBUG
        NSLog("Perch Sidebar: acceptDrop ids=%@ target=%@",
              ids.map(\.uuidString).joined(separator: ","), target?.id.uuidString ?? "ungrouped")
        #endif
        parent.onMove(ids, target)
        return true
    }

    // MARK: - Context menus

    func outlineView(_ outlineView: NSOutlineView, menuForItem item: Any) -> NSMenu? {
        // (Custom delegate method we wire in via the NSOutlineView subclass —
        // see SidebarOutlineView.makeNSViewController. NSOutlineView itself
        // doesn't have a built-in `menuFor` delegate hook; we override
        // `menu(for:)` on the NSOutlineView subclass instead. Kept here for
        // discoverability when reading the coordinator.)
        return menuForSidebarItem(item)
    }

    func menuForSidebarItem(_ item: Any) -> NSMenu? {
        guard let item = sidebarItem(item) else { return nil }
        switch item {
        case .note(let oid):
            guard let note = noteByID[oid] else { return nil }
            return parent.noteMenu(note)
        case .group(let oid):
            guard let group = groupByID[oid] else { return nil }
            return parent.groupMenu(group)
        case .ungroupedHeader:
            return nil
        }
    }
}

// MARK: - Custom group header view

/// 分组头行的 cell。已在托盘菜单里隐藏的分组(见 `MenuHiddenGroups` / #1)会在
/// 行尾显示一个 eye.slash 图标、并把名字淡化,一眼看出「这个分组的笔记在菜单栏里
/// 被藏了」。未分组头恒不隐藏。两态尾部约束模式抄自 `NoteRowCellView`。
final class GroupHeaderCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let hiddenIcon = NSImageView()
    /// 折叠时显示分组下笔记数,展开时隐藏。跟 hiddenIcon 一起塞进尾部 stack,
    /// 靠 NSStackView 对隐藏 arranged subview 自动收缩宽度,不用再手写第三套
    /// 两态尾部约束。
    private let countLabel = NSTextField(labelWithString: "")
    private lazy var trailingStack: NSStackView = {
        let stack = NSStackView(views: [countLabel, hiddenIcon])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var labelTrailingToStack =
        label.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -4)

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        // 不挂到 `textField`:source list 的 group row 会接管 textField 的字体和颜色,
        // 窗口失去焦点时再把它淡化到几乎看不见。自己定字体 + 颜色,激活与否一致。
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        addSubview(label)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isEditable = false
        countLabel.isBordered = false
        countLabel.drawsBackground = false
        countLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.isHidden = true

        hiddenIcon.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        // tertiaryLabelColor + 10pt 在深色侧栏上几乎看不见,提到 secondary + 12pt medium。
        hiddenIcon.contentTintColor = .secondaryLabelColor
        hiddenIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        hiddenIcon.toolTip = L.t(.managerHideGroupFromMenu)
        hiddenIcon.isHidden = true

        addSubview(trailingStack)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        labelTrailingToStack.isActive = true
    }

    private var hiddenFromMenu = false
    private lazy var keyState = WindowKeyStateObserver { [weak self] in self?.updateColors() }

    func configure(text: String, hiddenFromMenu: Bool, count: Int, isExpanded: Bool) {
        label.stringValue = text
        self.hiddenFromMenu = hiddenFromMenu
        updateColors()
        hiddenIcon.isHidden = !hiddenFromMenu
        countLabel.stringValue = "\(count)"
        countLabel.isHidden = isExpanded || count == 0
    }

    /// 窗口失焦时适度变灰(macOS 惯例),但不像系统 group row 那样淡到看不清:
    /// 激活 = label(已隐藏分组 secondary),失焦 = 统一 secondary。
    private func updateColors() {
        let isKey = window?.isKeyWindow ?? true
        label.textColor = (isKey && !hiddenFromMenu) ? .labelColor : .secondaryLabelColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyState.observe(window)
        updateColors()
    }
}

/// 监听所在窗口 key 状态变化(激活 / 失焦),回调里由 cell 自己刷新颜色。
/// 分组头和笔记行共用。窗口变了(cell 复用 / 移出窗口)时重新挂。
final class WindowKeyStateObserver {
    private var observers: [NSObjectProtocol] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func observe(_ window: NSWindow?) {
        removeAll()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in self?.onChange() })
        }
    }

    private func removeAll() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit { removeAll() }
}

// MARK: - Custom note row view

/// Mirrors the SwiftUI NoteSidebarRow design: 3pt color bar + title (italic
/// when content empty). Layout via Auto Layout for crisp rendering at any
/// row height.
final class NoteRowCellView: NSTableCellView {
    private let colorBar = SidebarColorBarView()
    private let label = NSTextField(labelWithString: "")
    /// 行尾的任务进度饼,靠右对齐。无任务项时隐藏,标题随之延伸到行尾。
    private let pie = TaskProgressPieView()

    /// 标题尾部约束的两态:有饼时收到饼左侧、无饼时收到行尾。configure 切换。
    private lazy var labelTrailingToPie =
        label.trailingAnchor.constraint(lessThanOrEqualTo: pie.leadingAnchor, constant: -6)
    private lazy var labelTrailingToEdge =
        label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        colorBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(colorBar)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label

        pie.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pie)

        NSLayoutConstraint.activate([
            colorBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            colorBar.widthAnchor.constraint(equalToConstant: 3),
            colorBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            colorBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: colorBar.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            pie.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pie.centerYAnchor.constraint(equalTo: centerYAnchor),
            pie.widthAnchor.constraint(equalToConstant: 14),
            pie.heightAnchor.constraint(equalToConstant: 14),
        ])
        labelTrailingToEdge.isActive = true
    }

    func configure(with note: Note) {
        let palette = StickyPalette.from(index: note.colorIndex)
        colorBar.stops = palette.isRainbow
            ? StickyPalette.rainbowStops(vivid: true)
            : [palette.nsColor, palette.nsColor]

        let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        label.stringValue = isEmpty ? L.t(.emptyNote) : note.displayTitle
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.font = isEmpty
            ? NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            : baseFont
        self.isEmpty = isEmpty
        updateColors()

        if let progress = note.taskProgress {
            pie.isHidden = false
            pie.progress = progress
            pie.toolTip = "\(progress.completed)/\(progress.total)"
            labelTrailingToEdge.isActive = false
            labelTrailingToPie.isActive = true
        } else {
            pie.isHidden = true
            pie.progress = nil
            pie.toolTip = nil
            labelTrailingToPie.isActive = false
            labelTrailingToEdge.isActive = true
        }
    }

    private var isEmpty = false
    private lazy var keyState = WindowKeyStateObserver { [weak self] in self?.updateColors() }

    /// 同 GroupHeaderCellView:窗口失焦时标题适度变灰。空笔记本来就是 secondary。
    private func updateColors() {
        let isKey = window?.isKeyWindow ?? true
        label.textColor = (isKey && !isEmpty) ? .labelColor : .secondaryLabelColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyState.observe(window)
        updateColors()
    }

    /// 选中且窗口激活时为 `.emphasized`(强调色背景)。标题 textField 系统会自动反白,
    /// 自绘的进度饼不会,要自己换成反白色,否则画在强调色背景上看不清。
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            pie.baseColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        }
    }
}

/// 笔记行的 3pt 竖色条。纯色时两端同色,炫彩时纵向扫一遍彩虹。
/// 用 `draw(_:)` 自绘而不是 CAGradientLayer 宿主层:拖拽图靠 `cacheDisplay` 截 cell,
/// 宿主层的内容截不进去。动态颜色在 draw 时按当前外观解析,深浅色切换也自动跟上。
final class SidebarColorBarView: NSView {
    var stops: [NSColor] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard !stops.isEmpty else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5)
        // 90° = 第一个色标在底部,和原来 CAGradientLayer(startPoint y=0,非翻转坐标)方向一致
        NSGradient(colors: stops)?.draw(in: path, angle: 90)
    }
}
