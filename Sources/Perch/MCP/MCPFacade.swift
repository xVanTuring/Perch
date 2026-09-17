import CoreData
import Foundation

/// MCP 唯一接触 Core Data / `FloatingNotesRegistry` 的地方。所有变更都复用
/// 应用其它入口已经在用的方法(`Note.create`、`FloatingNotesRegistry.delete`
/// 等),不重新发明写库逻辑 —— 这样 MCP 触发的操作跟 UI 操作行为完全一致
/// (比如删除一样是软删进回收站,pin 一样会真的开出浮窗)。
///
/// `@MainActor` 是因为 `PersistenceController.shared.container.viewContext`
/// 是 main-queue-confined 的 context,应用别处也都是直接在主线程摸它,这里跟着
/// 同一约定,不用 `context.perform`。
@MainActor
final class MCPFacade {
    private let context: NSManagedObjectContext
    private let floating: FloatingNotesRegistry

    init(context: NSManagedObjectContext, floating: FloatingNotesRegistry) {
        self.context = context
        self.floating = floating
    }

    // MARK: - Lookup

    private func note(id: UUID) throws -> Note {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        guard let note = (try? context.fetch(request))?.first else {
            throw MCPToolError("no note with id \(id.uuidString)")
        }
        return note
    }

    private func group(id: UUID) throws -> NoteGroup {
        let request = NSFetchRequest<NoteGroup>(entityName: "NoteGroup")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        guard let group = (try? context.fetch(request))?.first else {
            throw MCPToolError("no group with id \(id.uuidString)")
        }
        return group
    }

    // MARK: - State

    func state() -> MCPObject {
        let pinnedRequest = NSFetchRequest<Note>(entityName: "Note")
        pinnedRequest.predicate = NSPredicate(format: "isPinned == %@", NSNumber(value: true))
        return [
            "activeNotes": (try? context.count(for: Note.sortedFetchRequest())) ?? 0,
            "pinnedNotes": (try? context.count(for: pinnedRequest)) ?? 0,
            "archivedNotes": (try? context.count(for: Note.archivedFetchRequest())) ?? 0,
            "trashedNotes": (try? context.count(for: Note.trashedFetchRequest())) ?? 0,
            "groups": (try? context.count(for: NoteGroup.sortedFetchRequest())) ?? 0,
            "writeAllowed": UserDefaults.standard.bool(forKey: SettingsKey.mcpAllowWrite)
        ]
    }

    // MARK: - Notes

    private func summary(_ note: Note) -> MCPObject {
        [
            "id": note.id.uuidString,
            "title": note.displayTitle,
            "contentPreview": String(note.content.prefix(200)),
            "isPinned": note.isPinned,
            "isArchived": note.isArchived,
            "isTrashed": note.isTrashed,
            "colorIndex": Int(note.colorIndex),
            "groupId": note.group.map { $0.id.uuidString } ?? NSNull(),
            "groupName": note.group.map { $0.name } ?? NSNull(),
            "createdAt": ISO8601DateFormatter().string(from: note.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: note.updatedAt)
        ]
    }

    private func detail(_ note: Note) -> MCPObject {
        var obj = summary(note)
        obj["content"] = note.content
        return obj
    }

    private func fetchRequest(scope: String) -> NSFetchRequest<Note> {
        switch scope {
        case "archived": return Note.archivedFetchRequest()
        case "trashed": return Note.trashedFetchRequest()
        default: return Note.sortedFetchRequest()
        }
    }

    func listNotes(scope: String, groupID: UUID?, pinnedOnly: Bool, limit: Int, offset: Int) -> [MCPObject] {
        var notes = (try? context.fetch(fetchRequest(scope: scope))) ?? []
        if let groupID { notes = notes.filter { $0.group?.id == groupID } }
        if pinnedOnly { notes = notes.filter(\.isPinned) }
        return notes.dropFirst(offset).prefix(limit).map(summary)
    }

    func getNote(id: UUID) throws -> MCPObject {
        detail(try note(id: id))
    }

    func searchNotes(query: String, scope: String, limit: Int) -> [MCPObject] {
        let notes = (try? context.fetch(fetchRequest(scope: scope))) ?? []
        let matched = notes.filter { $0.content.localizedCaseInsensitiveContains(query) }
        return matched.prefix(limit).map(summary)
    }

    @discardableResult
    func createNote(content: String, groupID: UUID?, pinned: Bool) throws -> MCPObject {
        let note = Note.create(in: context, content: content)
        if let groupID { note.group = try group(id: groupID) }
        try context.save()
        // 复用 registry.show,而不是直接写 isPinned —— 这样"pinned"真的打开一个
        // 浮窗,跟用户从列表点开的效果一致(isPinned 单纯写字段不会有窗口出现)。
        if pinned { floating.show(note: note) }
        return detail(note)
    }

    func updateNote(id: UUID, content: String) throws -> MCPObject {
        let note = try note(id: id)
        note.content = content
        note.updatedAt = Date()
        try context.save()
        return detail(note)
    }

    func moveNote(id: UUID, groupID: UUID?) throws -> MCPObject {
        let note = try note(id: id)
        note.group = try groupID.map { try group(id: $0) }
        try context.save()
        return summary(note)
    }

    func setPinned(id: UUID, pinned: Bool) throws -> MCPObject {
        let note = try note(id: id)
        if pinned {
            floating.show(note: note)
        } else if note.isPinned {
            floating.toggle(note: note)
        }
        return summary(note)
    }

    func archiveNote(id: UUID) async throws -> MCPObject {
        let note = try note(id: id)
        floating.archive(note: note)
        await waitForDeferredRegistryWrite()
        return summary(note)
    }

    func unarchiveNote(id: UUID) async throws -> MCPObject {
        let note = try note(id: id)
        floating.unarchive(note: note)
        await waitForDeferredRegistryWrite()
        return summary(note)
    }

    func deleteNote(id: UUID) async throws -> MCPObject {
        let note = try note(id: id)
        floating.delete(note: note)
        await waitForDeferredRegistryWrite()
        return ["id": id.uuidString, "movedToTrash": true]
    }

    func restoreNote(id: UUID) async throws -> MCPObject {
        let note = try note(id: id)
        floating.restore(note: note)
        await waitForDeferredRegistryWrite()
        return summary(note)
    }

    /// `FloatingNotesRegistry.delete/restore/archive/unarchive` intentionally
    /// defer their actual field writes by one runloop tick via
    /// `DispatchQueue.main.async` (see its own comments — lets a closing
    /// sticky window's SwiftUI tree tear down before the note object it was
    /// observing gets mutated/faulted, avoiding a crash). That means reading
    /// the note right back after calling them sees stale data. Enqueuing our
    /// own `DispatchQueue.main.async` block here and awaiting it is
    /// guaranteed (GCD serial-queue FIFO) to run strictly after whatever the
    /// registry call just enqueued, so by the time we resume the mutation
    /// has landed and `summary(note)` reads the real post-write state.
    private func waitForDeferredRegistryWrite() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Groups

    private func groupSummary(_ group: NoteGroup) -> MCPObject {
        ["id": group.id.uuidString, "name": group.name, "noteCount": group.notes.count]
    }

    func listGroups() -> [MCPObject] {
        let groups = (try? context.fetch(NoteGroup.sortedFetchRequest())) ?? []
        return groups.map(groupSummary)
    }

    @discardableResult
    func createGroup(name: String) throws -> MCPObject {
        let group = NoteGroup.create(in: context, name: name)
        try context.save()
        return groupSummary(group)
    }
}
