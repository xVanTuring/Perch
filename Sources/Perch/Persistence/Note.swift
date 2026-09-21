import CoreData
import AppKit

@objc(Note)
public final class Note: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var content: String
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var isPinned: Bool
    @NSManaged public var colorIndex: Int16
    @NSManaged public var frameX: Double
    @NSManaged public var frameY: Double
    @NSManaged public var frameW: Double
    @NSManaged public var frameH: Double
    @NSManaged public var hasSavedFrame: Bool
    @NSManaged public var isTrashed: Bool
    @NSManaged public var trashedAt: Date?
    /// V3 起:归档状态。与 isTrashed 互斥(三态:活跃 / 归档 / 回收站)。
    /// 归档笔记不进菜单栏列表、不开机自动恢复、不进主列表,但永不自动删除。
    @NSManaged public var isArchived: Bool
    /// V3 起:归档时间。nil = 未归档。仅做展示/排序与跨设备同步,不驱动任何
    /// 自动清理(归档没有过期一说)。
    @NSManaged public var archivedAt: Date?
    @NSManaged public var isCollapsed: Bool
    /// V4 起:悬浮窗显示序号(stack 层叠次序 / tile 排列次序)。0 = 未排序。
    /// 由 `FloatingNotesRegistry` 在重排后写入,启动 restore 按它升序恢复,
    /// 使顺序跨重启保持。仅对当前 pinned 的窗有意义,关掉后值留着不清。
    @NSManaged public var displayOrder: Int32
    /// V2 起:一次性提醒时间。nil = 未设。
    /// 设/清值后,代码层调 `ReminderScheduler` 同步 UN 调度;
    /// 这个字段只是做持久化记忆(用于 UI 显示和跨设备 CloudKit 同步)。
    @NSManaged public var reminderDate: Date?
    @NSManaged public var group: NoteGroup?
}

extension Note {
    var savedFrame: NSRect? {
        guard hasSavedFrame else { return nil }
        return NSRect(x: frameX, y: frameY, width: frameW, height: frameH)
    }

    func setSavedFrame(_ frame: NSRect) {
        frameX = Double(frame.origin.x)
        frameY = Double(frame.origin.y)
        frameW = Double(frame.size.width)
        frameH = Double(frame.size.height)
        hasSavedFrame = true
    }
}

extension Note {
    /// 默认 fetch:**只取活跃笔记**(未进回收站 **且** 未归档)。所有
    /// 列表/管理/菜单都用这个。想看回收站走 `trashedFetchRequest`,
    /// 想看归档走 `archivedFetchRequest`。
    static func sortedFetchRequest() -> NSFetchRequest<Note> {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(
            format: "isTrashed == %@ AND isArchived == %@",
            NSNumber(value: false), NSNumber(value: false)
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        return request
    }

    /// 回收站列表用。最近丢进去的排在最前。
    static func trashedFetchRequest() -> NSFetchRequest<Note> {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(format: "isTrashed == %@", NSNumber(value: true))
        request.sortDescriptors = [
            NSSortDescriptor(key: "trashedAt", ascending: false)
        ]
        return request
    }

    /// 归档列表用。`isArchived == true` 且不在回收站(回收站优先级更高:
    /// 把归档笔记移入回收站时会清掉 isArchived)。最近归档的排在最前;
    /// archivedAt 缺失的(理论上不该出现)排到末尾。
    static func archivedFetchRequest() -> NSFetchRequest<Note> {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(
            format: "isArchived == %@ AND isTrashed == %@",
            NSNumber(value: true), NSNumber(value: false)
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "archivedAt", ascending: false)
        ]
        return request
    }

    @discardableResult
    static func create(in context: NSManagedObjectContext, content: String = "") -> Note {
        let note = Note(context: context)
        note.id = UUID()
        note.content = content
        let now = Date()
        note.createdAt = now
        note.updatedAt = now
        note.isPinned = false
        // 默认颜色读 Settings(用户在 Notes tab 选);未设过时 UserDefaults.integer
        // 返回 0 = StickyPalette.yellow,等同旧行为。选「随机」时存的是哨兵值,
        // resolveDefault 在这里每张现摇一个颜色。
        let storedDefault = UserDefaults.standard.integer(forKey: SettingsKey.defaultColorIndex)
        note.colorIndex = StickyPalette.resolveDefault(storedDefault).rawValue
        return note
    }

    /// 第一非空行作为标题,剥掉常见 markdown 标记 —— `#` 标题、`>` 引用、列表
     /// 前缀、加粗/斜体/删除线/行内代码、链接和图片语法都还原成纯文本。便于在
    /// 标题条/菜单/管理列表里展示干净的标题。
    var displayTitle: String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let raw = firstLine else { return "New note" }
        let stripped = Self.stripMarkdownMarkers(raw).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? "New note" : stripped
    }

    /// 剥 markdown 用的纯文本:首行没有内容时为空。比 `displayTitle` 更干净
    /// (不返回 "New note" 这种占位符)。浮窗顶部标题条没内容就完全不显示,
    /// 用这个版本判断是否要渲染。
    var cleanTitle: String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let raw = firstLine else { return "" }
        return Self.stripMarkdownMarkers(raw).trimmingCharacters(in: .whitespaces)
    }

    /// 笔记里 markdown 任务项的完成进度。`taskProgress` 仅在 total > 0 时返回,
    /// 所以 `fraction` 的 total==0 兜底理论上用不到。`isComplete` 给「全部勾完」
    /// 时画整圆用。
    struct TaskProgress: Equatable {
        var completed: Int
        var total: Int
        /// 0...1 的完成比例。
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
        /// 至少有一项且全部勾完。
        var isComplete: Bool { total > 0 && completed >= total }
    }

    /// 扫描内容里的 markdown 任务项(`- [ ]` / `* [x]` / `+ [X]`,允许行首缩进),
    /// 统计总数与已勾选数。没有任何任务项时返回 nil —— 调用方据此决定不画进度饼。
    /// 浮窗标题条与管理列表行都派生自这里。
    var taskProgress: TaskProgress? {
        var completed = 0
        var total = 0
        for line in content.components(separatedBy: .newlines) {
            guard let done = Self.taskCheckState(in: line) else { continue }
            total += 1
            if done { completed += 1 }
        }
        guard total > 0 else { return nil }
        return TaskProgress(completed: completed, total: total)
    }

    /// 单行是不是任务项:是 → 返回是否已勾选(true=完成),否 → nil。容忍行首缩进
    /// 与 `-`/`*`/`+` 三种 bullet,勾选记号大小写不敏感。手写扫描而非正则 ——
    /// 这个判断在每次标题条/行渲染时都会跑,免去 NSRegularExpression 的开销。
    private static func taskCheckState(in line: String) -> Bool? {
        var s = Substring(line)
        func dropSpaces() { while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() } }
        dropSpaces()
        guard let bullet = s.first, bullet == "-" || bullet == "*" || bullet == "+" else { return nil }
        s = s.dropFirst()
        // bullet 后必须至少一个空白,否则 `-[x]` 这类不算(也排除普通连字符行)。
        guard let sp = s.first, sp == " " || sp == "\t" else { return nil }
        dropSpaces()
        guard s.first == "[" else { return nil }
        s = s.dropFirst()
        guard let mark = s.first else { return nil }
        s = s.dropFirst()
        guard s.first == "]" else { return nil }
        switch mark {
        case " ":      return false
        case "x", "X": return true
        default:       return nil
        }
    }

    private static func stripMarkdownMarkers(_ input: String) -> String {
        var s = input
        // 行首结构标记:#+ heading、>+ blockquote、`-`/`*`/`+` 列表、有序列表
        // 数字、taskmark `[ ]`/`[x]`。每一类只匹配开头,顺序无所谓,匹配不到就跳过。
        s = s.replacingOccurrences(of: "^#+\\s*",      with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^>+\\s*",      with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[-*+]\\s+",   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\d+\\.\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\[[ xX]\\]\\s*", with: "", options: .regularExpression)
        // 图片嵌入 `![[名称|UUID|宽度]]` 只留名称(UUID 和宽度是内部信息)。
        s = s.replacingOccurrences(of: "!\\[\\[([^\\]|]*)[^\\]]*\\]\\]", with: "$1", options: .regularExpression)
        // 图片 / 链接:`![alt](url)` 和 `[text](url)` 各保留括号里的可见文本。
        // 图片必须先于链接,因为 `![...](...)` 也匹配链接 pattern。
        s = s.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        // 行内强调/代码:`**bold**`、`*italic*`、`__bold__`、`_italic_`、
        // `~~strike~~`、`==highlight==`、`` `code` ``。粗体先于斜体,免得 `**` 被吃成两次 `*`。
        s = s.replacingOccurrences(of: "\\*\\*([^\\*]+)\\*\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "__([^_]+)__",           with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*([^\\*]+)\\*",       with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_([^_]+)_",             with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "~~([^~]+)~~",           with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "==([^=]+)==",           with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "`([^`]+)`",             with: "$1", options: .regularExpression)
        return s
    }
}

// MARK: - Task extraction & write-back (All Tasks 聚合视图用)

extension Note {
    /// 从一条笔记里解析出的单个任务行,带足够信息支持层级展示与回写。
    /// `lineIndex` + `rawLine` 一起做回写定位(下标优先,失配时退回按整行
    /// 文本匹配);`indent` 建父子树。仅 All Tasks 聚合视图消费 —— 浮窗/管理
    /// 列表的进度饼仍走轻量的 `taskProgress`。
    struct ParsedTask: Equatable {
        var lineIndex: Int
        var indent: Int
        var rawLine: String
        var label: String
        var isDone: Bool
    }

    /// 按文档顺序扫出本笔记所有任务行(平铺)。无任务返回 []。行切分用 "\n"
    /// (跟 `toggledTaskContent` 一致,保证 `lineIndex` 在解析与回写两侧对齐)。
    var parsedTasks: [ParsedTask] {
        let lines = content.components(separatedBy: "\n")
        var out: [ParsedTask] = []
        for (i, line) in lines.enumerated() {
            guard let p = Self.scanTask(line) else { continue }
            out.append(ParsedTask(
                lineIndex: i, indent: p.indent, rawLine: line,
                label: p.label, isDone: p.isDone
            ))
        }
        return out
    }

    /// 翻转某行任务的勾选态,返回新的整段 content;定位失败返回 nil(调用方据此
    /// 不写库)。优先用 `lineIndex`(前提是该行仍等于 `expectedRaw`),失配则全局
    /// 找等于 `expectedRaw` 的行 —— 应对回写前笔记在别处被编辑导致的行号漂移。
    static func toggledTaskContent(_ content: String, lineIndex: Int,
                                   expectedRaw: String, setDone: Bool) -> String? {
        var lines = content.components(separatedBy: "\n")
        let targetIndex: Int? =
            (lines.indices.contains(lineIndex) && lines[lineIndex] == expectedRaw)
            ? lineIndex
            : lines.firstIndex(of: expectedRaw)
        guard let idx = targetIndex,
              let flipped = toggledLine(lines[idx], setDone: setDone) else { return nil }
        lines[idx] = flipped
        return lines.joined(separator: "\n")
    }

    /// 扫一行:是任务项 → (缩进列数, 是否勾选, 勾选记号 String.Index, 标签);否则
    /// nil。缩进按 space=1、tab=4 归一,只用于建层级时的单调度量。容忍行首缩进、
    /// `-`/`*`/`+` 三种 bullet,勾选记号大小写不敏感 —— 跟 `taskCheckState` 同口径。
    private static func scanTask(_ line: String)
        -> (indent: Int, isDone: Bool, markIndex: String.Index, label: String)? {
        var idx = line.startIndex
        var indent = 0
        while idx < line.endIndex {
            let c = line[idx]
            if c == " " { indent += 1 }
            else if c == "\t" { indent += 4 }
            else { break }
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let bullet = line[idx]
        guard bullet == "-" || bullet == "*" || bullet == "+" else { return nil }
        idx = line.index(after: idx)
        // bullet 后必须至少一个空白,否则 `-[x]` 不算(也排除普通连字符行)。
        guard idx < line.endIndex, line[idx] == " " || line[idx] == "\t" else { return nil }
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == "[" else { return nil }
        idx = line.index(after: idx)
        guard idx < line.endIndex else { return nil }
        let markIndex = idx
        let mark = line[markIndex]
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == "]" else { return nil }
        let isDone: Bool
        switch mark {
        case " ":      isDone = false
        case "x", "X": isDone = true
        default:       return nil
        }
        let afterClose = line.index(after: idx)
        let label = String(line[afterClose...]).trimmingCharacters(in: .whitespaces)
        return (indent, isDone, markIndex, label)
    }

    /// 翻转单行任务的勾选记号,缩进/bullet/标签原样保留。非任务行返回 nil。
    private static func toggledLine(_ line: String, setDone: Bool) -> String? {
        guard let p = scanTask(line) else { return nil }
        var out = line
        out.replaceSubrange(p.markIndex...p.markIndex, with: setDone ? "x" : " ")
        return out
    }
}
