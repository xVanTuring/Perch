import Foundation

struct MCPHTTPRequest {
    var method: String
    var path: String
    /// key 已转小写,方便大小写不敏感查找(HTTP header 名不区分大小写)。
    var headers: [String: String]
    var body: Data
}

struct MCPHTTPResponse {
    var status: Int
    var statusText: String
    var headers: [String: String] = [:]
    var body: Data

    static func json(_ status: Int, _ object: Any, extraHeaders: [String: String] = [:]) -> MCPHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        return MCPHTTPResponse(status: status, statusText: statusText(for: status), headers: headers, body: MCPJSON.encode(object))
    }

    static func empty(_ status: Int, extraHeaders: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, statusText: statusText(for: status), headers: extraHeaders, body: Data())
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Internal Server Error"
        }
    }

    func serialize() -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        // 每条连接只服务一个请求(见 MCPHTTPRequestParser 的注释),显式关闭
        // 让客户端不去复用这条 TCP 连接发第二个请求。
        allHeaders["Connection"] = "close"

        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in allHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// 增量喂字节,凑齐一条完整 HTTP 请求(头部 + Content-Length 指定的 body)就
/// 返回它。只服务本地单发单收的 MCP 调用:不支持 chunked transfer encoding、
/// keep-alive、pipelining —— 每条 TCP 连接只处理一个请求(够用,MCP 客户端
/// 每次工具调用本来就是独立的 HTTP 请求)。
/// `@unchecked Sendable`:每个 parser 实例只在它所属的那条 NWConnection 的
/// `netQueue` 回调链里被访问,不会被并发访问 —— `receiveLoop` 递归时是串行的
/// 下一次 `receive` 回调,不是并行调用。
final class MCPHTTPRequestParser: @unchecked Sendable {
    private var buffer = Data()
    private var headParsed: (method: String, path: String, headers: [String: String])?
    private var contentLength: Int?

    /// 追加收到的字节;凑够一条完整请求时返回它,否则返回 nil 继续等下一批字节。
    /// 解析失败(比如损坏的请求行)抛错,调用方应回 400 并关闭连接。
    func feed(_ data: Data) throws -> MCPHTTPRequest? {
        buffer.append(data)

        if headParsed == nil {
            guard let separatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headerData = buffer.subdata(in: buffer.startIndex..<separatorRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                throw MCPToolError("invalid header encoding")
            }
            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                throw MCPToolError("empty request")
            }
            let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                throw MCPToolError("malformed request line: \(requestLine)")
            }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            headParsed = (String(parts[0]), String(parts[1]), headers)
            contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            buffer.removeSubrange(buffer.startIndex..<separatorRange.upperBound)
        }

        guard let head = headParsed, let length = contentLength else { return nil }
        guard buffer.count >= length else { return nil }

        let bodyEnd = buffer.index(buffer.startIndex, offsetBy: length)
        let body = buffer.subdata(in: buffer.startIndex..<bodyEnd)
        return MCPHTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body)
    }
}
