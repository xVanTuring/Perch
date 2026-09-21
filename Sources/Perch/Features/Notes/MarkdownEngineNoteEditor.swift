import SwiftUI
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex

/// WYSIWYG Markdown 编辑器 —— 全 app 唯一的便签编辑器(浮窗 + 管理窗口详情都用它)。
///
/// 用上游 `swift-markdown-engine`(TextKit 2 backed)做**单一可编辑面**:
/// 边打字边内联渲染标题/粗斜/列表/代码块/图片/数学公式,没有「渲染态 ↔ 源码态」
/// 的切换,也不需要双击进编辑态。早先基于 Textual 的双态编辑器(以及那个实验性
/// 开关)已移除。
///
/// 代码高亮 / LaTeX 用 engine 自带的 turnkey bridge(`HighlighterSwiftBridge`
/// 走 HighlighterSwift,`SwiftMathBridge` 走 SwiftMath),不用我们这边自己写
/// adapter。两个 bridge 都是 class:内部有缓存 + KVO/通知观察者,**必须建一次
/// 全局共享**,否则每次 SwiftUI 重算 `body` 都重建,缓存清空、观察者泄漏。
struct MarkdownEngineNoteEditor: View {
    @Binding var text: String
    /// 稳定的 per-note 文档标识。多个浮窗同时开时,engine 用它把 undo 历史
    /// 和 pending replacement 按文档隔离 —— 必须每个 note 唯一。
    let documentId: String

    /// 跟 Settings → Notes 字号同步;改设置时 engine 通过 updateNSView 自动对齐。
    @AppStorage(SettingsKey.noteFontSize) private var noteFontSize: Int = 14

    /// engine 服务的全局单例。HighlighterSwift 走 JavaScriptCore、SwiftMath 有
    /// 渲染缓存,建一次全 app 复用最划算;两者都自带 light/dark 自动跟随。
    private static let sharedHighlighter = HighlighterSwiftBridge()
    private static let sharedLatex = SwiftMathBridge()

    /// 右键「格式」菜单 + 它的通知名。引擎已不再自带这个菜单,见 NoteFormatMenu。
    private var formatMenu: NoteFormatMenu { NoteFormatMenu(documentId: documentId) }

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(
            syntaxHighlighter: Self.sharedHighlighter,
            latex: Self.sharedLatex,
            bus: formatMenu.bus
        )
        // 列表每级缩进。engine 默认 27.5pt 是给宽编辑器调的;便签窗很窄,
        // 列表项(尤其嵌套/换行 hang)左边空白显得太大。收紧到 16pt。
        config.lists.indentPerLevel = 16
        // 引擎 0.10.0 起 `~~删除线~~` 不再是核心语法,不注册就按普通文本显示。
        // 注册后渲染与旧版(0.5.0 核心内置)完全一致。
        config.extensions = [StrikethroughExtension()]
        return config
    }

    var body: some View {
        let format = formatMenu
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontName: "SF Pro",
            fontSize: CGFloat(noteFontSize),
            documentId: documentId,
            isEditable: true,
            onBuildContextMenu: { menu, _ in format.decorate(menu) }
        )
    }
}
