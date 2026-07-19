import Cocoa

/// 分屏预览矩形：与分屏面板共用悬浮表面、强调色描边和短促的目标吸附动画。
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
        // 预览只表达可放置区域，不添加任何外边缘或阴影，避免与菜单栏/壁纸形成“描边感”。
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = UIConfig.FloatingSurface.cornerRadius
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(effect)

        let initialFrame = frame.insetBy(dx: max(2, frame.width * 0.012), dy: max(2, frame.height * 0.012))
        panel.setFrame(initialFrame, display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)

        // 从略小的目标区域吸附到准确位置；不做过冲，避免遮挡用户正在拖动的窗口。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = UIConfig.Animation.shouldReduceMotion ? 0.12 : UIConfig.Animation.dragSplitPreviewShowDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }

        window = panel
    }

    /// 在不同布局目标之间保持同一套吸附曲线。
    func animate(to frame: CGRect) {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = UIConfig.Animation.shouldReduceMotion ? 0.12 : UIConfig.Animation.dragSplitPreviewAnimateDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            win.animator().setFrame(frame, display: true)
        }
    }

    func close() {
        guard let panel = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.close()
        }
    }
}
