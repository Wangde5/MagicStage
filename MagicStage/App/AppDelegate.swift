import AppKit
import SwiftUI
import Sparkle
import ApplicationServices.HIServices.AXActionConstants
import ApplicationServices.HIServices.AXAttributeConstants
import ApplicationServices.HIServices.AXError
import ApplicationServices.HIServices.AXRoleConstants
import ApplicationServices.HIServices.AXUIElement
import ApplicationServices.HIServices.AXValue

#if DEBUG
private func toggleLog(_ message: @autoclosure () -> String) { print(message()) }
#else
private func toggleLog(_ message: @autoclosure () -> String) {}
#endif

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var preferencesWindow: NSWindow?
    var lastActiveApp: NSRunningApplication?
    let hotkeyManager = HotkeyManager.shared
    let windowService = WindowManagementService()
    private let accessibilityPermission = AccessibilityPermissionCoordinator.shared

    /// Sparkle 更新控制器
    private var updaterController: SPUStandardUpdaterController?
    // MARK: - Dock 点击检测

    /// CGEvent tap：只监听 leftMouseUp，始终放行事件
    private var dockMouseTap: CFMachPort?
    private var dockMouseTapSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 确保以常规应用模式运行，以便显示权限对话框
        NSApp.setActivationPolicy(.regular)

        // 服务会在初始化时读取这些值，因此默认值必须先于单例初始化注册。
        UserDefaults.standard.register(defaults: [
            "enableExcludeKey": true,
            "excludeKeyType": 0,
            "enableHaptic": true,
            "launchAtLogin": false,
            "enableHotkeyAll": true,
            "enableHotkeyOthers": true,
            "enableDockToggleKeyWindow": false,
            "dragSplitRestoreEnabled": true
        ])

        // 初始化拖拽分屏服务
        _ = DragSplitService.shared

        // 初始化移动窗口服务
        _ = MoveWindowService.shared

        // 初始化窗口预览服务
        _ = WindowPreviewService.shared

        // 初始化文件抽屉服务
        _ = FileDrawerService.shared

        // 延迟初始化 Sparkle，确保 App 完全启动后再检查更新，避免与自动更新冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: UpdaterService.shared,
                userDriverDelegate: nil
            )
            if let updater = self?.updaterController?.updater {
                UpdaterService.shared.configure(with: updater)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidDeactivate(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityAvailabilityChanged),
            name: .hotkeyTapAvailabilityChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityAvailabilityChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityAvailabilityChanged),
            name: .accessibilityPermissionDidChange,
            object: nil
        )
        

        // 先启动快捷键监听（不需要辅助功能权限）
        hotkeyManager.startListening()

        // 从 UserDefaults 加载快捷键到 ShortcutRegistry 并绑定 handler
        setupShortcutRegistry()

        // 冲突检测回调
        hotkeyManager.onConflict = { conflict, shortcut, featureID, userDecision in
            DispatchQueue.main.async {
                self.showConflictAlert(conflict: conflict, shortcut: shortcut,
                                       feature: featureID, userDecision: userDecision)
            }
        }

        // 激活应用到前台。首次安装时随后显示应用内引导；系统权限页仅由用户点击打开。
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissionDependentServices(retryCount: 0)
        windowService.activateHotKeys()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.accessibilityPermission.presentOnboardingIfNeeded()
        }
    }

    /// 用户在系统设置中首次授予辅助功能权限后，恢复所有依赖事件 Tap 的服务。
    /// 权限状态在 TCC 中传播可能有延迟，因此进行有限次数重试。
    @objc private func accessibilityAvailabilityChanged() {
        refreshPermissionDependentServices(retryCount: 0)
    }

    private func refreshPermissionDependentServices(retryCount: Int) {
        let isGranted = accessibilityPermission.refresh()
        DragSplitService.shared.refreshForAccessibilityChange()
        MoveWindowService.shared.refreshForAccessibilityChange()
        WindowPreviewService.shared.refreshForAccessibilityChange()
        FileDrawerService.shared.refreshForAccessibilityChange()
        windowService.refreshForAccessibilityChange()
        hotkeyManager.refreshForAccessibilityChange()

        if isGranted {
            if dockMouseTap == nil { startDockClickMonitoring() }
            return
        }

        stopDockClickMonitoring()

        // TCC 在“返回应用”后的传播有延迟。持续一小段时间重试，确保授权后无需重启、
        // 无需手动关开功能开关。
        guard retryCount < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshPermissionDependentServices(retryCount: retryCount + 1)
        }
    }

    // MARK: - 快捷键注册表初始化

    private func setupShortcutRegistry() {
        let registry = ShortcutRegistry.shared

        // 注册 handler（功能行为，永不改变）
        registry.setHandler({ [weak self] in self?.executeMinimize(mode: .all) },
                            for: .minimizeAll)
        registry.setHandler({ [weak self] in self?.executeMinimize(mode: .others) },
                            for: .minimizeOthers)
        registry.setHandler({ DockHoverQuitService.shared.handleShortcutPressed() },
                            for: .dockQuit)
        registry.setHandler({ FileDrawerService.shared.toggle() },
                            for: .fileDrawer)
        // moveWindow 不需要 handler：MoveWindowService 通过自己的鼠标 CGEvent tap 工作

        // 从 UserDefaults 加载已保存的快捷键映射
        _ = hotkeyManager.loadShortcut(for: .minimizeAll)
        _ = hotkeyManager.loadShortcut(for: .minimizeOthers)
        _ = hotkeyManager.loadShortcut(for: .dockQuit)
        _ = hotkeyManager.loadShortcut(for: .moveWindow)
        if hotkeyManager.loadShortcut(for: .fileDrawer) == nil {
            let defaultDrawerShortcut = KeyboardShortcut(
                keyCode: 49,
                modifiers: [.control, .option]
            )
            if registry.findConflict(for: defaultDrawerShortcut, excluding: .fileDrawer) == nil {
                hotkeyManager.restoreShortcut(defaultDrawerShortcut, for: .fileDrawer)
            }
        }
    }

    // MARK: - 冲突对话框

    private func showConflictAlert(conflict: ShortcutConflict, shortcut: KeyboardShortcut,
                                    feature: FeatureID, userDecision: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "快捷键冲突"
        alert.informativeText = conflict.alertMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")

        guard let window = preferencesWindow else {
            userDecision(false)
            return
        }

        alert.beginSheetModal(for: window) { response in
            userDecision(response == .alertFirstButtonReturn)
        }
    }

    // MARK: - Dock 点击 → 最小化所有窗口

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 如果设置窗口开着，不做最小化
        guard preferencesWindow == nil || !preferencesWindow!.isVisible else {
            preferencesWindow?.makeKeyAndOrderFront(nil)
            return true
        }
        performMinimizeTask()
        return true
    }

    @objc func appDidDeactivate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.lastActiveApp = app
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let prefItem = NSMenuItem(title: "偏好设置", action: #selector(openPreferences), keyEquivalent: ",")
        prefItem.target = self
        menu.addItem(prefItem)
        return menu
    }

    @objc private func toggleFileDrawer() {
        FileDrawerService.shared.toggle()
    }

    // MARK: - 最小化任务（Dock 点击触发）

    @objc func performMinimizeTask() {
        let mode: MinimizeMode = isExcludeKeyPressed() ? .others : .all
        executeMinimize(mode: mode)
    }

    func executeMinimize(mode: MinimizeMode) {
        let currentFront = NSWorkspace.shared.frontmostApplication
        let targetApp = (currentFront?.bundleIdentifier == Bundle.main.bundleIdentifier) ? lastActiveApp : currentFront

        minimizeAllWindowsSmart(excludeActive: mode == .others, activeApp: targetApp, mode: mode)

        if mode == .others, let appToRestore = targetApp {
            appToRestore.activate()
        }

        if UserDefaults.standard.bool(forKey: "enableHaptic") {
            triggerSmartHapticFeedback(mode: mode)
        }
    }

    private func isExcludeKeyPressed() -> Bool {
        guard UserDefaults.standard.bool(forKey: "enableExcludeKey") else { return false }
        let keyType = UserDefaults.standard.integer(forKey: "excludeKeyType")
        switch keyType {
        case 0: return CGEventSource.keyState(.hidSystemState, key: 63)           // fn
        case 1: return CGEventSource.keyState(.hidSystemState, key: 56)           // shift
                || CGEventSource.keyState(.hidSystemState, key: 60)
        default: return false
        }
    }

    enum MinimizeMode { case all, others }

    private func minimizeAllWindowsSmart(excludeActive: Bool, activeApp: NSRunningApplication?, mode: MinimizeMode) {
        let workspace = NSWorkspace.shared
        let currentApp = NSRunningApplication.current
        let apps = workspace.runningApplications.filter { $0.activationPolicy == .regular && $0 != currentApp }

        let group = DispatchGroup()
        for app in apps {
            if excludeActive && app == activeApp { continue }
            let pid = app.processIdentifier
            DispatchQueue.global(qos: .userInteractive).async(group: group) {
                // 用 timeout 包裹 AX 调用，防止卡死应用导致 group.notify 永不执行
                // 超时后任务"完成"，group.notify 仍会触发 Finder 激活
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    self.minimizeAppWindowsAX(app: app, pid: pid)
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 3.0)
            }
        }

        group.notify(queue: .main) {
            if mode == .all {
                let finderApps = workspace.runningApplications.filter { $0.bundleIdentifier == "com.apple.finder" }
                if let finder = finderApps.first {
                    finder.activate()
                }
            }
        }
    }

    /// 单个应用的 AX 最小化逻辑（从 minimizeAllWindowsSmart 提取）
    /// 包含 AX 路径 + AppleScript 降级路径
    private func minimizeAppWindowsAX(app: NSRunningApplication, pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowList: AnyObject?
        var hasMinimizableWindow = false
        var hasUnminimizedWindow = false

        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
           let windows = windowList as? [AXUIElement] {
            for window in windows {
                var isMinimized: AnyObject?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimized) == .success,
                   let minimizedNum = isMinimized as? NSNumber,
                   minimizedNum.boolValue == true { continue }
                hasUnminimizedWindow = true

                var isSettable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &isSettable) == .success,
                   isSettable.boolValue {
                    hasMinimizableWindow = true
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }
        }

        if hasUnminimizedWindow && !hasMinimizableWindow {
            DispatchQueue.main.async {
                if let bundleID = app.bundleIdentifier {
                    let script = NSAppleScript(source: "tell application id \"\(bundleID)\" to miniaturize every window")
                    var error: NSDictionary?
                    let result = script?.executeAndReturnError(&error)
                    if result == nil || error != nil {
                        // 绝不降级为模拟 ⌘M：窗口可能已经全部最小化，额外按键会触发系统警报音。
                        toggleLog("[Minimize] AppleScript 最小化失败，跳过键盘模拟: \(bundleID)")
                    }
                } else {
                    app.hide()
                }
            }
        }
    }

    // MARK: - 仅切换焦点窗口（最小化 ↔ 恢复）

    /// Dock 图标点击切换窗口。只监听 leftMouseUp，始终放行事件。
    /// 核心技巧：最小化前台窗口后，将鼠标事件坐标瞬移到 (0,0)，让 Dock 以为用户拖走了鼠标，
    /// 从而取消恢复行为，避免窗口被弹回。
    private func startDockClickMonitoring() {
        stopDockClickMonitoring()
        guard AXIsProcessTrusted() else { return }

        let eventMask = (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = delegate.dockMouseTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                delegate.handleDockMouseUp(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        dockMouseTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        dockMouseTapSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopDockClickMonitoring() {
        if let source = dockMouseTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            dockMouseTapSource = nil
        }
        if let tap = dockMouseTap {
            CFMachPortInvalidate(tap)
            dockMouseTap = nil
        }
    }

    /// 处理 Dock 区域的 leftMouseUp 事件。
    /// 严格按 import SwiftUI.md 方案：只在点击前台 App 的 Dock 图标时拦截，
    /// 后台线程最小化 + 立即瞬移鼠标到 (0,0)，绝不在事件回调中阻塞。
    private func handleDockMouseUp(_ event: CGEvent) {
        guard UserDefaults.standard.bool(forKey: "enableDockToggleKeyWindow") else { return }

        let point = event.location

        // 0. 快速区域判断：不在 Dock 区域则直接放行，避免 AX 查询干扰其他应用
        guard isInDockArea(point) else { return }

        // 1. 检查是否为前台应用（先于 AX 查询，避免不必要的开销）
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        // 2. 检查点击的元素是否属于 Dock 进程
        let systemWide = AXUIElementCreateSystemWide()
        // 设置 0.5s 超时，防止卡死应用阻塞事件回调（坑 12）
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var clickedElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &clickedElement) == .success,
              let element = clickedElement else { return }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let dockApp = NSRunningApplication(processIdentifier: pid),
              dockApp.bundleIdentifier == "com.apple.dock" else {
            return // 不是 Dock 上的点击，放行
        }

        // 3. 获取被点击的 Dock 项标题
        guard let dockItemTitle = getDockItemTitle(from: element) else { return }

        let appName = frontmostApp.localizedName ?? ""
        let bundleName = frontmostApp.bundleURL?.deletingPathExtension().lastPathComponent ?? ""

        guard dockItemTitle == appName || dockItemTitle == bundleName || dockItemTitle.hasPrefix(appName) else {
            return // 点击的不是前台应用，放行
        }

        // 4. 检查是否有可见窗口需要最小化
        let frontPid = frontmostApp.processIdentifier
        guard SkyLightBridge.hasVisibleWindows(pid: frontPid) else { return }

        toggleLog("[Toggle] 🎯 最小化前台 App: \(appName)")

        // 5. 后台线程执行最小化，绝不阻塞事件回调
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.hideAppWindow(for: frontmostApp)
        }

        // 6. 瞬移鼠标到 (0,0)，让 Dock 以为用户拖走了鼠标，取消恢复行为
        event.location = CGPoint(x: 0, y: 0)
    }

    /// 从 AXUIElement 向上查找 Dock 项标题（最多 5 层）
    private func getDockItemTitle(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let cur = current else { break }

            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role) == .success,
               let roleStr = role as? String, roleStr == "AXDockItem" {
                var title: CFTypeRef?
                if AXUIElementCopyAttributeValue(cur, kAXTitleAttribute as CFString, &title) == .success,
                   let name = title as? String, !name.isEmpty {
                    return name
                }
            }

            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent)
            if let parent = parent, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                current = (parent as! AXUIElement)
            } else { break }
        }
        return nil
    }

    /// 判断坐标是否在 Dock 区域（无 AX 查询，纯坐标系计算）
    private func isInDockArea(_ point: CGPoint) -> Bool {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let bounds = CGDisplayBounds(displayID)

            guard point.x >= bounds.minX, point.x < bounds.maxX,
                  point.y >= bounds.minY, point.y < bounds.maxY else { continue }

            let visible = ScreenCoordinates.quartzFrame(
                fromCocoa: screen.visibleFrame,
                primaryScreenMaxY: primaryMaxY
            )

            // Dock 所占区域就是显示器 frame 与 visibleFrame 之间缺失的边条。
            if visible.maxY < bounds.maxY, point.y >= visible.maxY { return true }
            if visible.minX > bounds.minX, point.x <= visible.minX { return true }
            if visible.maxX < bounds.maxX, point.x >= visible.maxX { return true }
        }
        return false
    }

    /// 隐藏 App 当前活跃窗口（点击前台 App 时调用）。
    /// 主路径：CGWindowList + SLSOrderWindow（WindowServer 层，对所有应用有效）
    /// 降级1：AX 最小化（对标准 AppKit 应用有效）
    /// 降级2：AppleScript（对 Electron 等支持脚本的应用有效）
    private func hideAppWindow(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "?"
        
        // 主路径：CGWindowList + SLSOrderWindow
        let count = SkyLightBridge.minimizeWindows(pid: pid)
        if count > 0 {
            toggleLog("[Toggle] SkyLight order-out \(count) 个窗口 for \(appName)")
            return
        }
        
        // 降级1：AX 最小化
        toggleLog("[Toggle] SkyLight 降级为 AX 最小化 for \(appName)")
        let axApp = AXUIElementCreateApplication(pid)
        if tryMinimizeViaAX(app: app, axApp: axApp) {
            return
        }
        
        // 降级2：AppleScript（Electron 等应用 AX 不可写时使用）
        toggleLog("[Toggle] AX 也失败，尝试 AppleScript for \(appName)")
        if let bundleID = app.bundleIdentifier {
            let script = NSAppleScript(source: "tell application id \"\(bundleID)\" to miniaturize every window")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if error == nil {
                toggleLog("[Toggle] ✅ AppleScript 最小化成功 for \(appName)")
                return
            }
            toggleLog("[Toggle] ❌ AppleScript 失败 for \(appName): \(error?.description ?? "?")")
        }
        
        toggleLog("[Toggle] ❌ 所有路径均失败 for \(appName)")
    }

    /// 尝试通过 AX API 最小化窗口，返回是否成功
    private func tryMinimizeViaAX(app: NSRunningApplication, axApp: AXUIElement) -> Bool {
        let targetWindow = findTargetWindow(in: axApp)
        
        if let window = targetWindow {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success,
               settable.boolValue {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                return true
            }
        }
        
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
           let windows = list as? [AXUIElement] {
            for w in windows {
                var isMinimized: CFTypeRef?
                let isMin = (AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &isMinimized) == .success)
                            && (isMinimized as? NSNumber)?.boolValue == true
                if isMin { continue }
                
                var settable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(w, kAXMinimizedAttribute as CFString, &settable) == .success,
                   settable.boolValue {
                    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    return true
                }
            }
        }
        
        return false
    }

    /// 在给定 App 的 AX 树中定位"该操作的窗口"，优先级：
    /// 1. kAXMainWindowAttribute（后台 App 也能拿到）
    /// 2. kAXFocusedWindowAttribute
    /// 3. 窗口列表里第一个未最小化的窗口；若全已最小化则返回第一个（用于恢复）
    private func findTargetWindow(in axApp: AXUIElement) -> AXUIElement? {
        func isDesktopWindow(_ window: AXUIElement) -> Bool {
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success {
                if let titleStr = title as? String, titleStr.isEmpty {
                    return true
                }
            }
            return false
        }

        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &main) == .success,
           let mainRef = main, CFGetTypeID(mainRef) == AXUIElementGetTypeID() {
            let mainWin = mainRef as! AXUIElement
            if !isDesktopWindow(mainWin) { return mainWin }
        }
        
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focusedRef = focused, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let focusedWin = focusedRef as! AXUIElement
            if !isDesktopWindow(focusedWin) { return focusedWin }
        }
        
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
              let windows = list as? [AXUIElement] else { return nil }
        var firstMinimized: AXUIElement?
        for w in windows {
            guard !isDesktopWindow(w) else { continue }
            var minVal: CFTypeRef?
            let isMin = (AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minVal) == .success)
                        && (minVal as? NSNumber)?.boolValue == true
            if isMin {
                if firstMinimized == nil { firstMinimized = w }
                continue
            }
            return w
        }
        return firstMinimized
    }

    

    private func triggerSmartHapticFeedback(mode: MinimizeMode) {
        let performer = NSHapticFeedbackManager.defaultPerformer
        let baseDelay = 0.10

        if mode == .all {
            let steps: [(NSHapticFeedbackManager.FeedbackPattern, Double)] = [
                (.generic, 0.0),
                (.generic, 0.08),
                (.alignment, 0.16),
                (.alignment, 0.24),
                (.levelChange, 0.38)
            ]
            for step in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay + step.1) {
                    performer.perform(step.0, performanceTime: .now)
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay) {
                performer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    // MARK: - 偏好设置窗口

    /// 将窗口居中后下移，避免过于接近菜单栏
    private func positionWindowLower(_ window: NSWindow) {
        var frame = window.frame
        frame.origin.y -= UIConfig.Window.centerYOffset
        window.setFrame(frame, display: false)
    }

    @objc func openPreferences() {
        // 如果窗口已存在，复用
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            window.center()
            positionWindowLower(window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UIConfig.Window.width, height: UIConfig.Window.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MagicStage 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = ContentView()
            .environmentObject(windowService)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])

        self.preferencesWindow = window
        window.center()
        positionWindowLower(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == preferencesWindow {
            preferencesWindow = nil
            if let appToRestore = lastActiveApp {
                appToRestore.activate()
            }
        }
    }

    func checkAccessibilityPermission() -> Bool {
        accessibilityPermission.showStatusPanel()
        return accessibilityPermission.isGranted
    }
}
