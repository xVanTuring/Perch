import Foundation

/// - `.read`:任何时候都能调。
/// - `.write`:会新建/修改/删除数据,受 `SettingsKey.mcpAllowWrite` 总闸控制
///   (默认关闭),闸门检查集中在 `MCPCatalog.call`,不用每个 tool handler 各自判断。
enum MCPToolTier {
    case read
    case write
}

struct MCPToolResult {
    var text: String
    var structured: MCPObject?

    init(text: String, structured: MCPObject? = nil) {
        self.text = text
        self.structured = structured
    }
}

struct MCPTool {
    let name: String
    let title: String
    let description: String
    let inputSchema: MCPObject
    let tier: MCPToolTier
    let handler: (MCPArgs) async throws -> MCPToolResult
}

/// 工具注册表 + 统一的写权限闸门。所有 tool handler 都通过 `call(name:arguments:)`
/// 执行,"写权限关闭时任何写操作都拒绝"这条规则只写这一处。
final class MCPCatalog {
    private var tools: [String: MCPTool] = [:]
    /// 由 MCPServer 注入,读 `SettingsKey.mcpAllowWrite` —— 这里不直接耦合
    /// UserDefaults key 名,方便单独测试 catalog。
    var isWriteAllowed: () -> Bool = { false }

    func register(_ tool: MCPTool) {
        tools[tool.name] = tool
    }

    func toolDescriptors() -> [MCPObject] {
        tools.values.sorted { $0.name < $1.name }.map { tool in
            [
                "name": tool.name,
                "title": tool.title,
                "description": tool.description,
                "inputSchema": tool.inputSchema,
                "annotations": [
                    "readOnlyHint": tool.tier == .read,
                    "destructiveHint": tool.tier == .write
                ]
            ]
        }
    }

    func call(name: String, arguments: MCPObject) async throws -> MCPObject {
        guard let tool = tools[name] else {
            throw MCPInvalidParams("unknown tool: \(name)")
        }
        if tool.tier == .write, !isWriteAllowed() {
            return errorResult("Write access is disabled. Enable \"Allow agents to write\" in Perch → Settings → Agent to use \(name).")
        }
        do {
            let result = try await tool.handler(MCPArgs(raw: arguments))
            var obj: MCPObject = ["content": [["type": "text", "text": result.text]]]
            if var structured = result.structured {
                // Claude Code 有 structuredContent 时只把它给模型、text 整段丢掉(2026-10-20 实测)。
                // 短 text(摘要、提示)抄进 `message`,模型才看得到;长 text(get_note 的正文这类)
                // 结构化里本来就有,不抄,免得 token 翻倍。
                if !result.text.isEmpty, result.text.count <= Self.messageLimit, structured["message"] == nil {
                    structured["message"] = result.text
                }
                obj["structuredContent"] = structured
            }
            return obj
        } catch let error as MCPToolError {
            return errorResult(error.message)
        }
    }

    /// 多长以内的 text 抄进结构化结果的 `message`(见 `call`)。
    static let messageLimit = 500

    private func errorResult(_ message: String) -> MCPObject {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}
