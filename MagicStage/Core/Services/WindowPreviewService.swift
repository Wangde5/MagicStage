import Cocoa
import SwiftUI
import ApplicationServices
import Combine
import ScreenCaptureKit

#if DEBUG
private func previewLog(_ message: @autoclosure () -> String) { print(message()) }
#else
private func previewLog(_ message: @autoclosure () -> String) {}
#endif

// MARK: - 窗口预览服务

/// 鼠标悬停 Dock 图标时，显示该应用的窗口缩略图预览。
///
/// 设计参考 dock 项目 dockApp.swift：
/// - NSEvent 全局/本地鼠标移动监听触发悬停检测
/// - AXUIElementCopyElementAtPosition + kAXDockItemRole 定位 Dock 图标
/// - ScreenCaptureKit 截取该 PID 下所有正常层级窗口（含最小化）
/// - NSPanel（nonactivatingPanel + popUpMenu level）+ SwiftUI LazyVGrid
/// - hostingView.sizingOptions = [] 阻断 SwiftUI 反向约束，由 NSPanel 主导尺寸
/// - 0.1s 心跳 Timer 检测鼠标是否离开 Dock + Panel 合并区域，可配置延迟后淡出
@MainActor
final class WindowPreviewService: ObservableObject {
    static let shared = WindowPreviewService()

    // MARK: - 开关

    @Published var isEnabled = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "enableWindowPreview")
            if isEnabled { startMonitoring() } else { stopMonitoring() }
        }
    }

    // MARK: - 可配置参数
    //
    // 所有参数均通过 UserDefaults 持久化，didSet 在 UI 调整时触发持久化
    // 与面板重排（init 中从 UserDefaults 读取不会触发 didSet，符合预期）。

    /// 预览缩略图宽度（点）。通过滑动条调节，范围 160~400
    @Published var customCardWidth: CGFloat = 200 {
        didSet {
            UserDefaults.standard.set(Double(customCardWidth), forKey: "wp_customCardWidth")
            relayoutPanelIfVisible()
        }
    }

    @Published var triggerDelay: Double = 0.30 {
        didSet { UserDefaults.standard.set(triggerDelay, forKey: "wp_triggerDelay") }
    }

    @Published var dismissDelay: Double = 0.25 {
        didSet { UserDefaults.standard.set(dismissDelay, forKey: "wp_dismissDelay") }
    }

    @Published var cardSpacing: CGFloat = 8 {
        didSet {
            UserDefaults.standard.set(Double(cardSpacing), forKey: "wp_cardSpacing")
            relayoutPanelIfVisible()
        }
    }

    @Published var dockOffset: CGFloat = 20 {
        didSet {
            UserDefaults.standard.set(Double(dockOffset), forKey: "wp_dockOffset")
            relayoutPanelIfVisible()
        }
    }

    @Published var closeButtonSize: CGFloat = 12 {
        didSet {
            UserDefaults.standard.set(Double(closeButtonSize), forKey: "wp_closeButtonSize")
            relayoutPanelIfVisible()
        }
    }

    /// 使用液态玻璃材质（macOS 26+，默认开启）
    @Published var useLiquidGlass: Bool = true {
        didSet {
            UserDefaults.standard.set(useLiquidGlass, forKey: "wp_useLiquidGlass")
            rebuildPanel()
        }
    }

    /// 预览面板弹出时触控板震动（默认开启）
    @Published var enablePreviewHaptic: Bool = true {
        didSet {
            UserDefaults.standard.set(enablePreviewHaptic, forKey: "wp_enablePreviewHaptic")
        }
    }

    // MARK: - 派生尺寸

    /// 实际卡片宽度：直接使用 customCardWidth
    var effectiveCardWidth: CGFloat { customCardWidth }
    /// 实际图像高度：按宽高比 0.6 固定比例计算
    var effectiveImageHeight: CGFloat {
        effectiveCardWidth * 0.6
    }
    var cardWidth: CGFloat { effectiveCardWidth }
    var imageHeight: CGFloat { effectiveImageHeight }
    /// 卡片内边距（上下左右统一），根据图像高度动态缩放
    /// 图像较小时按比例增大边距，避免缩略图与容器边缘过近
    var cardPadding: CGFloat {
        max(8, effectiveImageHeight * 0.08)
    }
    /// 标题栏与缩略图之间的纵向间距，跟随图像高度动态缩放
    var vStackSpacing: CGFloat {
        max(6, effectiveImageHeight * 0.06)
    }
    /// 单卡总高 = padding*2 + spacing + 标题栏(closeButtonSize+2) + 图像高度
    /// 与 AppWindow.cardHeight 对齐
    var cardHeight: CGFloat { imageHeight + cardPadding * 2 + vStackSpacing + closeButtonSize + 2 }

    // MARK: - SwiftUI 绑定数据

    @Published private(set) var activeWindows: [AppWindow] = []
    @Published private(set) var visibleWindowIDs: Set<UInt32> = []
    @Published private(set) var isPanelVisible: Bool = false
    /// 是否是当前悬停会话中首次预览该应用
    /// 用于分类讨论卡片延迟：首次预览（容器淡入）延迟小，连续切换（容器resize）延迟大
    @Published private(set) var isFirstPreview: Bool = true

    // MARK: - 内部状态

    private var panel: NSPanel?
    /// 容器视图引用（用于消失动画的 layer transform）
    private weak var containerView: NSVisualEffectView?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 全局鼠标点击监听（右键菜单时立即隐藏面板，避免遮挡）
    private var globalClickMonitor: Any?
    /// 应用退出通知监听（Dock 快捷键退出后立即隐藏预览面板）
    private var workspaceObserver: NSObjectProtocol?

    private var trackingTimer: Timer?
    private var hideTimer: AnyCancellable?
    private var pendingShowTimer: Timer?
    /// 窗口数量检测计数器（每 0.5s 检测一次窗口变化）
    private var windowCheckCounter = 0
    /// 上次窗口检测的 ID 集合（避免 getCGWindowInfo 与 activeWindows 差异导致误判）
    private var lastCheckedWindowIDs: Set<UInt32> = []

    private var currentHoverPID: pid_t?
    private var captureTask: Task<Void, Never>?
    private var currentDockIconRect: CGRect = .zero

    private init() {
        // 第一次启动时注册默认值（用户修改后覆盖）
        UserDefaults.standard.register(defaults: [
            "enableWindowPreview": true,
            "wp_customCardWidth": 200.0,
            "wp_triggerDelay": 0.30,
            "wp_dismissDelay": 0.25,
            "wp_cardSpacing": 8.0,
            "wp_dockOffset": 20.0,
            "wp_closeButtonSize": 12.0,
            "wp_useLiquidGlass": true,
            "wp_enablePreviewHaptic": true
        ])

        if let v = UserDefaults.standard.object(forKey: "wp_customCardWidth") as? Double {
            customCardWidth = CGFloat(v)
        }
        if let v = UserDefaults.standard.object(forKey: "wp_triggerDelay") as? Double {
            triggerDelay = v
        }
        if let v = UserDefaults.standard.object(forKey: "wp_dismissDelay") as? Double {
            dismissDelay = v
        }
        if let v = UserDefaults.standard.object(forKey: "wp_cardSpacing") as? Double {
            cardSpacing = CGFloat(v)
        }
        if let v = UserDefaults.standard.object(forKey: "wp_dockOffset") as? Double {
            dockOffset = CGFloat(v)
        }
        if let v = UserDefaults.standard.object(forKey: "wp_closeButtonSize") as? Double {
            closeButtonSize = CGFloat(v)
        }
        if let v = UserDefaults.standard.object(forKey: "wp_useLiquidGlass") as? Bool {
            useLiquidGlass = v
        }
        if let v = UserDefaults.standard.object(forKey: "wp_enablePreviewHaptic") as? Bool {
            enablePreviewHaptic = v
        }

        let enabled = UserDefaults.standard.bool(forKey: "enableWindowPreview")
        isEnabled = enabled
    }

    // MARK: - 监听启停

    func startMonitoring() {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            return
        }

        guard globalMonitor == nil else { return }
        setupPanel()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.triggerHoverCheck() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in self?.triggerHoverCheck() }
            return event
        }

        // 全局鼠标点击监听：右键菜单/左键点击 Dock 图标时立即隐藏面板，避免遮挡
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.isPanelVisible else { return }
                // 只响应 Dock 区域的点击（面板内部点击由按钮自行处理）
                let mouseLoc = NSEvent.mouseLocation
                let inDock = self.currentDockIconRect
                    .insetBy(dx: -10, dy: -10)
                    .contains(mouseLoc)
                let inPanel = self.panel?.frame.contains(mouseLoc) ?? false
                if inDock && !inPanel {
                    self.hidePanel()
                }
            }
        }

        // 监听应用退出：Dock 快捷键退出后立即隐藏预览面板，避免鼠标还在 Dock 图标上时面板残留
        workspaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let hoverPID = self.currentHoverPID,
                  app.processIdentifier == hoverPID else { return }
            Task { @MainActor in
                self.hidePanel()
                self.currentHoverPID = nil
            }
        }
    }

    func stopMonitoring() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let observer = workspaceObserver {
            NotificationCenter.default.removeObserver(observer)
            workspaceObserver = nil
        }

        trackingTimer?.invalidate()
        trackingTimer = nil
        hideTimer?.cancel()
        hideTimer = nil
        pendingShowTimer?.invalidate()
        pendingShowTimer = nil

        captureTask?.cancel()
        captureTask = nil

        hidePanel()
    }

    // MARK: - 悬停检测

    private struct DockIconInfo {
        let pid: pid_t
        let dockRect: CGRect
    }

    /// 通过遍历 Dock 子元素定位鼠标下方的图标，返回 PID 与图标物理边框
    ///
    /// 不走 AXUIElementCopyElementAtPosition（跨进程 AX 可能返回错误元素），
    /// 而是展开 Dock 的 AX 树，逐个检查 frame 是否包含鼠标，选面积最小的命中项。
    /// 匹配时优先通过 AXURL → bundleURL 精确比较，解决 VS Code/Cursor 等
    /// Electron 应用 AXTitle 相同（都是 "Code"）导致误匹配的问题。
    private func detectDockIcon() -> DockIconInfo? {
        let mouseLocation = NSEvent.mouseLocation
        let cgMouseLocation = CGPoint(x: mouseLocation.x, y: mouseLocation.y)

        guard let dockAX = dockAXElement() else { return nil }
        let allItems = flattenAXElements(dockAX)

        var bestMatch: DockIconInfo?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for item in allItems {
            // 只关心 AXDockItem（图标），跳过 AXList 等容器
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == kAXDockItemRole else { continue }

            guard let frame = axElementFrame(item), frame.contains(cgMouseLocation) else { continue }

            let area = frame.width * frame.height
            guard area < bestArea else { continue }

            var pid: pid_t = 0
            var hasURL = false

            // 1. 优先：AXURL → bundleURL 精确匹配（解决同名 App 问题）
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef) == .success {
                let url: URL? = (urlRef as? NSURL) as URL? ?? (urlRef as? String).flatMap { URL(string: $0) }
                if let url = url {
                    hasURL = true
                    let standardURL = url.standardizedFileURL
                    if let app = NSWorkspace.shared.runningApplications.first(where: {
                        $0.bundleURL?.standardizedFileURL == standardURL
                    }) {
                        pid = app.processIdentifier
                    }
                }
            }

            // 2. 回退：名称匹配（仅在 AXURL 不可用时使用）
            // 关键：如果 AXURL 存在但找不到运行中的应用，说明该 App 已退出，
            // 不应回退到名称匹配，否则同名 App（如 Codex vs VS Code 都是 "Code"）会误匹配
            if pid == 0 && !hasURL, let appName = axElementTitle(item) {
                if let app = findRunningApp(named: appName) {
                    pid = app.processIdentifier
                }
            }

            if pid != 0 {
                bestArea = area
                bestMatch = DockIconInfo(pid: pid, dockRect: frame)
            }
        }

        return bestMatch
    }

    private func triggerHoverCheck() {
        guard let info = detectDockIcon() else {
            // 不在 Dock 图标上：取消待触发的延迟显示
            // 已显示的面板由 trackingTimer 负责淡出
            pendingShowTimer?.invalidate()
            pendingShowTimer = nil
            return
        }

        // 实时更新 Dock 图标物理边框（鼠标在图标内移动时位置不变，但保留以备尺寸变化）
        currentDockIconRect = info.dockRect

        if info.pid != currentHoverPID {
            // 切换到新的悬停目标
            pendingShowTimer?.invalidate()
            currentHoverPID = info.pid

            // 关键：如果面板已显示，不重新触发入场动画
            // 而是位移到新图标上方 + 内容同步淡入淡出
            if isPanelVisible {
                switchToTarget(info.pid)
                return
            }

            if triggerDelay > 0 {
                // 延迟触发，避免快速划过 Dock 时频繁截图
                pendingShowTimer = Timer.scheduledTimer(
                    withTimeInterval: triggerDelay,
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self, self.currentHoverPID == info.pid else { return }
                        self.showThumbnails(for: info.pid)
                    }
                }
            } else {
                showThumbnails(for: info.pid)
            }
        } else if !isPanelVisible {
            // 同一应用，但面板已隐藏（如调节设置后鼠标离开又回来）
            // 重新显示面板
            if triggerDelay > 0 {
                pendingShowTimer?.invalidate()
                pendingShowTimer = Timer.scheduledTimer(
                    withTimeInterval: triggerDelay,
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self, self.currentHoverPID == info.pid else { return }
                        self.showThumbnails(for: info.pid)
                    }
                }
            } else {
                showThumbnails(for: info.pid)
            }
        }
    }

    // MARK: - 心跳守护：鼠标脱离合并区域后淡出

    private func startTrackingTimer() {
        trackingTimer?.invalidate()
        windowCheckCounter = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isPanelVisible else { return }

                let mouseLoc = NSEvent.mouseLocation
                let inPanel = self.panel?.frame.contains(mouseLoc) ?? false
                // Dock 图标区域适当外扩，避免边缘抖动立刻触发隐藏
                let inDock = self.currentDockIconRect
                    .insetBy(dx: -15, dy: -25)
                    .contains(mouseLoc)

                if !inPanel && !inDock {
                    if self.hideTimer == nil {
                        let delay = self.dismissDelay
                        self.hideTimer = Just(())
                            .delay(for: .seconds(delay), scheduler: RunLoop.main)
                            .sink { [weak self] _ in
                                Task { @MainActor in self?.hidePanel() }
                            }
                    }
                } else {
                    self.hideTimer?.cancel()
                    self.hideTimer = nil
                }

                // 窗口数量检测：每 0.5s（5 次）检测一次窗口变化
                // 鼠标在 Dock 图标上时，检测新窗口/关闭窗口，自动刷新预览
                self.windowCheckCounter += 1
                if self.windowCheckCounter >= 5 && inDock {
                    self.windowCheckCounter = 0
                    self.checkWindowCountChanged()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }
    /// 用 lastCheckedWindowIDs 记录上次检测结果，不与 activeWindows 比较
    /// （因为 getCGWindowInfo 返回的集合比 activeWindows 大，含未过 SC/AX 过滤的窗口）
    /// 注意：最小化会让窗口从 layer==0 消失，可能导致误刷新；但关闭窗口也表现为 ID 消失
    /// 这里通过检测 ID 减少来捕获关闭事件，接受最小化的偶发刷新代价（用户体验更重要）
    private func checkWindowCountChanged() {
        guard let pid = currentHoverPID else { return }
        let (currentIDs, _, _) = getCGWindowInfo(for: pid)

        // 首次检测：只记录，不触发
        if lastCheckedWindowIDs.isEmpty {
            lastCheckedWindowIDs = currentIDs
            return
        }

        // 检测新增和关闭的窗口
        let newWindows = currentIDs.subtracting(lastCheckedWindowIDs)
        let closedWindows = lastCheckedWindowIDs.subtracting(currentIDs)
        lastCheckedWindowIDs = currentIDs

        if !newWindows.isEmpty || !closedWindows.isEmpty {
            #if DEBUG
            if !newWindows.isEmpty { previewLog("[WindowPreview] 检测到新窗口: +\(newWindows.count)") }
            if !closedWindows.isEmpty { previewLog("[WindowPreview] 检测到窗口关闭: -\(closedWindows.count)") }
            #endif
            // 重新捕获（用 switchToTarget 走淡入淡出，不重新触发入场动画）
            switchToTarget(pid)
        }
    }

    // MARK: - CGWindowList 窗口检测

    /// 用 CGWindowListCopyWindowInfo 获取指定 PID 的正常窗口 ID 列表 + 完整条目
    /// layer == 0 + alpha > 0.1（Electron 幽灵窗口 alpha=0 或极接近 0）
    /// 同时返回 windowID → title 映射 + 完整 CG 条目（用于 isOnscreen 查询）
    /// 不做 title/size 过滤，确保检测全面（与 SkyLightBridge 对齐）
    private func getCGWindowInfo(for pid: pid_t) -> (ids: Set<UInt32>, titles: [UInt32: String], entries: [UInt32: [String: Any]]) {
        guard let winInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return ([], [:], [:])
        }

        var ids = Set<UInt32>()
        var titles: [UInt32: String] = [:]
        var entries: [UInt32: [String: Any]] = [:]
        for info in winInfo {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.1 else { continue }
            if let wid = info[kCGWindowNumber as String] as? UInt32 {
                ids.insert(wid)
                let title = info[kCGWindowName as String] as? String ?? ""
                if !title.isEmpty { titles[wid] = title }
                entries[wid] = info
            }
        }

        return (ids, titles, entries)
    }

    // MARK: - AX 交叉验证

    /// AX 真实窗口信息（标题 + 尺寸 + 最小化状态 + windowID），用于过滤 SC 返回的辅助窗口
    /// isMinimized 来自 AX kAXMinimizedAttribute，比 SC isOnScreen 更可靠
    /// 解决 Electron 应用（Typora/VS Code）的隐藏窗口被误判为最小化的问题
    private struct AXWindowInfo {
        let title: String
        let size: CGSize
        let isMinimized: Bool
        let isFullscreen: Bool
        let windowID: UInt32  // 通过 _AXUIElementGetWindow 获取，用于与 SC 精确匹配
    }

    /// 获取指定 PID 的 AX 真实窗口信息列表
    /// 严格按 solve.md 实现：
    /// 1. 不过滤任何 subrole（隐藏白板不在 AX 树中，根本不会被枚举到）
    /// 2. 不做尺寸过滤（solve.md 不要求）
    /// 3. 仅作为"真实窗口白名单"使用，用于与 SC 双向强校验
    /// 4. AX 内部去重：相同 windowID 的 AX 窗口只保留第一个
    ///    （windowID 是唯一标识，比标题+尺寸更可靠）
    /// 返回 nil 表示 AX 不可用
    private func getAXWindows(for pid: pid_t) -> [AXWindowInfo]? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let windows = windowsRef as? [AXUIElement] else { return nil }

        var infos: [AXWindowInfo] = []
        var seenWindowIDs = Set<UInt32>()  // AX 内部去重（基于 windowID）
        var seenSignatures = Set<String>() // 兜底去重（windowID 获取失败时用标题+尺寸）

        for window in windows {
            // 优先获取 windowID（通过 _AXUIElementGetWindow 私有 API）
            // 这是与 SC 窗口精确匹配的关键，比标题+尺寸匹配可靠得多
            let windowID = SkyLightBridge.getWindowID(from: window) ?? 0

            // 获取尺寸（用于兜底匹配和幽灵检测）
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
            var size = CGSize.zero
            if let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
                AXValueGetValue(sv as! AXValue, .cgSize, &size)
            }

            // 获取标题（用于兜底匹配和显示）
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // 获取最小化状态（用于决定显示状态和幽灵检测）
            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            let isMinimized = (minimizedRef as? Bool) ?? false

            // 获取全屏状态（用于幽灵检测：全屏窗口可能在其他 Space）
            var fullscreenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef)
            let isFullscreen = (fullscreenRef as? Bool) ?? false

            // AX 内部去重：
            // - 优先用 windowID（唯一标识，最可靠）
            // - windowID 获取失败时用标题+尺寸兜底
            if windowID != 0 {
                if seenWindowIDs.contains(windowID) {
                    #if DEBUG
                    previewLog("[WindowPreview] AX 内部去重(windowID): wid=\(windowID) title=\(title.isEmpty ? "<empty>" : title)")
                    #endif
                    continue
                }
                seenWindowIDs.insert(windowID)
            } else {
                let sig = "\(title)_\(Int(size.width))x\(Int(size.height))"
                if seenSignatures.contains(sig) {
                    #if DEBUG
                    previewLog("[WindowPreview] AX 内部去重(sig): title=\(title.isEmpty ? "<empty>" : title) size=\(size.width)x\(size.height)")
                    #endif
                    continue
                }
                seenSignatures.insert(sig)
            }

            infos.append(AXWindowInfo(
                title: title,
                size: size,
                isMinimized: isMinimized,
                isFullscreen: isFullscreen,
                windowID: windowID
            ))
        }

        #if DEBUG
        previewLog("[WindowPreview] AX windows for pid=\(pid): count=\(infos.count), \(infos.map { "(\($0.title.isEmpty ? "<empty>" : $0.title), \($0.size.width)x\($0.size.height), min=\($0.isMinimized), fs=\($0.isFullscreen), wid=\($0.windowID))" })")
        #endif

        return infos
    }

    /// 从 AX 池中查找匹配的 SC 窗口，返回匹配的 AXWindowInfo 及其索引
    /// 用于一对一消耗：匹配后调用方从池中 remove(at: index)
    ///
    /// 匹配策略（两级，从精确到模糊）：
    ///
    /// 1. **windowID 精确匹配**（主路径，参考 DockDoor WindowUtil.findWindow）：
    ///    通过 _AXUIElementGetWindow 获取 AX 窗口的 CGWindowID，与 SC.windowID 直接比较。
    ///    这是唯一标识匹配，完全消除标题/尺寸歧义导致的幽灵窗口。
    ///
    /// 2. **标题+尺寸模糊匹配**（降级路径，windowID 获取失败时使用）：
    ///    必须同时满足「标题匹配 AND 尺寸高度吻合」
    ///    - 只比对标题：Typora 隐藏窗口标题也是 "Untitled" → 会误判
    ///    - 只比对尺寸：影子窗口大小可能和主窗口一样 → 会误判
    ///    - 联合强绑定（&&）：标题和尺寸都必须匹配，才能通过
    ///
    /// 返回 (AXWindowInfo, index) 或 nil
    private func scMatchesAXFromPool(sc: SCWindow, pool: [AXWindowInfo]) -> (AXWindowInfo, Int)? {
        // 路径 1：windowID 精确匹配（优先）
        // 这是最可靠的匹配方式，完全消除幽灵窗口
        if let exactIndex = pool.firstIndex(where: { $0.windowID != 0 && $0.windowID == sc.windowID }) {
            return (pool[exactIndex], exactIndex)
        }

        // 路径 2：标题+尺寸模糊匹配（降级）
        // 仅当 AX 窗口没有获取到 windowID 时使用
        let scTitle = (sc.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var bestMatch: AXWindowInfo?
        var bestIndex: Int?
        var bestDiff: CGFloat = .greatestFiniteMagnitude

        for (i, ax) in pool.enumerated() {
            // 已有 windowID 的 AX 窗口不参与模糊匹配（避免与精确匹配冲突）
            if ax.windowID != 0 { continue }

            let dw = abs(sc.frame.width - ax.size.width)
            let dh = abs(sc.frame.height - ax.size.height)
            let sizeDiff = dw + dh

            // 尺寸高度吻合：误差 ≤ 20px（容纳微小的系统边框差异）
            let sizeMatches = dw <= 20 && dh <= 20
            guard sizeMatches else { continue }

            // 标题匹配：
            // 双空标题 → 仅靠尺寸匹配（macOS 极简编辑器/播放器/设置面板）
            // 单空标题 → 不匹配（防止 Typora 空标题幽灵窗口）
            // 双非空标题 → 互相包含匹配
            let titleMatches: Bool
            if ax.title.isEmpty && scTitle.isEmpty {
                titleMatches = true
            } else if ax.title.isEmpty || scTitle.isEmpty {
                continue
            } else {
                titleMatches = ax.title.contains(scTitle) || scTitle.contains(ax.title)
            }
            guard titleMatches else { continue }

            if sizeDiff < bestDiff {
                bestDiff = sizeDiff
                bestMatch = ax
                bestIndex = i
            }
        }

        guard let match = bestMatch, let index = bestIndex else { return nil }
        return (match, index)
    }

    // MARK: - 截图与展示

    private func showThumbnails(for pid: pid_t) {
        self.currentHoverPID = pid
        captureTask?.cancel()

        captureTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let capturedWindows = await self.captureWindowsAsync(for: pid) else {
                self.hidePanel()
                return
            }

            if Task.isCancelled { return }

            self.isFirstPreview = true
            self.activeWindows = capturedWindows

            // 关键：取消之前可能 pending 的 hideTimer
            // 否则 panel 显示后 hideTimer 立即触发，导致"闪一下就消失"
            self.hideTimer?.cancel()
            self.hideTimer = nil

            // 无动画瞬间定位到 Dock 图标上方
            self.updatePanelFrame(
                for: capturedWindows.count,
                mouseX: self.currentDockIconRect.midX,
                animate: false
            )

            if self.panel?.isVisible == false {
                self.panel?.alphaValue = 1.0  // 确保显示时完全不透明（hidePanel 会重置为 1）
                self.panel?.orderFrontRegardless()
            }

            // 关键：先瞬间填满数据（不带动画），切断 SwiftUI 布局拉伸
            // 这样卡片的物理占位瞬间就是满的，不会有 0→100 的扫描拉伸
            self.visibleWindowIDs = Set(capturedWindows.map { $0.id })
            // 更新检测基准，避免 checkWindowCountChanged 误判
            let (_, _, cgEntries) = self.getCGWindowInfo(for: pid)
            self.lastCheckedWindowIDs = Set(cgEntries.keys)

            // 然后再触发容器的动画（只动画 isPanelVisible，不动画数据插入）
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                self.isPanelVisible = true
            }

            // 触控板震动反馈
            if self.enablePreviewHaptic {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }

            self.startTrackingTimer()
        }
    }

    /// 连续 Dock 切换：直接更新内容 + 面板位移动画
    /// 不做淡入淡出（之前淡入淡出会导致 activeWindows 和 visibleWindowIDs 不同步，卡片瞬间消失再出现）
    private func switchToTarget(_ pid: pid_t) {
        self.currentHoverPID = pid
        captureTask?.cancel()

        captureTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let capturedWindows = await self.captureWindowsAsync(for: pid) else {
                self.hidePanel()
                return
            }
            if Task.isCancelled { return }

            // 同时更新 activeWindows 和 visibleWindowIDs（保持同步，避免卡片消失）
            self.isFirstPreview = false
            self.activeWindows = capturedWindows
            self.visibleWindowIDs = Set(capturedWindows.map { $0.id })
            let (_, _, cgEntries) = self.getCGWindowInfo(for: pid)
            self.lastCheckedWindowIDs = Set(cgEntries.keys)

            // 面板位移动画到新位置
            self.updatePanelFrame(
                for: capturedWindows.count,
                mouseX: self.currentDockIconRect.midX,
                animate: true
            )

            // 触控板震动反馈（连续切换也震动）
            if self.enablePreviewHaptic {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    /// 窗口捕获逻辑（从 showThumbnails 提取，供 showThumbnails 和 switchToTarget 复用）
    /// 返回捕获的窗口列表，失败返回 nil
    private func captureWindowsAsync(for pid: pid_t) async -> [AppWindow]? {
        do {
            // SCShareableContent 必须在主线程调用
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )

            // 1. 用 CGWindowListCopyWindowInfo 获取窗口白名单 + 完整条目
            let (cgWindowIDs, cgTitles, cgEntries) = self.getCGWindowInfo(for: pid)

            // 2. SC 过滤：同 PID + 在 CG 白名单中 + 尺寸 >120x120
            let scWindows = content.windows.filter { sc in
                sc.owningApplication?.processID == pid
                    && sc.frame.width > 120
                    && sc.frame.height > 120
                    && cgWindowIDs.contains(sc.windowID)
            }

            // 3. AX 硬过滤 + 幽灵检测
            let axInfos = self.getAXWindows(for: pid)
            let app = NSRunningApplication(processIdentifier: pid)
            let appIsHidden = app?.isHidden ?? false
            var scToAXMinimized: [UInt32: Bool] = [:]

            let appWindows: [SCWindow]
            if let axInfos = axInfos, !axInfos.isEmpty {
                // AX 树不为空 → 硬过滤 + 一对一消耗
                var unmatchedAX = axInfos
                appWindows = scWindows.filter { sc in
                    let cgEntry = cgEntries[sc.windowID]
                    if let (match, matchIndex) = self.scMatchesAXFromPool(sc: sc, pool: unmatchedAX) {
                        unmatchedAX.remove(at: matchIndex)
                        scToAXMinimized[sc.windowID] = match.isMinimized
                        let cgIsOnscreen = cgEntry?[kCGWindowIsOnscreen as String] as? Bool ?? sc.isOnScreen
                        if !cgIsOnscreen && !match.isMinimized && !match.isFullscreen && !appIsHidden {
                            return false
                        }
                        return true
                    }
                    return false
                }
            } else {
                // AX 树为空 → 软过滤
                var seenSignatures = Set<String>()
                appWindows = scWindows.filter { sc in
                    guard sc.isOnScreen else { return false }
                    let scTitle = (sc.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let cgTitle = cgTitles[sc.windowID] ?? ""
                    let displayTitle = !scTitle.isEmpty ? scTitle : cgTitle
                    let sig = "\(displayTitle)_\(Int(sc.frame.width))x\(Int(sc.frame.height))"
                    if seenSignatures.contains(sig) {
                        return false
                    }
                    seenSignatures.insert(sig)
                    return true
                }
            }

            if appWindows.isEmpty { return nil }

            // 并行截图：三级降级策略
            let capturedWindows: [AppWindow] = await withTaskGroup(
                of: AppWindow?.self,
                returning: [AppWindow].self
            ) { group in
                for window in appWindows {
                    group.addTask { [self] in
                        let aspectRatio = window.frame.height > 0
                            ? window.frame.width / window.frame.height
                            : 1.0
                        let axMinimized = scToAXMinimized[window.windowID] ?? !window.isOnScreen

                        var title = window.title ?? ""
                        if title.isEmpty {
                            title = cgTitles[window.windowID] ?? ""
                        }
                        if title.isEmpty {
                            title = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
                        }

                        var cgImage: CGImage?

                        // 路径 1：CGSHWCaptureWindowList
                        if cgImage == nil {
                            cgImage = SkyLightBridge.captureWindow(windowID: window.windowID, bestResolution: true)
                        }

                        // 路径 2：SC 截图
                        if cgImage == nil {
                            let filter = SCContentFilter(desktopIndependentWindow: window)
                            let config = SCStreamConfiguration()
                            config.width = Int(window.frame.width * 2)
                            config.height = Int(window.frame.height * 2)
                            config.showsCursor = false
                            cgImage = try? await SCScreenshotManager.captureImage(
                                contentFilter: filter,
                                configuration: config
                            )
                        }

                        // 路径 3：CGWindowListCreateImage
                        if cgImage == nil {
                            let windowBounds = CGRect(
                                origin: window.frame.origin,
                                size: window.frame.size
                            )
                            if let cgBundle = CFBundleGetBundleWithIdentifier("com.apple.CoreGraphics" as CFString) {
                                if let fn = CFBundleGetFunctionPointerForName(
                                    cgBundle,
                                    "CGWindowListCreateImage" as CFString
                                ) {
                                    typealias CGWindowListCreateImageFn = @convention(c) (
                                        CGRect, CGWindowListOption, UInt32, CGWindowImageOption
                                    ) -> Unmanaged<CGImage>?
                                    let createImageFn = unsafeBitCast(fn, to: CGWindowListCreateImageFn.self)
                                    let imageRef = createImageFn(
                                        windowBounds,
                                        [.optionIncludingWindow],
                                        window.windowID,
                                        [.boundsIgnoreFraming, .bestResolution]
                                    )
                                    cgImage = imageRef?.takeRetainedValue()
                                }
                            }
                        }

                        guard let image = cgImage else {
                            // placeholder 尺寸按窗口 aspectRatio 计算，确保与真实图像比例一致
                            let placeholderH: CGFloat = 240
                            let placeholderW = max(50, placeholderH * aspectRatio)
                            let placeholder = WindowController.createPlaceholderImage(
                                size: CGSize(width: placeholderW, height: placeholderH),
                                title: title
                            )
                            return AppWindow(
                                id: window.windowID,
                                pid: pid,
                                title: title,
                                image: NSImage(cgImage: placeholder, size: .zero),
                                isMinimized: axMinimized,
                                aspectRatio: aspectRatio
                            )
                        }

                        return AppWindow(
                            id: window.windowID,
                            pid: pid,
                            title: title,
                            image: NSImage(cgImage: image, size: .zero),
                            isMinimized: axMinimized,
                            aspectRatio: aspectRatio
                        )
                    }
                }
                var results: [AppWindow] = []
                for await result in group {
                    if let result = result {
                        results.append(result)
                    }
                }
                return results.sorted { $0.id < $1.id }
            }

            return capturedWindows.isEmpty ? nil : capturedWindows
        } catch {
            return nil
        }
    }

    /// 计算面板尺寸并更新 frame（从指定窗口列表计算）
    private func updatePanelFrame(for windows: [AppWindow], mouseX: CGFloat, animate: Bool) {
        if windows.isEmpty { hidePanel(); return }

        // 卡片图像区域最大尺寸（扣除动态 padding）
        let pad = cardPadding
        let maxImageWidth = effectiveCardWidth - pad * 2
        let maxImageHeight = effectiveImageHeight

        // 每个卡片的尺寸（基于宽高比自适应）
        let cards = windows.map { appWindow -> (width: CGFloat, height: CGFloat) in
            let w = appWindow.cardWidth(maxImageWidth: maxImageWidth, maxImageHeight: maxImageHeight, cardPadding: pad)
            let h = appWindow.cardHeight(maxImageWidth: maxImageWidth, maxImageHeight: maxImageHeight, closeButtonSize: closeButtonSize, cardPadding: pad, vStackSpacing: vStackSpacing)
            return (w, h)
        }

        // 屏幕边界：根据 Dock 图标所在屏确定（多屏环境下 Dock 可能在副屏）
        let dockScreen = NSScreen.screens.first(where: { $0.frame.contains(currentDockIconRect) })
            ?? NSScreen.main
        let screenMaxX = dockScreen?.frame.maxX ?? 2000
        let screenMinX = dockScreen?.frame.minX ?? 0
        let screenWidth = screenMaxX - screenMinX

        // 容器 padding：FlowLayout padding(2) * 2 = 4
        let horizontalPadding: CGFloat = 2 * 2
        let verticalPadding: CGFloat = 2 * 2

        // 屏幕最大可用宽度（留 40px 边距）
        let maxScreenWidth = screenWidth - 40

        // 模拟 FlowLayout 换行：计算每行的卡片，得出总尺寸
        // 第一个卡片居中于 Dock 图标，所以面板宽度由"第一个卡片 + 后续卡片"决定
        // 但面板宽度不超过屏幕最大宽度，超出的卡片换行
        var lines: [[Int]] = []  // 每行存储卡片索引
        var currentLine: [Int] = []
        var currentLineWidth: CGFloat = 0
        let firstCardWidth = cards.first?.width ?? effectiveCardWidth

        for (idx, card) in cards.enumerated() {
            let additional = (currentLine.isEmpty ? 0 : cardSpacing) + card.width
            if currentLineWidth + additional > maxScreenWidth - horizontalPadding && !currentLine.isEmpty {
                // 换行
                lines.append(currentLine)
                currentLine = [idx]
                currentLineWidth = card.width
            } else {
                currentLine.append(idx)
                currentLineWidth += additional
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }

        // 面板宽度 = 最长行的宽度 + padding
        let maxLineWidth = lines.map { line in
            line.reduce(CGFloat(0)) { $0 + cards[$1].width } + CGFloat(max(0, line.count - 1)) * cardSpacing
        }.max() ?? firstCardWidth
        let totalWidth = maxLineWidth + horizontalPadding

        // 面板高度 = 行数 * 最高卡片 + 行间距 + padding
        let lineHeight = cards.map { $0.height }.max() ?? cardHeight
        let rowCount = lines.count
        let rowSpacing = cardSpacing  // 行间距 = 卡片间距
        let totalHeight = lineHeight * CGFloat(rowCount) + CGFloat(max(0, rowCount - 1)) * rowSpacing + verticalPadding

        // 对齐：第一个卡片居中于 Dock 图标
        // 面板左边 = mouseX - firstCardWidth/2 - leftPadding
        let leftPadding: CGFloat = 2 * 2  // FlowLayout padding(2) * 2
        var xPos = mouseX - firstCardWidth / 2 - leftPadding
        // 左边界：不超出屏幕左边
        if xPos < screenMinX + 10 { xPos = screenMinX + 10 }
        // 右边界：不超出屏幕右边
        if xPos + totalWidth > screenMaxX - 10 {
            xPos = max(screenMinX + 10, screenMaxX - 10 - totalWidth)
        }

        // Dock 栏顶部 = 屏幕可用区域底部（visibleFrame.minY）
        // currentDockIconRect.maxY 是图标顶部，图标顶部到 Dock 栏顶部有 padding
        // 用 visibleFrame.minY 确保 dockOffset=0 时面板贴 Dock 栏顶部
        let dockTopY = dockScreen?.visibleFrame.minY ?? 0
        var yPos = dockTopY + dockOffset
        if yPos < 50 { yPos = 90 }

        let newFrame = CGRect(x: xPos, y: yPos, width: totalWidth, height: totalHeight)

        if animate {
            NSAnimationContext.runAnimationGroup({ context in
                // 提速：容器resize比之前0.38s快，减少等待感
                // 快速到位给卡片动画让路，避免卡片等待太久拖泥带水
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                self.panel?.animator().setFrame(newFrame, display: true)
            })
        } else {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            self.panel?.setFrame(newFrame, display: true, animate: false)
            NSAnimationContext.endGrouping()
        }
    }

    /// 计算面板尺寸并更新 frame（从当前 activeWindows 计算，count 指定显示数量）
    private func updatePanelFrame(for count: Int, mouseX: CGFloat, animate: Bool) {
        if count == 0 { hidePanel(); return }
        updatePanelFrame(for: Array(activeWindows.prefix(count)), mouseX: mouseX, animate: animate)
    }

    /// 用户调整尺寸/间距/列数时，若面板正在显示则即时重排
    private func relayoutPanelIfVisible() {
        guard isPanelVisible, !activeWindows.isEmpty else { return }
        updatePanelFrame(
            for: activeWindows.count,
            mouseX: currentDockIconRect.midX,
            animate: true
        )
    }

    // MARK: - 卡片交互

    func activateWindow(_ window: AppWindow) {
        // 先启动出场动画，再延迟激活窗口
        // 关键：用 CATransaction 驱动 layer.opacity（Core Animation 层级）
        // 不受 App 焦点切换影响，确保动画在窗口激活后仍能播放
        self.currentHoverPID = nil
        self.trackingTimer?.invalidate()
        self.trackingTimer = nil
        self.hideTimer?.cancel()
        self.hideTimer = nil

        let duration: CFTimeInterval = 0.28

        // 1. 立即启动 CATransaction layer opacity 动画（Core Animation 层级）
        //    即使后续窗口激活改变前台进程，此动画也不会被打断
        guard let contentView = self.panel?.contentView,
              let layer = contentView.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.opacity = 0
        CATransaction.commit()

        // 2. SwiftUI withAnimation 双轨（镜像入场：scale + offset + opacity）
        //    万一没被打断会更好；被打断也无所谓，layer.opacity 兜底
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            self.isPanelVisible = false
        }

        // 3. 延迟一小段时间（动画已开始播放）再激活窗口，避免激活打断动画起手
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                WindowController.activateWindow(pid: window.pid, title: window.title, windowID: window.id)
            }
        }

        // 4. 动画结束后清理状态
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.visibleWindowIDs.removeAll()
                self.activeWindows.removeAll()
                self.panel?.orderOut(nil)
                // 重置 layer opacity 供下次显示
                if let layer = self.panel?.contentView?.layer {
                    layer.opacity = 1.0
                }
                self.panel?.alphaValue = 1.0
            }
        }
    }

    func closeWindowAndAnimate(window: AppWindow) {
        WindowController.closeWindow(pid: window.pid, title: window.title, windowID: window.id)

        // 卡片淡出 + 面板缩小同时进行
        // FlowLayout 已左对齐（.frame(maxWidth: .infinity, alignment: .leading)），
        // 面板动画只缩小右侧，剩余卡片保持在左侧 Dock 图标居中位置，不会偏移
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            self.visibleWindowIDs.remove(window.id)
            self.activeWindows.removeAll { $0.id == window.id }
        }
        // 同步更新检测基准，避免 checkWindowCountChanged 误判窗口关闭
        lastCheckedWindowIDs.remove(window.id)
        updatePanelFrame(
            for: self.activeWindows.count,
            mouseX: self.currentDockIconRect.midX,
            animate: true
        )
    }

    func hidePanel() {
        self.currentHoverPID = nil
        self.trackingTimer?.invalidate()
        self.trackingTimer = nil
        self.hideTimer?.cancel()
        self.hideTimer = nil

        // 出场动画：SwiftUI withAnimation + NSWindow alphaValue 双轨
        // 1. SwiftUI withAnimation 驱动卡片/容器的 scale/offset/opacity（镜像入场）
        // 2. NSWindow alphaValue 驱动 HUD 材质背景淡出（SwiftUI 无法影响 NSVisualEffectView）
        // 两者同时进行，相同时长，视觉上统一收回
        let duration = 0.3

        // SwiftUI 视图动画：镜像入场（scale 1.0→0.99, offset 0→2, opacity 1→0）
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            self.isPanelVisible = false
        }

        // NSWindow alphaValue 动画：HUD 材质背景跟着淡出
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel?.animator().alphaValue = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.visibleWindowIDs.removeAll()
                self.activeWindows.removeAll()
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1.0  // 重置供下次显示
            }
        }
    }

    // MARK: - Panel 初始化

    /// 透明的 NSHostingView 子类
    /// 重写 isOpaque 返回 false，确保系统不绘制不透明矩形背景
    private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
        override var isOpaque: Bool { false }
        deinit {} // 避免编译器优化 deinit 时崩溃
    }

    /// 圆角 NSVisualEffectView 子类
    /// 关键：layer.cornerRadius 和 layer.mask 都不会裁切 NSVisualEffectView 的材质渲染
    /// 必须用 NSVisualEffectView 专用的 maskImage 属性裁切材质
    /// maskImage 用 image 的 alpha 通道作为 mask
    private final class RoundedVisualEffectView: NSVisualEffectView {
        private var lastBoundsSize: NSSize = .zero

        override func layout() {
            super.layout()
            // bounds 变化时重新创建 maskImage，确保圆角正确
            guard bounds.size != lastBoundsSize else { return }
            guard bounds.width > 0, bounds.height > 0 else { return }
            lastBoundsSize = bounds.size

            let radius: CGFloat = 16
            // 用当前 bounds 大小创建圆角矩形 maskImage
            // 黑色填充 = alpha=1 = 显示材质，透明 = alpha=0 = 隐藏材质
            let mask = NSImage(
                size: bounds.size,
                flipped: false
            ) { rect in
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                NSColor.black.set()
                return true
            }
            self.maskImage = mask
        }
    }

    private func setupPanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = false

        let hostingView = TransparentHostingView(rootView: ThumbnailContainerView(manager: self))
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        if useLiquidGlass, #available(macOS 26.0, *) {
            // 液态玻璃方案：SwiftUI .glassEffect() 处理背景和圆角
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
            hostingView.layer?.isOpaque = false
            p.contentView = hostingView
        } else {
            // 传统方案：NSVisualEffectView .hudWindow + maskImage 圆角裁切
            let containerView = RoundedVisualEffectView()
            containerView.material = .hudWindow
            containerView.blendingMode = .behindWindow
            containerView.state = .active
            containerView.wantsLayer = true
            containerView.layer?.cornerRadius = 16
            containerView.layer?.masksToBounds = true
            containerView.layer?.backgroundColor = .clear

            containerView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            ])

            p.contentView = containerView
            self.containerView = containerView
        }

        panel = p
    }

    /// 重建面板（切换液态玻璃开关时调用）
    private func rebuildPanel() {
        if panel != nil {
            visibleWindowIDs.removeAll()
            activeWindows.removeAll()
            isPanelVisible = false
            panel?.orderOut(nil)
            panel = nil
            containerView = nil
        }
        setupPanel()
    }
}

// MARK: - 数据模型

struct AppWindow: Identifiable, Equatable {
    let id: UInt32
    let pid: pid_t
    let title: String
    let image: NSImage
    let isMinimized: Bool
    /// 窗口宽高比（width / height）。用于自适应卡片尺寸：横窗口更宽，竖窗口更窄。
    let aspectRatio: CGFloat

    static func == (lhs: AppWindow, rhs: AppWindow) -> Bool { lhs.id == rhs.id }

    /// 根据图像实际尺寸与最大可用高度，计算实际图像尺寸。
    /// 高度统一为 maxHeight（所有卡片高度一致），宽度按图像实际宽高比自适应。
    /// 用图像实际尺寸算比例（而非 window.frame），避免截图与窗口 frame 比例不一致导致留白。
    /// 图像刚好填满 frame，无灰色留白
    func scaledImageSize(maxWidth: CGFloat, maxHeight: CGFloat) -> (width: CGFloat, height: CGFloat) {
        // 优先用图像实际尺寸算宽高比
        let imgW = image.size.width
        let imgH = image.size.height
        let ratio = (imgH > 0) ? (imgW / imgH) : aspectRatio
        guard ratio > 0 else { return (maxWidth, maxHeight) }
        // 高度始终统一为 maxHeight，宽度按宽高比自适应（不封顶，无留白）
        let width = maxHeight * ratio
        return (width, maxHeight)
    }

    /// 卡片宽度 = 图像宽度 + 动态 padding * 2
    func cardWidth(maxImageWidth: CGFloat, maxImageHeight: CGFloat, cardPadding: CGFloat) -> CGFloat {
        let img = scaledImageSize(maxWidth: maxImageWidth, maxHeight: maxImageHeight)
        return img.width + cardPadding * 2
    }

    /// 卡片高度 = 图像高度 + padding*2 + 标题栏(closeButtonSize+2) + vStackSpacing
    /// 标题栏跟随 closeButtonSize 变化，与 WindowCardView 对齐
    func cardHeight(maxImageWidth: CGFloat, maxImageHeight: CGFloat, closeButtonSize: CGFloat, cardPadding: CGFloat, vStackSpacing: CGFloat) -> CGFloat {
        let img = scaledImageSize(maxWidth: maxImageWidth, maxHeight: maxImageHeight)
        return img.height + cardPadding * 2 + vStackSpacing + closeButtonSize + 2
    }
}

// MARK: - 窗口操作（无障碍层 + SkyLight 私有 API）

enum WindowController {
    /// 激活指定窗口：先 activate 应用，再用 windowID 精确找到 AX 窗口并 raise
    ///
    /// 六步组合拳（参考 DockDoor WindowInfo.bringToFront，针对 accessory 模式增强）：
    /// 1. NSApp.activate(ignoringOtherApps:) 让 MagicStage 自己先获得前台权限
    ///    （accessory 应用直接调用 NSRunningApplication.activate 不会真正切换前台）
    /// 2. NSRunningApplication.activate(.activateIgnoringOtherApps) 唤醒目标进程
    /// 3. AXUIElementSetAttributeValue(kAXMinimizedAttribute, false) 解除最小化
    /// 4. **SkyLightBridge.bringWindowToFront(pid, windowID)** WindowServer 层级置顶
    ///    （关键新增：直接操作 WindowServer 合成层，解决 Chrome 被 QQ 遮挡等问题）
    /// 5. AXUIElementSetAttributeValue(kAXMainAttribute, true) 让窗口成为主窗口
    /// 6. AXUIElementPerformAction(kAXRaiseAction) 置顶目标窗口
    ///
    /// windowID 匹配优先（通过 _AXUIElementGetWindow），标题匹配作为降级
    static func activateWindow(pid: pid_t, title: String, windowID: UInt32) {
        #if DEBUG
        previewLog("[WindowPreview] activateWindow start: pid=\(pid), title=\(title), wid=\(windowID)")
        #endif

        // 如果应用被隐藏，先 unhide（不抢焦点，仅取消隐藏）
        // 参考 DockDoor bringToFront：不调用 NSApp.activate / NSRunningApplication.activate
        // 这两个调用会抢焦点或与 SLPS 冲突，导致窗口激活失败
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
            app.unhide()
        }

        // 参考 DockDoor bringToFront 的重试机制（3次，间隔50ms）
        let maxRetries = 3
        var retryCount = 0

        func attemptActivation() -> Bool {
            // Step 1+2+3: SkyLight 置前 + makeKeyWindow（核心步骤）
            // 直接操作 WindowServer 合成层，绕过应用层协商
            // 对 AX 树为空的应用（VS Code/网易云）也有效
            guard SkyLightBridge.bringWindowToFront(pid: pid, windowID: windowID) else {
                #if DEBUG
                previewLog("[WindowPreview] attempt \(retryCount + 1): SkyLight bringWindowToFront 失败")
                #endif
                return false
            }

            // Step 4+5: AX raise + setMain（顺序与 DockDoor 一致：先 raise 再 setMain）
            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsRef
            )

            guard axResult == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                #if DEBUG
                previewLog("[WindowPreview] attempt \(retryCount + 1): AX 树为空，SLPS 已执行")
                #endif
                return true  // AX 失败但 SLPS 成功，算成功
            }

            // 优先用 windowID 精确匹配 AX 窗口
            var matchedWindow: AXUIElement? = nil
            for window in windows {
                if let axWid = SkyLightBridge.getWindowID(from: window), axWid == windowID {
                    matchedWindow = window
                    break
                }
            }

            // 降级：windowID 匹配失败时用标题匹配
            if matchedWindow == nil {
                for window in windows {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    if isTitleMatch((titleRef as? String) ?? "", title) {
                        matchedWindow = window
                        break
                    }
                }
            }

            guard let window = matchedWindow else {
                #if DEBUG
                previewLog("[WindowPreview] attempt \(retryCount + 1): AX 未找到匹配窗口，SLPS 已执行")
                #endif
                return true  // AX 没找到但 SLPS 成功，算成功
            }

            // 顺序与 DockDoor 一致：先 raise，再 setMain
            let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let setMainResult = AXUIElementSetAttributeValue(
                window,
                kAXMainAttribute as CFString,
                true as CFTypeRef
            )
            #if DEBUG
            previewLog("[WindowPreview] attempt \(retryCount + 1): AX raise=\(raiseResult.rawValue) setMain=\(setMainResult.rawValue)")
            #endif
            return true
        }

        while retryCount < maxRetries {
            if attemptActivation() {
                #if DEBUG
                previewLog("[WindowPreview] activateWindow 成功 (attempt \(retryCount + 1))")
                #endif
                return
            }
            retryCount += 1
            if retryCount < maxRetries {
                // 50ms 间隔，与 DockDoor 一致
                // 用 RunLoop.run 替代 usleep，让主线程在等待期间继续处理动画事件
                // 避免阻塞导致面板淡出动画卡顿
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        #if DEBUG
        previewLog("[WindowPreview] activateWindow 失败，已重试 \(maxRetries) 次")
        #endif
    }

    /// 关闭指定窗口：模拟点击窗口的关闭按钮（保留原生未保存提示）
    /// 降级路径：AX → AppleScript Cmd+W
    ///
    /// windowID 匹配优先（通过 _AXUIElementGetWindow），标题匹配作为降级
    static func closeWindow(pid: pid_t, title: String, windowID: UInt32) {
        // 路径 1：AX 关闭按钮（适用于有 AX 树的应用）
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
           let windows = windowsRef as? [AXUIElement] {

            // 优先用 windowID 精确匹配
            for window in windows {
                if let axWid = SkyLightBridge.getWindowID(from: window), axWid == windowID {
                    if let closeBtn = getCloseButton(from: window) {
                        AXUIElementPerformAction(closeBtn, kAXPressAction as CFString)
                        return
                    }
                }
            }

            // 降级：标题匹配
            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                if isTitleMatch((titleRef as? String) ?? "", title) {
                    if let closeBtn = getCloseButton(from: window) {
                        AXUIElementPerformAction(closeBtn, kAXPressAction as CFString)
                        return
                    }
                }
            }
        }

        // 路径 2：AX 失败 → AppleScript 发送 Cmd+W（适用于无 AX 树的 Electron/自研 GUI 应用）
        // 先激活目标应用，再发送 Cmd+W 关闭最前窗口
        #if DEBUG
        previewLog("[WindowPreview] closeWindow AX 失败，降级到 AppleScript Cmd+W for pid=\(pid) wid=\(windowID)")
        #endif
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: .activateIgnoringOtherApps)
            // 短暂延迟让应用成为前台
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let script = """
                tell application "System Events"
                    keystroke "w" using command down
                end tell
                """
                if let appleScript = NSAppleScript(source: script) {
                    var errorInfo: NSDictionary?
                    appleScript.executeAndReturnError(&errorInfo)
                    if let error = errorInfo {
                        #if DEBUG
                        previewLog("[WindowPreview] AppleScript Cmd+W 失败: \(error)")
                        #endif
                    }
                }
            }
        }
    }

    /// 获取窗口的关闭按钮（类型安全封装）
    private static func getCloseButton(from window: AXUIElement) -> AXUIElement? {
        var closeBtnRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &closeBtnRef
        ) == .success,
        let btn = closeBtnRef,
        CFGetTypeID(btn) == AXUIElementGetTypeID() else { return nil }
        return (btn as! AXUIElement)
    }

    /// 创建占位图（截图失败时使用）
    /// 纯 Core Graphics 实现，线程安全，可在 TaskGroup 后台线程调用
    static func createPlaceholderImage(size: CGSize, title: String) -> CGImage {
        let scale: CGFloat = 2
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // 兜底：用 CGContext 创建 1x1 灰色图
            let fallbackCtx = CGContext(
                data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            fallbackCtx.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1))
            fallbackCtx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return fallbackCtx.makeImage()!
        }
        // 深灰色背景
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 中心绘制一个浅色矩形作为"窗口"图标占位
        let iconRect = CGRect(
            x: CGFloat(w) * 0.25,
            y: CGFloat(h) * 0.3,
            width: CGFloat(w) * 0.5,
            height: CGFloat(h) * 0.4
        )
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.32, alpha: 1))
        context.fill(iconRect)
        return context.makeImage()!
    }

    /// 标题模糊匹配：忽略大小写与空白，相互包含即视为匹配
    static func isTitleMatch(_ axTitle: String, _ scTitle: String) -> Bool {
        if axTitle == scTitle || (axTitle.isEmpty && scTitle.isEmpty) { return true }
        let axClean = axTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let scClean = scTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return axClean == scClean || axClean.contains(scClean) || scClean.contains(axClean)
    }
}
