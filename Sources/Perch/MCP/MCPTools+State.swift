import Foundation

extension MCPTools {
    @MainActor
    static func registerState(into server: MCPServer) {
        let facade = server.facade

        server.catalog.register(MCPTool(
            name: "get_state",
            title: "Perch state",
            description: "Note/group counts and whether write tools are currently allowed. Call this first to orient yourself.",
            inputSchema: MCPSchema.object([:]),
            tier: .read
        ) { _ in
            let state = await facade.state()
            let lines = [
                "Active notes: \(state["activeNotes"] ?? 0) (pinned: \(state["pinnedNotes"] ?? 0))",
                "Archived notes: \(state["archivedNotes"] ?? 0)",
                "Trashed notes: \(state["trashedNotes"] ?? 0)",
                "Groups: \(state["groups"] ?? 0)",
                "Write access allowed: \(state["writeAllowed"] ?? false)"
            ]
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: state)
        })
    }
}
