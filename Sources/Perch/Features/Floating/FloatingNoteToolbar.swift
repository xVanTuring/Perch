import AppKit
import SwiftUI

/// 浮窗顶部始终可见的标题条。空标题 + 没有 fallback 时不渲染(EmptyView),
/// 保持顶部 strip 留给 hover 工具条不挤压编辑器。`fallbackWhenEmpty` 给折叠
/// 态用 —— 没标题文字也得显示个占位符,否则折叠后是空 strip 用户看不到任何
/// 信息。文本居中、单行截断,左右各 32pt 给 × / ⋯ 按钮腾位置。
///
/// `stripHeight` 决定垂直居中的容器高度:展开态 28pt,折叠态 32pt。文本以
/// `.frame(height:, alignment: .center)` 居中,不再依赖 `.padding(.top, 8)`,
/// 这样折叠时整条 bar 内文字自然垂直居中。
struct NoteTitleBar: View {
    let text: String
    var fallbackWhenEmpty: String? = nil
    let stripHeight: CGFloat
    /// 任务进度,有任务项时在标题文字左侧画一个圆饼。nil = 无任务,不画。
    var taskProgress: Note.TaskProgress? = nil

    var body: some View {
        let display = text.isEmpty ? (fallbackWhenEmpty ?? "") : text
        let isFallback = text.isEmpty && fallbackWhenEmpty != nil

        if display.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                // 圆饼 + 标题作为一个整体居中:饼始终贴在标题左侧、随标题一起移动。
                HStack(spacing: 5) {
                    if let taskProgress {
                        TaskProgressPie(progress: taskProgress, diameter: 12)
                    }
                    Text(display)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(isFallback ? 0.4 : 0.65))
                        .italic(isFallback)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: stripHeight, alignment: .center)
                Spacer(minLength: 0)
            }
            // 标题条不挡点击,不抢编辑器/按钮/双击 hit 区的事件。
            .allowsHitTesting(false)
        }
    }
}

/// 标题条上的拖窗 + 双击命中层。catch mouseDown:clickCount==2 且 onDoubleClick
/// 非 nil → 触发 onDoubleClick;单击 + 真位移 → `window.performDrag(with:)` 转交给
/// 系统拖窗 —— 这样这块区域既能双击折叠/展开,又不挡用户拖动整个浮窗。
///
/// **必须始终渲染**,不能跟「双击折叠」开关绑定:窗口内容是 NSHostingView,它吞掉
/// mouseDown,`isMovableByWindowBackground` 对 SwiftUI 内容不生效;标题条上没有这层
/// 原生 view 时整个浮窗都拖不动(GitHub #1 #2)。开关关闭时传 `onDoubleClick: nil`,
/// 双击就按普通按下处理,照样能拖。
///
/// **关键:performDrag 只能等 mouseDragged 累计位移超过阈值再调**。直接在第一次
/// mouseDown 就 performDrag,触摸板的微抖动会瞬间触发 windowDidMove,导致
/// stack/tile layout 模式的 reflow 跟双击折叠动画打架(出现折一半/卡住的视觉
/// bug)。设 4pt 阈值,小于这个就当用户没动 —— 双击间隙的颤抖不算拖。
///
/// 在 ZStack 里**必须放在 HoverToolbar 之下** —— 上层的 × / ⋯ 按钮要先吃到点击。
/// 自身限定 ~28pt 高顶部条,不会下探到编辑器区域。
struct TitleDoubleClickHit: NSViewRepresentable {
    /// nil = 双击折叠关闭,只保留拖窗。
    let onDoubleClick: (() -> Void)?

    final class HitView: NSView {
        var onDoubleClick: (() -> Void)?
        /// 当前一次 mouseDown 的原始事件,等到 mouseDragged 越过阈值时拿它当
        /// performDrag 的 anchor。判定为双击 / mouseUp 后清空。
        private var pendingDownEvent: NSEvent?
        private var downLocation: NSPoint = .zero
        private static let dragThreshold: CGFloat = 4

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                pendingDownEvent = nil
                onDoubleClick()
                return
            }
            pendingDownEvent = event
            downLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = pendingDownEvent else { return }
            let dx = event.locationInWindow.x - downLocation.x
            let dy = event.locationInWindow.y - downLocation.y
            if dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold {
                pendingDownEvent = nil
                // performDrag 进 modal 循环直到 mouseUp;期间 windowDidMove 正常触发,
                // 用户是真在拖,reflow 应该走。
                window?.performDrag(with: down)
            }
        }

        override func mouseUp(with event: NSEvent) {
            pendingDownEvent = nil
        }
    }

    func makeNSView(context: Context) -> HitView {
        let v = HitView()
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: HitView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

/// 浮窗顶部 hover 工具条 + 全窗 hover 检测。`@State hovering` 在这里独立持有,
/// 状态变化不会冒泡到 FloatingNoteView,从而不让 MarkdownEngineNoteEditor 重渲染。
///
/// 按钮一律 hover-only:鼠标进入浮窗才显示 × / 铃铛 / ⋯,移出即隐藏 ——
/// 折叠态和展开态行为一致(`isCollapsed` 仍传入,只用于 ⋯ 菜单里折叠/展开项的
/// 文案与图标)。已设提醒的铃铛例外,始终常驻当状态标记。
struct HoverToolbar: View {
    let palette: StickyPalette
    let isCollapsed: Bool
    /// 顶部 strip 高度:展开 28pt / 折叠 32pt。HStack 用它做 frame 高度 + 居中。
    let stripHeight: CGFloat
    /// 当前 note 的 reminderDate(可能 nil / 过去 / 未来)。决定铃铛是 outline
    /// 还是 fill,以及是否「无 hover 也常驻显示」(已设提醒时铃铛是状态标记)。
    let reminderDate: Date?
    /// 当前(展开)窗口尺寸,用来在尺寸行里高亮命中的预设。nil = 没有存档尺寸,
    /// 不高亮任何预设。
    let currentSize: NSSize?
    let onClose: () -> Void
    let onPickColor: (StickyPalette) -> Void
    let onPickSize: (NSSize) -> Void
    let onToggleCollapse: () -> Void
    let onDelete: () -> Void
    let onArchive: () -> Void
    let onSetReminder: (Date) -> Void
    let onClearReminder: () -> Void
    @State private var hovering = false
    @State private var showReminderPicker = false

    /// 是否有「已设」提醒(过去/未来都算 —— 用户至少要看到铃铛常驻才能知道
    /// 还有遗留提醒可以清掉)。
    private var hasReminder: Bool { reminderDate != nil }

    /// 按钮只在 hover 时显示 —— 折叠态和展开态行为一致。
    private var buttonsVisible: Bool { hovering }

    var body: some View {
        ZStack(alignment: .top) {
            // 全窗 hover 检测层:用 NSTrackingArea 自己的 NSView,不挡点击
            // (`hitTest` 返回 nil),整窗都能感知 mouseEntered/Exited。
            // SwiftUI `.onHover` 只能配合 hit-test 区域,要么挡点击要么覆盖不全 ——
            // 这层 NSView 走 AppKit 原生路线两全。
            HoverTracker(hovering: $hovering)
                .allowsHitTesting(false)

            HStack(spacing: 6) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(NonDraggable())
                .opacity(buttonsVisible ? 1 : 0)

                Spacer()

                // 铃铛:hover 时和「已设提醒」时都显示。fill 图标 + 强调色 = 设了。
                // outline + 默认色 = 没设(只在 hover 期间出现)。
                // 圆形底:hasReminder 时铃铛常驻顶部,长标题截尾会撞到这里 ——
                // 给个半透明 + 毛玻璃的圆底把标题文本盖住,避免视觉重叠。
                // .ultraThinMaterial 在 palette 色底上自然糊一层,既能遮字
                // 又不会像实色圆点那么突兀。
                Button {
                    showReminderPicker.toggle()
                } label: {
                    Image(systemName: hasReminder ? "bell.fill" : "bell")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hasReminder ? Color.accentColor : Color.primary.opacity(0.65))
                        .contentShape(Rectangle())
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .background(NonDraggable())
                .opacity(buttonsVisible || hasReminder ? 1 : 0)
                .popover(isPresented: $showReminderPicker, arrowEdge: .top) {
                    ReminderPicker(
                        currentReminder: reminderDate,
                        onSet: { date in
                            showReminderPicker = false
                            onSetReminder(date)
                        },
                        onClear: {
                            showReminderPicker = false
                            onClearReminder()
                        },
                        onCancel: {
                            showReminderPicker = false
                        }
                    )
                }

                // 动作菜单是自建的 NSMenu(见 StickyActionMenuButton)。用 NSMenu 而非
                // popover:NSMenu 在自己的事件追踪循环里开关,选中项后菜单同步消失、动作
                // 立刻执行 —— 不像 NSPopover 那样有独立子窗口的 dismiss 动画会和折叠时改父窗
                // frame 打架。颜色行是自绘 NSView:系统 palette picker 的 hover 是个灰色圆角
                // 方块、改不掉,这里自己画圆点 + hover 浅色环 + 选中强调环。
                StickyActionMenuButton(
                    selected: palette,
                    currentSize: currentSize,
                    isCollapsed: isCollapsed,
                    onPickColor: onPickColor,
                    onPickSize: onPickSize,
                    onToggleCollapse: onToggleCollapse,
                    onArchive: onArchive,
                    onDelete: onDelete
                )
                .frame(width: 20, height: 20)
                .background(NonDraggable())
                .opacity(buttonsVisible ? 1 : 0)
            }
            .padding(.horizontal, 8)
            // 用固定 stripHeight + center 对齐替换原先的 `.padding(.top, 6)` ——
            // 折叠态 32pt 下按钮自然垂直居中(原方案 6pt top padding 留出底部空白)。
            // 外层 ZStack(alignment: .top) 负责把整个 HStack 锚到窗顶。
            .frame(height: stripHeight, alignment: .center)
            .foregroundStyle(.primary.opacity(0.65))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// 配合 `isMovableByWindowBackground = true` 使用:NSHostingView 不知道 SwiftUI
/// Button 区域是控件,默认整窗都允许背景拖动,Button 的 mouseDown 被吞掉
/// 当成拖窗事件 → 点了没反应。把这个表示为 .background 垫在按钮下,系统
/// 看到 mouseDownCanMoveWindow = false 就会把事件正常下发。
private struct NonDraggable: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 全窗 hover 检测的隐形 NSView。NSTrackingArea 走 AppKit 原生 mouse enter/exit,
/// `hitTest` 返回 nil 让点击穿透到下面的 SwiftUI 编辑器。`@Binding hovering` 把
/// AppKit 端的 enter/exit 事件转成 SwiftUI state(只反映在 HoverToolbar 内部)。
private struct HoverTracker: NSViewRepresentable {
    @Binding var hovering: Bool

    final class TrackerView: NSView {
        var onHoverChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for ta in trackingAreas { removeTrackingArea(ta) }
            // .inVisibleRect:tracking area 跟着 view 可见区域走,不需要手动维护 rect。
            // .activeInActiveApp:只在 App 活跃时跟踪,失活了不发杂事件。
            let ta = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(ta)
        }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
        override func mouseExited(with event: NSEvent)  { onHoverChange?(false) }

        // 不挡点击 —— 编辑器在我们下面,要能拿到 mouseDown。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.onHoverChange = { newValue in
            // tracking 回调可能在非 main 走;SwiftUI state 必须 main 设。
            DispatchQueue.main.async { hovering = newValue }
        }
        return v
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        // 闭包持有的是 binding 的当前 setter,binding 每次重建都更新一下避免持引用旧版。
        nsView.onHoverChange = { newValue in
            DispatchQueue.main.async { hovering = newValue }
        }
    }
}

/// ⋯ 动作菜单的触发器。点一下弹一个**自建 NSMenu**:第一项是自绘的颜色行
/// (`ColorSwatchMenuRow`),分隔线,然后折叠/归档/删除三个原生菜单项。
///
/// 为什么不用 SwiftUI `Menu` + palette Picker:系统 palette picker 的 hover 高亮是
/// 个灰色圆角方块,没有公开 API 改成圆环;而 SwiftUI `Menu` 又塞不进任意 NSView。
/// 所以颜色行只能走 AppKit 自绘,菜单也得自己建。折叠/归档/删除仍用原生菜单项 ——
/// 保留它们的系统外观,也保留「NSMenu 同步关闭、动作立刻执行」对折叠动画的友好性。
struct StickyActionMenuButton: NSViewRepresentable {
    let selected: StickyPalette
    /// 当前(展开)窗口尺寸,用于在尺寸行里高亮命中的预设。nil = 不高亮。
    let currentSize: NSSize?
    let isCollapsed: Bool
    let onPickColor: (StickyPalette) -> Void
    let onPickSize: (NSSize) -> Void
    let onToggleCollapse: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.title = ""
        button.setButtonType(.momentaryChange)
        // 跟 × / 铃铛(SF Symbol 16pt hierarchical, primary 0.65)对齐。
        button.contentTintColor = NSColor.labelColor.withAlphaComponent(0.65)
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.preferringHierarchical())
        button.image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        // 弹菜单时从 coordinator.parent 现读 selected / isCollapsed,这里只需刷新引用。
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: StickyActionMenuButton
        init(_ parent: StickyActionMenuButton) { self.parent = parent }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let colorItem = NSMenuItem()
            colorItem.view = ColorSwatchMenuRow(selected: parent.selected) { [weak self] picked in
                self?.parent.onPickColor(picked)
            }
            menu.addItem(colorItem)
            menu.addItem(.separator())

            // 尺寸预设行:跟颜色行同理,自绘 NSView,点中某个预设直接切换窗口尺寸。
            let sizeItem = NSMenuItem()
            sizeItem.view = SizePresetMenuRow(currentSize: parent.currentSize) { [weak self] size in
                self?.parent.onPickSize(size)
            }
            menu.addItem(sizeItem)
            menu.addItem(.separator())

            let collapse = NSMenuItem(
                title: parent.isCollapsed ? L.t(.floatExpand) : L.t(.floatCollapse),
                action: #selector(doCollapse), keyEquivalent: ""
            )
            collapse.target = self
            collapse.image = NSImage(
                systemSymbolName: parent.isCollapsed ? "chevron.down" : "chevron.up",
                accessibilityDescription: nil
            )
            menu.addItem(collapse)

            let archive = NSMenuItem(title: L.t(.floatArchive), action: #selector(doArchive), keyEquivalent: "")
            archive.target = self
            archive.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            menu.addItem(archive)

            let delete = NSMenuItem(title: L.t(.floatDelete), action: #selector(doDelete), keyEquivalent: "")
            delete.target = self
            delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(delete)

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc private func doCollapse() { parent.onToggleCollapse() }
        @objc private func doArchive() { parent.onArchive() }
        @objc private func doDelete() { parent.onDelete() }
    }
}

/// NSMenu 里那一行调色板,自绘。系统 palette picker 的 hover 是灰色圆角方块改不掉,
/// 这里自己来:画 6 个实心圆点;hover 的圆点外圈一道**浅色环**;当前选中的外圈一道
/// **强调色环**。鼠标移动靠 tracking area 追(.mouseMoved + .activeAlways 在菜单的
/// 事件追踪 runloop 里照常派发),点中某个圆点回调 onPick 并 cancelTracking 收菜单。
final class ColorSwatchMenuRow: NSView {
    private let palettes = StickyPalette.allCases
    private let selected: StickyPalette
    private let onPick: (StickyPalette) -> Void
    private var hovered: Int?

    private let dot: CGFloat = 15      // 圆点直径
    private let gap: CGFloat = 12      // 圆点之间(边到边)
    private let hPad: CGFloat = 14     // 跟原生菜单项的 leading 内缩大致对齐
    private let vPad: CGFloat = 7
    private let ringGap: CGFloat = 3   // 环跟圆点的间隙

    init(selected: StickyPalette, onPick: @escaping (StickyPalette) -> Void) {
        self.selected = selected
        self.onPick = onPick
        super.init(frame: .zero)
        let n = CGFloat(palettes.count)
        let width = hPad * 2 + n * dot + (n - 1) * gap
        let height = vPad * 2 + dot + (ringGap + 2) * 2   // 上下给环留位置
        frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func centerX(_ i: Int) -> CGFloat {
        hPad + dot / 2 + CGFloat(i) * (dot + gap)
    }

    private func index(at p: NSPoint) -> Int? {
        let cy = bounds.midY
        let hitR = dot / 2 + gap / 2   // 命中区放宽到圆点间隙的一半
        for i in palettes.indices {
            let dx = p.x - centerX(i)
            let dy = p.y - cy
            if dx * dx + dy * dy <= hitR * hitR { return i }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let cy = bounds.midY
        for (i, p) in palettes.enumerated() {
            let cx = centerX(i)
            let dotRect = NSRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot)
            p.fill(path: NSBezierPath(ovalIn: dotRect), vivid: true)

            // 选中 = 强调色环;否则 hover = 浅色环。选中优先(选中且 hover 时不叠 hover 环)。
            if p == selected {
                strokeRing(cx: cx, cy: cy, color: .controlAccentColor, lineWidth: 2)
            } else if i == hovered {
                strokeRing(cx: cx, cy: cy, color: NSColor.labelColor.withAlphaComponent(0.4), lineWidth: 1.5)
            }
        }
    }

    private func strokeRing(cx: CGFloat, cy: CGFloat, color: NSColor, lineWidth: CGFloat) {
        let r = dot / 2 + ringGap
        let rect = NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        color.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = index(at: p)
        if idx != hovered { hovered = idx; needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = index(at: p) {
            onPick(palettes[idx])
        }
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

/// NSMenu 里那一行尺寸预设,自绘 —— 跟 `ColorSwatchMenuRow` 同一套交互:画
/// `DefaultNoteSize.allCases` 每个预设一个圆角方块,边长按预设实际尺寸等比缩放
/// (小→中→大,直观表达尺寸关系);hover 的外圈一道**浅色环**、当前命中的预设
/// 外圈一道**强调色环**(选中优先,选中且 hover 时不叠 hover 环)。鼠标移动靠
/// tracking area 追,点中某个方块回调 onPick 并 cancelTracking 收菜单。
///
/// 「命中的预设」= 当前窗口尺寸与某预设在 1pt 容差内相等;用户手动 resize 到非
/// 预设尺寸时则没有方块带强调环。
final class SizePresetMenuRow: NSView {
    private let presets = DefaultNoteSize.allCases
    private let currentSize: NSSize?
    private let onPick: (NSSize) -> Void
    private var hovered: Int?

    private let cell: CGFloat = 22      // 每个预设的方格(命中 + 等距)边长
    private let gap: CGFloat = 14       // 方格之间(边到边)
    private let hPad: CGFloat = 14      // 跟原生菜单项 leading 内缩对齐
    private let vPad: CGFloat = 7
    private let ringGap: CGFloat = 3    // 环跟方格的间隙
    private let corner: CGFloat = 3     // 方格圆角

    init(currentSize: NSSize?, onPick: @escaping (NSSize) -> Void) {
        self.currentSize = currentSize
        self.onPick = onPick
        super.init(frame: .zero)
        let n = CGFloat(presets.count)
        let width = hPad * 2 + n * cell + (n - 1) * gap
        let height = vPad * 2 + cell + (ringGap + 2) * 2   // 上下给环留位置
        frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func centerX(_ i: Int) -> CGFloat {
        hPad + cell / 2 + CGFloat(i) * (cell + gap)
    }

    /// 方格按预设实际尺寸等比缩放:最大的预设占满 cell,其余按宽度比例缩小,
    /// 但留个下限免得最小预设缩成一个点。
    private func glyphSide(_ i: Int) -> CGFloat {
        let maxW = presets.map(\.size.width).max() ?? 1
        let ratio = presets[i].size.width / maxW
        return max(cell * ratio, cell * 0.6)
    }

    private func index(at p: NSPoint) -> Int? {
        let half = (cell + gap) / 2   // 命中区放宽到方格间隙的一半
        for i in presets.indices where abs(p.x - centerX(i)) <= half { return i }
        return nil
    }

    /// 当前窗口尺寸是否落在某预设的 1pt 容差内 —— 命中则该方格带强调环。
    private func isSelected(_ i: Int) -> Bool {
        guard let cur = currentSize else { return false }
        let s = presets[i].size
        return abs(cur.width - s.width) < 1 && abs(cur.height - s.height) < 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let cy = bounds.midY
        for i in presets.indices {
            let cx = centerX(i)
            let side = glyphSide(i)
            let rect = NSRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            let box = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

            // 方格底:浅填充 + 描边,跟颜色行的实心圆点视觉重量相当。
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            box.fill()
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            box.lineWidth = 1
            box.stroke()

            // 选中 = 强调色环;否则 hover = 浅色环。选中优先(选中且 hover 时不叠 hover 环)。
            if isSelected(i) {
                strokeRing(cx: cx, cy: cy, side: side, color: .controlAccentColor, lineWidth: 2)
            } else if i == hovered {
                strokeRing(cx: cx, cy: cy, side: side, color: NSColor.labelColor.withAlphaComponent(0.4), lineWidth: 1.5)
            }
        }
    }

    private func strokeRing(cx: CGFloat, cy: CGFloat, side: CGFloat, color: NSColor, lineWidth: CGFloat) {
        let r = side / 2 + ringGap
        let rect = NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: corner + ringGap, yRadius: corner + ringGap)
        path.lineWidth = lineWidth
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = index(at: p)
        if idx != hovered { hovered = idx; needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = index(at: p) {
            onPick(presets[idx].size)
        }
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
