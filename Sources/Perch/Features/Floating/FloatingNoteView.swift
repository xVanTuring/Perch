import AppKit
import SwiftUI
import CoreData

struct FloatingNoteView: View {
    @ObservedObject var note: Note
    @ObservedObject var foldState: FoldState
    @Environment(\.managedObjectContext) private var context
    /// 当前窗口是否处于 key 状态:.key = 活跃,其它都按非活跃处理(渲染毛玻璃)。
    /// SwiftUI 自动跟踪这个 env value,key 状态变化会触发 body 重渲染,
    /// 拿到自由的「失焦动画」,不用手动监听 NSWindow 通知。
    @Environment(\.controlActiveState) private var controlActiveState
    /// 用户在设置面板里可关掉这个效果;@AppStorage 跨视图自动同步。
    @AppStorage(SettingsKey.fadeWhenInactive) private var fadeWhenInactive: Bool = true
    /// 双击标题切换折叠的总开关。默认 false —— 用户在 Settings 里自己开。
    /// 关掉时标题条命中层照常渲染(负责拖窗),只是双击不再触发折叠。
    @AppStorage(SettingsKey.doubleClickTitleToCollapse) private var doubleClickToCollapseEnabled: Bool = false
    @ObservedObject private var loc = LocalizationManager.shared
    let onClose: () -> Void
    let onDelete: () -> Void
    let onArchive: () -> Void
    let onToggleCollapse: () -> Void
    let onPickSize: (NSSize) -> Void

    private var palette: StickyPalette {
        guard !note.isDeleted, note.managedObjectContext != nil else { return .yellow }
        return StickyPalette.from(index: note.colorIndex)
    }

    /// 尺寸预设行的「当前尺寸」高亮依据:存档的展开 W/H(折叠态也存的是展开尺寸)。
    /// 没存过就 nil,尺寸行不高亮任何预设。
    private var currentSize: NSSize? {
        guard !note.isDeleted, note.managedObjectContext != nil, note.hasSavedFrame else { return nil }
        return NSSize(width: note.frameW, height: note.frameH)
    }

    /// 设置开了 fade,且当前窗确实失焦了,才进入毛玻璃态。
    /// fade 关掉时永远渲染实色,跟"经典"sticky 一致。
    private var isInactive: Bool {
        fadeWhenInactive && controlActiveState != .key
    }

    var body: some View {
        // 删除流程里浮窗已 orderOut 但 SwiftUI 视图树尚未释放;@ObservedObject
        // 会在 context.delete 那一刻被通知去重渲染。提前 guard 就不会访问已 fault
        // 的 note 属性 → 跳过 CoreData 的 debug breakpoint。
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            // 动画期间把卡片高度绑到 foldState.currentHeight(逐帧显式驱动 → 每帧
            // 重绘);非动画时不约束,正常填满 host。
            // **clipShape 必须在 currentHeight frame 之后**:这样圆角裁剪发生在
            // currentHeight 这个高度上,而不是 mainBody 内部 ZStack 的自然高度(被
            // 冻结的编辑器撑到展开高度)—— 否则圆角落在展开高度处,可视底边只是中段
            // 的直边 = 底部直角。
            mainBody
                .frame(height: foldState.animating ? foldState.currentHeight : nil, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var mainBody: some View {
        // 顶部 strip 高度:折叠 / 展开两态都用 collapsedHeight(32pt)。
        // 这样折叠时标题文字垂直位置不跳;同时编辑器顶部 spacer 也用这个值,
        // 跟标题条对齐。
        let stripHeight = FloatingNoteWindowController.collapsedHeight

        return ZStack(alignment: .top) {
            // 卡片本体:活跃时实色填充,失焦时切到 .regularMaterial(NSVisualEffectView)
            // 毛玻璃 + 调色板色当 tint(opacity 0.45 让材质透出来)。
            // 窗体本身透明,系统阴影自动跟圆角形状走。
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.backgroundFill)
                    .opacity(isInactive ? 0.45 : 1.0)
            }
            .animation(.easeInOut(duration: 0.18), value: isInactive)

            // 折叠态(静止)隐藏编辑器 —— 整个 NSTextView/SwiftUI 子树移除,光标失焦
            // 无副作用。但**动画期间必须挂着**:折叠的「从下往上裁掉」/ 展开的「自上
            // 而下显出」靠的就是编辑器以固定展开高度存在、被窗口裁剪。动画结束 isCollapsed
            // 仍 true 时再卸载(此时窗口已是 32pt,编辑器早被裁没,卸载无可见跳变)。
            if foldState.animating || !note.isCollapsed {
                VStack(spacing: 0) {
                    Spacer().frame(height: FloatingNoteWindowController.collapsedHeight)
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
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
                // 动画期间把编辑器区域钉死在展开高度、顶端对齐 —— 不随窗口收缩压扁
                // 文字;超出当前窗口的部分由外层 clipShape(= 窗口圆角)裁掉,于是
                // 折叠 = 文字从底部被裁没、展开 = 自上而下显出。非动画时填满 host。
                // 卡片背景与圆角始终跟随 host bounds(下方 ZStack 的 clipShape),
                // 所以动画全程圆角 + 阴影都正确。
                .frame(height: foldState.animating ? foldState.expandedHeight : nil, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
            }

            // 顶部标题条:始终可见,跟着 note.content 自动派生(`cleanTitle` 剥过
            // markdown 标记,`# 标题`、`**bold**`、列表前缀等都还原成纯文本)。
            // 跟 hover toolbar 在同一个顶部 strip,左右 padding 让出 ×/⋯ 按钮的位置,
            // hover 时三者并存不打架。展开态空内容直接不显示;折叠态用 "Empty Note"
            // 占位,免得用户折叠后只剩一条空 bar 不知道是啥。
            NoteTitleBar(
                text: note.cleanTitle,
                fallbackWhenEmpty: note.isCollapsed ? L.t(.emptyNote) : nil,
                stripHeight: stripHeight,
                taskProgress: note.taskProgress
            )

            // 拖窗 + 双击命中层。**位于 HoverToolbar 之下** —— × / ⋯ 按钮要先吃到点击。
            // 高度 = stripHeight,跟编辑器上方的 spacer 等高,不挡编辑器 mouseDown;
            // 折叠态整条 bar 都能拖 / 双击展开。**始终渲染**:它是标题条上唯一能拖窗
            // 的原生 view(NSHostingView 吞 mouseDown,isMovableByWindowBackground
            // 管不到)。设置关掉时只是不传双击回调。
            VStack {
                TitleDoubleClickHit(onDoubleClick: doubleClickToCollapseEnabled ? onToggleCollapse : nil)
                    .frame(height: stripHeight)
                Spacer(minLength: 0)
            }

            // 顶部 hover 工具条独立成一个 struct,**自己拥有 hovering @State** ——
            // hover 状态切换只让这个子 struct 重渲染,不会沿父链冒泡触发整个
            // FloatingNoteView 重渲染。否则任何鼠标进出窗都会让 MarkdownEngineNoteEditor
            // 的 NSTextView updateNSView 被调,扰动中文 IME 的 marked text(拼音)。
            HoverToolbar(
                palette: palette,
                isCollapsed: note.isCollapsed,
                stripHeight: stripHeight,
                reminderDate: note.reminderDate,
                currentSize: currentSize,
                onClose: onClose,
                onPickColor: { picked in
                    note.colorIndex = picked.rawValue
                    note.updatedAt = Date()
                    try? context.save()
                },
                onPickSize: onPickSize,
                onToggleCollapse: onToggleCollapse,
                onDelete: onDelete,
                onArchive: onArchive,
                onSetReminder: { date in setReminder(date) },
                onClearReminder: { clearReminder() }
            )
        }
        // clipShape 不在这里 —— 移到 body 里、currentHeight frame 之后,确保圆角
        // 落在当前帧高度上而不是被冻结编辑器撑出的展开高度上(见 body 注释)。
    }

    /// 设/改提醒:先 async 申请权限,授权后写库 + 调度 UN。被拒弹引导对话框。
    /// 早于当前时间的 date 也兜一层 alert(理论上 DatePicker 限制了,保险起见)。
    private func setReminder(_ date: Date) {
        guard date > Date() else {
            showAlert(title: L.t(.reminderInvalidTimeTitle), body: L.t(.reminderInvalidTimeBody))
            return
        }
        Task {
            let granted = await ReminderScheduler.shared.requestAuthorizationIfNeeded()
            await MainActor.run {
                guard !note.isDeleted, note.managedObjectContext != nil else { return }
                if !granted {
                    showPermissionDeniedAlert()
                    return
                }
                note.reminderDate = date
                try? context.save()
                ReminderScheduler.shared.schedule(
                    noteID: note.id,
                    title: note.cleanTitle.isEmpty ? L.t(.appName) : note.cleanTitle,
                    body: previewBody(note.content),
                    fireAt: date
                )
            }
        }
    }

    private func clearReminder() {
        ReminderScheduler.shared.cancel(noteID: note.id)
        note.reminderDate = nil
        try? context.save()
    }

    /// 通知 body 取笔记前 N 字符,去掉首行(已经是 title)。空内容用占位符。
    private func previewBody(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // 跳过首行(给 title 用了),取剩下的拼成一段,截到 200 字符以内,
        // 系统通知本身也会再截一次。
        let body = lines.dropFirst().joined(separator: " ")
        if body.isEmpty { return "" }
        return String(body.prefix(200))
    }

    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = L.t(.reminderPermissionDeniedTitle)
        alert.informativeText = L.t(.reminderPermissionDeniedBody)
        alert.addButton(withTitle: L.t(.permissionOpenSettings))
        alert.addButton(withTitle: L.t(.cancel))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ReminderScheduler.openNotificationSettings()
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L.t(.ok))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
