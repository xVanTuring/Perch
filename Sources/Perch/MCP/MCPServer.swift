import AppKit
import CoreData
import Foundation
import Network

/// MCP(Model Context Protocol)服务器:本机唯一入口,让 AI Agent(Claude Code
/// 等)通过 HTTP + JSON-RPC 读写便签。协议/HTTP 解析是纯逻辑(见
/// MCPProtocol.swift / MCPHTTP.swift),这里只负责 NWListener 网络层、鉴权、
/// 生命周期。跑在应用进程内自己的 dispatch queue 上,不是独立进程/target ——
/// 参考 uni-reader 的 Sources/MCP/MCPServer.swift 同一套架构。
@MainActor
final class MCPServer: ObservableObject {
    /// 弱引用,所有权在 AppDelegate 的 `private var mcpServer`(全程存活)。
    /// Settings → Agent tab 靠这个拿到运行中的实例(同 FloatingNotesRegistry.shared
    /// 的用法)。
    static weak var shared: MCPServer?

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    let facade: MCPFacade
    let catalog = MCPCatalog()

    private var listener: NWListener?
    private let netQueue = DispatchQueue(label: "tech.xvanturing.perch.mcp.net")
    /// initialize 响应里带的 session id。单进程本地工具,不做多会话跟踪 ——
    /// 固定一个值只是为了满足 Streamable HTTP 规范"服务端应返回 session id"
    /// 这条,后续请求不强制校验它。
    private let sessionID = UUID().uuidString

    private static let tokenAccount = "mcp-token"

    /// 正在服务的口令,`start()` 时从钥匙串读一次,重置口令时跟着换。原先每个请求都在主线程现读,
    /// 读失败还会当成「没有」去生成新的写回 —— 一次读失败(钥匙串锁着、访问被拒)就可能把口令换掉,
    /// 已配置的客户端从此全部 401,看起来就是「过一阵连不上了」。
    private var activeToken: String?

    // 监听器自愈。失败的 NWListener 不会自己恢复;原先 `.failed` 只把 isRunning 置 false,
    // 之后一直停着、客户端连过来就是拒绝连接。现在用户没手动停(`wanted`)就退避重开,
    // 唤醒后和每 `healthInterval` 再自己连一下自己,连不上就重开(状态回调报不出来的那种死法)。
    private var wanted = false
    /// 每换一个监听器 +1,旧监听器迟到的回调据此丢掉。
    private var listenerGen = 0
    /// 当前监听器实际用的端口(`port` 读的是设置,可能已经改了还没重启)。
    private var servingPort = 0
    private var retryDelay: TimeInterval = 1
    private var retryWork: DispatchWorkItem?
    private var healthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private static let healthInterval: TimeInterval = 300

    init(context: NSManagedObjectContext, floating: FloatingNotesRegistry) {
        self.facade = MCPFacade(context: context, floating: floating)
        MCPServer.shared = self
        catalog.isWriteAllowed = { UserDefaults.standard.bool(forKey: SettingsKey.mcpAllowWrite) }
    }

    var port: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.mcpServerPort)
        return (1024...65535).contains(stored) ? stored : 8774
    }

    var bindAllInterfaces: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.mcpBindAllInterfaces)
    }

    /// 首次打开 Settings → Agent 就已经有 token 可复制,不需要用户先手动点一次"生成"。
    /// 只有钥匙串里**确实没有**才生成;读失败时不生成(那会盖掉一个其实还在的口令),
    /// 给出正在服务的那个。
    var token: String {
        switch Keychain.lookup(account: Self.tokenAccount) {
        case .found(let existing):
            return existing
        case .missing:
            let generated = UUID().uuidString
            Keychain.write(generated, account: Self.tokenAccount)
            return generated
        case .failed(let status):
            NSLog("Perch MCP: keychain read failed (%d); keeping the token in use", status)
            return activeToken ?? ""
        }
    }

    @discardableResult
    func regenerateToken() -> String {
        let generated = UUID().uuidString
        if Keychain.write(generated, account: Self.tokenAccount) {
            activeToken = generated
        } else {
            NSLog("Perch MCP: keychain write failed; the old token stays in use")
        }
        return activeToken ?? generated   // 写失败时设置页继续显示真正在用的那个
    }

    func start() {
        guard listener == nil else { return }
        wanted = true
        retryWork?.cancel(); retryWork = nil
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // 等网络栈缓一下再查
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    Task { @MainActor in self?.checkHealth(reason: "wake") }
                }
            }
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            lastError = "invalid port \(port)"
            return
        }
        // 口令读不出来(钥匙串锁着)就过会儿再试 —— 不生成新的,也不带着空口令开门
        switch Keychain.lookup(account: Self.tokenAccount) {
        case .found(let existing):
            activeToken = existing
        case .missing:
            activeToken = token
        case .failed(let status):
            lastError = "can't read the access token from the keychain (OSStatus \(status))"
            listenerDied()
            return
        }

        let params = NWParameters.tcp
        // 端口切换后立刻重启会撞上一个连接还在 TIME_WAIT 的旧 socket,允许复用
        // 本地地址,避免 "address already in use"。
        params.allowLocalEndpointReuse = true
        let host: NWEndpoint.Host = bindAllInterfaces ? "0.0.0.0" : "127.0.0.1"
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: nwPort)

        do {
            // 端口已经通过 `params.requiredLocalEndpoint` 指定 —— 不能再用
            // `NWListener(using:on:)` 重复传一次端口,两者一起给会直接抛
            // EINVAL(实测)。
            let listener = try NWListener(using: params)
            listenerGen += 1
            let gen = listenerGen
            servingPort = port
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    guard gen == self.listenerGen else { return }   // 旧监听器迟到的回调
                    switch state {
                    case .failed(let error):
                        NSLog("Perch MCP: listener failed: %@", "\(error)")
                        self.lastError = "\(error)"
                        self.listenerDied()
                    case .ready:
                        NSLog("Perch MCP: listening on %@:%d", self.bindAllInterfaces ? "0.0.0.0" : "127.0.0.1", self.port)
                        self.isRunning = true
                        self.lastError = nil
                        self.retryDelay = 1
                        self.startHealthTimer()
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: netQueue)
            self.listener = listener
        } catch {
            NSLog("Perch MCP: failed to start listener: %@", "\(error)")
            lastError = "\(error)"
        }
    }

    func stop() {
        wanted = false
        retryWork?.cancel(); retryWork = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        closeListener()
    }

    private func closeListener() {
        listenerGen += 1
        listener?.cancel()
        listener = nil
        healthTimer?.invalidate(); healthTimer = nil
        isRunning = false
    }

    /// 监听器没了(`.failed`、健康检查连不上、口令暂时读不出):关掉它,用户没手动停就按
    /// 1、2、4…30 秒退避重开。
    private func listenerDied() {
        closeListener()
        guard wanted else { return }
        retryWork?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted, self.listener == nil else { return }
                self.start()
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        NSLog("Perch MCP: reopening the listener in %ds", Int(delay))
    }

    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth(reason: "periodic") }
        }
    }

    /// 自己连一下自己的端口(绑 0.0.0.0 时也收 127.0.0.1);几秒内连不上,不管状态怎么说,监听都已经没了。
    private func checkHealth(reason: String) {
        guard wanted, isRunning, let port = NWEndpoint.Port(rawValue: UInt16(servingPort)) else { return }
        let gen = listenerGen
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        var settled = false   // 只在 netQueue 上读写
        let finish: (Bool) -> Void = { [weak self] ok in
            guard !settled else { return }
            settled = true
            conn.cancel()
            guard !ok else { return }
            Task { @MainActor in
                guard let self, self.wanted, gen == self.listenerGen else { return }
                NSLog("Perch MCP: health check (%@): nothing answers on 127.0.0.1:%d, reopening", reason, self.servingPort)
                self.listenerDied()
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            // 连接被拒时停在 .waiting(ECONNREFUSED),不会进 .failed
            case .waiting, .failed: finish(false)
            default: break
            }
        }
        conn.start(queue: netQueue)
        netQueue.asyncAfter(deadline: .now() + 3) { finish(false) }
    }

    // MARK: - Connection handling
    //
    // 下面这几个方法标 `nonisolated`:它们跑在 NWListener/NWConnection 的回调
    // 队列(`netQueue`,不是主线程)上,不应该悄悄把网络 I/O 也顶到主线程。
    // 真正需要碰 MainActor 状态(catalog/facade/token)的地方显式 `Task { @MainActor in }`
    // 跳一次。

    private nonisolated func accept(_ connection: NWConnection) {
        let parser = MCPHTTPRequestParser()
        connection.start(queue: netQueue)
        receiveLoop(connection: connection, parser: parser)
    }

    private nonisolated func receiveLoop(connection: NWConnection, parser: MCPHTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    if let request = try parser.feed(data) {
                        self.respond(to: request, on: connection)
                        return
                    }
                } catch {
                    self.send(.json(400, ["error": "bad request"]), on: connection)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(connection: connection, parser: parser)
        }
    }

    private nonisolated func respond(to request: MCPHTTPRequest, on connection: NWConnection) {
        guard request.path == "/mcp" else {
            send(.json(404, ["error": "not found; POST to /mcp"]), on: connection)
            return
        }
        guard request.method == "POST" else {
            send(.json(405, ["error": "method not allowed; this server only supports POST /mcp"]), on: connection)
            return
        }
        // 非浏览器客户端(curl、Claude Code)通常不带 Origin —— 只在带了的时候校验,
        // 防的是恶意网页用 fetch() 打本机端口(DNS rebinding 类攻击),不是拦本地 CLI。
        if let origin = request.headers["origin"], !Self.isOriginAllowed(origin) {
            send(.json(403, ["error": "origin not allowed"]), on: connection)
            return
        }

        Task { @MainActor in
            guard self.isAuthorized(request.headers["authorization"]) else {
                self.send(.json(401, ["error": "missing or invalid bearer token"]), on: connection)
                return
            }
            let result = await MCPDispatcher.dispatch(body: request.body, catalog: self.catalog)
            guard let responseObject = result.responseObject else {
                self.send(.empty(202), on: connection)
                return
            }
            self.send(.json(200, responseObject, extraHeaders: ["Mcp-Session-Id": self.sessionID]), on: connection)
        }
    }

    private nonisolated func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated static func isOriginAllowed(_ origin: String) -> Bool {
        let allowedPrefixes = ["http://localhost", "http://127.0.0.1", "https://localhost", "https://127.0.0.1"]
        return allowedPrefixes.contains { origin.hasPrefix($0) }
    }

    /// 比的是 `start()` 时读好的 `activeToken`,不再每个请求现读钥匙串(见 `activeToken`)。
    private func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer "), let expected = activeToken, !expected.isEmpty else { return false }
        return Self.constantTimeEquals(String(header.dropFirst("Bearer ".count)), expected)
    }

    /// 避免用 `==` 直接比 token —— 字符串比较遇到第一个不同字符就短路返回,
    /// 理论上给计时攻击留了个侧信道。逐字节异或再判断全零,耗时跟内容无关。
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }
}
