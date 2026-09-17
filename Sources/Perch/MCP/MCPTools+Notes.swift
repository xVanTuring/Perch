import Foundation

extension MCPTools {
    @MainActor
    static func registerNoteTools(into server: MCPServer) {
        let facade = server.facade
        let catalog = server.catalog

        catalog.register(MCPTool(
            name: "list_notes",
            title: "List notes",
            description: "List notes, optionally filtered by scope, group, or pinned state.",
            inputSchema: MCPSchema.object([
                "scope": MCPSchema.string("Which bucket to list (default: active)", enumValues: ["active", "archived", "trashed"]),
                "group_id": MCPSchema.nullableString("Only notes in this group UUID"),
                "pinned_only": MCPSchema.boolean("Only notes currently pinned/open as a sticky"),
                "limit": MCPSchema.integer("Max notes to return (default 50)", minimum: 1, maximum: 200),
                "offset": MCPSchema.integer("Skip this many notes, for pagination", minimum: 0)
            ]),
            tier: .read
        ) { args in
            let scope = args.optionalString("scope") ?? "active"
            let groupID = try args.optionalUUID("group_id")
            let pinnedOnly = args.bool("pinned_only", default: false)
            let limit = min(max(args.int("limit", default: 50), 1), 200)
            let offset = max(args.int("offset", default: 0), 0)
            let notes = await facade.listNotes(scope: scope, groupID: groupID, pinnedOnly: pinnedOnly, limit: limit, offset: offset)
            return MCPToolResult(text: "\(notes.count) note(s).", structured: ["notes": notes])
        })

        catalog.register(MCPTool(
            name: "get_note",
            title: "Get note",
            description: "Fetch a single note's full content and metadata by id.",
            inputSchema: MCPSchema.object(["id": MCPSchema.string("Note UUID")], required: ["id"]),
            tier: .read
        ) { args in
            let id = try args.requiredUUID("id")
            let note = try await facade.getNote(id: id)
            return MCPToolResult(text: (note["content"] as? String) ?? "", structured: note)
        })

        catalog.register(MCPTool(
            name: "search_notes",
            title: "Search notes",
            description: "Case-insensitive substring search over note content.",
            inputSchema: MCPSchema.object([
                "query": MCPSchema.string("Text to search for"),
                "scope": MCPSchema.string("Which bucket to search (default: active)", enumValues: ["active", "archived", "trashed"]),
                "limit": MCPSchema.integer("Max results (default 50)", minimum: 1, maximum: 200)
            ], required: ["query"]),
            tier: .read
        ) { args in
            let query = try args.string("query")
            let scope = args.optionalString("scope") ?? "active"
            let limit = min(max(args.int("limit", default: 50), 1), 200)
            let notes = await facade.searchNotes(query: query, scope: scope, limit: limit)
            return MCPToolResult(text: "\(notes.count) match(es) for \"\(query)\".", structured: ["notes": notes])
        })

        catalog.register(MCPTool(
            name: "create_note",
            title: "Create note",
            description: "Create a new note. Set pinned:true to also open it as a floating sticky window on screen.",
            inputSchema: MCPSchema.object([
                "content": MCPSchema.string("Note body (markdown)"),
                "group_id": MCPSchema.nullableString("Group UUID to file the note under"),
                "pinned": MCPSchema.boolean("Also open as a floating sticky window (default false)")
            ], required: ["content"]),
            tier: .write
        ) { args in
            let content = try args.string("content")
            let groupID = try args.optionalUUID("group_id")
            let pinned = args.bool("pinned", default: false)
            let note = try await facade.createNote(content: content, groupID: groupID, pinned: pinned)
            return MCPToolResult(text: "Created note \(note["id"] ?? "").", structured: note)
        })

        catalog.register(MCPTool(
            name: "update_note",
            title: "Update note content",
            description: "Replace a note's full content.",
            inputSchema: MCPSchema.object([
                "id": MCPSchema.string("Note UUID"),
                "content": MCPSchema.string("New note body (markdown); replaces the existing content entirely")
            ], required: ["id", "content"]),
            tier: .write
        ) { args in
            let id = try args.requiredUUID("id")
            let content = try args.string("content")
            let note = try await facade.updateNote(id: id, content: content)
            return MCPToolResult(text: "Updated note \(id.uuidString).", structured: note)
        })

        catalog.register(MCPTool(
            name: "move_note",
            title: "Move note to group",
            description: "Assign a note to a group. Pass group_id: null to remove it from its current group.",
            inputSchema: MCPSchema.object([
                "id": MCPSchema.string("Note UUID"),
                "group_id": MCPSchema.nullableString("Target group UUID, or null to ungroup")
            ], required: ["id", "group_id"]),
            tier: .write
        ) { args in
            let id = try args.requiredUUID("id")
            try args.requiresKey("group_id")
            let groupID: UUID? = args.isNull("group_id") ? nil : try args.requiredUUID("group_id")
            let note = try await facade.moveNote(id: id, groupID: groupID)
            return MCPToolResult(text: "Moved note \(id.uuidString).", structured: note)
        })

        catalog.register(MCPTool(
            name: "set_note_pinned",
            title: "Pin or unpin note",
            description: "Pinning opens the note as a floating sticky window on screen (and keeps it auto-restored on next launch); unpinning closes it.",
            inputSchema: MCPSchema.object([
                "id": MCPSchema.string("Note UUID"),
                "pinned": MCPSchema.boolean("true = open as sticky, false = close it")
            ], required: ["id", "pinned"]),
            tier: .write
        ) { args in
            let id = try args.requiredUUID("id")
            guard let pinned = args.raw["pinned"] as? Bool else {
                throw MCPInvalidParams("missing required boolean 'pinned'")
            }
            let note = try await facade.setPinned(id: id, pinned: pinned)
            return MCPToolResult(text: "Set pinned=\(pinned) for note \(id.uuidString).", structured: note)
        })

        catalog.register(MCPTool(
            name: "archive_note",
            title: "Archive note",
            description: "Move a note to the Archive. Reversible with unarchive_note.",
            inputSchema: MCPSchema.object(["id": MCPSchema.string("Note UUID")], required: ["id"]),
            tier: .write
        ) { args in
            let id = try args.requiredUUID("id")
            let note = try await facade.archiveNote(id: id)
            return MCPToolResult(text: "Archived note \(id.uuidString).", structured: note)
        })

        catalog.register(MCPTool(
            name: "unarchive_note",
            title: "Unarchive note",
            description: "Restore an archived note back to the active list.",
            inputSchema: MCPSchema.object(["id": MCPSchema.string("Note UUID")], required: ["id"]),
            tier: .write
        ) { args in
            let id = try args.requiredUUID("id")
            let note = try await facade.unarchiveNote(id: id)
            return MCPToolResult(text: "Unarchived note \(id.uuidString).", structured: note)
        })

        catalog.register(MCPTool(
            name: "delete_note",
            title: "Delete note",
            description: "Soft-delete a note to the Trash. Reversible with restore_note until the trash retention period expires.",
            inputSchema: MCPSchema.object(["id": MCPSchema.string("Note UUID")], required: ["id"]),
            tier: .write
        ) { args in
            let id = try args.requiredUUID("id")
            let result = try await facade.deleteNote(id: id)
            return MCPToolResult(text: "Moved note \(id.uuidString) to Trash.", structured: result)
        })

        catalog.register(MCPTool(
            name: "restore_note",
            title: "Restore note from Trash",
            description: "Restore a trashed note back to the active list.",
            inputSchema: MCPSchema.object(["id": MCPSchema.string("Note UUID")], required: ["id"]),
            tier: .write
        ) { args in
            let id = try args.requiredUUID("id")
            let note = try await facade.restoreNote(id: id)
            return MCPToolResult(text: "Restored note \(id.uuidString).", structured: note)
        })
    }
}
