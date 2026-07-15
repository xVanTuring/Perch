import AppKit
import CoreGraphics
import IOKit

/// 单台显示器的展示信息。`uuid` 是 `CGDisplayCreateUUIDFromDisplayID` 的字符串
/// 表示 —— 跨重启 / 拔插稳定的物理设备标识,用来在 Core Data 里保存"这条
/// 便签钉在哪台屏上"。CGDirectDisplayID(int)本身在重启 / 拓扑改变后可能复用,
/// 不可靠;NSScreen 没有自带 stable identifier,所以只能从 CGDisplay API 走。
struct DisplayInfo: Identifiable, Equatable {
    let uuid: String
    let name: String
    let screen: NSScreen

    var id: String { uuid }
}

/// 显示器枚举与 UUID 解析的集中入口。所有需要"按 UUID 找屏"或"列出当前
/// 屏"的代码都从这里走,避免每处重新写 CGDisplay bridging。
enum DisplayCatalog {
    /// 当前所有在线显示器。顺序与 `NSScreen.screens` 一致(主屏在第一位是
    /// 系统约定,但实际顺序由用户在系统设置里排过)。CGDisplay 拿不到 UUID
    /// 的屏会被跳过(理论上不该发生,debug 时打 log 提醒)。
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = uuid(for: screen) else {
                NSLog("Perch DisplayCatalog: skip screen without UUID: %@", screen.debugDescription)
                return nil
            }
            return DisplayInfo(uuid: uuid, name: displayName(for: screen), screen: screen)
        }
    }

    /// 给定 UUID 找当前在线的 NSScreen。显示器被拔掉时返回 nil。
    static func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { Self.uuid(for: $0) == uuid }
    }

    /// 给定一个窗口 frame,返回它主要落在哪块在线屏(取交集面积最大的一块)。
    /// 跨屏窗按面积归主屏。**完全落在所有屏之外(交集全为 0)返回 nil** ——
    /// 调用方据此判断「窗还在不在某块屏上」。
    static func dominantScreen(for frame: NSRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let r = screen.frame.intersection(frame)
            let area = max(0, r.width) * max(0, r.height)
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// 从 NSScreen 抽 CGDirectDisplayID,再问 CoreGraphics 拿持久 UUID。
    /// 失败(虚拟屏 / 异常)返回 nil。
    static func uuid(for screen: NSScreen) -> String? {
        // NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        // 是 CGDirectDisplayID(UInt32),官方文档原话:
        // https://developer.apple.com/documentation/appkit/nsscreen/1388360-devicedescription
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let raw = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(raw.uint32Value)
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String
    }

    /// 显示器的"用户可读名称"。macOS 10.15+ 的 NSScreen.localizedName 直接给
    /// EDID 里厂家写的型号名(`Built-in Retina Display` / `LG ULTRAFINE`)。
    /// 没拿到就退回到尺寸描述。
    static func displayName(for screen: NSScreen) -> String {
        let localized = screen.localizedName
        if !localized.isEmpty { return localized }
        let frame = screen.frame
        return "\(Int(frame.width))×\(Int(frame.height))"
    }
}
