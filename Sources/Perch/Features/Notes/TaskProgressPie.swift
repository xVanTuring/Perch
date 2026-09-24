import AppKit
import SwiftUI

/// 圆饼进度:外圈一道淡色轨道环 + 内部一块扇形(从 12 点顺时针扫)表示完成
/// 比例。直观显示笔记里 `- [ ]` / `- [x]` 任务的完成度。配色走 `.primary`
/// 灰阶,跟标题文字(`.primary.opacity(0.65)`)一致,在各调色板底色上都清晰。
///
/// SwiftUI 版用在浮窗标题条左侧;管理列表行尾走下面的 AppKit `TaskProgressPieView`
/// (那一行是 NSTableCellView,直接 NSBezierPath 绘制比塞 NSHostingView 轻)。
struct TaskProgressPie: View {
    let progress: Note.TaskProgress
    var diameter: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            if progress.isComplete {
                Circle().fill(Color.primary.opacity(0.6)).padding(1.5)
            } else {
                TaskPieSlice(fraction: progress.fraction)
                    .fill(Color.primary.opacity(0.6))
                    .padding(1.5)
            }
        }
        .frame(width: diameter, height: diameter)
        .help("\(progress.completed)/\(progress.total)")
    }
}

/// 从 12 点(-90°)顺时针扫 `fraction` 圈的扇形。fraction==0 时返回空 path
/// (只剩轨道环);==1 时是整圆。
private struct TaskPieSlice: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        guard fraction > 0 else { return Path() }
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        p.move(to: center)
        // SwiftUI 坐标系 y 向下:clockwise: false 在屏幕上呈现为顺时针。
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

/// `TaskProgressPie` 的 AppKit 等价物,给管理列表的 NSTableCellView 行尾用。
/// 直接 NSBezierPath 绘制,recycle 友好(只换 `progress` 触发重绘)。
final class TaskProgressPieView: NSView {
    var progress: Note.TaskProgress? {
        didSet { if progress != oldValue { needsDisplay = true } }
    }
    /// 圆环和扇形的基础色(各自再乘透明度)。侧栏选中行在强调色背景上时换成反白色。
    var baseColor: NSColor = .labelColor {
        didSet { if baseColor != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        guard let progress, progress.total > 0 else { return }
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0 else { return }
        let box = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter, height: diameter
        )
        let center = NSPoint(x: box.midX, y: box.midY)

        // 轨道环:inset 0.5 让 1pt 线完全落在圆内不被裁。
        let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        baseColor.withAlphaComponent(0.22).setStroke()
        ring.stroke()

        // 完成扇形:AppKit y 向上,12 点 = 90°,顺时针 = 角度递减。
        let fraction = progress.fraction
        guard fraction > 0 else { return }
        let radius = diameter / 2 - 1.5
        let wedge = NSBezierPath()
        wedge.move(to: center)
        wedge.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * CGFloat(fraction),
            clockwise: true
        )
        wedge.close()
        baseColor.withAlphaComponent(0.55).setFill()
        wedge.fill()
    }
}
