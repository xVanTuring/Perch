import AppKit
import CoreData
import UniformTypeIdentifiers

/// 便签图片的存储:粘贴 / 拖入的图片写进 Core Data 的 `NoteImage` 实体,便签正文里
/// 只留 `![[名称|UUID]]`,不依赖原文件路径 —— 原文件之后被移动或删除也不影响。
/// 因为存在 Core Data 里,图片会随 CloudKit 一起同步(见 `NoteImage` / `SchemaV5`)。
///
/// 读取走 `viewContext`(引擎在主线程同步取图),解码后的 `NSImage` 放内存缓存。
final class NoteImageStore: @unchecked Sendable {
    static let shared = NoteImageStore(context: PersistenceController.shared.container.viewContext)

    struct StoredImage {
        let id: UUID
        /// 写进 `![[名称|UUID]]` 的名称:原文件名,或粘贴时生成的名字。
        let displayName: String
    }

    /// 一条便签「关联」到的一张图片,给图片面板列表用(见 NoteImagesPopover)。
    /// 名称不落库,所以这里只有客观信息;显示名由 `defaultName(for:fileExtension:)`
    /// 按导入时间还原。
    struct LinkedImage: Identifiable {
        let id: UUID
        let createdAt: Date
        let fileExtension: String
        /// 正文里还有 `![[…|这个 id]]` 引用。false = 引用被删了,图片还在,
        /// 可以从面板放回去 —— 这正是这个面板存在的理由。
        let isReferenced: Bool
    }

    enum ImportError: Error {
        case notAnImage
        case tooLarge
    }

    /// 单张图片上限。截图和照片一般在几 MB,再大的多半是误粘贴;同步到 iCloud
    /// 也会占用户的配额。
    static let maxBytes = 30 * 1024 * 1024

    let context: NSManagedObjectContext
    private let decoded = NSCache<NSString, NSImage>()

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: 读取

    func image(for id: UUID) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = decoded.object(forKey: key) { return cached }

        var data: Data?
        context.performAndWait {
            let request = NSFetchRequest<NoteImage>(entityName: "NoteImage")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            data = (try? context.fetch(request))?.first?.data
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        decoded.setObject(image, forKey: key)
        return image
    }

    /// 一条便签关联到的所有图片,按导入时间排序。两个来源取并集:
    /// - `ownerNoteID` 记在这条便签名下的(粘贴 / 拖入时登记的),**包括正文里
    ///   已经没有引用的** —— 面板要能把它们放回去;
    /// - 正文里引用到的(可能是从别的便签复制过来的引用,owner 不是这条)。
    ///
    /// 只读元信息,不碰 `data` —— 图片本体按需走 `image(for:)`(它自带解码缓存),
    /// 否则开一次面板就把这条便签的所有图片全解出来。
    func linkedImages(for note: Note) -> [LinkedImage] {
        let referenced = Self.referencedImageIDs(in: note.content)
        let noteID = note.id
        var result: [LinkedImage] = []
        context.performAndWait {
            let request = NSFetchRequest<NoteImage>(entityName: "NoteImage")
            request.predicate = NSPredicate(
                format: "ownerNoteID == %@ OR id IN %@", noteID as CVarArg, Array(referenced)
            )
            // 同 id 可能有多份(CloudKit 没有唯一约束),按 id 去重。
            var seen = Set<UUID>()
            for image in (try? context.fetch(request)) ?? [] {
                guard let id = image.id, seen.insert(id).inserted else { continue }
                result.append(LinkedImage(
                    id: id,
                    createdAt: image.createdAt ?? .distantPast,
                    fileExtension: image.fileExtension ?? "png",
                    isReferenced: referenced.contains(id)
                ))
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    /// 图片的默认显示名。名称没有落库,粘贴时用的就是这个格式,所以对截图来说
    /// 从面板放回去的名字和当初粘进来的完全一致;拖入的文件会丢掉原文件名。
    static func defaultName(for date: Date, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let ext = fileExtension.isEmpty ? "png" : fileExtension
        return "Pasted image \(formatter.string(from: date)).\(ext)"
    }

    // MARK: 导入

    /// 复制一个图片文件进存储。不是图片、或超过上限时抛错。
    func importFile(_ source: URL, ownerNoteID: UUID?) throws -> StoredImage {
        guard let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: .image) else { throw ImportError.notAnImage }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else { throw ImportError.tooLarge }
        let data = try Data(contentsOf: source)
        return try importImageData(
            data, fileExtension: source.pathExtension.lowercased(),
            name: source.lastPathComponent, ownerNoteID: ownerNoteID
        )
    }

    /// 写入一段图片数据(截图、网页里「拷贝图片」)。解不出图片、或超过上限时抛错。
    func importImageData(
        _ data: Data, fileExtension: String = "png", name: String, ownerNoteID: UUID?
    ) throws -> StoredImage {
        guard data.count <= Self.maxBytes else { throw ImportError.tooLarge }
        // 扩展名像图片不代表真能解码;解不出来就不存。
        guard let image = NSImage(data: data) else { throw ImportError.notAnImage }

        let id = UUID()
        var failure: Error?
        context.performAndWait {
            let record = NoteImage(context: context)
            record.id = id
            record.data = data
            record.fileExtension = fileExtension
            record.createdAt = Date()
            record.ownerNoteID = ownerNoteID
            do {
                try context.save()
            } catch {
                // 撤销这次插入,不动 context 里别的未保存改动(所以不用 rollback)。
                context.delete(record)
                failure = error
            }
        }
        if let failure { throw failure }
        decoded.setObject(image, forKey: id.uuidString as NSString)
        return StoredImage(id: id, displayName: Self.sanitizedName(name))
    }

    // MARK: 清理

    /// 永久删除便签**之前**调用:记下这些便签用到的图片 —— 正文里引用的,以及登记为
    /// 「属于」它们的(哪怕正文里已经删掉了引用)。便签删除并保存之后,把结果交给
    /// `removeUnreferenced`。
    func candidates(for notes: [Note]) -> Set<UUID> {
        var ids = Set<UUID>()
        var noteIDs: [UUID] = []
        for note in notes {
            ids.formUnion(Self.referencedImageIDs(in: note.content))
            noteIDs.append(note.id)
        }
        guard !noteIDs.isEmpty else { return ids }

        context.performAndWait {
            let request = NSFetchRequest<NoteImage>(entityName: "NoteImage")
            request.predicate = NSPredicate(format: "ownerNoteID IN %@", noteIDs)
            for image in (try? context.fetch(request)) ?? [] {
                if let id = image.id { ids.insert(id) }
            }
        }
        return ids
    }

    /// 便签删除并保存**之后**调用:候选图片里,没有被任何剩下的便签(含回收站、归档)
    /// 引用的,删掉。删除会随 CloudKit 同步到其他设备。
    ///
    /// 只按候选清理,不做全库扫描:全库扫描在新设备首次同步时(图片先到、便签还没
    /// 到)会把「暂时没人引用」的图片误删,而且删除会同步出去,无法挽回。
    func removeUnreferenced(_ candidates: Set<UUID>) {
        guard !candidates.isEmpty else { return }
        context.performAndWait {
            let remaining = (try? context.fetch(NSFetchRequest<Note>(entityName: "Note"))) ?? []
            var referenced = Set<UUID>()
            for note in remaining { referenced.formUnion(Self.referencedImageIDs(in: note.content)) }

            let orphaned = candidates.subtracting(referenced)
            guard !orphaned.isEmpty else { return }
            delete(ids: Array(orphaned))
        }
    }

    /// 清空全部内容时用:所有便签都没了,图片一并删光。
    func removeAll() {
        context.performAndWait {
            let all = (try? context.fetch(NSFetchRequest<NoteImage>(entityName: "NoteImage"))) ?? []
            for image in all { context.delete(image) }
            try? context.save()
            decoded.removeAllObjects()
        }
    }

    /// 必须在 `context.performAndWait` 里调用。按 id 删除**所有**同 id 记录
    /// (CloudKit 没有唯一约束,同 id 可能有多份)。
    private func delete(ids: [UUID]) {
        let request = NSFetchRequest<NoteImage>(entityName: "NoteImage")
        request.predicate = NSPredicate(format: "id IN %@", ids)
        for image in (try? context.fetch(request)) ?? [] { context.delete(image) }
        try? context.save()
        for id in ids { decoded.removeObject(forKey: id.uuidString as NSString) }
    }

    // MARK: 引用解析

    private static let embedPattern = try! NSRegularExpression(pattern: "!\\[\\[([^\\]\\r\\n]*)\\]\\]")

    /// 正文里 `![[名称|UUID|宽度]]` 引用到的图片 id。写在代码块里的也算引用 ——
    /// 宁可多留一张图,也不误删。
    static func referencedImageIDs(in content: String) -> Set<UUID> {
        guard content.contains("![[") else { return [] }
        let ns = content as NSString
        var ids = Set<UUID>()
        for match in embedPattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: match.range(at: 1))
            // 第一段是名称,后面的段里第一个能解析成 UUID 的就是图片 id(与引擎的解析一致)。
            for part in inner.split(separator: "|").dropFirst() {
                if let id = UUID(uuidString: part.trimmingCharacters(in: .whitespaces)) {
                    ids.insert(id)
                    break
                }
            }
        }
        return ids
    }

    /// 名称会写进 `![[名称|UUID]]`,其中的 `|` `[` `]` 和换行都会破坏语法,替换成 `-`。
    static func sanitizedName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "|[]").union(.newlines)
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "image" : cleaned
    }
}
