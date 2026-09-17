import Foundation

extension MCPTools {
    @MainActor
    static func registerGroupTools(into server: MCPServer) {
        let facade = server.facade
        let catalog = server.catalog

        catalog.register(MCPTool(
            name: "list_groups",
            title: "List groups",
            description: "List all note groups with their note counts.",
            inputSchema: MCPSchema.object([:]),
            tier: .read
        ) { _ in
            let groups = await facade.listGroups()
            return MCPToolResult(text: "\(groups.count) group(s).", structured: ["groups": groups])
        })

        catalog.register(MCPTool(
            name: "create_group",
            title: "Create group",
            description: "Create a new note group.",
            inputSchema: MCPSchema.object(["name": MCPSchema.string("Group name")], required: ["name"]),
            tier: .write
        ) { args in
            let name = try args.string("name")
            let group = try await facade.createGroup(name: name)
            return MCPToolResult(text: "Created group \(group["id"] ?? "").", structured: group)
        })
    }
}
