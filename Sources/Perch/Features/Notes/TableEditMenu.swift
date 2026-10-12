import AppKit
import MarkdownEngine

/// 表格单元格编辑器的右键菜单:行 / 列的结构操作 + 列对齐。
///
/// 引擎 0.14.0 起不自带这个菜单。之前那版把标题放在引擎模块内的资源包里,而模块的
/// 资源包是按**宿主 App** 的本地化解析的 —— Perch.app 没有任何 `.lproj`,那套标题
/// 永远解析成英文,跟不了 Perch 自己的运行时语言。现在引擎在单元格里右键时把
/// 「编辑器自己的菜单 + `TableCellMenuContext`」交给 `onTableCellContextMenu`,
/// 标题和语言由我们出。
///
/// 可不可执行照引擎给的算(`context.isEnabled`:表头不能删 / 上移,末列不能删 /
/// 右移),不在这边重述规则;列对齐三项永远可选,当前那项打勾。
enum TableEditMenu {
    /// 三组(行 / 列 / 对齐)插在编辑器自己的菜单最上面 —— 单元格里的剪切 / 复制 /
    /// 粘贴接在下面。
    static func decorate(_ menu: NSMenu, context: TableCellMenuContext) -> NSMenu {
        let groups: [[TableEditOperation]] = [
            [.insertRowAbove, .insertRowBelow, .moveRowUp, .moveRowDown, .deleteRow],
            [.insertColumnLeft, .insertColumnRight, .moveColumnLeft, .moveColumnRight, .deleteColumn],
            [.alignLeft, .alignCenter, .alignRight],
        ]
        var items: [NSMenuItem] = []
        for group in groups {
            if !items.isEmpty { items.append(.separator()) }
            items.append(contentsOf: group.map { item($0, context: context) })
        }
        // 倒着插,最终顺序就是 items 的顺序:表格项在最上面,接一条分隔线,再下面
        // 才是编辑器自己的菜单项。
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    private static func item(_ operation: TableEditOperation, context: TableCellMenuContext) -> NSMenuItem {
        let entry = ActionMenuItem(title: title(for: operation)) { context.perform(operation) }
        entry.isEnabled = context.isEnabled(operation)
        entry.state = isChecked(operation, alignment: context.alignment) ? .on : .off
        return entry
    }

    private static func title(for operation: TableEditOperation) -> String {
        switch operation {
        case .insertRowAbove:    return L.t(.tableInsertRowAbove)
        case .insertRowBelow:    return L.t(.tableInsertRowBelow)
        case .moveRowUp:         return L.t(.tableMoveRowUp)
        case .moveRowDown:       return L.t(.tableMoveRowDown)
        case .deleteRow:         return L.t(.tableDeleteRow)
        case .insertColumnLeft:  return L.t(.tableInsertColumnLeft)
        case .insertColumnRight: return L.t(.tableInsertColumnRight)
        case .moveColumnLeft:    return L.t(.tableMoveColumnLeft)
        case .moveColumnRight:   return L.t(.tableMoveColumnRight)
        case .deleteColumn:      return L.t(.tableDeleteColumn)
        case .alignLeft:         return L.t(.tableAlignLeft)
        case .alignCenter:       return L.t(.tableAlignCenter)
        case .alignRight:        return L.t(.tableAlignRight)
        }
    }

    /// 列对齐三项里哪一项要打勾。
    private static func isChecked(_ operation: TableEditOperation, alignment: TableEditAlignment) -> Bool {
        switch operation {
        case .alignLeft:   return alignment == .left
        case .alignCenter: return alignment == .center
        case .alignRight:  return alignment == .right
        default:           return false
        }
    }
}
