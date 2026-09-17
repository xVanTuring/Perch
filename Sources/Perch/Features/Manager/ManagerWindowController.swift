import AppKit
import SwiftUI
import CoreData

/// 集中管理窗口 —— 不像浮窗是常驻便签,而是一个标准的 titled NSWindow,
/// 用户从菜单栏点 "Show All Notes" 唤出来,左边是分组+笔记列表,右边显示
/// 选中笔记的渲染内容。一个 App 同一时间只有一个实例。
final class ManagerWindowController: NSObject, NSWindowDelegate {
    private let context: NSManagedObjectContext
    private let floating: FloatingNotesRegistry
    private var window: NSWindow?

    init(context: NSManagedObjectContext, floating: FloatingNotesRegistry) {
        self.context = context
        self.floating = floating
        super.init()
        // Settings 里切换「管理窗口显示 Dock 图标」时,窗口开着也即时生效。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in self?.applyActivationPolicy() }
    }

    /// LSUIElement 默认 `.accessory`(无 Dock 图标)。开关打开且窗口在时切 `.regular`,
    /// 窗口关掉或开关关闭时切回。只在值真变化时调用,避免菜单栏闪烁。
    private func applyActivationPolicy() {
        let wantsDock = window != nil
            && UserDefaults.standard.bool(forKey: SettingsKey.managerShowsDockIcon)
        let target: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            applyActivationPolicy()
            return
        }

        let host = NSHostingController(
            rootView: ManagerView(floating: floating)
                .environment(\.managedObjectContext, context)
        )

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Perch"
        w.titlebarAppearsTransparent = true
        w.contentViewController = host
        w.setContentSize(NSSize(width: 900, height: 600))
        w.minSize = NSSize(width: 600, height: 400)
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
        applyActivationPolicy()
    }

    func windowWillClose(_ notification: Notification) {
        // 释放 SwiftUI 视图树,下次 show 重建。NSHostingController 会持有 FetchRequest
        // 订阅,不释放会重复占内存。
        window?.contentViewController = nil
        window = nil
        applyActivationPolicy()
    }
}
