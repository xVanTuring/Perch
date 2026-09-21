import CoreData

/// Schema 版本枚举。**新增版本就在这里加 case + 在 makeModel() 加分支。**
///
/// `current` 是 head —— `PersistenceController` 启动时拿这个版本的 model 去 load store。
/// 老版本 case 保留是为了让未来需要做 NSMigrationManager 自定义迁移时,
/// 还能重建出对应版本的 NSManagedObjectModel(programmatic model 没有 .xcdatamodeld
/// 缓存,只能靠代码重建)。
enum SchemaVersion: String, CaseIterable {
    case v1
    case v2
    case v3
    case v4
    case v5

    /// 当前发布版本。改这个之前先把 SchemaV{N+1}.swift 写好。
    static let current: SchemaVersion = .v5

    func makeModel() -> NSManagedObjectModel {
        switch self {
        case .v1: return SchemaV1.makeModel()
        case .v2: return SchemaV2.makeModel()
        case .v3: return SchemaV3.makeModel()
        case .v4: return SchemaV4.makeModel()
        case .v5: return SchemaV5.makeModel()
        }
    }
}

/// Schema 操作集中入口。代码里其它地方都通过这里拿 model / 查询 store 状态,
/// 不要直接调 SchemaV1.makeModel() —— 否则将来加版本要改一堆地方。
enum CoreDataSchema {
    /// PersistenceController 用的 head model。
    static func currentModel() -> NSManagedObjectModel {
        SchemaVersion.current.makeModel()
    }

    /// 检查 sqlite 元数据里的 schema hash 跟当前 model 是不是匹配。
    /// - 返回 nil:文件不存在 / 元数据读不出来(可能是 corrupt)
    /// - 返回 true:hash 一致,直接 load 就行
    /// - 返回 false:不一致,load 时 Core Data 会尝试 lightweight migration
    ///
    /// 这个不是给 hot path 用的(load 阶段 Core Data 自己会判),主要给
    /// 失败诊断用 —— alert 文案里告诉用户"你的库 hash 跟当前不匹配"。
    static func storeIsCompatibleWithCurrentModel(at url: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url, options: nil
        ) else { return nil }
        return currentModel().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    /// 从 sqlite 元数据里抽出"上次保存时的 model versionIdentifiers"。
    /// SchemaV1 写入的是 ["v1"],V2 是 ["v2"],老用户库可能是空 set(没有
    /// 显式版本号 —— 即"V0",我们引入 schema versioning 之前的库)。
    static func storeVersionIdentifiers(at url: URL) -> Set<String>? {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url, options: nil
        ) else { return nil }
        // NSStoreModelVersionIdentifiersKey 在 sqlite 里存成 NSArray<String>,
        // 但有些老路径返回 NSSet。两种都收。
        if let array = metadata[NSStoreModelVersionIdentifiersKey] as? [String] {
            return Set(array)
        }
        if let set = metadata[NSStoreModelVersionIdentifiersKey] as? Set<String> {
            return set
        }
        return nil
    }
}
