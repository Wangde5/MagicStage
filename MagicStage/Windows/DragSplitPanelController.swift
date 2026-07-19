import Cocoa
import SwiftUI

/// 分屏选择面板
///
/// 两阶段、两个独立窗口：
/// - peek：位于菜单栏下方的 HUD Peek 条
/// - expanded：同材质 HUD 布局面板，以短淡入 + 轻微落位出现
final class DragSplitPanelController {
    private let service: DragSplitService
    private let screen: NSScreen
    private var peekWindow: NSPanel?
    private var expandedWindow: NSPanel?
    private var hostingView: NSHostingView<DragSplitPanelView>?
    private var panelView: DragSplitPanelView

    // 完整面板参数；灵动岛尺寸和热区由 UIConfig.PeekBar 单独管理。
    private let c = UIConfig.DragSplitPanel.self
    private let peekHeight: CGFloat = UIConfig.PeekBar.height

    // 动画时长统一由设计系统管理，避免面板、预览和窗口落位各自一套节奏。
    private let peekAnimDuration = UIConfig.Animation.dragSplitPeekDuration
    private let expandAnimDuration = UIConfig.Animation.dragSplitPanelExpandDuration
    private let peekFadeOutDuration: TimeInterval = 0.12

    private enum SurfaceShadow {
        enum Peek {
            // Core Animation 阴影在约 3 × radius 后才完全衰减，画布必须覆盖完整尾部。
            static let horizontalInset: CGFloat = 18
            static let bottomInset: CGFloat = 21
            static let radius: CGFloat = 6
            static let yOffset: CGFloat = -3
        }

        enum Expanded {
            static let horizontalInset: CGFloat = 27
            static let topInset: CGFloat = 24
            static let bottomInset: CGFloat = 30
            static let radius: CGFloat = 9
            static let yOffset: CGFloat = -3
        }
    }

    enum DisplayState { case hidden, peek, expanded }
    private(set) var displayState: DisplayState = .hidden

    init(service: DragSplitService, screen: NSScreen) {
        self.service = service
        self.screen = screen
        self.panelView = DragSplitPanelView(service: service)
    }

    // MARK: - 帧计算（peek / expand / 热区 统一）

    private var cornerRadius: CGFloat { c.cornerRadius }

    private func peekFrame() -> NSRect {
        let x = screen.visibleFrame.midX - UIConfig.PeekBar.width / 2
        let y = screen.visibleFrame.maxY - peekHeight - UIConfig.PeekBar.topInset
        return NSRect(x: x, y: y, width: UIConfig.PeekBar.width, height: peekHeight)
    }

    /// Peek 可见表面贴住菜单栏；窗口本体只在左右和下方预留阴影空间。
    private func peekWindowFrame(for visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.minX - SurfaceShadow.Peek.horizontalInset,
            y: visibleFrame.minY - SurfaceShadow.Peek.bottomInset,
            width: visibleFrame.width + SurfaceShadow.Peek.horizontalInset * 2,
            height: visibleFrame.height + SurfaceShadow.Peek.bottomInset
        )
    }

    private func peekVisibleFrame(in windowFrame: NSRect) -> NSRect {
        NSRect(
            x: windowFrame.minX + SurfaceShadow.Peek.horizontalInset,
            y: windowFrame.minY + SurfaceShadow.Peek.bottomInset,
            width: windowFrame.width - SurfaceShadow.Peek.horizontalInset * 2,
            height: windowFrame.height - SurfaceShadow.Peek.bottomInset
        )
    }

    private func expandedWindowFrame(for visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.minX - SurfaceShadow.Expanded.horizontalInset,
            y: visibleFrame.minY - SurfaceShadow.Expanded.bottomInset,
            width: visibleFrame.width + SurfaceShadow.Expanded.horizontalInset * 2,
            height: visibleFrame.height
                + SurfaceShadow.Expanded.topInset
                + SurfaceShadow.Expanded.bottomInset
        )
    }

    private func expandedVisibleFrame(in windowFrame: NSRect) -> NSRect {
        NSRect(
            x: windowFrame.minX + SurfaceShadow.Expanded.horizontalInset,
            y: windowFrame.minY + SurfaceShadow.Expanded.bottomInset,
            width: windowFrame.width - SurfaceShadow.Expanded.horizontalInset * 2,
            height: windowFrame.height
                - SurfaceShadow.Expanded.topInset
                - SurfaceShadow.Expanded.bottomInset
        )
    }

    private func expandedFrame() -> NSRect {
        UIConfig.DragSplitPanel.panelFrame(in: screen.visibleFrame)
    }

    // MARK: - 状态切换

    func showAsPeek() {
        guard peekWindow == nil else { return }

        let target = peekFrame()
        let start = target.offsetBy(dx: 0, dy: 2)

        let panel = makePeekBar(frame: peekWindowFrame(for: start))
        panel.alphaValue = 0
        panel.orderFront(nil)
        peekWindow = panel

        displayState = .peek

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = UIConfig.Animation.shouldReduceMotion ? 0.12 : peekAnimDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.82, 0.24, 1)
            panel.animator().setFrame(peekWindowFrame(for: target), display: true)
            panel.animator().alphaValue = 1
        }
    }

    func expandToFull() {
        guard expandedWindow == nil else { return }

        // 容器从 Peek 条连续展开；布局卡片在展开途中从中心轻微舒展，
        // 避免内容延迟出现或从单侧滑出的感觉。
        let island = peekWindow
        peekWindow = nil
        let end = expandedFrame()
        // 从当前 Peek 的实际位置开始；完整面板再轻轻落到下方的悬浮位置。
        // 这样 topGap 不会让展开起点与 Peek 条脱节。
        let start = peekFrame()

        let panel = makeExpandedPanel(frame: start)
        panel.alphaValue = 0
        if let hostingView {
            prepareContentForReveal(hostingView)
        }
        panel.orderFront(nil)
        expandedWindow = panel

        displayState = .expanded

        let duration = UIConfig.Animation.shouldReduceMotion ? 0.12 : expandAnimDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.92, 0.24, 1)
            panel.animator().setFrame(expandedWindowFrame(for: end), display: true)
            panel.animator().alphaValue = 1
        }

        if let island {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = min(0.12, duration)
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                island.animator().alphaValue = 0
            } completionHandler: {
                island.close()
            }
        }

        let contentDelay = duration * 0.16
        DispatchQueue.main.asyncAfter(deadline: .now() + contentDelay) { [weak self, weak panel] in
            guard let self, let panel, self.expandedWindow === panel,
                  let hosting = self.hostingView else { return }
            self.revealContent(hosting)
        }
    }

    func close() {
        let expWin = expandedWindow
        expandedWindow = nil
        hostingView = nil

        let pkWin = peekWindow
        peekWindow = nil

        displayState = .hidden

        if let win = expWin {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 0
            } completionHandler: { win.close() }
        }

        if let win = pkWin {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = peekFadeOutDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 0
            } completionHandler: { win.close() }
        }
    }

    // MARK: - 命中检测（热区 = 面板展开后的区域，与 expandedFrame 一致）

    func containsScreenPoint(_ pt: NSPoint) -> Bool {
        switch displayState {
        case .peek:
            guard let win = peekWindow else { return false }
            let visibleFrame = peekVisibleFrame(in: win.frame)
            let hitRect = CGRect(
                x: visibleFrame.minX - UIConfig.PeekBar.hitHorizontalPadding,
                y: visibleFrame.minY - UIConfig.PeekBar.hitBottomPadding,
                width: visibleFrame.width + UIConfig.PeekBar.hitHorizontalPadding * 2,
                height: peekHeight + UIConfig.PeekBar.hitBottomPadding
            )
            return hitRect.contains(pt)
        case .expanded:
            guard let win = expandedWindow else { return false }
            return expandedVisibleFrame(in: win.frame).contains(pt)
        default:
            return false
        }
    }

    var isPeeking: Bool { displayState == .peek }

    // MARK: - 展开内容动效

    private func prepareContentForReveal(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = UIConfig.Animation.shouldReduceMotion
            ? CATransform3DIdentity
            : CATransform3DMakeScale(0.985, 0.985, 1)
        CATransaction.commit()
    }

    private func revealContent(_ view: NSView) {
        guard let layer = view.layer else { return }

        let duration = UIConfig.Animation.shouldReduceMotion
            ? 0.12
            : UIConfig.Animation.dragSplitPanelContentRevealDuration
        let startTransform = layer.transform

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: startTransform)
        transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)

        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        layer.add(group, forKey: "dragSplitContentReveal")
    }

    func layoutAtScreenPoint(_ pt: NSPoint) -> WindowLayout? {
        guard let win = expandedWindow, displayState == .expanded,
              let hv = hostingView else { return nil }
        let local = win.convertFromScreen(NSRect(origin: pt, size: .zero)).origin
        return panelView.layout(at: hv.convert(local, from: nil))
    }

    // MARK: - 窗口构建（统一 HUD 材质、描边与阴影）

    private enum OutlineEdges {
        case full
        case excludingTop
    }

    /// 阴影画布可以延伸到 visibleFrame 之外；可见表面的位置由控制器精确计算。
    /// 若使用 NSPanel 默认约束，AppKit 会把透明画布压回屏幕并连带推低表面。
    private final class UnconstrainedFloatingPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    /// Peek 与完整面板共用 HUD 材质；只按尺寸调整圆角与阴影扩散范围。
    private final class FloatingSurfaceView: NSVisualEffectView {
        private let cornerRadius: CGFloat
        private let maskedCorners: CACornerMask
        private let shadowRadius: CGFloat
        private let shadowYOffset: CGFloat
        private var lastMaskSize: NSSize = .zero

        init(
            frame: NSRect,
            cornerRadius: CGFloat,
            maskedCorners: CACornerMask,
            shadowRadius: CGFloat,
            shadowYOffset: CGFloat
        ) {
            self.cornerRadius = cornerRadius
            self.maskedCorners = maskedCorners
            self.shadowRadius = shadowRadius
            self.shadowYOffset = shadowYOffset
            super.init(frame: frame)
            wantsLayer = true
            material = .hudWindow
            blendingMode = .behindWindow
            state = .active
            isEmphasized = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            guard bounds.size != lastMaskSize else { return }
            lastMaskSize = bounds.size
            updateSurfaceMask()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyAppearance()
        }

        private func applyAppearance() {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
            layer?.maskedCorners = maskedCorners
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = isDark ? 0.28 : 0.17
            layer?.shadowRadius = shadowRadius
            layer?.shadowOffset = CGSize(width: 0, height: shadowYOffset)
        }

        private func updateSurfaceMask() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let path = surfacePath(in: bounds)
            maskImage = NSImage(size: bounds.size, flipped: false) { _ in
                NSColor.black.setFill()
                path.fill()
                return true
            }
            layer?.shadowPath = path.cgPath
        }

        private func surfacePath(in rect: NSRect) -> NSBezierPath {
            let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
            let roundsTop = maskedCorners.contains(.layerMinXMaxYCorner)
                || maskedCorners.contains(.layerMaxXMaxYCorner)
            guard !roundsTop else {
                return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
            path.curve(
                to: NSPoint(x: rect.maxX - radius, y: rect.minY),
                controlPoint1: NSPoint(x: rect.maxX, y: rect.minY + radius * 0.45),
                controlPoint2: NSPoint(x: rect.maxX - radius * 0.45, y: rect.minY)
            )
            path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
            path.curve(
                to: NSPoint(x: rect.minX, y: rect.minY + radius),
                controlPoint1: NSPoint(x: rect.minX + radius * 0.45, y: rect.minY),
                controlPoint2: NSPoint(x: rect.minX, y: rect.minY + radius * 0.45)
            )
            path.close()
            return path
        }
    }

    /// 一物理像素的自适应浅灰内描边；Peek 省略贴菜单栏的顶部边。
    private final class SurfaceOutlineView: NSView {
        private let outline = CAShapeLayer()
        private let cornerRadius: CGFloat
        private let edges: OutlineEdges

        init(frame: NSRect, cornerRadius: CGFloat, edges: OutlineEdges) {
            self.cornerRadius = cornerRadius
            self.edges = edges
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(outline)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            updateOutline()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateOutline()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateOutline()
        }

        private func updateOutline() {
            let scale = max(window?.backingScaleFactor ?? 2, 1)
            let lineWidth = 1 / scale
            let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let radius = max(min(cornerRadius, rect.height / 2) - lineWidth / 2, 0)
            let path: CGPath

            switch edges {
            case .full:
                path = CGPath(
                    roundedRect: rect,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                )
            case .excludingTop:
                let openPath = CGMutablePath()
                openPath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                openPath.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
                openPath.addQuadCurve(
                    to: CGPoint(x: rect.minX + radius, y: rect.minY),
                    control: CGPoint(x: rect.minX, y: rect.minY)
                )
                openPath.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
                openPath.addQuadCurve(
                    to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                    control: CGPoint(x: rect.maxX, y: rect.minY)
                )
                openPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path = openPath
            }

            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color = isDark
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.gray.withAlphaComponent(0.24)
            outline.frame = bounds
            outline.path = path
            outline.fillColor = nil
            outline.strokeColor = color.cgColor
            outline.lineWidth = lineWidth
            outline.lineJoin = .round
        }
    }

    private func makeTransparentPanel(frame: NSRect) -> NSPanel {
        let panel = UnconstrainedFloatingPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        panel.ignoresMouseEvents = true
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.masksToBounds = false
        return panel
    }

    private func makePeekBar(frame: NSRect) -> NSPanel {
        let panel = makeTransparentPanel(frame: frame)
        let contentView = panel.contentView!
        let surfaceFrame = NSRect(
            x: SurfaceShadow.Peek.horizontalInset,
            y: SurfaceShadow.Peek.bottomInset,
            width: frame.width - SurfaceShadow.Peek.horizontalInset * 2,
            height: frame.height - SurfaceShadow.Peek.bottomInset
        )
        let surface = FloatingSurfaceView(
            frame: surfaceFrame,
            cornerRadius: UIConfig.PeekBar.cornerRadius,
            maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner],
            shadowRadius: SurfaceShadow.Peek.radius,
            shadowYOffset: SurfaceShadow.Peek.yOffset
        )
        surface.autoresizingMask = [.width]
        contentView.addSubview(surface)

        let outline = SurfaceOutlineView(
            frame: surface.bounds,
            cornerRadius: UIConfig.PeekBar.cornerRadius,
            edges: .excludingTop
        )
        outline.autoresizingMask = [.width, .height]
        surface.addSubview(outline)
        return panel
    }

    private func makeExpandedPanel(frame: NSRect) -> NSPanel {
        let panel = makeTransparentPanel(frame: expandedWindowFrame(for: frame))
        let contentView = panel.contentView!
        let surfaceFrame = NSRect(
            x: SurfaceShadow.Expanded.horizontalInset,
            y: SurfaceShadow.Expanded.bottomInset,
            width: contentView.bounds.width - SurfaceShadow.Expanded.horizontalInset * 2,
            height: contentView.bounds.height
                - SurfaceShadow.Expanded.topInset
                - SurfaceShadow.Expanded.bottomInset
        )
        let surface = FloatingSurfaceView(
            frame: surfaceFrame,
            cornerRadius: cornerRadius,
            maskedCorners: [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner
            ],
            shadowRadius: SurfaceShadow.Expanded.radius,
            shadowYOffset: SurfaceShadow.Expanded.yOffset
        )
        surface.autoresizingMask = [.width, .height]
        contentView.addSubview(surface)

        let hosting = NSHostingView(rootView: panelView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        surface.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: surface.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        let outline = SurfaceOutlineView(
            frame: surface.bounds,
            cornerRadius: cornerRadius,
            edges: .full
        )
        outline.autoresizingMask = [.width, .height]
        surface.addSubview(outline)
        hostingView = hosting

        return panel
    }

}
