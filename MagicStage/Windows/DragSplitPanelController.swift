import Cocoa
import SwiftUI

/// 分屏选择面板
///
/// 两阶段、两个独立窗口，统一白色实底（自适应深色模式），easeOut 平滑动画：
/// - peek：把手条（宽度=面板宽度，高度=20），从菜单栏边缘滑出，仅底部圆角
/// - expanded：卡片面板，从 peek 位置展开
final class DragSplitPanelController {
    private let service: DragSplitService
    private let screen: NSScreen
    private var peekWindow: NSPanel?
    private var expandedWindow: NSPanel?
    private var hostingView: NSHostingView<DragSplitPanelView>?
    private var panelView: DragSplitPanelView

    // 所有视觉参数统一引用 UIConfig.DragSplitPanel
    // panelWidth / panelHeight / cornerRadius 三者复用，改一处即同步 peek + expand + 热区
    private let c = UIConfig.DragSplitPanel.self
    private let peekHeight: CGFloat = UIConfig.PeekBar.height

    // 动画时长（可直接修改调手感）
    private let peekAnimDuration: TimeInterval = 0.25
    private let expandAnimDuration: TimeInterval = 0.40
    private let peekFadeOutDuration: TimeInterval = 0.12

    enum DisplayState { case hidden, peek, expanded }
    private(set) var displayState: DisplayState = .hidden

    init(service: DragSplitService, screen: NSScreen) {
        self.service = service
        self.screen = screen
        self.panelView = DragSplitPanelView(service: service)
    }

    // MARK: - 帧计算（peek / expand / 热区 统一）

    private var panelWidth: CGFloat { c.panelWidth }
    private var panelHeight: CGFloat { c.panelHeight }
    private var cornerRadius: CGFloat { c.cornerRadius }

    private func peekFrame() -> NSRect {
        let x = screen.visibleFrame.midX - panelWidth / 2
        let y = screen.visibleFrame.maxY - peekHeight
        return NSRect(x: x, y: y, width: panelWidth, height: peekHeight)
    }

    private func expandedFrame() -> NSRect {
        UIConfig.DragSplitPanel.panelFrame(in: screen.visibleFrame)
    }

    // MARK: - 状态切换

    func showAsPeek() {
        guard peekWindow == nil else { return }

        let target = peekFrame()
        let start = NSRect(x: target.origin.x, y: screen.visibleFrame.maxY,
                           width: target.width, height: target.height)

        let panel = makePeekBar(frame: start)
        panel.alphaValue = 0
        panel.orderFront(nil)
        peekWindow = panel

        displayState = .peek

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = peekAnimDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func expandToFull() {
        peekWindow?.close()
        peekWindow = nil

        guard expandedWindow == nil else { return }

        let start = peekFrame()
        let end   = expandedFrame()

        let panel = makeExpandedPanel(frame: start)
        panel.alphaValue = 0
        panel.orderFront(nil)
        expandedWindow = panel

        displayState = .expanded

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = expandAnimDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 1
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
            let hitRect = CGRect(
                x: win.frame.minX - UIConfig.PeekBar.hitHorizontalPadding,
                y: win.frame.minY - UIConfig.PeekBar.hitBottomPadding,
                width: win.frame.width + UIConfig.PeekBar.hitHorizontalPadding * 2,
                height: peekHeight + UIConfig.PeekBar.hitBottomPadding
            )
            return hitRect.contains(pt)
        case .expanded:
            guard let win = expandedWindow else { return false }
            return win.frame.contains(pt)
        default:
            return false
        }
    }

    var isPeeking: Bool { displayState == .peek }

    func layoutAtScreenPoint(_ pt: NSPoint) -> WindowLayout? {
        guard let win = expandedWindow, displayState == .expanded,
              let hv = hostingView else { return nil }
        let local = win.convertFromScreen(NSRect(origin: pt, size: .zero)).origin
        return panelView.layout(at: hv.convert(local, from: nil))
    }

    // MARK: - 窗口构建（统一实底，跟随系统深色/浅色模式）

    /// 能自动响应 effectiveAppearance 变化的背景视图
    private final class AdaptiveBackgroundView: NSView {
        override var wantsUpdateLayer: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyBackground()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyBackground()
        }

        override func updateLayer() {
            applyBackground()
        }

        private func applyBackground() {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func solidBackgroundView(in parent: NSView) -> NSView {
        let bg = AdaptiveBackgroundView(frame: parent.bounds)
        bg.autoresizingMask = [.width, .height]
        return bg
    }

    private func makePanel(frame: NSRect, cornerRadius: CGFloat, maskedCorners: CACornerMask? = nil) -> NSPanel {
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        panel.ignoresMouseEvents = true

        let cv = panel.contentView!
        cv.wantsLayer = true
        cv.layer?.cornerRadius = cornerRadius
        if let corners = maskedCorners {
            cv.layer?.maskedCorners = corners
        }
        cv.layer?.masksToBounds = true

        cv.addSubview(solidBackgroundView(in: cv))

        return panel
    }

    private func makePeekBar(frame: NSRect) -> NSPanel {
        return makePanel(frame: frame,
                         cornerRadius: UIConfig.PeekBar.cornerRadius,
                         maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    private func makeExpandedPanel(frame: NSRect) -> NSPanel {
        let panel = makePanel(frame: frame, cornerRadius: cornerRadius)

        let hosting = NSHostingView(rootView: panelView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView?.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])
        hostingView = hosting

        return panel
    }
}
