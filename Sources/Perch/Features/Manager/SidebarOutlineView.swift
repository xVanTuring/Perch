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
        if let item = item as? SidebarItem, case .note = item,
           !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator?.menuForSidebarItem(item)
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

    /// Top-level items in display order.
    private var topLevel: [SidebarItem] = []
    /// note objectID → Note. Used to hydrate the lightweight SidebarItem cases.
    private var noteByID: [NSManagedObjectID: Note] = [:]
    private var groupByID: [NSManagedObjectID: NoteGroup] = [:]
    /// note objectID → its parent SidebarItem (group | ungrouped header).
    /// Outline view passes Any? for items; we need parent lookup for drop coercion.
    private var parentItemForNote: [NSManagedObjectID: SidebarItem] = [:]
    /// Children arrays per parent, in display order.
    private var childrenForParent: [SidebarItem: [SidebarItem]] = [:]

    /// Suppress feedback when SwiftUI is pushing a selection change down to
    /// AppKit — otherwise selectionDidChange would write the same value back
    /// to the binding and we'd loop.
    private var suppressSelectionWriteback = false

    init(_ parent: SidebarOutlineView) {
        self.parent = parent
    }

    // MARK: - Snapshot application

    func applySnapshot(_ s: SidebarSnapshot, expandAll: Bool) {
        // **Always reloadData**. Earlier we tried skipping when the snapshot
        // was structurally identical (same NSManagedObjectIDs in same order),
        // but that misses edits to a note's *content* — typing into a note
        // doesn't change the ID set, so the row's title would stay stuck on
        // "Empty note" until something else forced a reload. NSOutlineView
        // reuses cell views, so reloadData for ~30 visible rows is cheap.

        // Rebuild lookup tables.
        groupByID.removeAll(keepingCapacity: true)
        noteByID.removeAll(keepingCapacity: true)
        parentItemForNote.removeAll(keepingCapacity: true)
        childrenForParent.removeAll(keepingCapacity: true)

        for g in s.groups { groupByID[g.objectID] = g }
        for (_, list) in s.notesByGroup {
            for n in list { noteByID[n.objectID] = n }
        }
        for n in s.ungroupedNotes { noteByID[n.objectID] = n }
        if let flat = s.flatNotes {
            for n in flat { noteByID[n.objectID] = n }
        }

        // Build top-level + parent/child maps.
        if let flat = s.flatNotes {
            // No groups at all — flat list, no headers.
            topLevel = flat.map { .note($0.objectID) }
        } else {
            var top: [SidebarItem] = []
            for g in s.groups {
                let groupItem = SidebarItem.group(g.objectID)
                top.append(groupItem)
                let kids = (s.notesByGroup[g.objectID] ?? []).map { note -> SidebarItem in
                    let item = SidebarItem.note(note.objectID)
                    parentItemForNote[note.objectID] = groupItem
                    return item
                }
                childrenForParent[groupItem] = kids
            }
            top.append(.ungroupedHeader)
            let ungroupedKids = s.ungroupedNotes.map { note -> SidebarItem in
                let item = SidebarItem.note(note.objectID)
                parentItemForNote[note.objectID] = .ungroupedHeader
                return item
            }
            childrenForParent[.ungroupedHeader] = ungroupedKids
            topLevel = top
        }

        guard let outlineView = controller?.outlineView else { return }
        // Save current selection to re-apply after reload (selectRowIndexes uses
        // row indices which are invalidated by reload).
        let preselected = parent.selection
        suppressSelectionWriteback = true
        outlineView.reloadData()
        if expandAll {
            outlineView.expandItem(nil, expandChildren: true)
        }
        // Re-apply previous selection by item identity, not row index.
        applySelection(preselected, on: outlineView)
        suppressSelectionWriteback = false
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
            if let item = outlineView.item(atRow: row) as? SidebarItem,
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
            if let item = outlineView.item(atRow: row) as? SidebarItem,
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
        guard let parent = item as? SidebarItem else { return 0 }
        switch parent {
        case .group, .ungroupedHeader:
            return childrenForParent[parent]?.count ?? 0
        case .note:
            return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return topLevel[index] }
        guard let parent = item as? SidebarItem else { return SidebarItem.ungroupedHeader }
        return childrenForParent[parent]?[index] ?? SidebarItem.ungroupedHeader
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? SidebarItem else { return false }
        switch item {
        case .group, .ungroupedHeader: return true
        case .note: return false
        }
    }

    // MARK: - NSOutlineViewDelegate (visuals)

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        // Source-list style: top-level items render as gray section headers.
        guard let item = item as? SidebarItem else { return false }
        switch item {
        case .group, .ungroupedHeader: return true
        case .note: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? SidebarItem else { return false }
        // Group/header rows aren't selectable as notes — only note rows feed
        // the SwiftUI selection set.
        switch item {
        case .note: return true
        case .group, .ungroupedHeader: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        switch item {
        case .group(let oid):
            let name = groupByID[oid]?.name ?? ""
            let hiddenFromMenu = groupByID[oid].map { MenuHiddenGroups.isHidden($0.id) } ?? false
            return makeGroupHeaderView(text: name.isEmpty ? L.t(.untitled) : name,
                                       hiddenFromMenu: hiddenFromMenu, outlineView: outlineView)
        case .ungroupedHeader:
            return makeGroupHeaderView(text: L.t(.managerUngrouped),
                                       hiddenFromMenu: false, outlineView: outlineView)
        case .note(let oid):
            guard let note = noteByID[oid] else { return nil }
            return makeNoteRowView(note: note, outlineView: outlineView)
        }
    }

    private static let groupHeaderID = NSUserInterfaceItemIdentifier("Perch.SidebarGroupHeader")
    private static let noteRowID = NSUserInterfaceItemIdentifier("Perch.SidebarNoteRow")

    private func makeGroupHeaderView(text: String, hiddenFromMenu: Bool, outlineView: NSOutlineView) -> NSView {
        let view: GroupHeaderCellView
        if let recycled = outlineView.makeView(withIdentifier: Self.groupHeaderID, owner: nil) as? GroupHeaderCellView {
            view = recycled
        } else {
            view = GroupHeaderCellView()
            view.identifier = Self.groupHeaderID
        }
        view.configure(text: text, hiddenFromMenu: hiddenFromMenu)
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
        guard !suppressSelectionWriteback else { return }
        guard let outlineView = controller?.outlineView else { return }
        let new = currentSelectionUUIDs(in: outlineView)
        if new != parent.selection {
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
        guard let item = item as? SidebarItem,
              case .note(let oid) = item,
              let note = noteByID[oid] else { return nil }
        let pb = NSPasteboardItem()
        // Multi-drag source: if the dragged note is part of the current
        // selection, the table view will call this for each selected note
        // independently, so we just encode this single one and let AppKit
        // build the multi-row drag.
        pb.setString(note.id.uuidString, forType: kNotePasteboardType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Only valid drop = onto a group / ungrouped header / a note (which
        // we coerce to its parent group). Reject drops "between" rows
        // (index != NSOutlineViewDropOnItemIndex above the parent itself).
        guard let item = item as? SidebarItem else { return [] }

        switch item {
        case .group, .ungroupedHeader:
            // Force "drop on" semantics — no reordering UI inside groups.
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        case .note:
            // User dragged onto a sibling note — coerce to its parent group.
            guard case .note(let oid) = item, let parentItem = parentItemForNote[oid] else {
                return []
            }
            outlineView.setDropItem(parentItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let item = item as? SidebarItem else { return false }
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
        guard let item = item as? SidebarItem else { return nil }
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

    private lazy var labelTrailingToIcon =
        label.trailingAnchor.constraint(lessThanOrEqualTo: hiddenIcon.leadingAnchor, constant: -4)
    private lazy var labelTrailingToEdge =
        label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)

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
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        addSubview(label)

        hiddenIcon.translatesAutoresizingMaskIntoConstraints = false
        hiddenIcon.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        // tertiaryLabelColor + 10pt 在深色侧栏上几乎看不见,提到 secondary + 12pt medium。
        hiddenIcon.contentTintColor = .secondaryLabelColor
        hiddenIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        hiddenIcon.toolTip = L.t(.managerHideGroupFromMenu)
        addSubview(hiddenIcon)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            hiddenIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hiddenIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        labelTrailingToEdge.isActive = true
    }

    private var hiddenFromMenu = false
    private lazy var keyState = WindowKeyStateObserver { [weak self] in self?.updateColors() }

    func configure(text: String, hiddenFromMenu: Bool) {
        label.stringValue = text
        self.hiddenFromMenu = hiddenFromMenu
        updateColors()
        hiddenIcon.isHidden = !hiddenFromMenu
        labelTrailingToEdge.isActive = !hiddenFromMenu
        labelTrailingToIcon.isActive = hiddenFromMenu
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
    private let colorBar = NSView()
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
        // colorBar 用 CAGradientLayer 当宿主层 —— 纯色时是退化的单色渐变(两端同色),
        // 炫彩时纵向扫一遍彩虹。宿主层 frame 由 AppKit 跟着 view bounds 自动同步。
        let grad = CAGradientLayer()
        grad.cornerRadius = 1.5
        grad.startPoint = CGPoint(x: 0.5, y: 0)
        grad.endPoint = CGPoint(x: 0.5, y: 1)
        colorBar.layer = grad
        colorBar.wantsLayer = true
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
        if let grad = colorBar.layer as? CAGradientLayer {
            let stops = palette.isRainbow
                ? StickyPalette.rainbowStops(vivid: true)
                : [palette.nsColor, palette.nsColor]
            // dynamic NSColor → cgColor 必须按当前外观解析,否则深浅色会错。
            var cg: [CGColor] = []
            effectiveAppearance.performAsCurrentDrawingAppearance {
                cg = stops.map { $0.cgColor }
            }
            grad.colors = cg
        }

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
}
