import AppKit

/// 侧栏拖拽阈值：鼠标按下后移动够远、并且按住够久才开始拖拽，减少点选时的误拖（Finder 的做法）。
/// 在 `SidebarOutlineNSView.mouseDown` 里、调用 `super` 之前使用。
///
/// 为什么需要：NSTableView 在 `mouseDown` 里用嵌套事件循环识别拖拽，只看距离、不看时间，距离也没有开放设置。
/// 快速上下乱点时按下瞬间指针还在移动，一百毫秒内就可能移动超过系统阈值，被误判成拖拽。
///
/// 做法：在交给 `super.mouseDown` 之前，先由我们读后续事件——
/// - 开始拖拽前松手：把 mouseUp 放回队列最前面，super 照常当成一次点击；
/// - 移动超过 `distance` 且按住超过 `minimumPressDuration`：把最新的 mouseDragged 放回队列最前面，
///   super 一看离按下点已经很远，立刻开始拖拽。
/// 中间的 mouseDragged 直接丢弃。
///
/// 等待期间主线程是阻塞的，所以每 `pollInterval` 检查一次左键的实际状态：
/// 左键已经松开却没收到 mouseUp 时，补发一个 mouseUp 并退出，避免卡住后积压的点击再依次触发。
///
/// 只能用在 NSTableView / NSOutlineView 子类里处理自己的事件。不要改成全局事件监听去套 SwiftUI List：
/// SwiftUI 会把按下事件延后约 100ms 才派发，拦截会打乱它的事件时序，连普通点击都会出问题
/// （在 swiftui-siderbar demo 里验证过）。
///
/// 代价：按住不动时选中高亮要等松手或开始拖拽才出现（普通点击感觉不到）。
enum SidebarDragThreshold {
    static let distance: CGFloat = 10
    static let minimumPressDuration: TimeInterval = 0.15
    /// 等待事件时检查左键实际状态的间隔。
    static let pollInterval: TimeInterval = 0.05

    /// 在 `super.mouseDown(with: down)` 之前调用。返回时已经把该交给 super 的后续事件放回了队列。
    static func holdUntilDecided(after down: NSEvent) {
        guard down.clickCount == 1,                       // 双击不拦截
              !down.modifierFlags.contains(.control),     // Control-点按 = 右键菜单
              let window = down.window else { return }

        let origin = down.locationInWindow
        let earliestDrag = down.timestamp + minimumPressDuration
        // 距离已经够了、但按住时间还不够时，先记下最新的拖动事件继续等
        var pending: NSEvent?

        while true {
            if let pending, ProcessInfo.processInfo.systemUptime >= earliestDrag {
                NSApp.postEvent(pending, atStart: true)
                return
            }
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                              until: Date(timeIntervalSinceNow: pollInterval),
                                              inMode: .eventTracking, dequeue: true) else {
                // 这一轮没有事件：左键已经松开却没收到 mouseUp → 补一个，交给 super 当点击处理
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    #if DEBUG
                    NSLog("Perch Sidebar: drag threshold — button released without mouseUp, synthesizing one")
                    #endif
                    if let up = syntheticMouseUp(for: down) { NSApp.postEvent(up, atStart: true) }
                    return
                }
                continue
            }
            if next.type == .leftMouseUp {
                // 松手 = 点击，哪怕中途移动超过了距离（快速点击时指针还在移动）
                NSApp.postEvent(next, atStart: true)
                return
            }
            let p = next.locationInWindow
            guard hypot(p.x - origin.x, p.y - origin.y) >= distance else { continue }
            if next.timestamp >= earliestDrag {
                NSApp.postEvent(next, atStart: true)
                return
            }
            pending = next
        }
    }

    private static func syntheticMouseUp(for down: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseUp,
                           location: down.locationInWindow,
                           modifierFlags: down.modifierFlags,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: down.windowNumber,
                           context: nil,
                           eventNumber: down.eventNumber,
                           clickCount: down.clickCount,
                           pressure: 0)
    }
}
