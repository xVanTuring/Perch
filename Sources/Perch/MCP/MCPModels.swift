import Foundation

/// 松散的 JSON 对象 —— MCP 协议往返的最小公分母,免去为每个 tool 的输入/输出
/// 建 Codable 类型。跟 uni-reader 的 Sources/MCP 同一套约定。
typealias MCPObject = [String: Any]

enum MCPJSON {
    static func decode(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func encode(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
    }
}

/// 工具执行期间的"软失败"——不是协议错误,而是业务失败(比如笔记不存在)。
/// `MCPCatalog.call` 捕获后包成 `isError:true` 的正常响应,让模型看到消息去纠正
/// 参数重试,而不是收到一个 JSON-RPC 协议级错误。
struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 参数校验失败 —— 协议级错误,对应 JSON-RPC -32602 Invalid params。
struct MCPInvalidParams: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// JSON-RPC 方法路由失败(不是某个 tool 名字不对,是顶层 method 本身不存在)。
struct MCPMethodNotFound: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 从 tool 的 `arguments` 字典里按类型读值,统一在这里转成 `MCPInvalidParams`,
/// 每个 tool handler 就不用各自重复校验逻辑。
struct MCPArgs {
    let raw: MCPObject

    func string(_ key: String) throws -> String {
        guard let value = raw[key] as? String, !value.isEmpty else {
            throw MCPInvalidParams("missing or empty required string '\(key)'")
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        raw[key] as? String
    }

    func bool(_ key: String, default def: Bool) -> Bool {
        (raw[key] as? Bool) ?? def
    }

    func int(_ key: String, default def: Int) -> Int {
        if let n = raw[key] as? Int { return n }
        if let n = raw[key] as? NSNumber { return n.intValue }
        return def
    }

    func requiredUUID(_ key: String) throws -> UUID {
        let value = try string(key)
        guard let uuid = UUID(uuidString: value) else {
            throw MCPInvalidParams("'\(key)' is not a valid UUID: \(value)")
        }
        return uuid
    }

    /// 完全可选:没传这个 key,或传了 null,都当作"没有值"。用于 create_note /
    /// list_notes 这类"不指定就是默认行为"的字段。
    func optionalUUID(_ key: String) throws -> UUID? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        guard let str = value as? String, let uuid = UUID(uuidString: str) else {
            throw MCPInvalidParams("'\(key)' is not a valid UUID")
        }
        return uuid
    }

    /// 校验某个 key 必须出现在 `arguments` 里(值本身可以是 null)。用于
    /// move_note 的 group_id —— "必须显式传,null 表示取消分组",跟"完全不传"
    /// 语义不同,不能用 `optionalUUID` 的默认值兜底。
    func requiresKey(_ key: String) throws {
        guard raw.keys.contains(key) else {
            throw MCPInvalidParams("missing required key '\(key)' (pass null explicitly if you mean \"no value\")")
        }
    }

    func isNull(_ key: String) -> Bool {
        raw[key] is NSNull
    }
}

/// JSON Schema 构造小工具,只覆盖 MCP tool `inputSchema` 需要的子集。
enum MCPSchema {
    static func object(_ properties: MCPObject, required: [String] = []) -> MCPObject {
        var obj: MCPObject = ["type": "object", "properties": properties]
        if !required.isEmpty { obj["required"] = required }
        return obj
    }

    static func string(_ description: String, enumValues: [String]? = nil) -> MCPObject {
        var obj: MCPObject = ["type": "string", "description": description]
        if let enumValues { obj["enum"] = enumValues }
        return obj
    }

    static func boolean(_ description: String) -> MCPObject {
        ["type": "boolean", "description": description]
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> MCPObject {
        var obj: MCPObject = ["type": "integer", "description": description]
        if let minimum { obj["minimum"] = minimum }
        if let maximum { obj["maximum"] = maximum }
        return obj
    }

    /// 允许显式传 `null` 的字符串字段(比如"传 null 取消分组")。
    static func nullableString(_ description: String) -> MCPObject {
        ["type": ["string", "null"], "description": description]
    }
}
