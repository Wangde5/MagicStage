import Cocoa

/// 分屏预览矩形：.hud 毛玻璃，无阴影无描边，弹性动画
final class DragSplitPreviewOverlay {
    private var window: NSPanel?

    func show(frame: CGRect) {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = UIConfig.CornerRadius.large
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(effect)

        panel.alphaValue = 0
        panel.orderFront(nil)

        // 弹性淡入
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = UIConfig.Animation.dragSplitPreviewShowDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().alphaValue = 1
        }

        window = panel
    }

    /// 弹性 frame 过渡：轻微的 overshoot 感觉
    func animate(to frame: CGRect) {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = UIConfig.Animation.dragSplitPreviewAnimateDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.26, 1)
            win.animator().setFrame(frame, display: true)
        }
    }

    func close() {
        window?.close()
        window = nil
    }
}
