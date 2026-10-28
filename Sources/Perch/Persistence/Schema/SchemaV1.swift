import CoreData

/// Perch Core Data schema 的 **第一个版本**(初始发布版)。
///
/// ============================================================================
/// 修改规则 —— 一旦发布给用户,这个文件不能再改 schema 内容
/// ============================================================================
///
/// 任何 schema 改动(加 entity、加字段、改类型、改关系):
///   1. **复制** 这个文件为 `SchemaV2.swift`,把 `SchemaV1` 全替换成 `SchemaV2`
///   2. 在 SchemaV2 里改你想改的东西
///   3. `CoreDataSchema.current = .v2`
///   4. 跑测试 + 拿真实 V1 sqlite 验证升级路径
///
/// 直接改这个文件等于改了老用户的 sqlite hash,Core Data 加载老 store 时会抛
/// `NSPersistentStoreIncompatibleVersionHashError`,用户视角是"升级一次清空所有便签"。
///
/// ============================================================================
/// 字段/Entity 重命名(V2+ 用)
/// ============================================================================
///
/// 默认行为:Core Data 把"删旧字段+加新字段"理解成两件事,数据丢失。
///
/// 正确做法 —— 在新版本的 attribute 上设 renaming identifier:
///
///   let renamed = NSAttributeDescription()
///   renamed.name = "newName"
///   renamed.renamingIdentifier = "oldName"   // 老库里那个字段的名字
///   ...
///
/// Entity 重命名同理:`entity.renamingIdentifier = "OldEntityName"`。
///
/// ============================================================================
/// CloudKit 兼容性约束(整个项目都跟)
/// ============================================================================
///
/// - 不能加 unique constraint(CloudKit 不支持,会启动失败)
/// - 不能改字段的 `isOptional`(已发布的 record 在 CloudKit 上不可变,推不上去)
/// - to-many 关系必须 optional + nullify delete rule
/// - 改完 schema 要在 Settings → iCloud Sync 里手动跑 initializeCloudKitSchema
///   把新 record types/字段推到 CloudKit Production 环境
///   (iCloud 同步下线期间不用跑,但上面几条约束照守,免得以后重开同步时推不上去)
/// - id/createdAt/updatedAt 在 schema 层 `isOptional=true`,代码路径(Note.create)
///   总会立即赋值,Swift 侧 @NSManaged 仍可保持非可选
enum SchemaV1 {
    static let identifier = "v1"

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        // versionIdentifiers 写进 sqlite 元数据,后续可以反查"这个 store 上次保存
        // 时是哪个 schema 版本",对失败诊断和迁移路径选择有用。
        model.versionIdentifiers = [identifier]

        // Note entity ------------------------------------------------------------
        let note = NSEntityDescription()
        note.name = "Note"
        note.managedObjectClassName = NSStringFromClass(Note.self)

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = true

        let content = NSAttributeDescription()
        content.name = "content"
        content.attributeType = .stringAttributeType
        content.isOptional = false
        content.defaultValue = ""

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = true

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = true

        let isPinned = NSAttributeDescription()
        isPinned.name = "isPinned"
        isPinned.attributeType = .booleanAttributeType
        isPinned.isOptional = false
        isPinned.defaultValue = false

        let colorIndex = NSAttributeDescription()
        colorIndex.name = "colorIndex"
        colorIndex.attributeType = .integer16AttributeType
        colorIndex.isOptional = false
        colorIndex.defaultValue = 0

        let frameX = doubleAttr("frameX")
        let frameY = doubleAttr("frameY")
        let frameW = doubleAttr("frameW")
        let frameH = doubleAttr("frameH")

        let hasSavedFrame = NSAttributeDescription()
        hasSavedFrame.name = "hasSavedFrame"
        hasSavedFrame.attributeType = .booleanAttributeType
        hasSavedFrame.isOptional = false
        hasSavedFrame.defaultValue = false

        // 软删除:笔记进回收站置 isTrashed=true + trashedAt=now。所有"普通"
        // fetch 都加 isTrashed==false 过滤,只有 Trash 视图查 ==true。
        // 启动时按 SettingsKey.trashRetentionDays 真删过期项。
        let isTrashed = NSAttributeDescription()
        isTrashed.name = "isTrashed"
        isTrashed.attributeType = .booleanAttributeType
        isTrashed.isOptional = false
        isTrashed.defaultValue = false

        let trashedAt = NSAttributeDescription()
        trashedAt.name = "trashedAt"
        trashedAt.attributeType = .dateAttributeType
        trashedAt.isOptional = true

        // 折叠态:浮窗双击标题缩成只剩标题条;持久化让用户重启后回到上次的状态。
        let isCollapsed = NSAttributeDescription()
        isCollapsed.name = "isCollapsed"
        isCollapsed.attributeType = .booleanAttributeType
        isCollapsed.isOptional = false
        isCollapsed.defaultValue = false

        // NoteGroup entity ------------------------------------------------------
        let groupEntity = NSEntityDescription()
        groupEntity.name = "NoteGroup"
        groupEntity.managedObjectClassName = NSStringFromClass(NoteGroup.self)

        let groupId = NSAttributeDescription()
        groupId.name = "id"
        groupId.attributeType = .UUIDAttributeType
        groupId.isOptional = true

        let groupName = NSAttributeDescription()
        groupName.name = "name"
        groupName.attributeType = .stringAttributeType
        groupName.isOptional = false
        groupName.defaultValue = ""

        let groupCreatedAt = NSAttributeDescription()
        groupCreatedAt.name = "createdAt"
        groupCreatedAt.attributeType = .dateAttributeType
        groupCreatedAt.isOptional = true

        let groupSortOrder = NSAttributeDescription()
        groupSortOrder.name = "sortOrder"
        groupSortOrder.attributeType = .integer32AttributeType
        groupSortOrder.isOptional = false
        groupSortOrder.defaultValue = Int32(0)

        // Relationships ---------------------------------------------------------
        // Note <-> NoteGroup,多对一。任何一方删除都 nullify(保留对方),不级联。
        // CloudKit 要求 to-many 关系必须 optional + nullify。
        let noteToGroup = NSRelationshipDescription()
        noteToGroup.name = "group"
        noteToGroup.destinationEntity = groupEntity
        noteToGroup.maxCount = 1
        noteToGroup.minCount = 0
        noteToGroup.isOptional = true
        noteToGroup.deleteRule = .nullifyDeleteRule

        let groupToNotes = NSRelationshipDescription()
        groupToNotes.name = "notes"
        groupToNotes.destinationEntity = note
        groupToNotes.maxCount = 0  // unlimited
        groupToNotes.minCount = 0
        groupToNotes.isOptional = true
        groupToNotes.deleteRule = .nullifyDeleteRule

        noteToGroup.inverseRelationship = groupToNotes
        groupToNotes.inverseRelationship = noteToGroup

        note.properties = [
            id, content, createdAt, updatedAt, isPinned, colorIndex,
            frameX, frameY, frameW, frameH, hasSavedFrame,
            isTrashed, trashedAt, isCollapsed,
            noteToGroup
        ]
        groupEntity.properties = [groupId, groupName, groupCreatedAt, groupSortOrder, groupToNotes]
        model.entities = [note, groupEntity]
        return model
    }

    private static func doubleAttr(_ name: String) -> NSAttributeDescription {
        let attr = NSAttributeDescription()
        attr.name = name
        attr.attributeType = .doubleAttributeType
        attr.isOptional = false
        attr.defaultValue = 0.0
        return attr
    }
}
