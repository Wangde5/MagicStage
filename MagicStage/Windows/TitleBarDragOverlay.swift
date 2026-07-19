import Cocoa

// MARK: - 标题栏拖拽恢复 Overlay
///
/// 由 DragSplitService 的 CGEvent tap 驱动（不再依赖 NSPanel + NSEvent localMonitor）。
///
/// 事件流：
/// - leftMouseDown：创建 overlay，消费事件阻止原生拖拽，但 **不恢复 size**（避免点击就恢复）
/// - leftMouseDragged：移动超过阈值才恢复 size 并接管拖拽；未超过阈值则什么也不做
/// - leftMouseUp：如果未真正拖动过，什么也不做（窗口保持原样，恢复帧保留）；拖动过则发通知清理
///
/// 标题栏对齐策略：
/// - 按下时记录鼠标相对窗口左上角的偏移 offset = mouseDownPt - windowOriginAtDown
/// - 真正拖动时恢复 size（AX 改 size 会导致 origin 跑偏），然后用 AX 把 origin 拉回
///   期望位置 expectedOrigin = 当前鼠标 - offset，确保标题栏仍在指针下
/// - 后续拖拽用 delta 移动窗口，标题栏始终跟随指针
final class TitleBarDragOverlay {
    private let targetWindow: AXUIElement
    private let restoreSize: CGSize

    /// 按下时的鼠标位置（Quartz，左上原点 Y↓）
    private let mouseDownPt: CGPoint
    /// 按下时的窗口 origin（AX，左上原点 Y↓）
    private let windowOriginAtDown: CGPoint

    /// 开始真正拖拽时的鼠标位置（用于计算 delta）
    private var dragInitialMouse: CGPoint
    /// 开始真正拖拽时的窗口 origin（用于计算 delta）
    private var dragInitialOrigin: CGPoint

    /// 是否已通过拖拽阈值（真正开始拖拽）
    private(set) var hasDragged = false

    /// 拖拽阈值：移动超过此距离才认为是拖拽，避免纯点击触发恢复
    private let dragThreshold: CGFloat = 5

    init(window: AXUIElement, restoreSize: CGSize, initialQuartzPt: CGPoint) {
        self.targetWindow = window
        self.restoreSize = restoreSize
        self.mouseDownPt = initialQuartzPt

        let origin: CGPoint
        if let frame = Self.getAXFrame(window) {
            origin = frame.origin
        } else {
            origin = .zero
        }
        self.windowOriginAtDown = origin
        self.dragInitialMouse = initialQuartzPt
        self.dragInitialOrigin = origin
        // 注意：init 时不恢复 size，等真正拖拽时再恢复
    }

    // MARK: - 事件处理（由 DragSplitService CGEvent tap 调用）

    func handleDrag(quartzPt: CGPoint) {
        if !hasDragged {
            // 检查是否超过拖拽阈值
            let dx = quartzPt.x - mouseDownPt.x
            let dy = quartzPt.y - mouseDownPt.y
            guard sqrt(dx * dx + dy * dy) > dragThreshold else { return }
            // 真正开始拖拽：恢复 size 并把窗口拉到指针下
            startDragAt(quartzPt: quartzPt)
            hasDragged = true
            return
        }

        // 正常拖拽：仅更新位置，尺寸已在 startDragAt 中恢复
        let dx = quartzPt.x - dragInitialMouse.x
        let dy = quartzPt.y - dragInitialMouse.y
        let newOrigin = CGPoint(x: dragInitialOrigin.x + dx,
                                 y: dragInitialOrigin.y + dy)
        // 显式传 restoreSize，避免 SkyLightBridge.setWindowPosition 读到旧尺寸覆盖恢复
        Self.setAXFrame(targetWindow, origin: newOrigin, size: restoreSize)
    }

    /// 真正开始拖拽：恢复 size，并把窗口拉到指针下
    private func startDragAt(quartzPt: CGPoint) {
        // 按下时鼠标相对窗口左上角的偏移
        var offsetX = mouseDownPt.x - windowOriginAtDown.x
        var offsetY = mouseDownPt.y - windowOriginAtDown.y

        // clamp，确保鼠标在新窗口内（距离左右边缘至少 20px）
        let maxX = max(restoreSize.width - 20, 20)
        offsetX = min(max(offsetX, 20), maxX)
        offsetY = min(max(offsetY, 0), max(restoreSize.height - 1, 0))

        // 先恢复尺寸
        Self.setAXSize(targetWindow, size: restoreSize)

        // 计算期望 origin，确保标题栏在指针下
        var expectedOrigin = CGPoint(x: quartzPt.x - offsetX,
                                      y: quartzPt.y - offsetY)

        // 约束窗口不超出屏幕右边界（右半屏恢复时原宽度可能超出）
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoaMouse = ScreenCoordinates.cocoaPoint(fromQuartz: quartzPt, primaryScreenMaxY: primaryMaxY)
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(cocoaMouse, $0.frame, false)
        }) {
            let maxOriginX = screen.visibleFrame.maxX - restoreSize.width
            expectedOrigin.x = min(max(expectedOrigin.x, screen.visibleFrame.origin.x), maxOriginX)
        }

        Self.setAXOrigin(targetWindow, origin: expectedOrigin)

        // 记录拖拽起点，后续 delta 基于此计算
        dragInitialMouse = quartzPt
        dragInitialOrigin = expectedOrigin
    }

    /// 松手：只有真正拖动过才发通知清理（WindowManagementService 据此清除 Toggle 快照）
    func handleUp() {
        guard hasDragged else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(targetWindow, &pid)
        if pid != 0 {
            let identity = WindowIdentity(window: targetWindow)
            NotificationCenter.default.post(
                name: .init("MagicStageWindowRestored"),
                object: nil,
                userInfo: ["pid": pid, "windowToken": identity.token]
            )
        }
    }

    // MARK: - AX 辅助

    private static func getAXFrame(_ window: AXUIElement) -> CGRect? {
        var pr: CFTypeRef?, sr: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pr) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sr) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = pr, CFGetTypeID(pv) == AXValueGetTypeID(), AXValueGetValue(pv as! AXValue, .cgPoint, &p),
              let sv = sr, CFGetTypeID(sv) == AXValueGetTypeID(), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func setAXFrame(_ window: AXUIElement, origin: CGPoint, size: CGSize) {
        // 优先 SkyLight 路径（解决 Electron/CEF 应用 frame 设置失效问题）
        let frame = CGRect(origin: origin, size: size)
        if SkyLightBridge.setWindowFrame(window, frame: frame) { return }
        // 降级到 AX 路径
        setAXOrigin(window, origin: origin)
        setAXSize(window, size: size)
    }

    private static func setAXOrigin(_ window: AXUIElement, origin: CGPoint) {
        if SkyLightBridge.setWindowPosition(window, position: origin) { return }
        var pos = origin
        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
    }

    private static func setAXSize(_ window: AXUIElement, size: CGSize) {
        if SkyLightBridge.setWindowSize(window, size: size) { return }
        var sz = size
        if let v = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }
}
