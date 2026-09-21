import Foundation
import AppKit
import CoreData
import UniformTypeIdentifiers

/// 便签导入 / 导出的逻辑核心。每个 entry point 都是「拿一个
/// `NSManagedObjectContext` + 一个 user-presented panel」的形式,UI 层(Manager
/// toolbar / 右键菜单)只负责弹 panel 和把结果传过来。
///
/// **格式选择:**
/// - 单条导出:`.md` 文件,内容直接写 note.content。就是标准 Markdown,
///   任意编辑器都能开。
/// - 多条 / 整库 Markdown 导出:一个文件夹,里面每条便签一个 `.md`,文件名用
///   displayTitle(经过 Markdown 标记剥离 + 文件名安全字符 sanitize)。
/// - 整库导出 / 导入:单个独立 `.sqlite`。用当前 schema **新建一个干净 store**
///   把全部 notes + groups 拷进去 —— 不带 CloudKit 系统表 / persistent history,
///   且 `journal_mode=DELETE` 不产生 -wal/-shm 边车,保证是单文件可携带。
///   导入侧反过来:把选中的 .sqlite 拷到 temp,允许 lightweight migration
///   兼容旧 schema 版本导出的文件,再按 UUID 去重 merge 进当前库。
///
/// **导入去重:** 按 UUID。已有相同 id 的 note/group 跳过(导入不覆盖现有数据)。
/// CloudKit 模式下,即使没跳过,CloudKitDeduplicator 也会兜底合并。
///
/// 旧版的 JSON `.noticky-backup.json` 整库备份已移除,改用 sqlite —— 单一机制,
/// 与本地 store 同构,导入侧直接走 Core Data lightweight migration 兼容旧版本。
enum NoteIO {

    // MARK: - 单条 / 多条 / 整库 Markdown 导出 --------------------------------

    /// 单条便签导出成 .md 文件。返回写入的 URL,失败 nil。
    @discardableResult
    static func exportNote(_ note: Note, to url: URL) -> URL? {
        do {
            try note.content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("Perch: exportNote failed: %@", "\(error)")
            return nil
        }
    }

    /// 多条便签导出到一个文件夹。返回成功写入的 URL 列表。
    /// 文件名冲突时附加 `-1` `-2` …。
    @discardableResult
    static func exportNotes(_ notes: [Note], toFolder folder: URL) -> [URL] {
        var written: [URL] = []
        for note in notes {
            let baseName = sanitizedFilename(note.displayTitle)
            var url = folder.appendingPathComponent(baseName).appendingPathExtension("md")
            var n = 1
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(baseName)-\(n)").appendingPathExtension("md")
                n += 1
            }
            if let written_ = exportNote(note, to: url) { written.append(written_) }
        }
        return written
    }

    /// 整库导出为 Markdown:把库里**全部**便签(含归档 / 回收站,做一次完整快照)
    /// 写进选定文件夹,每条一个 `.md`。返回写出的文件数。
    @discardableResult
    static func exportAllMarkdown(in context: NSManagedObjectContext, toFolder folder: URL) -> Int {
        let req = NSFetchRequest<Note>(entityName: "Note")
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let notes = (try? context.fetch(req)) ?? []
        return exportNotes(notes, toFolder: folder).count
    }

    // MARK: - Import 单 / 多文件(md/txt → 新便签)----------------------------

    /// 把多个 .md / .txt 文件作为新便签导入,每文件一条。返回成功导入的条数。
    /// **不**触碰 group —— 导入的笔记进 Ungrouped,用户后续手动分组。
    @discardableResult
    static func importFiles(_ urls: [URL], into context: NSManagedObjectContext) -> Int {
        var count = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            _ = Note.create(in: context, content: text)
            count += 1
        }
        if count > 0 { try? context.save() }
        return count
    }

    // MARK: - 整库 SQLite 导出 ------------------------------------------------

    /// 把整库导出成一个**独立的、干净的** sqlite 到 `url`。
    ///
    /// 实现:用当前 schema(`CoreDataSchema.currentModel()`)新建一个本地
    /// `NSPersistentContainer`(**非** CloudKit、不开 history tracking、
    /// `journal_mode=DELETE` 不产生 -wal/-shm),把全部 NoteGroup + Note 按 UUID
    /// 关系完整拷进去再 save。这样导出的文件:
    ///   - 不含 CloudKit `Z_*`/导出系统表 与 persistent history,体积小、可携带;
    ///   - 是单文件(无边车),NSSavePanel 返回的单个 URL 即完整结果;
    ///   - schema = 当前版本,导入侧无需特殊处理(旧版本文件靠导入侧 migration)。
    ///
    /// 回收站 / 归档的便签也包含进去 —— 整库导出是一次完整快照。
    /// 返回导出的便签数;失败返回 nil。
    static func exportAllSQLite(from sourceContext: NSManagedObjectContext, to url: URL) -> Int? {
        // NSSavePanel 已让用户确认覆盖,但它不会真的删旧文件;Core Data 往一个
        // 已存在的非空 sqlite 路径 addPersistentStore 会失败,先清掉三件套。
        removeStoreFiles(at: url)

        // 便签图片(V5)默认走外部二进制存储:大的图片数据放在 sqlite 旁边的隐藏目录
        // (`.<库名>_SUPPORT`),那样导出就不再是「单文件」—— 只拷走 .sqlite 会丢图。
        // 导出用的 model 关掉外部存储,让图片数据直接进 sqlite,文件保持自包含。
        let exportModel = CoreDataSchema.currentModel()
        exportModel.entitiesByName["NoteImage"]?.attributesByName["data"]?
            .allowsExternalBinaryDataStorage = false
        let container = NSPersistentContainer(name: "PerchExport", managedObjectModel: exportModel)
        guard let desc = container.persistentStoreDescriptions.first else { return nil }
        desc.url = url
        desc.type = NSSQLiteStoreType
        desc.shouldAddStoreAsynchronously = false
        // 单文件:DELETE 模式不留 -wal/-shm。导出文件就是「最终态」,不需要 WAL。
        desc.setOption(["journal_mode": "DELETE"] as NSDictionary, forKey: NSSQLitePragmasOption)
        // 导出文件不需要 history / remote-change(那是同步/多 context 合并用的)。
        desc.setOption(false as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            NSLog("Perch: exportAllSQLite store load failed: %@", "\(loadError)")
            return nil
        }

        let dest = container.viewContext

        // 源数据:全部 group + 全部 note(不过滤 trashed/archived,完整快照)。
        let groupReq = NoteGroup.sortedFetchRequest()
        let groups = (try? sourceContext.fetch(groupReq)) ?? []
        let noteReq = NSFetchRequest<Note>(entityName: "Note")
        noteReq.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let notes = (try? sourceContext.fetch(noteReq)) ?? []

        var groupMap: [UUID: NoteGroup] = [:]
        for g in groups {
            let copy = NoteGroup(context: dest)
            copy.id = g.id
            copy.name = g.name
            copy.createdAt = g.createdAt
            copy.sortOrder = g.sortOrder
            groupMap[g.id] = copy
        }
        for n in notes {
            let copy = Note(context: dest)
            copyNoteFields(from: n, to: copy)
            if let gid = n.group?.id, let g = groupMap[gid] { copy.group = g }
        }
        // 便签图片(V5):正文里只有 `![[名称|UUID]]` 引用,图片数据在 NoteImage 里,
        // 不一起带上的话备份恢复后所有图片都找不到。
        let images = (try? sourceContext.fetch(NSFetchRequest<NoteImage>(entityName: "NoteImage"))) ?? []
        for image in images { copyImage(from: image, to: NoteImage(context: dest)) }

        do {
            try dest.save()
            return notes.count
        } catch {
            NSLog("Perch: exportAllSQLite save failed: %@", "\(error)")
            return nil
        }
    }

    // MARK: - 整库 SQLite 导入 ------------------------------------------------

    /// 从一个 Perch sqlite 导入。**已存在相同 UUID 的不导入**,避免覆盖用户当前
    /// 数据。返回 (importedNotes, importedGroups, pinned);文件无法读取返回 nil。
    /// `pinned` = 这次新导入、且 isPinned 且未删未归档的 Note —— 调用方据此 spawn
    /// 浮窗,让导入即恢复显示(等同重启时 AppDelegate.restorePinnedNotes,用户
    /// 不必重启)。注意:`isPinned` 跟 frame/collapsed 一样是「本机窗口/UI 状态」,
    /// 但备份的语义是「这些当时开着」,所以我们**保留** isPinned 并主动 spawn,
    /// 而不是像 hasSavedFrame/isCollapsed 那样清掉(否则 menu 打勾但无窗,要重启
    /// 才一致)。
    ///
    /// 鲁棒性:
    ///   - 先把选中文件(连同可能存在的 -wal/-shm)拷到 temp 再打开 —— 不改动
    ///     用户的源文件,且可在副本上跑 migration;
    ///   - 打开时开 `shouldInferMappingModelAutomatically`,旧 schema 版本(V1/V2)
    ///     导出的 sqlite 会被 lightweight 迁移到当前版本再读;
    ///   - 这也能容忍用户直接拷一份「活的」Noticky.sqlite(带 CloudKit 系统表 /
    ///     history)进来:Core Data 用非 CloudKit container 打开时忽略那些表。
    static func importSQLite(_ url: URL, into context: NSManagedObjectContext) -> (notes: Int, groups: Int, pinned: [Note])? {
        guard let temp = copyStoreToTemp(url) else {
            NSLog("Perch: importSQLite temp copy failed for %@", url.path)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }

        let container = NSPersistentContainer(
            name: "PerchImport",
            managedObjectModel: CoreDataSchema.currentModel()
        )
        guard let desc = container.persistentStoreDescriptions.first else { return nil }
        desc.url = temp
        desc.type = NSSQLiteStoreType
        desc.shouldAddStoreAsynchronously = false
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        desc.setOption(false as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            NSLog("Perch: importSQLite store load failed: %@", "\(loadError)")
            return nil
        }

        let src = container.viewContext
        let srcGroups = (try? src.fetch(NoteGroup.sortedFetchRequest())) ?? []
        let noteReq = NSFetchRequest<Note>(entityName: "Note")
        noteReq.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let srcNotes = (try? src.fetch(noteReq)) ?? []

        var groupMap: [UUID: NoteGroup] = [:]
        var importedGroups = 0
        for g in srcGroups {
            if let existing = fetchGroup(id: g.id, in: context) {
                groupMap[g.id] = existing
                continue
            }
            let copy = NoteGroup(context: context)
            copy.id = g.id
            copy.name = g.name
            copy.createdAt = g.createdAt
            copy.sortOrder = g.sortOrder
            groupMap[g.id] = copy
            importedGroups += 1
        }

        var importedNotes = 0
        // 备份里 isPinned==true 表示「当时开着浮窗 / 开机自动恢复」。收集这次新
        // 导入且 pinned 的笔记,调用方导入完立刻 spawn,无需等重启。
        // isTrashed/isArchived 脏数据(pin 理论上会被清,跨设备同步残留可能仍带)
        // 挡掉 —— 跟 AppDelegate.restorePinnedNotes 同款防御。
        var toShow: [Note] = []
        for n in srcNotes {
            if fetchNote(id: n.id, in: context) != nil { continue }
            let copy = Note(context: context)
            copyNoteFields(from: n, to: copy)
            // frame / collapsed 是本机 UI 状态,不跨库带过来(同旧 restore 行为)。
            copy.hasSavedFrame = false
            copy.isCollapsed = false
            if let gid = n.group?.id, let g = groupMap[gid] { copy.group = g }
            if copy.isPinned && !copy.isTrashed && !copy.isArchived {
                toShow.append(copy)
            }
            importedNotes += 1
        }

        // 便签图片:已有相同 id 的不导入。旧版本(V4 及以前)导出的备份没有这个实体,
        // 迁移后就是空的,这里自然什么都不做。
        let srcImages = (try? src.fetch(NSFetchRequest<NoteImage>(entityName: "NoteImage"))) ?? []
        var knownImageIDs = Set(
            ((try? context.fetch(NSFetchRequest<NoteImage>(entityName: "NoteImage"))) ?? []).compactMap(\.id)
        )
        var importedImages = 0
        for image in srcImages {
            guard let id = image.id, !knownImageIDs.contains(id) else { continue }
            copyImage(from: image, to: NoteImage(context: context))
            knownImageIDs.insert(id)
            importedImages += 1
        }

        if importedNotes > 0 || importedGroups > 0 || importedImages > 0 {
            try? context.save()
        }
        return (importedNotes, importedGroups, toShow)
    }

    // MARK: - Helpers ---------------------------------------------------------

    /// 拷贝便签的「数据」字段(不含 frame/collapsed 这类本机 UI 状态,也不含
    /// reminderDate —— 跨库恢复的提醒没经过 ReminderScheduler 调度,带过去只是
    /// 一个不会触发的死值,沿用旧 restore 不带它的行为)。
    private static func copyNoteFields(from src: Note, to dst: Note) {
        dst.id = src.id
        dst.content = src.content
        dst.createdAt = src.createdAt
        dst.updatedAt = src.updatedAt
        dst.isPinned = src.isPinned
        dst.colorIndex = src.colorIndex
        dst.isTrashed = src.isTrashed
        dst.trashedAt = src.trashedAt
        dst.isArchived = src.isArchived
        dst.archivedAt = src.archivedAt
    }

    private static func copyImage(from src: NoteImage, to dst: NoteImage) {
        dst.id = src.id
        dst.data = src.data
        dst.fileExtension = src.fileExtension
        dst.createdAt = src.createdAt
        dst.ownerNoteID = src.ownerNoteID
    }

    /// 删掉 sqlite 三件套(.sqlite/.sqlite-shm/.sqlite-wal)。导出前清理目标用。
    private static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let f = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix)
            if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
        }
    }

    /// 把源 sqlite(及可能的 -wal/-shm 边车)拷到一个独立 temp 目录,返回拷贝后
    /// 的 .sqlite URL。失败返回 nil。调用方负责删 temp 目录(`removeItem` 父目录)。
    private static func copyStoreToTemp(_ url: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("PerchImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try fm.copyItem(at: url, to: dest)
            for suffix in ["-shm", "-wal"] {
                let from = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                try fm.copyItem(
                    at: from,
                    to: dir.appendingPathComponent(url.lastPathComponent + suffix)
                )
            }
            // 直接拷来的「活」库,大的图片数据在旁边的 `.<库名>_SUPPORT` 目录里(外部二进制
            // 存储),不一起拷的话那些图片读出来是空的。
            let supportName = "." + url.deletingPathExtension().lastPathComponent + "_SUPPORT"
            let support = url.deletingLastPathComponent().appendingPathComponent(supportName)
            if fm.fileExists(atPath: support.path) {
                try fm.copyItem(at: support, to: dir.appendingPathComponent(supportName))
            }
            return dest
        } catch {
            NSLog("Perch: copyStoreToTemp failed: %@", "\(error)")
            return nil
        }
    }

    private static func fetchNote(id: UUID, in context: NSManagedObjectContext) -> Note? {
        let req = NSFetchRequest<Note>(entityName: "Note")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    private static func fetchGroup(id: UUID, in context: NSManagedObjectContext) -> NoteGroup? {
        let req = NSFetchRequest<NoteGroup>(entityName: "NoteGroup")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    /// 把 displayTitle 化简成文件系统安全的 basename。剥掉 / : 等控制字符,空字符串
    /// 兜底成 "Untitled"。max 80 字符,免得 Finder 那头看着累。
    private static func sanitizedFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let s = cleaned.isEmpty ? "Untitled" : cleaned
        return String(s.prefix(80))
    }
}

// MARK: - 用户面板 (NSOpenPanel / NSSavePanel) -----------------------------------

/// 包装常用的文件 panel 调用,UI 调用方一行解决。所有 panel 都同步阻塞,跑在
/// 主线程没问题(用户在等结果)。
enum NoteIOPanels {

    /// 选若干 .md / .txt 文件来 import(逐文件 → 新便签)。用户取消返回空数组。
    static func chooseFilesToImport() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// 单条 export 的 save panel。建议名 = note.displayTitle.md。
    static func chooseExportSingleNote(suggestedTitle: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = suggestedTitle + ".md"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 多条 / 整库 Markdown export 的目录选择器。返回选中的目录 URL。
    static func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 整库 SQLite export 的 save panel。建议名 `Perch-export-YYYYMMDD.sqlite`。
    static func chooseExportAllSQLite() -> URL? {
        let panel = NSSavePanel()
        if let t = UTType(filenameExtension: "sqlite") { panel.allowedContentTypes = [t] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "Perch-export-\(formatter.string(from: Date())).sqlite"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 整库 SQLite import 的 open panel。`allowsOtherFileTypes` 放宽,免得用户
    /// 那份 store 扩展名不是 .sqlite(比如直接拷的容器内文件)就选不中。
    static func chooseSQLiteToImport() -> URL? {
        let panel = NSOpenPanel()
        var types: [UTType] = [.data]
        if let t = UTType(filenameExtension: "sqlite") { types.insert(t, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
