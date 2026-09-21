import CoreData

/// 便签里的图片(V5 起)。粘贴 / 拖入的图片存成这个实体,便签正文里只留
/// `![[名称|UUID]]`,按 `id` 找回。
///
/// 存在 Core Data 里而不是散落的文件,是因为这样才能随 CloudKit 一起同步:
/// `data` 打开了 `allowsExternalBinaryDataStorage`,Core Data 把大的二进制放到 store
/// 旁边的外部文件,CloudKit 镜像时当成 CKAsset 上传。
///
/// 图片和便签之间**没有关系(relationship)**,引用只靠正文里的 UUID 文本。
/// 这样复制 / 剪切嵌入语法到别的便签、撤销删除都自然成立,代价是清理时要
/// 扫一遍正文找引用(见 `NoteImageStore.removeUnreferenced`)。
@objc(NoteImage)
public final class NoteImage: NSManagedObject, Identifiable {
    /// 模型层是可选(CloudKit 不允许必填无默认值的字段),实际总是有值。
    @NSManaged public var id: UUID?
    @NSManaged public var data: Data?
    /// 原文件扩展名(png / jpg / gif …),仅作记录。
    @NSManaged public var fileExtension: String
    @NSManaged public var createdAt: Date?
    /// 粘贴 / 拖入时正在编辑的便签 id。只是清理用的**线索**,不是外键:便签被
    /// 永久删除时,即使正文里已经删掉了这张图的引用,也能据此把它一起清掉。
    @NSManaged public var ownerNoteID: UUID?
}
