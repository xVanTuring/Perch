import AppKit
import MarkdownEngine

/// 便签编辑器的右键「格式」菜单:Format(加粗/斜体)、Heading(H1–H3)、
/// Lists(无序/有序)。
///
/// 引擎 0.8.0 起不再自带这个菜单,只保留格式化动作,由使用方经
/// `onBuildContextMenu` 建菜单、再通过 `MarkdownEditorBus` 的通知触发动作。
///
/// ⚠️ 引擎对总线通知是 `object: nil` 的全局订阅,处理函数也不检查「是不是
/// 当前编辑器」。如果所有编辑器共用同一组通知名,点一次「加粗」会让所有打开
/// 的便签窗口同时加粗。所以通知名里带上 documentId,每个编辑器只订阅、只响应
/// 属于自己的那一组。
struct NoteFormatMenu {
    let documentId: String

    private enum Action: String {
        case bold, italic, heading, bullet, numbered
    }

    private func name(_ action: Action) -> Notification.Name {
        Notification.Name("tech.xvanturing.Perch.editorFormat.\(action.rawValue).\(documentId)")
    }

    /// 交给 `MarkdownEditorServices.bus`,让本文档的编辑器订阅这一组通知名。
    var bus: MarkdownEditorBus {
        MarkdownEditorBus(
            applyBoldRequest: name(.bold),
            applyItalicRequest: name(.italic),
            applyHeadingRequest: name(.heading),
            applyUnorderedListRequest: name(.bullet),
            applyOrderedListRequest: name(.numbered)
        )
    }

    /// 把 Format / Heading / Lists 插到系统右键菜单里剪贴板那一组
    /// (Cut / Copy / Paste / Paste and Match Style)之后。
    /// 没有 Paste(只读文本)时不加 —— 格式化对只读内容没有意义。
    func decorate(_ menu: NSMenu) -> NSMenu {
        guard let pasteIndex = menu.items.firstIndex(where: {
            $0.action == #selector(NSText.paste(_:))
        }) else { return menu }

        let items: [NSMenuItem] = [
            .separator(),
            submenu(L.t(.editorFormat), [
                item(L.t(.editorBold), .bold),
                item(L.t(.editorItalic), .italic),
            ]),
            submenu(L.t(.editorHeading), (1...3).map { level in
                item("H\(level)", .heading, userInfo: ["level": level])
            }),
            submenu(L.t(.editorLists), [
                item(L.t(.editorBullet), .bullet),
                item(L.t(.editorNumbered), .numbered),
            ]),
        ]
        // 剪贴板这一组以 Paste 之后的下一条分隔线结束;插在这条线之前,
        // 不要把 Paste 和 Paste and Match Style 拆开。
        let groupEnd = menu.items[(pasteIndex + 1)...].firstIndex(where: \.isSeparatorItem)
            ?? menu.items.count
        for (offset, entry) in items.enumerated() {
            menu.insertItem(entry, at: groupEnd + offset)
        }
        return menu
    }

    private func item(
        _ title: String,
        _ action: Action,
        userInfo: [AnyHashable: Any]? = nil
    ) -> NSMenuItem {
        let notificationName = name(action)
        return ActionMenuItem(title: title) {
            NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
        }
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }
}

/// 带闭包的菜单项。`NSMenuItem.target` 是弱引用,让菜单项自己当自己的
/// target,生命周期就跟着菜单走,不需要另外持有。
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}
