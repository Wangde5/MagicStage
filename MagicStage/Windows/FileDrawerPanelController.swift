import AppKit
import QuartzCore
import QuickLookUI
import SwiftUI

@MainActor
final class FileDrawerPanelController: NSObject {
    private weak var service: FileDrawerService?
    private var panel: FileDrawerPanel?
    private var peekPanel: NSPanel?
    private weak var peekHostingView: NSView?
    private var previewPanel: QLPreviewPanel?
    private var previewPanelOriginalLevel: NSWindow.Level?
    private var previewItems: [FileDrawerItem] = []
    private var previewSourceFramesOnScreen: [String: NSRect] = [:]
    private weak var edgeScreen: NSScreen?
    /// 当前触发的方位（鼠标进入某个 hot zone 时记录），面板隐藏后重置为 nil。
    /// 非边缘触发（如快捷键呼出）时由 showFullPanel 设置为默认方位。
    private var activePlacement: FileDrawerPlacement?

    private var outsideGlobalMonitor: Any?
    private var outsideLocalMonitor: Any?
    private var localKeyMonitor: Any?
    private var previewKeyMonitor: Any?
    private var previewKeyInterceptorToken: UUID?
    private var edgeGlobalMonitor: Any?
    private var edgeLocalMonitor: Any?
    private var menuBeginObserver: Any?
    private var menuEndObserver: Any?

    private var animationGeneration: UInt64 = 0
    private var peekAnimationGeneration: UInt64 = 0
    private var peekShownAt = Date.distantPast
    private var peekActivationWorkItem: DispatchWorkItem?
    private var peekDismissWorkItem: DispatchWorkItem?
    private var panelDismissWorkItem: DispatchWorkItem?
    private var panelShownAt = Date.distantPast
    private var hasPointerEnteredPanelSincePresentation = false
    private var isPanelEntranceComplete = false
    /// 关闭完整抽屉后，只抑制鼠标仍停留的原触发边；不能把另一侧的热区也一并抑制。
    private var suppressedPeekPlacement: FileDrawerPlacement?
    private var isHidingPanel = false
    private var isPeekHiding = false
    private var isMenuTracking = false
    private var isPreviewSessionActive = false
    private var previewDismissGeneration: UInt64 = 0
    private var lastEdgeMovementHandledAt: CFTimeInterval = 0
    private var cachedPlacementSet: Set<FileDrawerPlacement> = []
    private var cachedPlacementCandidates: [FileDrawerPlacement] = [.right]

    init(service: FileDrawerService) {
        self.service = service
        super.init()
    }

    deinit {
        [outsideGlobalMonitor, outsideLocalMonitor, localKeyMonitor, previewKeyMonitor, edgeGlobalMonitor, edgeLocalMonitor]
            .compactMap { $0 }
            .forEach(NSEvent.removeMonitor)
        if let menuBeginObserver { NotificationCenter.default.removeObserver(menuBeginObserver) }
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
        if let previewKeyInterceptorToken {
            Task { @MainActor in
                HotkeyManager.shared.removeTransientKeyDownInterceptor(previewKeyInterceptorToken)
            }
        }
    }

    // MARK: - Public presentation

    func show() {
        let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        guard let screen else { return }
        hidePeek(animated: false)
        showFullPanel(on: screen)
    }

    func hide() {
        guard !isHidingPanel else { return }
        cancelPanelDismiss()
        hidePeek(animated: true)
        hidePreview(animated: true)
        guard let panel, panel.isVisible else {
            activePlacement = nil
            service?.panelDidHide()
            return
        }

        isHidingPanel = true
        suppressedPeekPlacement = activePlacement
        isPanelEntranceComplete = false
        hasPointerEnteredPanelSincePresentation = false
        animationGeneration &+= 1
        let generation = animationGeneration
        removeOutsideMonitors()
        let reducesMotion = UIConfig.Animation.shouldReduceMotion
        let end = reducesMotion ? panel.frame : exitFrame(from: panel.frame)
        panel.contentView?.layer?.removeAnimation(forKey: "fileDrawerEntranceTransform")
        panel.contentView?.layer?.removeAnimation(forKey: "fileDrawerExitTransform")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducesMotion ? 0.15 : UIConfig.FileDrawer.hideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.78, 0.58)
            panel.animator().setFrame(end, display: true)
            if reducesMotion {
                panel.animator().alphaValue = 0
            }
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, self.animationGeneration == generation else { return }
                panel?.orderOut(nil)
                panel?.alphaValue = 1
                panel?.contentView?.layer?.removeAnimation(forKey: "fileDrawerExitTransform")
                self.isHidingPanel = false
                self.activePlacement = nil
                self.service?.panelDidHide()
            }
        }
    }

    /// 打开外部文件时的「隐形隐藏」：仅将面板 alphaValue 设为 0，不 orderOut。
    /// 避免 LSUIElement 应用 orderOut 面板时干扰目标应用的激活时序。
    private var isInvisibleHiding = false

    func beginInvisibleHiding() {
        guard let panel, panel.isVisible, !isInvisibleHiding else { return }
        isInvisibleHiding = true
        panel.alphaValue = 0
    }

    func cancelInvisibleHiding() {
        guard isInvisibleHiding else { return }
        isInvisibleHiding = false
        if let panel { panel.alphaValue = 1 }
    }

    /// 立即移除面板（不走退出动画），用于打开外部文件前清除 floating 窗口对目标应用激活的干扰。
    func hideImmediatelyForExternalOpen() {
        cancelPanelDismiss()
        hidePeek(animated: false)
        hidePreview(animated: false)
        removeOutsideMonitors()
        if let panel {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        isHidingPanel = false
        isInvisibleHiding = false
        activePlacement = nil
        service?.panelDidHide()
    }

    func placementDidChange() {
        hidePeek(animated: false)
        // 退出动画进行中切换位置会与 setFrame 退出动画冲突,等下次显示再应用。
        guard !isHidingPanel, let panel, panel.isVisible else { return }
        let screen = screen(containing: panel.frame.center) ?? screen(containing: NSEvent.mouseLocation)
        guard let screen else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(targetFrame(on: screen), display: true)
        }
    }

    func clearTextFocus() {
        panel?.makeFirstResponder(nil)
    }

    func claimKeyboardFocus() {
        guard !isPreviewSessionActive, let panel, panel.isVisible else { return }
        panel.makeKey()
    }

    func restoreKeyFocus() {
        guard !isPreviewSessionActive, let panel, panel.isVisible else { return }
        panel.makeKey()
        panel.makeFirstResponder(nil)
    }

    func pointerInteractionDidBegin() {
        cancelPanelDismiss()
    }

    func pointerInteractionDidEnd() {
        guard service?.isPointerInteractionActive != true,
              service?.isPinned != true,
              let panel,
              panel.isVisible else { return }
        cancelPanelDismiss()
        guard !panel.frame.contains(NSEvent.mouseLocation) else {
            hasPointerEnteredPanelSincePresentation = true
            return
        }
        hasPointerEnteredPanelSincePresentation = true
        schedulePanelDismiss()
    }

    var isPreviewVisible: Bool { isPreviewSessionActive }

    func togglePreview(
        items: [FileDrawerItem],
        startingAt item: FileDrawerItem,
        sourceFramesInDrawer: [String: CGRect]
    ) {
        guard let drawerPanel = panel, drawerPanel.isVisible, !items.isEmpty else { return }
        if isPreviewSessionActive {
            hidePreview(animated: true)
            return
        }
        guard let systemPanel = QLPreviewPanel.shared() else { return }
        cancelPanelDismiss()
        // 能触发预览本身就说明用户已经和抽屉发生了交互。即使预览在
        // 入场动画结束前打开，也不能再被“尚未进入窗口”的保护条件拦住。
        hasPointerEnteredPanelSincePresentation = true
        previewDismissGeneration &+= 1
        isPreviewSessionActive = true
        previewItems = items
        updatePreviewSourceFrames(sourceFramesInDrawer)
        previewPanel = systemPanel
        systemPanel.alphaValue = 1
        systemPanel.ignoresMouseEvents = false
        systemPanel.dataSource = self
        systemPanel.delegate = self
        systemPanel.reloadData()
        let targetPreviewIndex = items.firstIndex(where: { $0.id == item.id }) ?? 0
        systemPanel.currentPreviewItemIndex = targetPreviewIndex
        // 抽屉使用 floating level；必须在展示前提升 Quick Look，避免先以默认层级
        // 绘制一帧、再提升一次所造成的液态玻璃重采样和来源缩略图闪烁。
        if previewPanelOriginalLevel == nil {
            previewPanelOriginalLevel = systemPanel.level
        }
        systemPanel.level = NSWindow.Level(
            rawValue: max(systemPanel.level.rawValue, drawerPanel.level.rawValue + 1)
        )
        // QLPreviewPanel 必须成为 key window 才会建立当前项目并执行系统原生缩放动画。
        // 层级已在上方一次性设好，因此这里只展示一次，不再追加 orderFrontRegardless，
        // 避免旧实现的二次窗口重排和液态玻璃重复采样。
        systemPanel.makeKeyAndOrderFront(nil)
        // QLPreviewPanel 第一次置前时会异步重载数据，并可能把索引复位为 0。
        // 展示后同步设一次，下一轮 run loop 再校准一次目标项目。
        systemPanel.currentPreviewItemIndex = targetPreviewIndex
        let openingGeneration = previewDismissGeneration
        DispatchQueue.main.async { [weak self, weak systemPanel] in
            guard let self,
                  let systemPanel,
                  self.isPreviewSessionActive,
                  self.previewDismissGeneration == openingGeneration,
                  self.previewPanel === systemPanel,
                  self.previewItems.indices.contains(targetPreviewIndex) else { return }
            systemPanel.currentPreviewItemIndex = targetPreviewIndex
        }
        installPreviewKeyMonitor()
    }

    func updatePreviewSourceFrames(_ framesInDrawer: [String: CGRect]) {
        guard let drawerPanel = panel, drawerPanel.isVisible else { return }
        let previewItemIDs = Set(previewItems.map(\.id))
        previewSourceFramesOnScreen = framesInDrawer.reduce(into: [:]) { result, entry in
            guard previewItemIDs.contains(entry.key),
                  let screenFrame = previewSourceFrameOnScreen(
                    fromDrawerFrame: entry.value,
                    drawerPanel: drawerPanel
                  ) else { return }
            result[entry.key] = screenFrame
        }
    }

    func hidePreview(animated _: Bool) {
        finishPreviewSession(orderOutPanel: true)
    }

    private var currentPreviewItem: FileDrawerItem? {
        guard let previewPanel,
              previewItems.indices.contains(previewPanel.currentPreviewItemIndex) else { return nil }
        return previewItems[previewPanel.currentPreviewItemIndex]
    }

    private func finishPreviewSession(orderOutPanel: Bool) {
        previewDismissGeneration &+= 1
        let generation = previewDismissGeneration
        isPreviewSessionActive = false
        removePreviewKeyMonitor()
        guard let closingPanel = previewPanel else {
            restoreDrawerAfterPreview()
            resumeDismissalAfterPreview(generation: generation)
            return
        }

        showQuickLookGhostFadeTail(above: closingPanel.level)

        if orderOutPanel, closingPanel.isVisible {
            closingPanel.orderOut(nil)
        }

        // QLPreviewPanel 在 orderOut/close 返回后仍会继续原生缩回动画。动画结束前
        // 必须保留 delegate、数据源、来源坐标和较高窗口层级，也不能把抽屉抢到前面。
        let cleanupDelay = UIConfig.Animation.shouldReduceMotion
            ? 0
            : UIConfig.FileDrawer.quickLookCloseTransitionDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay) { [weak self, weak closingPanel] in
            guard let self,
                  let closingPanel,
                  self.previewDismissGeneration == generation,
                  !self.isPreviewSessionActive else { return }
            self.completePreviewSessionCleanup(panel: closingPanel, generation: generation)
        }
    }

    /// Quick Look 的主体仍使用系统原生缩回；在它抵达来源位置的末段叠加同一张
    /// transition image 并仅淡出这一层，避免末帧直接消失。抽屉中的真实缩略图
    /// 始终不改透明度。
    private func showQuickLookGhostFadeTail(above windowLevel: NSWindow.Level) {
        guard let item = currentPreviewItem,
              let frame = previewSourceFramesOnScreen[item.id],
              let image = DrawerThumbnailCache.shared.image(for: item.id) else { return }
        let delay = UIConfig.Animation.shouldReduceMotion
            ? 0
            : max(
                0,
                UIConfig.FileDrawer.quickLookCloseTransitionDuration
                    - UIConfig.FileDrawer.ghostThumbnailFadeDuration
            )
        GhostThumbnailReturnAnimator.fadeAtRest(
            image: image,
            frame: frame,
            delay: delay,
            duration: UIConfig.FileDrawer.ghostThumbnailFadeDuration,
            level: NSWindow.Level(rawValue: windowLevel.rawValue + 1)
        )
    }

    private func completePreviewSessionCleanup(
        panel closingPanel: QLPreviewPanel,
        generation: UInt64,
        restoresWindowVisibility: Bool = true
    ) {
        if restoresWindowVisibility {
            closingPanel.alphaValue = 1
            closingPanel.ignoresMouseEvents = false
        }
        closingPanel.dataSource = nil
        closingPanel.delegate = nil
        if let previewPanelOriginalLevel {
            closingPanel.level = previewPanelOriginalLevel
        }
        previewPanelOriginalLevel = nil
        if previewPanel === closingPanel {
            previewPanel = nil
        }
        previewItems = []
        previewSourceFramesOnScreen = [:]
        restoreDrawerAfterPreview()
        resumeDismissalAfterPreview(generation: generation)
    }

    /// 统一在这里复核抽屉状态，覆盖 Space、Escape、关闭按钮和系统主动关闭等路径。
    /// 不等待 QLPreviewPanel.isVisible；系统收起动画期间该值仍可能短暂为 true。
    private func resumeDismissalAfterPreview(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.previewDismissGeneration == generation,
                  !self.isPreviewSessionActive,
                  let drawerPanel = self.panel,
                  drawerPanel.isVisible,
                  !drawerPanel.frame.contains(NSEvent.mouseLocation) else { return }
            self.cancelPanelDismiss()
            self.schedulePanelDismiss()
        }
    }

    private func restoreDrawerAfterPreview() {
        guard !isHidingPanel, let panel, panel.isVisible else { return }
        if !panel.isKeyWindow {
            panel.makeKey()
        }
        panel.makeFirstResponder(nil)
    }

    private func previewSourceFrameOnScreen(
        fromDrawerFrame frame: CGRect,
        drawerPanel: NSPanel
    ) -> NSRect? {
        guard frame.width > 0,
              frame.height > 0,
              let contentView = drawerPanel.contentView else { return nil }
        // SwiftUI 命名坐标空间以左上为视觉起点；AppKit view 坐标以左下为起点。
        let localFrame = NSRect(
            x: frame.minX,
            y: contentView.bounds.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        guard contentView.bounds.intersects(localFrame) else { return nil }
        let windowFrame = contentView.convert(localFrame, to: nil)
        return drawerPanel.convertToScreen(windowFrame)
    }

    private func installPreviewKeyMonitor() {
        removePreviewKeyMonitor()
        previewKeyInterceptorToken = HotkeyManager.shared.installTransientKeyDownInterceptor { [weak self] keyCode, _ in
            guard let self,
                  self.isPreviewSessionActive,
                  keyCode == 49 || keyCode == 53 else { return false }
            // 先同步告诉 CGEvent tap 消费事件，再异步结束预览，避免修改正在遍历的
            // 临时拦截器集合，也确保 Space 不会继续送到后方应用的输入框。
            Task { @MainActor [weak self] in
                self?.hidePreview(animated: true)
            }
            return true
        }
        previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPreviewSessionActive else { return event }
            guard event.keyCode == 49 || event.keyCode == 53 else { return event }
            self.hidePreview(animated: true)
            return nil
        }
    }

    private func removePreviewKeyMonitor() {
        if let previewKeyInterceptorToken {
            HotkeyManager.shared.removeTransientKeyDownInterceptor(previewKeyInterceptorToken)
            self.previewKeyInterceptorToken = nil
        }
        if let previewKeyMonitor { NSEvent.removeMonitor(previewKeyMonitor) }
        previewKeyMonitor = nil
    }

    // MARK: - Edge monitoring

    func startEdgeMonitoring() {
        guard edgeGlobalMonitor == nil, edgeLocalMonitor == nil else { return }
        edgeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleEdgeMovement(at: NSEvent.mouseLocation) }
        }
        edgeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleEdgeMovement(at: NSEvent.mouseLocation)
            return event
        }
    }

    func stopEdgeMonitoring() {
        pauseEdgeMonitoringForPanel()
        hidePeek(animated: false)
    }

    /// 权限变化、系统更新后恢复运行时调用。即使 token 非空也要重建，旧的全局
    /// monitor 可能是在未授权状态下注册的，表面存在但不会收到系统事件。
    func restartEdgeMonitoring() {
        pauseEdgeMonitoringForPanel()
        guard service?.isEnabled == true,
              service?.edgeTriggerEnabled == true,
              AXIsProcessTrusted(),
              panel?.isVisible != true else { return }
        startEdgeMonitoring()
    }

    private func pauseEdgeMonitoringForPanel() {
        if let edgeGlobalMonitor { NSEvent.removeMonitor(edgeGlobalMonitor) }
        if let edgeLocalMonitor { NSEvent.removeMonitor(edgeLocalMonitor) }
        edgeGlobalMonitor = nil
        edgeLocalMonitor = nil
    }

    private func handleEdgeMovement(at point: NSPoint) {
        guard let service, service.isEnabled, service.edgeTriggerEnabled else { return }
        if panel?.isVisible == true { return }

        // 高刷新率鼠标可能在同一个显示帧内发送多次 mouseMoved。边缘命中区域不会
        // 在这一帧内变化，只处理最新一帧所需的频率，避免后台监听与前台滚动争抢主线程。
        let now = CACurrentMediaTime()
        let refreshRate = max(60, NSScreen.main?.maximumFramesPerSecond ?? 60)
        guard now - lastEdgeMovementHandledAt >= 1.0 / Double(refreshRate) else { return }
        lastEdgeMovementHandledAt = now

        // 设置通常长期不变，不要在每一次 mouseMoved 上重复排序。
        if cachedPlacementSet != service.placements {
            cachedPlacementSet = service.placements
            let sorted = service.placements.sorted { $0.rawValue < $1.rawValue }
            cachedPlacementCandidates = sorted.isEmpty ? [.right] : sorted
        }
        let candidates = cachedPlacementCandidates
        let screens = NSScreen.screens

        // 遍历所有选中方位的 hot zone，找到第一个包含鼠标点的 placement。
        let previousPlacement = activePlacement
        // 找到则更新 activePlacement；未找到则保持不变，让 peek 隐藏逻辑正常工作。
        var matchedPlacement: FileDrawerPlacement?
        var matchedScreen: NSScreen?
        for placement in candidates {
            if let screen = screens.first(where: { hotZoneFrame(on: $0, for: placement).contains(point) }) {
                matchedPlacement = placement
                matchedScreen = screen
                break
            }
        }
        if let matchedPlacement {
            activePlacement = matchedPlacement
        }

        if let suppressedPeekPlacement {
            // 只要离开原边缘，或直接进入另一个已启用边缘，就解除抑制。
            // 这样左侧退出后可直接滑往右侧，不必刻意经过屏幕中央。
            if matchedPlacement == suppressedPeekPlacement {
                return
            }
            self.suppressedPeekPlacement = nil
        }

        if let matchedPlacement, let matchedScreen {
            // Peek 还在退出时 panel 仍可见，但 edgeScreen 已被清空。把新的进入
            // 作为一次明确的切换处理，避免第二个 hide 动画排队造成卡顿。
            let hasChangedEdge = previousPlacement != matchedPlacement || edgeScreen !== matchedScreen
            if isPeekHiding || (peekPanel?.isVisible == true && hasChangedEdge) {
                showPeek(on: matchedScreen)
                return
            }
        }

        if isPeekHiding {
            return
        }

        if peekPanel?.isVisible != true {
            guard let screen = matchedScreen else { return }
            showPeek(on: screen)
            return
        }

        guard let screen = edgeScreen else {
            hidePeek(animated: true)
            return
        }
        let peekFrame = peekTargetFrame(on: screen)
        let interactionFrame = hotZoneFrame(on: screen).union(peekFrame)
        if interactionFrame.contains(point) {
            cancelPeekDismiss()
            if peekActivationFrame(from: peekFrame).contains(point) {
                schedulePeekActivation(on: screen)
            } else {
                cancelPeekActivation()
            }
        } else {
            cancelPeekActivation()
            schedulePeekDismiss()
        }
    }

    private func showPeek(on screen: NSScreen) {
        cancelPeekActivation()
        cancelPeekDismiss()
        peekAnimationGeneration &+= 1
        isPeekHiding = false
        edgeScreen = screen
        peekShownAt = Date()

        let panel = peekPanel ?? makePeekPanel()
        peekPanel = panel
        // 确保 peek 条使用当前实际触发的方位，而非 service.placement（多选时固定为第一个）
        if let hosting = peekHostingView as? NSHostingView<FileDrawerPeekView> {
            hosting.rootView = FileDrawerPeekView(service: service!, placement: activePlacement ?? .right)
        }
        let target = peekTargetFrame(on: screen)
        // 若上一个方位正在退出，直接结束旧动画并从新方位的起点重新进入，
        // 而不是让 AppKit 的两个 window animator 竞争同一帧。
        panel.setFrame(UIConfig.Animation.shouldReduceMotion ? target : peekStartFrame(from: target), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = UIConfig.Animation.shouldReduceMotion ? 0.14 : UIConfig.FileDrawer.peekShowDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.86, 0.2, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

        if peekActivationFrame(from: target).contains(NSEvent.mouseLocation) {
            schedulePeekActivation(on: screen)
        }
    }

    private func hidePeek(animated: Bool) {
        cancelPeekActivation()
        cancelPeekDismiss()
        if animated, isPeekHiding { return }
        peekAnimationGeneration &+= 1
        let generation = peekAnimationGeneration
        guard let panel = peekPanel, panel.isVisible else {
            edgeScreen = nil
            isPeekHiding = false
            return
        }
        edgeScreen = nil
        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            isPeekHiding = false
            return
        }
        isPeekHiding = true
        let end = UIConfig.Animation.shouldReduceMotion ? panel.frame : peekStartFrame(from: panel.frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = UIConfig.FileDrawer.peekHideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 0.2)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.peekAnimationGeneration == generation else { return }
                self.peekPanel?.orderOut(nil)
                self.peekPanel?.alphaValue = 1
                self.isPeekHiding = false
            }
        }
    }

    private func schedulePeekDismiss() {
        guard peekDismissWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.peekDismissWorkItem = nil
                self?.hidePeek(animated: true)
            }
        }
        peekDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + UIConfig.FileDrawer.peekDismissDelay, execute: work)
    }

    private func cancelPeekDismiss() {
        peekDismissWorkItem?.cancel()
        peekDismissWorkItem = nil
    }

    private func schedulePeekActivation(on screen: NSScreen) {
        guard peekActivationWorkItem == nil,
              peekPanel?.isVisible == true,
              panel?.isVisible != true else { return }
        let generation = peekAnimationGeneration
        let remainingDwell = max(
            0,
            UIConfig.FileDrawer.peekMinimumDwell - Date().timeIntervalSince(peekShownAt)
        )
        let work = DispatchWorkItem { [weak self, weak screen] in
            Task { @MainActor [weak self, weak screen] in
                guard let self, let screen else { return }
                self.peekActivationWorkItem = nil
                guard self.peekAnimationGeneration == generation,
                      self.edgeScreen === screen,
                      self.peekPanel?.isVisible == true,
                      self.panel?.isVisible != true else { return }
                let point = NSEvent.mouseLocation
                let peekFrame = self.peekTargetFrame(on: screen)
                guard self.hotZoneFrame(on: screen).union(peekFrame).contains(point),
                      self.peekActivationFrame(from: peekFrame).contains(point) else { return }
                self.service?.prepareForPresentation()
                self.showFullPanel(on: screen)
            }
        }
        peekActivationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDwell, execute: work)
    }

    private func cancelPeekActivation() {
        peekActivationWorkItem?.cancel()
        peekActivationWorkItem = nil
    }

    // MARK: - Full panel

    private func showFullPanel(on screen: NSScreen) {
        cancelPeekActivation()
        isHidingPanel = false
        cancelPanelDismiss()
        animationGeneration &+= 1
        let generation = animationGeneration
        let panel = panel ?? makePanel()
        let wasVisible = panel.isVisible
        self.panel = panel
        hasPointerEnteredPanelSincePresentation = false
        isPanelEntranceComplete = false
        // 非边缘触发（如快捷键呼出）时 activePlacement 为 nil，使用 placements 首个方位作为默认。
        if activePlacement == nil {
            activePlacement = service?.placements.first ?? .right
        }

        let target = targetFrame(on: screen)
        panel.setFrame(UIConfig.Animation.shouldReduceMotion ? target : dismissedFrame(from: target), display: true)
        panel.alphaValue = 0
        panelShownAt = Date()
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        panel.makeKey()
        panel.makeFirstResponder(nil)
        pauseEdgeMonitoringForPanel()
        installOutsideMonitors()
        if !wasVisible, service?.enableHapticFeedback == true {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if let peekPanel, peekPanel.isVisible {
            peekAnimationGeneration &+= 1
            let peekGeneration = peekAnimationGeneration
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.11
                peekPanel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.peekAnimationGeneration == peekGeneration else { return }
                    self.peekPanel?.orderOut(nil)
                    self.peekPanel?.alphaValue = 1
                }
            }
        }
        edgeScreen = nil

        panel.displayIfNeeded()
        CATransaction.flush()
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.animationGeneration == generation, panel.isVisible else { return }
            if !UIConfig.Animation.shouldReduceMotion {
                self.animateSurfaceEntrance(panel.contentView)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = UIConfig.Animation.shouldReduceMotion ? 0.14 : UIConfig.FileDrawer.showDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.92, 0.22, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    guard let self, let panel, self.animationGeneration == generation else { return }
                    self.isPanelEntranceComplete = true
                    let pointerIsInside = panel.frame.contains(NSEvent.mouseLocation)
                    // 预览可能在入场动画结束前已经打开；不能用动画结束瞬间的
                    // 指针位置覆盖掉此前已经发生过的抽屉交互。
                    self.hasPointerEnteredPanelSincePresentation =
                        self.hasPointerEnteredPanelSincePresentation || pointerIsInside
                    // Quick Look 可能在抽屉入场动画结束前打开。此时不能把 key window
                    // 抢回抽屉，否则系统预览会失焦/收起，PDF 也无法正常交互翻阅。
                    if !self.isPreviewSessionActive {
                        panel.makeKey()
                        panel.makeFirstResponder(nil)
                    }
                    if self.hasPointerEnteredPanelSincePresentation, !pointerIsInside {
                        self.schedulePanelDismiss()
                    }
                }
            }
        }
    }

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let inset = UIConfig.FileDrawer.screenInset
        let size = NSSize(
            width: min(UIConfig.FileDrawer.width, max(360, visible.width - inset * 2)),
            height: min(UIConfig.FileDrawer.height, max(300, visible.height - inset * 2))
        )
        let x: CGFloat
        let y: CGFloat
        switch activePlacement ?? service?.placement ?? .right {
        case .left:
            x = visible.minX + inset
            y = visible.midY - size.height / 2
        case .right:
            x = visible.maxX - size.width - inset
            y = visible.midY - size.height / 2
        case .topLeft:
            x = visible.minX + inset
            y = visible.maxY - size.height - inset
        case .topRight:
            x = visible.maxX - size.width - inset
            y = visible.maxY - size.height - inset
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func dismissedFrame(from frame: NSRect) -> NSRect {
        switch activePlacement ?? service?.placement ?? .right {
        case .left: return frame.offsetBy(dx: -24, dy: 0)
        case .right: return frame.offsetBy(dx: 24, dy: 0)
        case .topLeft: return frame.offsetBy(dx: -17, dy: 17)
        case .topRight: return frame.offsetBy(dx: 17, dy: 17)
        }
    }

    private func exitFrame(from frame: NSRect) -> NSRect {
        let screen = screen(containing: frame.center)
            ?? NSScreen.screens.min { lhs, rhs in
                hypot(lhs.frame.midX - frame.midX, lhs.frame.midY - frame.midY)
                    < hypot(rhs.frame.midX - frame.midX, rhs.frame.midY - frame.midY)
            }
        guard let screen else { return dismissedFrame(from: frame) }
        let screenFrame = screen.frame
        let clearance: CGFloat = 10
        switch activePlacement ?? service?.placement ?? .right {
        case .left, .topLeft:
            return NSRect(
                x: screenFrame.minX - frame.width - clearance,
                y: frame.minY,
                width: frame.width,
                height: frame.height
            )
        case .right, .topRight:
            return NSRect(
                x: screenFrame.maxX + clearance,
                y: frame.minY,
                width: frame.width,
                height: frame.height
            )
        }
    }

    // MARK: - Edge geometry

    private func hotZoneFrame(on screen: NSScreen) -> NSRect {
        hotZoneFrame(on: screen, for: activePlacement ?? service?.placement ?? .right)
    }

    private func hotZoneFrame(on screen: NSScreen, for placement: FileDrawerPlacement) -> NSRect {
        let frame = screen.visibleFrame
        let sideDepth = min(UIConfig.FileDrawer.sideHotZoneDepth, frame.width)
        let sideLength = min(UIConfig.FileDrawer.sideHotZoneLength, frame.height)
        let cornerWidth = min(UIConfig.FileDrawer.cornerHotZoneWidth, frame.width)
        let cornerHeight = min(UIConfig.FileDrawer.cornerHotZoneHeight, frame.height)
        switch placement {
        case .left:
            return NSRect(
                x: frame.minX,
                y: frame.midY - sideLength / 2,
                width: sideDepth,
                height: sideLength
            )
        case .right:
            return NSRect(
                x: frame.maxX - sideDepth,
                y: frame.midY - sideLength / 2,
                width: sideDepth,
                height: sideLength
            )
        case .topLeft:
            return NSRect(x: frame.minX, y: frame.maxY - cornerHeight, width: cornerWidth, height: cornerHeight)
        case .topRight:
            return NSRect(x: frame.maxX - cornerWidth, y: frame.maxY - cornerHeight, width: cornerWidth, height: cornerHeight)
        }
    }

    private func peekTargetFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let visibleDepth = UIConfig.FileDrawer.peekVisibleDepth
        let sideY = visible.midY - UIConfig.FileDrawer.peekSideHeight / 2
        let cornerY = visible.maxY
            - UIConfig.FileDrawer.peekSideHeight
            - UIConfig.FileDrawer.peekCornerTopOffset
        switch activePlacement ?? service?.placement ?? .right {
        case .left:
            return NSRect(
                x: visible.minX - UIConfig.FileDrawer.peekSideWidth + visibleDepth,
                y: sideY,
                width: UIConfig.FileDrawer.peekSideWidth,
                height: UIConfig.FileDrawer.peekSideHeight
            )
        case .right:
            return NSRect(
                x: visible.maxX - visibleDepth,
                y: sideY,
                width: UIConfig.FileDrawer.peekSideWidth,
                height: UIConfig.FileDrawer.peekSideHeight
            )
        case .topLeft:
            return NSRect(
                x: visible.minX - UIConfig.FileDrawer.peekSideWidth + visibleDepth,
                y: cornerY,
                width: UIConfig.FileDrawer.peekSideWidth,
                height: UIConfig.FileDrawer.peekSideHeight
            )
        case .topRight:
            return NSRect(
                x: visible.maxX - visibleDepth,
                y: cornerY,
                width: UIConfig.FileDrawer.peekSideWidth,
                height: UIConfig.FileDrawer.peekSideHeight
            )
        }
    }

    private func peekActivationFrame(from frame: NSRect) -> NSRect {
        let inset = UIConfig.FileDrawer.peekActivationInset
        switch activePlacement ?? service?.placement ?? .right {
        case .left, .topLeft:
            return NSRect(x: frame.minX + inset, y: frame.minY, width: frame.width - inset, height: frame.height)
        case .right, .topRight:
            return NSRect(x: frame.minX, y: frame.minY, width: frame.width - inset, height: frame.height)
        }
    }

    private func peekStartFrame(from frame: NSRect) -> NSRect {
        switch activePlacement ?? service?.placement ?? .right {
        case .left: return frame.offsetBy(dx: -UIConfig.FileDrawer.peekVisibleDepth - 2, dy: 0)
        case .right: return frame.offsetBy(dx: UIConfig.FileDrawer.peekVisibleDepth + 2, dy: 0)
        case .topLeft:
            return frame.offsetBy(dx: -UIConfig.FileDrawer.peekVisibleDepth - 2, dy: 0)
        case .topRight:
            return frame.offsetBy(dx: UIConfig.FileDrawer.peekVisibleDepth + 2, dy: 0)
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    // MARK: - Panel construction and event handling

    private func makePanel() -> FileDrawerPanel {
        let panel = FileDrawerPanel(
            contentRect: NSRect(x: 0, y: 0, width: UIConfig.FileDrawer.width, height: UIConfig.FileDrawer.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel)
        panel.becomesKeyOnlyIfNeeded = true

        guard let service else { return panel }
        let container = GlassContainerView(frame: panel.contentView?.bounds ?? .zero)
        container.onPointerEntered = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isPanelEntranceComplete else { return }
                self.hasPointerEnteredPanelSincePresentation = true
                self.cancelPanelDismiss()
            }
        }
        container.onPointerExited = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isPanelEntranceComplete,
                      self.hasPointerEnteredPanelSincePresentation else { return }
                // 预览窗口是独立窗口；从抽屉移向 Quick Look 是正常操作，整个
                // 预览会话期间都暂停自动隐藏，待用户主动关闭预览后再复核指针。
                if self.isPreviewSessionActive {
                    self.cancelPanelDismiss()
                    return
                }
                self.schedulePanelDismiss()
            }
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        let hosting = TransparentHostingView(rootView: FileDrawerPanelView(service: service))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = []
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        return panel
    }

    private func makePeekPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel)
        panel.ignoresMouseEvents = true
        guard let service else { return panel }
        let hud = FileDrawerHUDView(frame: .zero, cornerRadius: UIConfig.FileDrawer.peekCornerRadius)
        hud.translatesAutoresizingMaskIntoConstraints = false
        let hosting = TransparentHostingView(rootView: FileDrawerPeekView(service: service, placement: service.placement))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = []
        hud.addSubview(hosting)
        peekHostingView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: hud.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: hud.bottomAnchor)
        ])
        panel.contentView = hud
        return panel
    }

    private func animateSurfaceEntrance(_ view: NSView?) {
        guard let layer = view?.layer else { return }
        layer.removeAnimation(forKey: "fileDrawerExitTransform")
        let spring = CASpringAnimation(keyPath: "transform")
        let travel = surfaceTravel(distance: 7)
        spring.fromValue = surfaceTransform(scale: 0.95, translation: travel)
        spring.toValue = CATransform3DIdentity
        spring.mass = 1
        spring.stiffness = 255
        spring.damping = 23
        spring.initialVelocity = 0.35
        spring.duration = min(0.5, spring.settlingDuration)
        layer.add(spring, forKey: "fileDrawerEntranceTransform")
    }

    private func surfaceTravel(distance: CGFloat) -> CGPoint {
        switch activePlacement ?? service?.placement ?? .right {
        case .left: return CGPoint(x: -distance, y: 0)
        case .right: return CGPoint(x: distance, y: 0)
        case .topLeft: return CGPoint(x: -distance * 0.72, y: distance * 0.72)
        case .topRight: return CGPoint(x: distance * 0.72, y: distance * 0.72)
        }
    }

    private func surfaceTransform(scale: CGFloat, translation: CGPoint) -> CATransform3D {
        CATransform3DTranslate(
            CATransform3DMakeScale(scale, scale, 1),
            translation.x,
            translation.y,
            0
        )
    }

    private func configure(_ panel: NSPanel) {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func installOutsideMonitors() {
        removeOutsideMonitors()
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel,
                      !panel.frame.contains(NSEvent.mouseLocation),
                      !(self.isPreviewSessionActive && self.previewPanel?.frame.contains(NSEvent.mouseLocation) == true) else { return }
                self.service?.hide()
            }
        }
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if self.isMenuTracking { return event }
            if !panel.frame.contains(NSEvent.mouseLocation),
               !(self.isPreviewSessionActive && self.previewPanel?.frame.contains(NSEvent.mouseLocation) == true) {
                self.service?.hide()
            }
            return event
        }
        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isMenuTracking = true
                self?.cancelPanelDismiss()
            }
        }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isMenuTracking = false
                guard let panel = self.panel,
                      !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.schedulePanelDismiss()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            // Quick Look 有独立的 key monitor；普通抽屉监听在预览期间不处理按键，
            // 避免依赖多个 monitor 的调用顺序或重复结束预览会话。
            if self.isPreviewSessionActive { return event }
            guard event.window === panel || panel.isKeyWindow else { return event }
            if panel.firstResponder is NSTextView {
                let isRenaming = self.service?.renamingItemID != nil
                // 重命名输入框需要正常输入空格,不能被空格预览拦截;
                // 仅搜索框在悬停文件时才用空格触发预览。
                if event.keyCode == 49, !isRenaming, self.service?.hoveredItemID != nil {
                    panel.makeFirstResponder(nil)
                    self.service?.previewSelectedItem()
                    return nil
                }
                if event.keyCode == 53 {
                    if isRenaming {
                        self.service?.cancelRename()
                    } else if self.service?.searchText.isEmpty == false {
                        self.service?.searchText = ""
                    } else {
                        self.service?.hide()
                    }
                    panel.makeFirstResponder(nil)
                    return nil
                }
                return event
            }
            if event.keyCode == 53 {
                self.service?.hide()
                return nil
            }
            switch event.keyCode {
            case 49:
                self.service?.previewSelectedItem()
                return nil
            case 36:
                self.service?.beginRenamingSelectedItem()
                return nil
            case 0 where event.modifierFlags.contains(.command):
                self.service?.selectAll()
                return nil
            case 8 where event.modifierFlags.contains(.command):
                self.service?.copySelectedItems()
                return nil
            case 9 where event.modifierFlags.contains(.command) && event.modifierFlags.contains(.option):
                self.service?.pasteItems(moving: true)
                return nil
            case 9 where event.modifierFlags.contains(.command):
                self.service?.pasteItems()
                return nil
            case 2 where event.modifierFlags.contains(.command):
                self.service?.duplicateSelectedItems()
                return nil
            case 45 where event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift):
                self.service?.createNewFolder()
                return nil
            case 31 where event.modifierFlags.contains(.command):
                self.service?.openSelectedItems()
                return nil
            case 51 where event.modifierFlags.contains(.command):
                self.service?.deleteSelectedItems()
                return nil
            case 126 where event.modifierFlags.contains(.command):
                self.service?.navigateBack()
                return nil
            case 125 where event.modifierFlags.contains(.command):
                self.service?.openSelectedItem()
                return nil
            case 6 where event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift):
                // Command+Shift+Z: 重做重命名
                if let service = self.service, service.undoManager.canRedo {
                    service.undoManager.redo()
                    return nil
                }
                return event
            case 6 where event.modifierFlags.contains(.command):
                // Command+Z: 撤销重命名
                if let service = self.service, service.undoManager.canUndo {
                    service.undoManager.undo()
                    return nil
                }
                return event
            case 123:
                self.service?.moveSelection(by: .left, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            case 124:
                self.service?.moveSelection(by: .right, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            case 125:
                self.service?.moveSelection(by: .down, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            case 126:
                self.service?.moveSelection(by: .up, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            case 116:
                self.service?.moveSelection(by: .pageUp, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            case 121:
                self.service?.moveSelection(by: .pageDown, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            case 115:
                self.service?.moveSelection(by: .home, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            case 119:
                self.service?.moveSelection(by: .end, extendingSelection: event.modifierFlags.contains(.shift))
                return nil
            default:
                return event
            }
        }
    }

    private func removeOutsideMonitors() {
        if let outsideGlobalMonitor { NSEvent.removeMonitor(outsideGlobalMonitor) }
        if let outsideLocalMonitor { NSEvent.removeMonitor(outsideLocalMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let menuBeginObserver { NotificationCenter.default.removeObserver(menuBeginObserver) }
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
        outsideGlobalMonitor = nil
        outsideLocalMonitor = nil
        localKeyMonitor = nil
        menuBeginObserver = nil
        menuEndObserver = nil
        isMenuTracking = false
        cancelPanelDismiss()
    }

    private func schedulePanelDismiss() {
        guard panelDismissWorkItem == nil,
              !isHidingPanel,
              !isMenuTracking,
              !isPreviewVisible,
              service?.isPointerInteractionActive != true,
              service?.isPinned != true,
              isPanelEntranceComplete,
              hasPointerEnteredPanelSincePresentation,
              panel?.isVisible == true else { return }
        let entranceGrace = max(
            0,
            UIConfig.FileDrawer.panelExitGrace - Date().timeIntervalSince(panelShownAt)
        )
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panelDismissWorkItem = nil
                guard let panel = self.panel,
                      panel.isVisible,
                      !panel.frame.contains(NSEvent.mouseLocation),
                      !self.isHidingPanel,
                      !self.isMenuTracking,
                      !self.isPreviewVisible,
                      self.service?.isPointerInteractionActive != true,
                      self.service?.isPinned != true,
                      self.isPanelEntranceComplete,
                      self.hasPointerEnteredPanelSincePresentation else { return }
                self.service?.hide()
            }
        }
        panelDismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + entranceGrace + (service?.dismissDelay ?? UIConfig.FileDrawer.defaultPanelExitDelay),
            execute: work
        )
    }

    private func cancelPanelDismiss() {
        panelDismissWorkItem?.cancel()
        panelDismissWorkItem = nil
    }
}

extension FileDrawerPanelController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index].url as NSURL
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        sourceFrameOnScreenFor item: (any QLPreviewItem)!
    ) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return previewSourceFramesOnScreen[url.standardizedFileURL.path] ?? .zero
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        guard let url = item.previewItemURL else { return nil }
        let identifier = url.standardizedFileURL.path
        let image = DrawerThumbnailCache.shared.image(for: identifier)
        guard let image else { return nil }
        // 抽屉的来源坐标是完整的 aspect-fit 缩略图框。将同一完整图像交给 QL，
        // 避免带透明边缘的 Finder 文件夹图标被 contentRect 二次裁切。
        contentRect?.pointee = NSRect(origin: .zero, size: image.size)
        return image
    }

    private func previewItem(for url: URL) -> FileDrawerItem? {
        let identifier = url.standardizedFileURL.path
        return previewItems.first { $0.id == identifier }
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 || event.keyCode == 53 else { return false }
        hidePreview(animated: true)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === previewPanel else { return true }
        // 关闭按钮属于明确的用户操作；不要再用 isVisible 的短暂变化推断关闭，
        // 否则 Quick Look 失焦或切换状态也会误触发抽屉自动隐藏。
        finishPreviewSession(orderOutPanel: false)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? QLPreviewPanel === previewPanel else { return }
        if isPreviewSessionActive {
            finishPreviewSession(orderOutPanel: false)
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

private final class FileDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 只承载转场用的“幽灵缩略图”。窗口关闭时即销毁，不会改变文件卡片本身。
@MainActor
enum GhostThumbnailReturnAnimator {
    struct Ghost {
        let image: NSImage
        let startFrame: NSRect
        let targetFrame: NSRect
    }

    static func animateReturn(
        _ ghosts: [Ghost],
        duration: TimeInterval,
        fadeDuration: TimeInterval,
        level: NSWindow.Level
    ) {
        guard !ghosts.isEmpty else { return }
        let reducesMotion = UIConfig.Animation.shouldReduceMotion
        if reducesMotion {
            return
        }

        // 只创建一个固定窗口，在窗口内部用 Core Animation 移动图层。
        // 这样动画提交给 WindowServer 后不需要主线程逐帧 setFrame。
        let animationBounds = ghosts.dropFirst().reduce(
            ghosts[0].startFrame.union(ghosts[0].targetFrame)
        ) { partial, ghost in
            partial.union(ghost.startFrame).union(ghost.targetFrame)
        }
        let panel = NSPanel(
            contentRect: animationBounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        let contentView = NSView(frame: NSRect(origin: .zero, size: animationBounds.size))
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        panel.contentView = contentView

        let fadeStart = max(0.001, min(1, 1 - fadeDuration / max(duration, 0.001)))
        for ghost in ghosts {
            var proposedRect = NSRect(origin: .zero, size: ghost.image.size)
            guard let cgImage = ghost.image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            ) else { continue }

            let startFrame = ghost.startFrame.offsetBy(
                dx: -animationBounds.minX,
                dy: -animationBounds.minY
            )
            let targetFrame = ghost.targetFrame.offsetBy(
                dx: -animationBounds.minX,
                dy: -animationBounds.minY
            )
            let imageLayer = CALayer()
            imageLayer.contents = cgImage
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            imageLayer.frame = targetFrame
            imageLayer.opacity = 0
            contentView.layer?.addSublayer(imageLayer)

            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: startFrame.center)
            position.toValue = NSValue(point: targetFrame.center)

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [1, 1, 0]
            opacity.keyTimes = [0, NSNumber(value: fadeStart), 1]

            let group = CAAnimationGroup()
            group.animations = [position, opacity]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            imageLayer.add(group, forKey: "fileDragReturn")
        }

        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            panel.orderOut(nil)
            panel.close()
        }
    }

    static func fadeAtRest(
        image: NSImage,
        frame: NSRect,
        delay: TimeInterval,
        duration: TimeInterval,
        level: NSWindow.Level
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let panel = makePanel(image: image, frame: frame, level: level)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                panel.close()
            }
        }
    }

    private static func makePanel(image: NSImage, frame: NSRect, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        panel.contentView = imageView
        return panel
    }
}

private final class FileDrawerHUDView: NSVisualEffectView {
    private let cornerRadius: CGFloat
    private var lastMaskSize: NSSize = .zero
    private var pointerTrackingArea: NSTrackingArea?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    init(frame frameRect: NSRect, cornerRadius: CGFloat = UIConfig.FileDrawer.cornerRadius) {
        self.cornerRadius = cornerRadius
        super.init(frame: frameRect)
        // 与抽屉菜单栏使用同一套 Finder 风格 header 材质，避免 Peek 条显得像 HUD。
        material = .headerView
        blendingMode = .behindWindow
        state = .active
        isEmphasized = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != lastMaskSize, bounds.width > 0, bounds.height > 0 else { return }
        lastMaskSize = bounds.size
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }
}

/// 纯 NSView 容器，用于主面板承载 SwiftUI 视图。
/// 不叠加任何 NSVisualEffectView 材质，让 SwiftUI .glassEffect(.clear) 独立渲染液态玻璃。
private final class GlassContainerView: NSView {
    private let cornerRadius: CGFloat
    private var pointerTrackingArea: NSTrackingArea?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    init(frame frameRect: NSRect, cornerRadius: CGFloat = UIConfig.FileDrawer.cornerRadius) {
        self.cornerRadius = cornerRadius
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }
}

/// 透明的 NSHostingView 子类：重写 isOpaque 返回 false，
/// 确保系统不绘制不透明矩形背景，让 .glassEffect() 能透过 hosting view 显示。
private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    deinit {} // 避免编译器优化 deinit 时崩溃（Swift 6.3 EarlyPerfInliner bug）
}

private struct FileDrawerPeekView: View {
    @ObservedObject var service: FileDrawerService
    let placement: FileDrawerPlacement

    var body: some View {
        ZStack {
            Color.primary.opacity(0.025)
            switch placement {
            case .left, .topLeft:
                sideHandle(direction: .right)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .right, .topRight:
                sideHandle(direction: .left)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: UIConfig.FileDrawer.peekCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: UIConfig.FileDrawer.peekCornerRadius, style: .continuous))
    }

    private enum SideDirection { case left, right }

    private func sideHandle(direction: SideDirection) -> some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.primary.opacity(0.5))
                .frame(width: 2.5, height: 24)
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: UIConfig.FileDrawer.peekVisibleDepth)
        .frame(maxHeight: .infinity)
    }
}
