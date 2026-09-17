import Foundation

/// JSON-RPC 2.0 请求解码 + MCP 方法路由(initialize / ping / tools.list /
/// tools.call)。纯逻辑,不碰网络 —— 方便脱离 NWListener 单独喂 JSON 测试。
/// 不实现 resources/prompts:Perch 的 MCP 场景只是"读写便签",tool calling
/// 已经够用,没必要照搬 uni-reader(PDF 阅读器,需要暴露文档为 resource)的
/// 那一层。
enum MCPProtocolVersion {
    static let supported = "2025-06-18"
}

struct MCPDispatchResult {
    /// nil 表示这是一条 notification(请求里没有 id),按 JSON-RPC spec 不需要
    /// 任何响应体 —— 调用方应回 202 Accepted 空 body。
    var responseObject: MCPObject?
}

enum MCPDispatcher {
    static func dispatch(body: Data, catalog: MCPCatalog) async -> MCPDispatchResult {
        guard let json = MCPJSON.decode(body) as? MCPObject else {
            return MCPDispatchResult(responseObject: errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }

        let isNotification = json["id"] == nil
        let id: Any = json["id"] ?? NSNull()

        guard let method = json["method"] as? String else {
            return isNotification ? MCPDispatchResult(responseObject: nil)
                : MCPDispatchResult(responseObject: errorResponse(id: id, code: -32600, message: "Invalid Request"))
        }

        if isNotification {
            // 目前只关心 notifications/initialized —— 单连接单请求模型下没有
            // 需要维护的会话状态,直接忽略即可。
            return MCPDispatchResult(responseObject: nil)
        }

        let params = json["params"] as? MCPObject ?? [:]

        do {
            let result = try await handle(method: method, params: params, catalog: catalog)
            return MCPDispatchResult(responseObject: ["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as MCPInvalidParams {
            return MCPDispatchResult(responseObject: errorResponse(id: id, code: -32602, message: error.message))
        } catch let error as MCPMethodNotFound {
            return MCPDispatchResult(responseObject: errorResponse(id: id, code: -32601, message: error.message))
        } catch {
            return MCPDispatchResult(responseObject: errorResponse(id: id, code: -32603, message: "\(error)"))
        }
    }

    private static func handle(method: String, params: MCPObject, catalog: MCPCatalog) async throws -> MCPObject {
        switch method {
        case "initialize":
            return [
                "protocolVersion": MCPProtocolVersion.supported,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "perch", "version": appVersion]
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": catalog.toolDescriptors()]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPInvalidParams("missing required 'name'")
            }
            let arguments = params["arguments"] as? MCPObject ?? [:]
            return try await catalog.call(name: name, arguments: arguments)
        default:
            throw MCPMethodNotFound("method not found: \(method)")
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> MCPObject {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
