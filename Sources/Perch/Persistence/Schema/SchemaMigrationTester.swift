#if DEBUG
import CoreData
import Foundation

/// 端到端验证 schema 升级链路:
///   1. 合成一个"前一个版本"的 model(从 SchemaV1 model 里删掉一个字段),
///   2. 用这个旧 model 在临时 sqlite 里写 N 条样本数据,
///   3. 关 store,
///   4. 用当前 SchemaV1 model + lightweight migration 重开同一个 sqlite,
///   5. 断言所有样本仍可读 + 新加的字段拿到 default value,
///   6. 清掉临时 sqlite。
///
/// 这是一个 **DEBUG-only smoke test** —— 在 Settings → iCloud Sync 里手动跑,
/// 每次新增 SchemaVN 之前确认链路没坏。比开 XCTest target 轻量,且用真实
/// `loadPersistentStores` 路径(包含 `shouldInferMappingModelAutomatically`)。
///
/// 限制:只能验证"加字段"这一种最常见的 lightweight migration。其他场景
/// (字段重命名、删字段、关系改动)出现时,把对应的合成 case 加进来。
enum SchemaMigrationTester {
    enum Result {
        case passed(message: String)
        case failed(message: String)

        var isPassed: Bool {
            if case .passed = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .passed(let m), .failed(let m): return m
            }
        }
    }

    /// 入口。依次跑「加字段」和「V4 → V5 新增实体」两个用例,任何一个失败就返回
    /// 失败。同步执行,可能耗时(秒级 IO),调用方记得放后台 thread。
    static func run() -> Result {
        let addField = runAddFieldCase()
        guard addField.isPassed else { return addField }
        let addEntity = runV4ToV5Case()
        guard addEntity.isPassed else { return addEntity }
        return .passed(message: "\(addField.message);\(addEntity.message)")
    }

    /// V4 → V5:新增 `NoteImage` 实体。和上面的合成用例不同,这里旧库用**真实的**
    /// `SchemaV4` model 写,再用 `SchemaV5` + lightweight migration 重开 —— 就是
    /// 用户升级时实际发生的事。断言:旧便签一条不少,新实体能写入并读回(包括大到
    /// 会走外部二进制存储的数据)。
    private static func runV4ToV5Case() -> Result {
        let storeURL = makeTempStoreURL()
        defer { cleanup(storeURL) }

        do {
            let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: SchemaV4.makeModel())
            try oldCoordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil
            )
            let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            oldContext.persistentStoreCoordinator = oldCoordinator

            let sampleIDs = (0..<3).map { _ in UUID() }
            for (idx, id) in sampleIDs.enumerated() {
                let note = NSEntityDescription.insertNewObject(forEntityName: "Note", into: oldContext)
                note.setValue(id, forKey: "id")
                note.setValue("v4 note #\(idx)", forKey: "content")
                note.setValue(Date(), forKey: "createdAt")
                note.setValue(Date(), forKey: "updatedAt")
            }
            try oldContext.save()
            for store in oldCoordinator.persistentStores { try oldCoordinator.remove(store) }

            let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: SchemaV5.makeModel())
            try newCoordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL,
                options: [
                    NSMigratePersistentStoresAutomaticallyOption: true,
                    NSInferMappingModelAutomaticallyOption: true,
                ]
            )
            let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            newContext.persistentStoreCoordinator = newCoordinator

            let notes = try newContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Note"))
            guard Set(notes.compactMap { $0.value(forKey: "id") as? UUID }) == Set(sampleIDs) else {
                return .failed(message: "V4→V5 迁移后便签丢失或 UUID 不一致(期望 \(sampleIDs.count) 条,实际 \(notes.count) 条)")
            }

            // 新实体可用。300KB 超过 Core Data 外部二进制存储的阈值(约 100KB),
            // 确保走的是外部文件那条路径。
            let payload = Data(repeating: 0xAB, count: 300_000)
            let imageID = UUID()
            let image = NSEntityDescription.insertNewObject(forEntityName: "NoteImage", into: newContext)
            image.setValue(imageID, forKey: "id")
            image.setValue(payload, forKey: "data")
            image.setValue("png", forKey: "fileExtension")
            image.setValue(Date(), forKey: "createdAt")
            try newContext.save()
            newContext.reset()

            let images = try newContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "NoteImage"))
            guard images.count == 1,
                  images[0].value(forKey: "id") as? UUID == imageID,
                  images[0].value(forKey: "data") as? Data == payload else {
                return .failed(message: "V4→V5 迁移后 NoteImage 写入 / 读回不一致")
            }

            for store in newCoordinator.persistentStores { try newCoordinator.remove(store) }
            return .passed(message: "V4→V5 迁移验证通过(\(sampleIDs.count) 条便签完整保留,NoteImage 可读写)")
        } catch {
            return .failed(message: "V4→V5 迁移测试抛异常:\((error as NSError).localizedDescription)")
        }
    }

    /// 合成的「加字段」用例:旧库缺 isCollapsed,新库(SchemaV1)有。
    private static func runAddFieldCase() -> Result {
        let storeURL = makeTempStoreURL()
        defer { cleanup(storeURL) }

        do {
            // Phase 1 ----- 用合成的 V0 model 写若干条数据
            let oldModel = makeSyntheticPreviousModel()
            let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
            try oldCoordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: nil
            )

            let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            oldContext.persistentStoreCoordinator = oldCoordinator

            let sampleIDs = (0..<3).map { _ in UUID() }
            for (idx, id) in sampleIDs.enumerated() {
                let note = NSEntityDescription.insertNewObject(
                    forEntityName: "Note", into: oldContext
                )
                note.setValue(id, forKey: "id")
                note.setValue("test note #\(idx)", forKey: "content")
                note.setValue(Date(), forKey: "createdAt")
                note.setValue(Date(), forKey: "updatedAt")
                note.setValue(false, forKey: "isPinned")
                note.setValue(Int16(idx % 6), forKey: "colorIndex")
                note.setValue(false, forKey: "hasSavedFrame")
                note.setValue(false, forKey: "isTrashed")
                // ⚠️ **故意不写** isCollapsed —— 合成 V0 里不存在这个字段
            }
            try oldContext.save()

            // 重要:必须显式 remove store,否则 sqlite-shm/wal 还挂着,后面用
            // 新 coordinator 打开会被 Core Data 当成"已被另一个 coordinator
            // 占用",重开行为不确定。
            for store in oldCoordinator.persistentStores {
                try oldCoordinator.remove(store)
            }

            // Phase 2 ----- 用当前 SchemaV1 + lightweight migration 重开
            let newModel = SchemaV1.makeModel()
            let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
            let migrationOptions: [AnyHashable: Any] = [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true,
            ]
            try newCoordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: migrationOptions
            )

            let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            newContext.persistentStoreCoordinator = newCoordinator

            // Phase 3 ----- 断言数据保留 + 新字段拿到 default
            let request = NSFetchRequest<NSManagedObject>(entityName: "Note")
            let migrated = try newContext.fetch(request)

            guard migrated.count == sampleIDs.count else {
                return .failed(message: "迁移后笔记数不对:期望 \(sampleIDs.count) 实际 \(migrated.count)")
            }

            let migratedIDs = Set(migrated.compactMap { $0.value(forKey: "id") as? UUID })
            guard migratedIDs == Set(sampleIDs) else {
                return .failed(message: "迁移后 UUID 集合不一致")
            }

            // 验证新加的字段(isCollapsed)拿到了 default value(false)
            for note in migrated {
                guard let collapsed = note.value(forKey: "isCollapsed") as? Bool else {
                    return .failed(message: "迁移后读不到 isCollapsed 字段")
                }
                if collapsed != false {
                    return .failed(message: "新字段 isCollapsed 默认值不是 false:\(collapsed)")
                }
            }

            for store in newCoordinator.persistentStores {
                try newCoordinator.remove(store)
            }

            return .passed(message: "lightweight migration 验证通过(\(sampleIDs.count) 条数据完整迁移)")
        } catch {
            return .failed(message: "迁移测试抛异常:\((error as NSError).localizedDescription)")
        }
    }

    // MARK: - Internals

    /// 合成"V0":SchemaV1 减去 isCollapsed 字段。代表"V1 加了 isCollapsed,
    /// V0 没有"这种典型的加字段升级。
    ///
    /// 这里手写一份精简 model,**不复用 SchemaV1.makeModel() 然后改** —— 那样
    /// 改完 entity 还是同一个 hash(NSEntityDescription 是引用类型,改 properties
    /// 等同于编辑同一个 entity)。Core Data 推 hash 时按 entity 当前形态,
    /// 拿不到"曾经少一个字段"的状态。
    private static func makeSyntheticPreviousModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.versionIdentifiers = ["v0_synthetic"]

        let note = NSEntityDescription()
        note.name = "Note"
        // 这里不绑 managedObjectClassName=Note,用泛型 NSManagedObject 操作,
        // 避免 Note class 上 @NSManaged 字段(isCollapsed 等)在 V0 model 里
        // 缺字段时触发 KVC 异常。

        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = true,
                  default: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            a.defaultValue = `default`
            return a
        }

        note.properties = [
            attr("id", .UUIDAttributeType, optional: true),
            attr("content", .stringAttributeType, optional: false, default: ""),
            attr("createdAt", .dateAttributeType, optional: true),
            attr("updatedAt", .dateAttributeType, optional: true),
            attr("isPinned", .booleanAttributeType, optional: false, default: false),
            attr("colorIndex", .integer16AttributeType, optional: false, default: Int16(0)),
            attr("frameX", .doubleAttributeType, optional: false, default: 0.0),
            attr("frameY", .doubleAttributeType, optional: false, default: 0.0),
            attr("frameW", .doubleAttributeType, optional: false, default: 0.0),
            attr("frameH", .doubleAttributeType, optional: false, default: 0.0),
            attr("hasSavedFrame", .booleanAttributeType, optional: false, default: false),
            attr("isTrashed", .booleanAttributeType, optional: false, default: false),
            attr("trashedAt", .dateAttributeType, optional: true),
            // **少了 isCollapsed** —— 这就是"加字段"升级要测的关键
        ]

        // V0 不带 NoteGroup,这次只测 Note 的字段加减。要测 entity 增加场景的话
        // 可以再加一个 makeSyntheticV{N} 函数。
        model.entities = [note]
        return model
    }

    private static func makeTempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Perch-MigrationTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    private static func cleanup(_ storeURL: URL) {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }
}
#endif
