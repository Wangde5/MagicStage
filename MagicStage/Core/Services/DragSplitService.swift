import Cocoa
import SwiftUI
import ApplicationServices
import Combine

/// 拖拽分屏服务
/// 策略：NSEvent 全局监听 leftMouseDown/Up 追踪拖拽状态 + Timer(.commonModes) 轮询鼠标位置
/// 因为窗口拖拽时系统会消费 leftMouseDragged 事件，CGEvent tap 也未必可靠，
/// 但 NSEvent.mouseLocation + CGEventSource.buttonState 始终有效
@MainActor
final class DragSplitService: ObservableObject {
    static let shared = DragSplitService()

    @Published var isEnabled = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "dragSplitEnabled")
            if isEnabled { startObserving() } else { stopObserving() }
        }
    }
    @Published var isPanelVisible = false
    @Published var hoveredLayout: WindowLayout?

    /// 分屏后拖动窗口自动恢复原始尺寸（独立开关）
    @Published var dragSplitRestoreEnabled: Bool {
        didSet {
            UserDefaults.standard.set(dragSplitRestoreEnabled, forKey: "dragSplitRestoreEnabled")
            if dragSplitRestoreEnabled {
                startRestoreTap()
            } else {
                stopRestoreTap()
            }
        }
    }

    // MARK: - 私有属性

    private var downMonitor: Any?
    private var upMonitor: Any?
    private var pollingTimer: Timer?

    private var isMouseDown = false
    private var externalDragActive = false   // MoveWindowService 正在拖拽时，跳过 buttonState 检查
    private var isDragging = false
    private var dragTargetWindow: AXUIElement?
    private var panelController: DragSplitPanelController?
    private var previewController: DragSplitPreviewOverlay?
    private var mouseDownLocation: CGPoint = .zero
    private var beginDragAttempts = 0
    /// 普通拖拽恢复后跳过本轮轮询，避免与系统拖拽冲突
    private var skipPollUntilMouseUp = false
    private var restoreTap: CFMachPort?
    private var restoreTapSource: CFRunLoopSource?

    /// 活跃的标题栏 overlay（拖拽期间拦截事件，阻止 WindowServer 原生拖拽）
    private var activeOverlay: TitleBarDragOverlay?

    /// 拖拽最小移动距离：超过此距离才算拖拽，纯点击不触发
    private let dragThreshold: CGFloat = 8

    /// 当前触发阶段
    /// - idle: 拖拽中但未进入热区
    /// - peeking: 已进入热区，peek 条已显示
    /// - expanded: 已拖到 peek 条，完整面板已展开
    private enum DragStage { case idle, peeking, expanded }
    private var stage: DragStage = .idle

    /// peek 条出现的时间与光标位置，用于防止误触（一闪而过直接展开）
    private var peekShownAt: Date?
    private var peekShownAtPoint: CGPoint?
    /// peek 条至少展示多久后才允许展开（秒）
    private let minimumPeekDuration: TimeInterval = 0.25
    /// 光标从 peek 出现位置移动超过此距离，允许立即展开（即使时间未到）
    private let deliberateMoveThreshold: CGFloat = 15

    // MARK: 拖拽分屏恢复（Toggle：再次拖到相同布局时恢复原始大小）
    private var dragSplitRestoreFrames: [AXWindowRef: CGRect] = [:]
    /// 拖拽开始前窗口的原始 frame（用于分屏后恢复）
    private var dragSplitPreDragFrame: CGRect?

    private struct AXWindowRef: Hashable {
        let pid: pid_t

        init(element: AXUIElement) {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            self.pid = pid
        }

        init(pid: pid_t) {
            self.pid = pid
        }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "dragSplitEnabled")
        dragSplitRestoreEnabled = UserDefaults.standard.object(forKey: "dragSplitRestoreEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "dragSplitRestoreEnabled")

        // 恢复 tap 独立于 drag split 功能：快捷键分屏后拖拽恢复也需要它
        if dragSplitRestoreEnabled {
            startRestoreTap()
        }

        // 如果拖拽分屏已启用，直接开始监听（修复启动后不生效需要重新开关的 Bug）
        if isEnabled {
            startObserving()
        }
    }

    // MARK: - 事件监听

    func startObserving() {
        guard downMonitor == nil else { return }

        startRestoreTap()

        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMouseDown() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMouseUp() }
        }

        // Timer 必须加入 .commonModes，否则拖拽期间 RunLoop 在 eventTracking 模式 Timer 不会 fire
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMousePosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    func stopObserving() {
        // 恢复 tap 由 dragSplitRestoreEnabled 独立管理，不随 drag split 功能停止
        if !dragSplitRestoreEnabled {
            stopRestoreTap()
        }
        if let m = downMonitor { NSEvent.removeMonitor(m); downMonitor = nil }
        if let m = upMonitor { NSEvent.removeMonitor(m); upMonitor = nil }
        pollingTimer?.invalidate()
        pollingTimer = nil
        isMouseDown = false
        externalDragActive = false
        hideAll()
        resetDragState()
    }

    // MARK: - 拖拽恢复 Tap

    private func startRestoreTap() {
        guard restoreTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.leftMouseDragged.rawValue)
                              | (1 << CGEventType.leftMouseUp.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let svc = Unmanaged<DragSplitService>.fromOpaque(userInfo).takeUnretainedValue()

                var shouldConsume = false
                MainActor.assumeIsolated {
                    switch type {
                    case .leftMouseDown:
                        // 按下时检测是否需要恢复：若需要则创建 overlay 并消费事件，阻止系统启动原生拖拽
                        shouldConsume = svc.tryCreateTitleBarOverlay(quartzPt: event.location)
                    case .leftMouseDragged:
                        // overlay 激活期间，由 overlay 通过 AX 移动窗口，消费事件防止系统介入
                        shouldConsume = svc.routeOverlayDrag(quartzPt: event.location)
                    case .leftMouseUp:
                        // 松手时清理 overlay。不消费 leftMouseUp：保持鼠标状态一致，避免系统结算过期拖拽
                        svc.routeOverlayUp()
                        shouldConsume = false
                    default:
                        break
                    }
                }
                return shouldConsume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let t = tap else { return }
        restoreTap = t
        restoreTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), restoreTapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stopRestoreTap() {
        if let s = restoreTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); restoreTapSource = nil }
        if let t = restoreTap { CFMachPortInvalidate(t); restoreTap = nil }
    }

        // MARK: - 外部拖拽驱动（MoveWindowService 从 CGEvent tap 回调中调用）

    /// MoveWindowService 开始拖拽时调用：如果该窗口之前被分屏吸附过，先恢复原始大小再开始拖拽
    func tryRestoreSnappedWindow(_ window: AXUIElement) {
        let ref = AXWindowRef(element: window)
        guard let savedFrame = dragSplitRestoreFrames.removeValue(forKey: ref) else { return }
        let restoreFrame = dragSplitPreDragFrame ?? savedFrame
        dragSplitPreDragFrame = nil
        // 即时恢复，不带动画（后续拖拽会接管控制权）
        setAXWindowFrame(window, frame: restoreFrame)
    }

    /// 检测是否需要恢复，是则吞事件 + 创建 TitleBarDragOverlay 接管后续拖拽
    /// 注意：此处不移除恢复帧。只有用户真正拖动后（handleUp 发通知）才清除。
    /// 这样纯点击不拖动时，恢复帧保留，窗口保持原样。
    private func tryCreateTitleBarOverlay(quartzPt: CGPoint) -> Bool {
        guard dragSplitRestoreEnabled, !dragSplitRestoreFrames.isEmpty else { return false }
        guard let pid = pidAtQuartz(quartzPt),
              pid != ProcessInfo.processInfo.processIdentifier else { return false }

        let ref = AXWindowRef(pid: pid)
        guard let restoreFrame = dragSplitRestoreFrames[ref] else { return false }

        let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoaPt = NSPoint(x: quartzPt.x, y: primaryH - quartzPt.y)
        guard let window = findWindow(for: pid, at: cocoaPt) else { return false }

        guard let currentFrame = getAXWindowFrame(window) else { return false }
        let titleBarH = min(max(currentFrame.size.height * 0.08, 24), 50)
        guard quartzPt.y >= currentFrame.origin.y &&
              quartzPt.y <= currentFrame.origin.y + titleBarH else { return false }

        // 排除交通灯按钮区域（窗口左上角），让用户能正常点击关闭/最小化/最大化按钮
        let relX = quartzPt.x - currentFrame.origin.x
        let relY = quartzPt.y - currentFrame.origin.y
        if relX < 80 && relY < 30 {
            return false
        }

        // 创建 overlay：不立即恢复 size，等真正拖动（超过阈值）才恢复
        activeOverlay = TitleBarDragOverlay(
            window: window,
            restoreSize: restoreFrame.size,
            initialQuartzPt: quartzPt
        )
        return true
    }

    /// overlay 激活期间，将拖拽事件路由给 overlay 处理
    private func routeOverlayDrag(quartzPt: CGPoint) -> Bool {
        guard let overlay = activeOverlay else { return false }
        overlay.handleDrag(quartzPt: quartzPt)
        return true
    }

    /// 松手时清理 overlay（不消费 leftMouseUp）
    /// 若用户真正拖动过，handleUp 会发通知，WindowManagementService 收到后清除恢复帧和 Toggle 快照
    /// 若只是点击未拖动，不发通知，恢复帧保留，下次点击/拖动仍可触发恢复
    private func routeOverlayUp() {
        guard let overlay = activeOverlay else { return }
        overlay.handleUp()
        activeOverlay = nil
    }

        private func findWindow(for pid: pid_t, at cocoaPt: NSPoint) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var listRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &listRef) == .success,
              let windows = listRef as? [AXUIElement] else { return nil }

        for axWin in windows {
            var pos = CGPoint.zero
            var size = CGSize.zero
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?

            guard AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef) == .success,
                  let pv = posRef,
                  CFGetTypeID(pv) == AXValueGetTypeID(),
                  AXValueGetValue(pv as! AXValue, .cgPoint, &pos) else { continue }

            AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef)
            if let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
                AXValueGetValue(sv as! AXValue, .cgSize, &size)
            }

            // AX position y 从主屏顶部算起，需转换为 Cocoa 坐标（底部算起）
            let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
            let cocoaY = primaryH - pos.y - size.height
            let cocoaFrame = CGRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
            if cocoaFrame.contains(cocoaPt) {
                return axWin
            }
        }

        // Fallback: focused window or first window
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let w = windowRef, CFGetTypeID(w) == AXUIElementGetTypeID() {
            return (w as! AXUIElement)
        }
        return windows.first
    }

    /// Quartz 坐标处窗口的 PID
    private func pidAtQuartz(_ quartzPt: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int32, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(quartzPt) {
                return info[kCGWindowOwnerPID as String] as? pid_t
            }
        }
        return nil
    }

    /// 快捷键分屏时主动注册恢复帧，让后续普通拖拽也能恢复原始大小
    func registerSnappedFrame(for pid: pid_t, frame: CGRect) {
        dragSplitRestoreFrames[AXWindowRef(pid: pid)] = frame
    }

    /// 快捷键 toggle 恢复时清除对应帧
    func clearSnappedFrame(for pid: pid_t) {
        dragSplitRestoreFrames.removeValue(forKey: AXWindowRef(pid: pid))
    }

    /// 拖拽期间鼠标位置更新，驱动热区检测→peek→展开→预览 全流程
    /// MoveWindowService 在 leftMouseDragged 回调中通过主线程 async 调用
    func handleExternalDrag(cocoaPt: NSPoint, screen: NSScreen, targetWindow: AXUIElement) {
        // 首次调用：挂起自身轮询，初始化拖拽状态
        if !externalDragActive {
            externalDragActive = true
        }
        if !isDragging {
            isDragging = true
            dragTargetWindow = targetWindow
            // 保存拖拽开始前窗口原始 frame（用于后续恢复，而非分屏瞬间的过渡位置）
            dragSplitPreDragFrame = getAXWindowFrame(targetWindow)
            peekShownAt = nil
            peekShownAtPoint = nil
        }

        let cgPt = CGPoint(x: cocoaPt.x, y: cocoaPt.y)

        switch stage {
        case .idle:
            guard isInHotZone(cgPt, screen) else { return }
            showPanelAsPeek(on: screen)
            stage = .peeking
        case .peeking:
            if isOnPeekBar(cocoaPt) {
                if canExpandFromPeek(pt: cocoaPt) {
                    panelController?.expandToFull()
                    stage = .expanded
                }
                return
            }
            if !isInHotZone(cgPt, screen) && !isOnPeekBar(cocoaPt) {
                hideAll()
            }
        case .expanded:
            let insidePanel = panelController?.containsScreenPoint(cocoaPt) ?? false
            if !insidePanel && !isInHotZone(cgPt, screen) {
                hideAll()
                return
            }
            guard let panel = panelController else { return }
            if let hovered = panel.layoutAtScreenPoint(cocoaPt) {
                if hoveredLayout != hovered {
                    hoveredLayout = hovered
                    showPreview(for: hovered, on: screen)
                }
            } else {
                if hoveredLayout != nil {
                    hoveredLayout = nil
                    hidePreview()
                }
            }
        }
    }

    /// 离开热区 → 隐藏面板和预览，回到 idle
    func handleExternalDragExit() {
        guard isDragging else { return }
        dragSplitPreDragFrame = nil
        hideAll()
    }

    /// 鼠标松开，应用布局（如果在热区内选中了布局）
    func handleExternalDragEnd(cocoaPt: NSPoint) {
        if stage == .expanded, let layout = hoveredLayout, let window = dragTargetWindow {
            applyLayout(layout, to: window)
        }
        hideAll()
        resetDragState()
        externalDragActive = false
    }

    // MARK: - 鼠标按下/松开

    private func onMouseDown() {
        isMouseDown = true
        isDragging = false
        beginDragAttempts = 0
        mouseDownLocation = NSEvent.mouseLocation
    }

    /// 检测用户是否在普通点击（非修饰键拖拽）已被分屏的窗口 → 恢复

    /// 给定坐标处最上层窗口的 PID
    func pidAtPoint(quartzPt: CGPoint, cocoaPt: NSPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int32, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(quartzPt) {
                return info[kCGWindowOwnerPID as String] as? pid_t
            }
        }
        return nil
    }

    /// 获取鼠标光标下最上层窗口的 PID
    private func pidUnderMouse() -> pid_t? {
        // NSEvent.mouseLocation = Cocoa（左下角原点）
        // CGWindowList bounds = Quartz（左上角原点）
        let cocoaPt = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let quartzPt = CGPoint(x: cocoaPt.x, y: primaryHeight - cocoaPt.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int32, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(quartzPt) {
                return info[kCGWindowOwnerPID as String] as? pid_t
            }
        }
        return nil
    }

    private func onMouseUp() {
        // MoveWindowService 正在驱动拖拽时，交由 handleExternalDragEnd 处理
        if externalDragActive {
            isMouseDown = false
            return
        }
        defer {
            isMouseDown = false
            skipPollUntilMouseUp = false
            resetDragState()
        }

        guard isDragging else { return }

        // 仅在完整面板展开时才应用布局
        if stage == .expanded, let layout = hoveredLayout, let window = dragTargetWindow {
            applyLayout(layout, to: window)
        }

        hideAll()
    }

    // MARK: - 轮询鼠标位置（核心逻辑）

    private func pollMousePosition() {
        // MoveWindowService 正在驱动拖拽，轮询由它负责
        guard !externalDragActive else { return }
        // TitleBarDragOverlay 正在处理标题栏拖拽恢复时，跳过轮询
        // 避免 polling 通过 CGEventSource.buttonState 检测到硬件按下后启动第二套拖拽逻辑
        // （CGEvent tap 消费了 leftMouseDown，但 buttonState 仍反映硬件真实状态）
        guard activeOverlay == nil else { return }
        // 普通拖拽恢复后，让系统接管本轮拖拽
        guard !skipPollUntilMouseUp else { return }

        // CGEventSource 补充检测
        if !isMouseDown {
            if CGEventSource.buttonState(.combinedSessionState, button: .left) {
                isMouseDown = true
                mouseDownLocation = NSEvent.mouseLocation
            } else {
                return
            }
        } else {
            if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                onMouseUp()
                return
            }
        }

        let pt = NSEvent.mouseLocation
        let cgPt = CGPoint(x: pt.x, y: pt.y)

        guard let screen = screenContaining(cgPt) else {
            hideAll()
            return
        }

        // 必须鼠标移动超过阈值才算拖拽（防止点击触发）
        if !isDragging {
            let dx = pt.x - mouseDownLocation.x
            let dy = pt.y - mouseDownLocation.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance > dragThreshold else { return }
            beginDragAttempts += 1
            guard beginDragAttempts <= 3 else { return }
            beginDrag(at: cgPt, screen: screen)
        }
        guard isDragging else { return }

        // 根据当前阶段分发处理
        switch stage {
        case .idle:
            handleIdle(pt: pt, cgPt: cgPt, screen: screen)
        case .peeking:
            handlePeeking(pt: pt, cgPt: cgPt, screen: screen)
        case .expanded:
            handleExpanded(pt: pt, cgPt: cgPt, screen: screen)
        }
    }

    // MARK: - 阶段处理

    /// idle：拖拽中但未显示任何 UI，进入热区则显示 peek
    private func handleIdle(pt: NSPoint, cgPt: CGPoint, screen: NSScreen) {
        guard isInHotZone(cgPt, screen) else { return }
        showPanelAsPeek(on: screen)
        stage = .peeking
    }

    /// peeking：peek 已显示，拖到 peek 条则展开面板；离开热区+peek条才隐藏
    private func handlePeeking(pt: NSPoint, cgPt: CGPoint, screen: NSScreen) {
        if isOnPeekBar(pt) {
            // 确认是否为"刻意"操作：peek 展示足够久或光标移动了足够距离
            if canExpandFromPeek(pt: pt) {
                panelController?.expandToFull()
                stage = .expanded
                return
            }
            // 否则忽略此次 peek 条命中（peek 刚出现，用户可能并非刻意移入）
            return
        }
        // peek 持续显示，只要还在热区或 peek 条上就不隐藏
        if !isInHotZone(cgPt, screen) && !isOnPeekBar(pt) {
            hideAll()
        }
    }

    /// 判断是否允许从 peek 展开：需等待最小展示时长或光标有明显移动
    private func canExpandFromPeek(pt: NSPoint) -> Bool {
        guard let shownAt = peekShownAt, let shownAtPoint = peekShownAtPoint else {
            return true // 无记录则放行（安全兜底）
        }
        let elapsed = Date().timeIntervalSince(shownAt)
        let moved = hypot(pt.x - shownAtPoint.x, pt.y - shownAtPoint.y)
        return elapsed >= minimumPeekDuration || moved >= deliberateMoveThreshold
    }

    /// expanded：完整面板已展开，更新悬停；离开面板+热区则隐藏
    private func handleExpanded(pt: NSPoint, cgPt: CGPoint, screen: NSScreen) {
        let insidePanel = panelController?.containsScreenPoint(pt) ?? false
        if !insidePanel && !isInHotZone(cgPt, screen) {
            hideAll()
            return
        }

        guard let panel = panelController else { return }

        if let hovered = panel.layoutAtScreenPoint(pt) {
            if hoveredLayout != hovered {
                hoveredLayout = hovered
                showPreview(for: hovered, on: screen)
            }
        } else {
            if hoveredLayout != nil {
                hoveredLayout = nil
                hidePreview()
            }
        }
    }

    // MARK: - 热区 & 命中检测

    /// 热区：与悬浮窗等大的矩形，位于屏幕最顶部（顶部对齐 screen.frame.maxY，含菜单栏区域）
    /// 拖窗口到这个矩形内即触发 peek
    private func isInHotZone(_ pt: CGPoint, _ screen: NSScreen) -> Bool {
        let w = UIConfig.DragSplitPanel.panelWidth
        let h = UIConfig.DragSplitPanel.panelHeight
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        return CGRect(x: x, y: y, width: w, height: h).contains(pt)
    }

    private func isOnPeekBar(_ pt: NSPoint) -> Bool {
        // peek 状态下，命中即视为在 peek 条上
        panelController?.isPeeking == true && (panelController?.containsScreenPoint(pt) ?? false)
    }

    // MARK: - 拖拽识别

    private func beginDrag(at pt: CGPoint, screen: NSScreen) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return }
        let window = windowRef as! AXUIElement

        // 最大化窗口不触发
        var isFull: AnyObject?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &isFull) == .success,
           let fullNum = isFull as? NSNumber, fullNum.boolValue { return }

        isDragging = true
        dragTargetWindow = window
    }

    private func resetDragState() {
        isDragging = false
        dragTargetWindow = nil
        hoveredLayout = nil
        stage = .idle
    }

    // MARK: - 面板 & 预览

    /// 以 peek 状态显示面板（同一面板后续可展开为完整）
    private func showPanelAsPeek(on screen: NSScreen) {
        guard panelController == nil else { return }
        isPanelVisible = true
        peekShownAt = Date()
        peekShownAtPoint = NSEvent.mouseLocation
        let controller = DragSplitPanelController(service: self, screen: screen)
        controller.showAsPeek()
        panelController = controller
    }

    /// 隐藏面板 + 预览，回到 idle
    private func hideAll() {
        if isPanelVisible {
            isPanelVisible = false
            panelController?.close()
            panelController = nil
        }
        hoveredLayout = nil
        hidePreview()
        peekShownAt = nil
        peekShownAtPoint = nil
        stage = .idle
    }

    private func showPreview(for layout: WindowLayout, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        var targetFrame = layout.targetFrame(in: visibleFrame)

        // 边缘留白：不顶满屏幕边缘
        let edgeGap: CGFloat = 6
        targetFrame = targetFrame.insetBy(dx: edgeGap, dy: edgeGap)

        if let preview = previewController {
            preview.animate(to: targetFrame)
        } else {
            let preview = DragSplitPreviewOverlay()
            preview.show(frame: targetFrame)
            previewController = preview
        }
    }

    private func hidePreview() {
        previewController?.close()
        previewController = nil
    }

    // MARK: - 应用布局

    private func applyLayout(_ layout: WindowLayout, to window: AXUIElement) {
        let pt = NSEvent.mouseLocation
        guard let screen = screenContaining(CGPoint(x: pt.x, y: pt.y)) else { return }
        let visibleFrame = screen.visibleFrame
        let targetFrame = layout.targetFrame(in: visibleFrame)

        var axY = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - targetFrame.maxY
        var pos = CGPoint(x: targetFrame.origin.x, y: axY)
        var sz  = targetFrame.size
        let axTargetFrame = CGRect(origin: pos, size: sz)

        guard let currentFrame = getAXWindowFrame(window) else {
            setAXWindowFrame(window, frame: axTargetFrame)
            return
        }

        let ref = AXWindowRef(element: window)

        if currentFrame.isClose(to: axTargetFrame),
           let previousFrame = dragSplitRestoreFrames[ref] {
            dragSplitRestoreFrames[ref] = nil
            // 恢复到拖拽前的原始大小位置
            let restoreTarget = dragSplitPreDragFrame ?? previousFrame
            dragSplitPreDragFrame = nil
            animateAXWindow(window, from: currentFrame, to: restoreTarget)
        } else {
            // 保存拖拽前 frame 用于恢复；若获取失败则用当前 frame 兜底
            let savedFrame = dragSplitPreDragFrame ?? currentFrame
            dragSplitRestoreFrames[ref] = savedFrame
            dragSplitPreDragFrame = nil
            animateAXWindow(window, from: currentFrame, to: axTargetFrame)
        }
    }

    // MARK: - AX 窗口动画（Timer 驱动）

    /// 仅动画恢复尺寸，位置不干预（跟随系统拖拽）
    private func animateSizeRestore(window: AXUIElement, fromSize: CGSize, toSize: CGSize) {
        guard abs(fromSize.width - toSize.width) > 2 || abs(fromSize.height - toSize.height) > 2 else {
            // 差异太小，直接设置
            var sz = toSize
            if SkyLightBridge.setWindowSize(window, size: toSize) { return }
            if let axSz = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSz)
            }
            return
        }
        let duration: TimeInterval = 0.15
        let startTime = CACurrentMediaTime()
        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        let interval = 1.0 / Double(max(fps, 60))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min((CACurrentMediaTime() - startTime) / duration, 1.0)
            let eased = 1.0 - pow(1.0 - progress, 2)
            let curSize = CGSize(
                width: fromSize.width + (toSize.width - fromSize.width) * eased,
                height: fromSize.height + (toSize.height - fromSize.height) * eased
            )
            if SkyLightBridge.setWindowSize(window, size: curSize) { return }
            var sz = curSize
            if let axSz = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSz)
            }
            if progress >= 1.0 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

        private func animateAXWindow(_ window: AXUIElement, from startFrame: CGRect, to endFrame: CGRect) {
        guard !startFrame.isClose(to: endFrame, tolerance: 1) else {
            setAXWindowFrame(window, frame: endFrame)
            return
        }
        let duration: TimeInterval = 0.20
        let startTime = CACurrentMediaTime()
        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        let interval = 1.0 / Double(max(fps, 60))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min((CACurrentMediaTime() - startTime) / duration, 1.0)
            let eased = 1.0 - pow(1.0 - progress, 2)
            let frame = CGRect(
                x: startFrame.origin.x + (endFrame.origin.x - startFrame.origin.x) * eased,
                y: startFrame.origin.y + (endFrame.origin.y - startFrame.origin.y) * eased,
                width: startFrame.size.width + (endFrame.size.width - startFrame.size.width) * eased,
                height: startFrame.size.height + (endFrame.size.height - startFrame.size.height) * eased
            )
            self.setAXWindowFrame(window, frame: frame)
            if progress >= 1.0 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func getAXWindowFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID(),
              AXValueGetValue(pv as! AXValue, .cgPoint, &position),
              let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID(),
              AXValueGetValue(sv as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func setAXWindowFrame(_ window: AXUIElement, frame: CGRect) {
        // 优先 SkyLight 路径（解决 Electron/CEF 应用 frame 设置失效问题）
        if SkyLightBridge.setWindowFrame(window, frame: frame) { return }
        // 降级到 AX 路径
        var pos = frame.origin
        var sz = frame.size
        if let axPos = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axPos)
        }
        if let axSz = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSz)
        }
    }

    // MARK: - 辅助方法

    private func screenContaining(_ pt: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSPoint(x: pt.x, y: pt.y), $0.frame, false) }
    }
}

private extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}
