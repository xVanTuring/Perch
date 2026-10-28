import CoreData

/// Core Data 对象 ↔ 同步字段。哪些字段同步见 docs/icloud-drive-sync.md 第 3 节:
/// 窗口相关的(`isPinned`、`frameX/Y/W/H`、`hasSavedFrame`、`isCollapsed`、`displayOrder`)
/// 只存本机,不在这里出现。
///
/// 日期一律先转成 `SyncValue`(毫秒精度的字符串)再比较 —— Core Data 里的 `Date` 有亚毫秒
/// 部分,直接比会把没改过的字段当成改过。
enum SyncCoreDataAdapter {
    typealias F = SyncFieldName

    static func fields(of note: Note) -> [String: SyncValue] {
        [
            F.content: .string(note.content),
            F.createdAt: .date(note.createdAt),
            F.updatedAt: .date(note.updatedAt),
            F.groupID: .uuid(note.group?.id),
            F.colorIndex: .int(Int(note.colorIndex)),
            F.isTrashed: .bool(note.isTrashed),
            F.trashedAt: .date(note.trashedAt),
            F.isArchived: .bool(note.isArchived),
            F.archivedAt: .date(note.archivedAt),
            F.reminderDate: .date(note.reminderDate),
        ]
    }

    static func fields(of group: NoteGroup) -> [String: SyncValue] {
        [
            F.name: .string(group.name),
            F.createdAt: .date(group.createdAt),
            F.sortOrder: .int(Int(group.sortOrder)),
        ]
    }

    static func fields(of image: NoteImage) -> [String: SyncValue] {
        [
            F.fileExtension: .string(image.fileExtension),
            F.createdAt: .date(image.createdAt),
            F.ownerNoteID: .uuid(image.ownerNoteID),
        ]
    }

    /// 把合并结果写进笔记。只写和当前值不同的字段,没变的不碰(免得无谓地触发保存和界面刷新)。
    static func apply(_ values: [String: SyncValue], to note: Note,
                      group lookup: (UUID) -> NoteGroup?) {
        let current = fields(of: note)
        for (name, value) in values where current[name] != value {
            switch name {
            case F.content:      note.content = value.stringValue ?? ""
            case F.createdAt:    if let d = value.dateValue { note.createdAt = d }
            case F.updatedAt:    if let d = value.dateValue { note.updatedAt = d }
            case F.groupID:      note.group = value.uuidValue.flatMap(lookup)
            case F.colorIndex:   if case .int(let i) = value { note.colorIndex = Int16(clamping: i) }
            case F.isTrashed:    note.isTrashed = value.boolValue ?? false
            case F.trashedAt:    note.trashedAt = value.dateValue
            case F.isArchived:   note.isArchived = value.boolValue ?? false
            case F.archivedAt:   note.archivedAt = value.dateValue
            case F.reminderDate: note.reminderDate = value.dateValue
            default:             break   // conflictOf 等只在同步记录里的字段
            }
        }
    }

    static func apply(_ values: [String: SyncValue], to group: NoteGroup) {
        let current = fields(of: group)
        for (name, value) in values where current[name] != value {
            switch name {
            case F.name:      group.name = value.stringValue ?? ""
            case F.createdAt: if let d = value.dateValue { group.createdAt = d }
            case F.sortOrder: if case .int(let i) = value { group.sortOrder = Int32(clamping: i) }
            default:          break
            }
        }
    }

    static func apply(_ values: [String: SyncValue], to image: NoteImage) {
        let current = fields(of: image)
        for (name, value) in values where current[name] != value {
            switch name {
            case F.fileExtension: image.fileExtension = value.stringValue ?? ""
            case F.createdAt:     image.createdAt = value.dateValue
            case F.ownerNoteID:   image.ownerNoteID = value.uuidValue
            default:              break
            }
        }
    }

    /// 从没同步过的记录第一次导出时用的时间:记录自己的修改 / 创建时间,而不是当前时间
    /// (方案第 3 节:否则后加入的 Mac 只因为导出得晚,就会盖掉别的 Mac 之前的修改)。
    static func historicalDate(of note: Note) -> Date { note.updatedAt }
    static func historicalDate(of group: NoteGroup) -> Date { group.createdAt }
    static func historicalDate(of image: NoteImage) -> Date { image.createdAt ?? Date() }
}
