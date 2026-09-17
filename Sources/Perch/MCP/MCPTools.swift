import Foundation

/// 汇总注册所有 tool。AppDelegate 启动时调一次 `MCPTools.registerAll(into:)`。
/// 按功能区拆到 MCPTools+State / +Notes / +Groups,这个文件只是入口。
enum MCPTools {
    @MainActor
    static func registerAll(into server: MCPServer) {
        registerState(into: server)
        registerNoteTools(into: server)
        registerGroupTools(into: server)
    }
}
