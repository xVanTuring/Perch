import CoreData

/// V5 = V4 + 新实体 `NoteImage`(便签图片,随 CloudKit 同步)。
///
/// 改动来源:便签支持粘贴 / 拖入图片。图片要跟着 iCloud 走,所以存进 Core Data
/// 而不是本地文件夹。`NoteImage.data` 打开 `allowsExternalBinaryDataStorage` —— 大的
/// 二进制由 Core Data 放到 store 旁的外部文件,CloudKit 镜像时当成 CKAsset。
///
/// lightweight migration:只**新增**一个实体,Note / NoteGroup 一个字节没动,
/// `shouldInferMappingModelAutomatically` 直接搞定,老库无需任何数据改写。
/// 测试入口:Settings → iCloud Sync → "Run migration self-test"(含 V4 → V5 用例)。
///
/// ⚠️ CloudKit 生产环境的 schema 只增不减。发布带 V5 的版本之前,必须先在 Debug
/// 构建里 "Initialize Cloud schema (Development)",再到 CloudKit Console 把
/// Development 部署到 Production(见 CLAUDE.md "Schema → CloudKit deployment workflow")。
/// 否则发布版上传 NoteImage 会被 CloudKit 静默丢弃。
///
/// NoteImage 没有 relationship:CloudKit 要求 relationship 必须有 inverse 且可选,
/// 而图片和便签的关系本来就只靠正文里的 UUID 文本,不需要外键。
enum SchemaV5 {
    static let identifier = "v5"

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
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

        let isTrashed = NSAttributeDescription()
        isTrashed.name = "isTrashed"
        isTrashed.attributeType = .booleanAttributeType
        isTrashed.isOptional = false
        isTrashed.defaultValue = false

        let trashedAt = NSAttributeDescription()
        trashedAt.name = "trashedAt"
        trashedAt.attributeType = .dateAttributeType
        trashedAt.isOptional = true

        let isCollapsed = NSAttributeDescription()
        isCollapsed.name = "isCollapsed"
        isCollapsed.attributeType = .booleanAttributeType
        isCollapsed.isOptional = false
        isCollapsed.defaultValue = false

        let reminderDate = NSAttributeDescription()
        reminderDate.name = "reminderDate"
        reminderDate.attributeType = .dateAttributeType
        reminderDate.isOptional = true

        let isArchived = NSAttributeDescription()
        isArchived.name = "isArchived"
        isArchived.attributeType = .booleanAttributeType
        isArchived.isOptional = false
        isArchived.defaultValue = false

        let archivedAt = NSAttributeDescription()
        archivedAt.name = "archivedAt"
        archivedAt.attributeType = .dateAttributeType
        archivedAt.isOptional = true

        let displayOrder = NSAttributeDescription()
        displayOrder.name = "displayOrder"
        displayOrder.attributeType = .integer32AttributeType
        displayOrder.isOptional = false
        displayOrder.defaultValue = Int32(0)

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

        // NoteImage entity(V5 新增)---------------------------------------------
        let imageEntity = NSEntityDescription()
        imageEntity.name = "NoteImage"
        imageEntity.managedObjectClassName = NSStringFromClass(NoteImage.self)

        let imageId = NSAttributeDescription()
        imageId.name = "id"
        imageId.attributeType = .UUIDAttributeType
        imageId.isOptional = true

        // 外部二进制存储:大图放到 store 旁边的外部文件,CloudKit 镜像时当 CKAsset。
        let imageData = NSAttributeDescription()
        imageData.name = "data"
        imageData.attributeType = .binaryDataAttributeType
        imageData.isOptional = true
        imageData.allowsExternalBinaryDataStorage = true

        let imageExtension = NSAttributeDescription()
        imageExtension.name = "fileExtension"
        imageExtension.attributeType = .stringAttributeType
        imageExtension.isOptional = false
        imageExtension.defaultValue = "png"

        let imageCreatedAt = NSAttributeDescription()
        imageCreatedAt.name = "createdAt"
        imageCreatedAt.attributeType = .dateAttributeType
        imageCreatedAt.isOptional = true

        // 只是清理线索,不是外键(见 NoteImage 的注释)。
        let imageOwner = NSAttributeDescription()
        imageOwner.name = "ownerNoteID"
        imageOwner.attributeType = .UUIDAttributeType
        imageOwner.isOptional = true

        // Relationships ---------------------------------------------------------
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
        groupToNotes.maxCount = 0
        groupToNotes.minCount = 0
        groupToNotes.isOptional = true
        groupToNotes.deleteRule = .nullifyDeleteRule

        noteToGroup.inverseRelationship = groupToNotes
        groupToNotes.inverseRelationship = noteToGroup

        note.properties = [
            id, content, createdAt, updatedAt, isPinned, colorIndex,
            frameX, frameY, frameW, frameH, hasSavedFrame,
            isTrashed, trashedAt, isCollapsed, reminderDate,
            isArchived, archivedAt, displayOrder,
            noteToGroup
        ]
        groupEntity.properties = [groupId, groupName, groupCreatedAt, groupSortOrder, groupToNotes]
        imageEntity.properties = [imageId, imageData, imageExtension, imageCreatedAt, imageOwner]
        model.entities = [note, groupEntity, imageEntity]
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
