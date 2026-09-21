import Foundation
import CoreData

/// 在 CloudKit import 成功后扫一遍 Note / NoteGroup / NoteImage,把同 UUID 的重复 record
/// 合并掉。Apple 官方 sample "Synchronizing a Local Store to the Cloud" 推荐的
/// 兜底 pattern,因为 CloudKit 不支持 unique constraint,sync race / 本地 store
/// 重建会让同一逻辑 UUID 在云上留多个 CKRecord,import 全拉下来本地就有多份。
///
/// **触发时机:** `NSPersistentCloudKitContainer.eventChangedNotification`,
/// 仅 `event.type == .import && endDate != nil && error == nil` 时跑。
///
/// **去重规则:**
/// - **Note**:同 id 多条 → 按 `(isTrashed asc, updatedAt desc)` 排,**首条胜出**,
///   余下 delete。语义:活的优先于回收;并列时取最近更新的。
/// - **NoteGroup**:同 id 多条 → 按 `(sortOrder asc, createdAt asc)` 排,**首条
///   胜出**。败者里的 notes 全部 reassign 给胜者(保住数据),再 delete 败者。
///
/// **不去重「同名分组但不同 UUID」**:用户可能有意建两个同名,只按 UUID 判重。
///
/// **并发:** 用 `newBackgroundContext()` 跑,避免阻塞 viewContext。dedup 删除
/// 后 context.save → 走 `automaticallyMergesChangesFromParent` 自动同步到
/// viewContext + CloudKit(后者自动把 delete 推到云端,清理云上副本)。
final class CloudKitDeduplicator {
    private let container: NSPersistentCloudKitContainer
    private var observer: NSObjectProtocol?
    /// 防抖:同时刻只跑一次,连续 import 事件不重叠扫描。
    private var dedupInFlight = false
    private let lock = NSLock()

    init(container: NSPersistentCloudKitContainer) {
        self.container = container
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] note in
            self?.handleEvent(note)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func handleEvent(_ note: Notification) {
        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
              event.type == .import,
              event.endDate != nil,
              event.error == nil
        else { return }

        lock.lock()
        if dedupInFlight { lock.unlock(); return }
        dedupInFlight = true
        lock.unlock()

        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.perform { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.dedupInFlight = false
                self.lock.unlock()
            }

            let removedNotes = self.dedupNotes(in: context)
            let removedGroups = self.dedupGroups(in: context)
            let removedImages = self.dedupImages(in: context)
            let removed = removedNotes + removedGroups + removedImages
            guard removed > 0 else { return }

            do {
                try context.save()
                NSLog("Perch: dedup removed %d note(s) + %d group(s) + %d image(s) after CloudKit import",
                      removedNotes, removedGroups, removedImages)
            } catch {
                NSLog("Perch: dedup save failed: %@", "\(error)")
            }
        }
    }

    /// 扫 Note 重复,删败者。返回删除条数。
    /// 排序保证同 id 的 group 内,**胜者排在最前** —— 我们一遍扫描即可。
    private func dedupNotes(in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.sortDescriptors = [
            NSSortDescriptor(key: "id", ascending: true),
            NSSortDescriptor(key: "isTrashed", ascending: true),  // false 优先
            NSSortDescriptor(key: "updatedAt", ascending: false), // 最近更新优先
        ]
        guard let notes = try? context.fetch(request) else { return 0 }

        var removed = 0
        var lastID: UUID? = nil
        for note in notes {
            // id 理论上不会 nil(Note.create 总是设),但模型层是 optional,防御一下。
            // 没法判重就跳过(留着,不删)。
            let currentID: UUID? = note.value(forKey: "id") as? UUID
            guard let id = currentID else { continue }
            if id != lastID {
                lastID = id
                continue  // 胜者
            }
            context.delete(note)
            removed += 1
        }
        return removed
    }

    /// 扫 NoteImage 重复(同 id 多份):留最早创建的一份,余下删除。同 id 的图片内容
    /// 相同(id 一次生成、之后不变),删哪份都不丢数据。
    private func dedupImages(in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NoteImage>(entityName: "NoteImage")
        request.sortDescriptors = [
            NSSortDescriptor(key: "id", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true),
        ]
        guard let images = try? context.fetch(request) else { return 0 }

        var removed = 0
        var lastID: UUID? = nil
        for image in images {
            guard let id = image.id else { continue }
            if id != lastID {
                lastID = id
                continue  // 胜者
            }
            context.delete(image)
            removed += 1
        }
        return removed
    }

    /// 扫 NoteGroup 重复,把败者的 notes 转给胜者后删败者。
    private func dedupGroups(in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NoteGroup>(entityName: "NoteGroup")
        request.sortDescriptors = [
            NSSortDescriptor(key: "id", ascending: true),
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true),
        ]
        guard let groups = try? context.fetch(request) else { return 0 }

        var removed = 0
        var lastID: UUID? = nil
        var winner: NoteGroup? = nil
        for group in groups {
            let currentID: UUID? = group.value(forKey: "id") as? UUID
            guard let id = currentID else { continue }
            if id != lastID {
                lastID = id
                winner = group
                continue
            }
            // 同 id,这条是败者:把 notes 转给 winner 再删
            guard let winner else { continue }
            for note in group.notes {
                note.group = winner
            }
            context.delete(group)
            removed += 1
        }
        return removed
    }
}
