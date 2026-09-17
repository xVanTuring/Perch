import AppKit
import SwiftUI

/// MCP 服务器设置。让本机 AI Agent(Claude Code 等)通过 HTTP + JSON-RPC
/// 读写便签。结构仿 ICloudTab:顶部开关 + 立即生效的 start/stop(不像 iCloud
/// 那个需要重启),端口/绑定地址/写权限/token 几项配置,底部给可直接复制的
/// 客户端接入片段。
struct MCPServerTab: View {
    // MCPServer 在 AppDelegate.applicationDidFinishLaunching 里无条件构造
    //(是否真的开始监听端口才由 mcpServerEnabled 决定),Settings 窗口不可能在
    // 那之前打开,所以这里强解包是安全的 —— 前提跟 FloatingNotesRegistry.shared
    // 在 GeneralTab 里的用法一致。
    @ObservedObject private var server: MCPServer = MCPServer.shared!
    @ObservedObject private var loc = LocalizationManager.shared

    @AppStorage(SettingsKey.mcpServerEnabled) private var enabled: Bool = false
    @AppStorage(SettingsKey.mcpServerPort) private var port: Int = 8774
    @AppStorage(SettingsKey.mcpBindAllInterfaces) private var bindAll: Bool = false
    @AppStorage(SettingsKey.mcpAllowWrite) private var allowWrite: Bool = false

    @State private var token: String = ""
    @State private var copiedFeedback: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: setEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t(.mcpEnable))
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(server.isRunning ? Color.green : Color.secondary)
                    }
                }
                if let error = server.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            } footer: {
                Text(L.t(.mcpEnableDesc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: Binding(get: { port }, set: { port = $0; restartIfRunning() }), in: 1024...65535) {
                    LabeledContent(L.t(.mcpPort)) {
                        Text("\(port)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Binding(get: { bindAll }, set: { bindAll = $0; restartIfRunning() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t(.mcpBindAll))
                        Text(L.t(.mcpBindAllDesc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle(isOn: $allowWrite) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t(.mcpAllowWrite))
                        Text(L.t(.mcpAllowWriteDesc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if !allowWrite {
                    Text(L.t(.mcpReadOnlyHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(L.t(.mcpToken)) {
                    Text(token)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(L.t(.mcpCopyToken)) { copy(token, feedback: L.t(.mcpCopyToken)) }
                    Button(L.t(.mcpRegenerateToken), role: .destructive, action: regenerateToken)
                }
            } footer: {
                Text(L.t(.mcpTokenDesc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t(.mcpCliSnippetLabel)).font(.callout.weight(.medium))
                    snippetBlock(cliSnippet)
                    Button(L.t(.mcpCopyCli)) { copy(cliSnippet, feedback: L.t(.mcpCopyCli)) }

                    Text(L.t(.mcpJsonSnippetLabel)).font(.callout.weight(.medium)).padding(.top, 6)
                    snippetBlock(jsonSnippet)
                    Button(L.t(.mcpCopyJson)) { copy(jsonSnippet, feedback: L.t(.mcpCopyJson)) }
                }
            } header: {
                Text(L.t(.mcpClientConfigSection))
            }

            if let copiedFeedback {
                Text(copiedFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 760)
        .id(loc.current)
        .onAppear { token = server.token }
    }

    private var statusLine: String {
        server.isRunning ? L.t(.mcpStatusRunning, port) : L.t(.mcpStatusStopped)
    }

    private var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

    private var cliSnippet: String {
        "claude mcp add --transport http perch \(endpointURL) --header \"Authorization: Bearer \(token)\""
    }

    private var jsonSnippet: String {
        """
        {
          "mcpServers": {
            "perch": {
              "type": "http",
              "url": "\(endpointURL)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    @ViewBuilder
    private func snippetBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if newValue {
            server.start()
        } else {
            server.stop()
        }
    }

    /// 端口 / 绑定地址是 NWListener 创建时就固定的参数,改了必须整个重启监听
    /// 才能生效 —— 只在当前确实在跑的时候才重启,off 状态下改配置不该意外启动服务。
    private func restartIfRunning() {
        guard server.isRunning else { return }
        server.stop()
        server.start()
    }

    private func regenerateToken() {
        token = server.regenerateToken()
    }

    private func copy(_ text: String, feedback: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let message = "\(feedback) ✓"
        copiedFeedback = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedFeedback == message { copiedFeedback = nil }
        }
    }
}
