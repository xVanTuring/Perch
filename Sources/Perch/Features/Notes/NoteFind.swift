import AppKit
import SwiftUI
import Observation
import MarkdownEngine

/// 笔记内查找(⌘F)。匹配和高亮都是引擎做的(`MarkdownEditorBus.findQuery`,在它自己的
/// 显示文本上算),这里只管查找栏的状态和通知的收发。
///
/// `@Observable` 而不是 `ObservableObject`:`MarkdownEngineNoteEditor` 的 body 不读这里
/// 的属性,查找栏里打字就只刷新查找栏,不会让编辑器走 updateNSView(那会扰动正文里的
/// 中文输入法,见 FloatingNoteView 里 HoverToolbar 的注释)。
///
/// 放在 `@State` 里,而 SwiftUI 每次重建 struct 都会临时构造一个再丢弃,所以 `init` 里
/// 不能有副作用,注册都在 `attach(to:)`。
@Observable
final class NoteFindController {
    var isVisible = false
    private(set) var query = ""
    /// nil = 没有可显示的结果:还没搜,或者正文改过、结果已经过期。
    private(set) var matchCount: Int?
    private(set) var currentIndex = 0
    /// 每次 +1 就让查找框抢一次焦点并全选。
    private(set) var focusRequest = 0

    /// 通知名带实例 id 而不是 documentId:同一条便签可以同时开在浮窗和管理窗口,
    /// documentId 分不开这两个编辑器,一边搜索另一边也会被高亮。
    @ObservationIgnored private let instanceID = UUID().uuidString
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var resultsObserver: NSObjectProtocol?
    /// 展开折叠内容之前的选区,见 `revealCurrentMatch(at:)`。nil = 现在没有展开着的。
    @ObservationIgnored private var selectionBeforeReveal: NSRange?

    /// 活着的查找控制器。⌘F 来自主菜单,靠这张表找到 key window 里的那个编辑器。
    private static let live = NSHashTable<NoteFindController>.weakObjects()

    /// key window 里的查找控制器。没有编辑器时为 nil:便签折叠着、管理窗口多选或
    /// 在回收站视图、设置窗口等。
    static var forKeyWindow: NoteFindController? {
        guard let key = NSApp.keyWindow else { return nil }
        return live.allObjects.first { $0.window === key }
    }

    deinit {
        if let resultsObserver { NotificationCenter.default.removeObserver(resultsObserver) }
    }

    private func name(_ kind: String) -> Notification.Name {
        Notification.Name("tech.xvanturing.Perch.noteFind.\(kind).\(instanceID)")
    }

    /// 把这个控制器的通知名写进编辑器的总线。
    func wire(into bus: inout MarkdownEditorBus) {
        bus.findQuery = name("query")
        bus.findResults = name("results")
        bus.findClearHighlights = name("clear")
    }

    fileprivate func attach(to window: NSWindow?) {
        self.window = window
        guard window != nil else { return }
        Self.live.add(self)
        guard resultsObserver == nil else { return }
        resultsObserver = NotificationCenter.default.addObserver(
            forName: name("results"), object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let count = notification.userInfo?["count"] as? Int else { return }
            self.matchCount = count
            self.currentIndex = min(self.currentIndex, max(count - 1, 0))
        }
    }

    // MARK: 动作

    func show() {
        if !isVisible, let editor {
            // 选中了文字就拿它当查询词;跨行的不算,查找框放不下。
            let range = editor.selectedRange()
            let selected = (editor.string as NSString).substring(with: range)
            if !selected.isEmpty, !selected.contains(where: \.isNewline) {
                query = selected
                currentIndex = 0
            }
        }
        isVisible = true
        focusRequest &+= 1
        if !query.isEmpty { search(at: currentIndex) }
    }

    /// 关掉查找栏,光标落到当前匹配上,接着打字就是在那里改。
    func close() {
        guard isVisible else { return }
        let editor = self.editor
        let hasMatch = (matchCount ?? 0) > 0
        let match = hasMatch ? editor.flatMap { self.match(at: currentIndex, in: $0) } : nil
        isVisible = false
        matchCount = nil
        clearHighlights()
        guard let editor else { return }
        if let match {
            selectionBeforeReveal = nil
            editor.setSelectedRange(match)
        } else {
            restoreSelection(in: editor)
        }
        window?.makeFirstResponder(editor)
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        currentIndex = 0
        if text.isEmpty {
            matchCount = nil
            clearHighlights()
            if let editor { restoreSelection(in: editor) }
        } else {
            search(at: 0)
        }
    }

    /// 上一个 / 下一个,到头绕回。结果过期时先按新正文重搜,不跳。
    func step(_ delta: Int) {
        guard !query.isEmpty else { return }
        guard let count = matchCount, count > 0 else {
            search(at: currentIndex)
            return
        }
        search(at: (currentIndex + delta + count) % count)
    }

    /// ⌘G / ⌘⇧G。查找栏关着时先打开,用上一次的查询词。
    func stepOrShow(_ delta: Int) {
        if isVisible { step(delta) } else { show() }
    }

    /// 正文变了:手动打字、同步、MCP 都走这里。高亮已经对不上,撤掉等下一次搜索。
    /// 这里不能直接重搜 —— 引擎每次搜索都会滚到当前匹配,用户在别处打字时视图会被拽走。
    func noteTextChanged() {
        // 记下的位置已经对不上了,而且用户正在改,选区该留在他手里。
        selectionBeforeReveal = nil
        guard isVisible, matchCount != nil else { return }
        matchCount = nil
        clearHighlights()
    }

    private func search(at index: Int) {
        currentIndex = index
        // 要在发查询之前:展开时引擎会重排那一段,冲掉上面已有的高亮。
        revealCurrentMatch(at: index)
        NotificationCenter.default.post(
            name: name("query"), object: nil,
            userInfo: ["query": query, "currentIndex": index]
        )
    }

    private func clearHighlights() {
        NotificationCenter.default.post(name: name("clear"), object: nil)
    }

    // MARK: 编辑器

    /// 引擎的 NSTextView。类型是引擎内部的,只能靠 delegate 认;表格单元格的编辑框
    /// 也是 NSTextView,但 delegate 不是这个。一个窗口里只有一个笔记编辑器。
    private var editor: NSTextView? {
        func search(_ view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, textView.delegate is NativeTextViewCoordinator {
                return textView
            }
            for subview in view.subviews {
                if let hit = search(subview) { return hit }
            }
            return nil
        }
        return window?.contentView.flatMap(search)
    }

    /// 第 `target` 个匹配在显示文本里的位置。引擎不回传位置,只能再数一遍,所以匹配选项
    /// 和步进必须和引擎的 `findMatches` 一致,否则下标对不上。
    private func match(at target: Int, in editor: NSTextView) -> NSRange? {
        let text = editor.string as NSString
        var start = 0
        for index in 0...target {
            guard start < text.length else { return nil }
            let scope = NSRange(location: start, length: text.length - start)
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: scope)
            guard found.location != NSNotFound else { return nil }
            if index == target { return found }
            start = found.location + max(found.length, 1)
        }
        return nil
    }

    /// 当前匹配落在折叠的内容里(链接地址、图片引用)时把它展开,否则这个匹配看不见。
    /// 引擎会展开选区起点所在的那段源码,不要求编辑器有焦点,所以焦点留在查找框里就行。
    /// 换到别的匹配时选区还原,那段再折回去。普通文字里的匹配不动选区,否则每跳一次
    /// `**`、`#` 这些标记都会冒出来。
    ///
    /// **这里必须选中整个匹配,不能只放光标**:空光标落进表格会打开单元格编辑器,把焦点
    /// 从查找框抢走。表格本身不参与展开,选中了也只是原样显示。
    private func revealCurrentMatch(at index: Int) {
        guard let editor else { return }
        restoreSelection(in: editor)
        guard let match = match(at: index, in: editor), isFolded(match, in: editor) else { return }
        selectionBeforeReveal = editor.selectedRange()
        editor.setSelectedRange(match)
    }

    private func restoreSelection(in editor: NSTextView) {
        guard let saved = selectionBeforeReveal else { return }
        selectionBeforeReveal = nil
        editor.setSelectedRange(saved)
    }

    /// 引擎隐藏文字的方式:前景色设成 clear,再缩到极小字号。
    private func isFolded(_ range: NSRange, in editor: NSTextView) -> Bool {
        let color = editor.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
        return (color as? NSColor) == .clear
    }

    // MARK: 高亮颜色

    /// 其他匹配:半透明的文字色,在 7 种便签底色、深浅色下都看得见,也不会和
    /// `==高亮==` 的橙色混淆。引擎默认的黄色放在黄便签上几乎看不见,当前匹配和其他
    /// 匹配也只差透明度。透明度由 `findMatchHighlightAlpha` 单独给。
    static let matchColor = NSColor.labelColor
    static let matchAlpha: CGFloat = 0.18

    /// 当前匹配:实色橙。深色模式下文字是浅色,要压暗才读得清。
    static let currentMatchColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.72, green: 0.38, blue: 0.02, alpha: 1)
            : NSColor(srgbRed: 1.00, green: 0.66, blue: 0.20, alpha: 1)
    }
}

/// 查找栏。关着时不占位置,开着时排在编辑器上方,挤开正文而不是盖住它 —— 盖住的话
/// 滚到顶部的匹配会被挡住。
struct NoteFindBar: View {
    let find: NoteFindController
    @ObservedObject private var loc = LocalizationManager.shared

    private var status: String? {
        guard let count = find.matchCount else { return nil }
        return count == 0 ? L.t(.findNoResults) : "\(find.currentIndex + 1)/\(count)"
    }

    var body: some View {
        if find.isVisible {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                NoteFindField(find: find, query: find.query, focusRequest: find.focusRequest)
                    .frame(minWidth: 60, maxWidth: 240)
                if let status {
                    Text(status)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                }
                button("chevron.up", L.t(.menuFindPrevious)) { find.step(-1) }
                    .disabled(find.query.isEmpty)
                button("chevron.down", L.t(.menuFindNext)) { find.step(1) }
                    .disabled(find.query.isEmpty)
                button("xmark", L.t(.findClose)) { find.close() }
            }
            .padding(.bottom, 4)
        }
    }

    private func button(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 查找框。用 AppKit 而不是 SwiftUI `TextField`:要分辨 Return / ⇧Return / Esc,还要判断
/// 输入法是否正在组字,这些只有字段编辑器(field editor)这一层拿得到。
private struct NoteFindField: NSViewRepresentable {
    let find: NoteFindController
    let query: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(find: find) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = context.coordinator
        // 栏上已经有关闭按钮,框里再来一个 × 容易点错。
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        field.placeholderString = L.t(.findPlaceholder)
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing, field.stringValue != query { field.stringValue = query }

        guard context.coordinator.focusRequest != focusRequest else { return }
        context.coordinator.focusRequest = focusRequest
        // 刚创建时还没进窗口,等这一轮布局结束再抢焦点。
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let find: NoteFindController
        var focusRequest: Int?

        init(find: NoteFindController) {
            self.find = find
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            // 拼音还没上屏时不搜,否则这串字母也算查询词。上屏后这里会再来一次。
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
            find.setQuery(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                find.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                find.close()
                return true
            default:
                return false
            }
        }
    }
}

/// 告诉控制器自己在哪个窗口。没有放进查找栏里,因为查找栏关着时不渲染。
struct NoteFindWindowAnchor: NSViewRepresentable {
    let find: NoteFindController

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.find = find
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        var find: NoteFindController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            find?.attach(to: window)
        }

        /// 它铺在编辑器背后,只用来知道窗口,不参与点击。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
