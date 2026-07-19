import Foundation
import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Combine
import QuartzCore

// MARK: - 布局配置

struct LayoutConfig {
    var shortcut: KeyboardShortcut
    var enabled: Bool
}

// MARK: - Toggle 快照（保存精确 appliedFrame，避免坐标转换精度问题）

private struct LayoutSnapshot {
    let originalFrame: CGRect
    let appliedTargetFrame: CGRect
}

@MainActor
final class WindowManagementService: ObservableObject {
    // MARK: Published 属性

    @Published var recordingLayout: WindowLayout? = nil
    @Published var accessibilityGranted = false

    /// 所有布局的配置（快捷键 + 启用状态）
    @Published private(set) var layoutConfigs: [WindowLayout: LayoutConfig] = [:]

    // MARK: 私有属性

    private var activationObserver: Any?
    private var terminationObserver: Any?
    private var isHotKeysActive = false
    private var lastTargetProcessIdentifier: pid_t?
    /// Toggle 恢复快照：[窗口身份: [布局: LayoutSnapshot]]
    /// 通过保存 appliedTargetFrame 避免每次重新计算 targetFrame 带来的浮点/坐标转换误差
    private var snapshot: [WindowIdentity: [WindowLayout: LayoutSnapshot]] = [:]
    private var animTargets: [WindowIdentity: (window: AXUIElement, state: AnimationState, originalFrame: CGRect)] = [:]

    init() {
        initializeLayouts()
        loadAllConfigs()
        observeApplicationActivation()
        // 监听 overlay 拖拽恢复通知（TitleBarDragOverlay 松手时发送）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOverlayRestore(_:)),
            name: .init("MagicStageWindowRestored"),
            object: nil
        )
    }

    deinit {
        // deinit 中访问 @MainActor 属性在 Swift 6 下需要 MainActor.assumeIsolated
        // NSWorkspace.notificationCenter.removeObserver 是线程安全的，可以在任何线程调用
        MainActor.assumeIsolated {
            if let observer = activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            if let observer = terminationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }
    }

    // MARK: - 初始化 & 生命周期

    private func initializeLayouts() {
        for layout in WindowLayout.allCases {
            layoutConfigs[layout] = LayoutConfig(shortcut: layout.defaultShortcut, enabled: true)
        }
    }

    func activateHotKeys() {
        guard !isHotKeysActive else { return }
        isHotKeysActive = true
        checkAccessibility()
        setupHotKeyHandlers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAccessibility),
            name: .hotkeyTapAvailabilityChanged,
            object: nil
        )
    }

    @objc private func refreshAccessibility() {
        checkAccessibility()
    }

    /// 与其他权限依赖服务一起刷新，保证设置页状态和实际 TCC 状态同步。
    func refreshForAccessibilityChange() {
        checkAccessibility()
    }

    func deactivateHotKeys() {
        isHotKeysActive = false
    }

    private func setupHotKeyHandlers() {
        for layout in WindowLayout.allCases {
            let featureID = FeatureID.windowLayout(layout)
            ShortcutRegistry.shared.setHandler({ [weak self] in
                self?.performLayout(layout)
            }, for: featureID)
        }
        reloadRegistryMappings()
    }

    private func reloadRegistryMappings() {
        for (layout, config) in layoutConfigs {
            let featureID = FeatureID.windowLayout(layout)
            if config.enabled, config.shortcut.keyCode != 0 || config.shortcut.modifierFlags != 0 {
                _ = ShortcutRegistry.shared.register(config.shortcut, for: featureID)
            } else {
                ShortcutRegistry.shared.unregister(featureID)
            }
        }

        // App 退出时清掉它的恢复帧
        // 先移除旧 observer，避免重复注册
        if let old = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(old)
            terminationObserver = nil
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.clearRestoreFrames(for: app.processIdentifier)
            }
        }
    }

    private func checkAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: false]
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 窗口布局执行

    func performLayout(_ layout: WindowLayout) {
        guard let pid = currentTargetPID(),
              let window = focusedWindow(forPID: pid),
              let currentFrame = getWindowFrame(window) else { return }
        let windowIdentity = WindowIdentity(window: window)
        let screen = screenFor(window: window) ?? NSScreen.main
        guard let screen else { return }

        let axVisibleFrame = axFrame(from: screen.visibleFrame)
        let currentSize = getWindowSize(window) ?? CGSize(width: 800, height: 600)
        let targetFrame = layout.targetFrame(screenAXFrame: axVisibleFrame, currentSize: currentSize)

        // 连续触发布局时保留本轮动画开始前的原始 frame，不能把动画中间帧
        // 当作恢复点，否则快速切换布局后无法回到真正的原始位置。
        let originalFrame = animTargets[windowIdentity]?.originalFrame ?? currentFrame
        animTargets[windowIdentity]?.state.cancelled = true
        animTargets[windowIdentity] = nil

        // Toggle 检查：用保存的 appliedTargetFrame 对比，而非重新计算（消除浮点误差）
        if let entry = snapshot[windowIdentity]?[layout],
           currentFrame.isClose(to: entry.appliedTargetFrame, tolerance: 12) {
            // 窗口在已应用的目标位置 → 恢复到原始大小
            snapshot[windowIdentity]?[layout] = nil
            DragSplitService.shared.clearSnappedFrame(for: window)
            animate(window: window, from: currentFrame, to: entry.originalFrame,
                    identity: windowIdentity, originalFrame: entry.originalFrame)
        } else {
            // 应用布局：同时保存原始帧 + 将要应用的目标帧
            let entry = LayoutSnapshot(originalFrame: originalFrame, appliedTargetFrame: targetFrame)
            if snapshot[windowIdentity] == nil { snapshot[windowIdentity] = [:] }
            snapshot[windowIdentity]?[layout] = entry
            DragSplitService.shared.registerSnappedFrame(
                for: window,
                originalFrame: originalFrame,
                snappedFrame: targetFrame
            )
            animate(window: window, from: currentFrame, to: targetFrame,
                    identity: windowIdentity, originalFrame: originalFrame)
        }
    }

    // MARK: - 窗口动画

    private func animate(window: AXUIElement, from startFrame: CGRect, to endFrame: CGRect,
                         identity: WindowIdentity, originalFrame: CGRect) {
        // 只取消同一窗口的旧动画，不影响同应用的其他窗口。
        animTargets[identity]?.state.cancelled = true
        animTargets[identity] = nil

        guard !startFrame.isClose(to: endFrame, tolerance: 1) else {
            setWindowFrame(window, frame: endFrame)
            return
        }

        let duration: TimeInterval = 0.20
        let startTime = CACurrentMediaTime()
        let state = AnimationState()
        animTargets[identity] = (window, state, originalFrame)

        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        let interval = 1.0 / Double(max(fps, 60))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !state.cancelled else {
                    timer.invalidate()
                    return
                }
                let progress = min((CACurrentMediaTime() - startTime) / duration, 1.0)
                let eased = 1.0 - pow(1.0 - progress, 2)
                let frame = startFrame.interpolated(to: endFrame, progress: eased).pixelAligned
                self.setWindowFrame(window, frame: frame)
                if progress >= 1.0 {
                    timer.invalidate()
                    self.animTargets[identity] = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - AX 辅助

    /// 获取当前目标 PID（前台 App 或上次记录的）
    private func currentTargetPID() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ownPID {
            lastTargetProcessIdentifier = app.processIdentifier
            return app.processIdentifier
        }
        return lastTargetProcessIdentifier
    }

    /// 获取指定 PID 的聚焦/主/第一个窗口
    private func focusedWindow(forPID pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?

        // 1) focused
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let win = ref, CFGetTypeID(win) == AXUIElementGetTypeID() {
            return (win as! AXUIElement)  // 已通过 CFGetTypeID 验证类型
        }
        // 2) main
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success,
           let win = ref, CFGetTypeID(win) == AXUIElementGetTypeID() {
            return (win as! AXUIElement)
        }
        // 3) first in list
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
           let windows = list as? [AXUIElement],
           let first = windows.first { return first }
        return nil
    }

    private func screenFor(window: AXUIElement) -> NSScreen? {
        guard let position = getWindowPosition(window),
              let size = getWindowSize(window) else { return NSScreen.main }
        let windowFrame = CGRect(origin: position, size: size)
        return NSScreen.screens.max { lhs, rhs in
            lhs.axIntersectionArea(with: windowFrame, primaryScreenMaxY: primaryScreenMaxY)
                < rhs.axIntersectionArea(with: windowFrame, primaryScreenMaxY: primaryScreenMaxY)
        }
    }


    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) {
        // 优先 SkyLight 路径（解决 Electron/CEF 应用 frame 设置失效问题）
        if SkyLightBridge.setWindowFrame(window, frame: frame) { return }
        // 降级到 AX 路径
        instantAXMove(window, position: frame.origin, size: frame.size)
    }

    private func instantAXMove(_ window: AXUIElement, position: CGPoint, size: CGSize) {
        var pos = position
        var sz  = size
        if let axPos = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axPos)
        }
        if let axSize = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize)
        }
    }

    private func axFrame(from appKitFrame: CGRect) -> CGRect {
        let maxY = primaryScreenMaxY
        return CGRect(
            x: appKitFrame.origin.x,
            y: maxY - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    private var primaryScreenMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    private func observeApplicationActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let activatedPID = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 分屏恢复只属于一次连续操作。切离应用（包括切到 MagicStage）后，
                // 不能在用户回来很久后再突然把窗口改回旧尺寸。
                if let previousPID = self.lastTargetProcessIdentifier,
                   previousPID != activatedPID {
                    self.clearRestoreFrames(for: previousPID)
                }
                self.lastTargetProcessIdentifier = activatedPID == ProcessInfo.processInfo.processIdentifier
                    ? nil
                    : activatedPID
            }
        }


    }

    @objc private func handleOverlayRestore(_ notification: Notification) {
        guard let pid = notification.userInfo?["pid"] as? pid_t else { return }
        if let token = notification.userInfo?["windowToken"] as? UInt64 {
            let identity = WindowIdentity(pid: pid, token: token)
            snapshot.removeValue(forKey: identity)
        } else {
            clearRestoreFrames(for: pid)
        }
    }

    private func clearRestoreFrames(for pid: pid_t) {
        snapshot.keys.filter { $0.pid == pid }.forEach { snapshot.removeValue(forKey: $0) }
        animTargets.keys.filter { $0.pid == pid }.forEach {
            animTargets[$0]?.state.cancelled = true
            animTargets.removeValue(forKey: $0)
        }
        DragSplitService.shared.clearSnappedFrames(for: pid)
    }

    // MARK: - AX 辅助方法

    // focusedWindow, currentTargetPID, screenFor 替代了旧的窗口查找方法

    private func getWindowSize(_ window: AXUIElement) -> CGSize? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &val) == .success,
              let axVal = val, CFGetTypeID(axVal) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axVal as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func getWindowPosition(_ window: AXUIElement) -> CGPoint? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &val) == .success,
              let axVal = val, CFGetTypeID(axVal) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axVal as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func getWindowFrame(_ window: AXUIElement) -> CGRect? {
        guard let position = getWindowPosition(window),
              let size = getWindowSize(window) else { return nil }
        return CGRect(origin: position, size: size)
    }


    // MARK: - 快捷键录制

    var isRecording: Bool { recordingLayout != nil }

    func recordShortcut(for layout: WindowLayout) {
        recordingLayout = layout
        HotkeyManager.shared.startRecording(for: .windowLayout(layout)) { [weak self] shortcut in
            guard let self else { return }
            guard let layout = self.recordingLayout else { return }
            if shortcut.keyCode != 0 || shortcut.modifierFlags != 0 {
                self.setShortcut(shortcut, for: layout)
                self.setEnabled(true, for: layout)
            }
            self.recordingLayout = nil
            self.saveAllConfigs()
        }
    }

    func cancelShortcutRecording() {
        recordingLayout = nil
        HotkeyManager.shared.cancelRecording()
    }

    func clearShortcut(for layout: WindowLayout) {
        setShortcut(KeyboardShortcut.empty, for: layout)
        saveAllConfigs()
    }

    // MARK: - 配置读写

    func setShortcut(_ shortcut: KeyboardShortcut, for layout: WindowLayout) {
        layoutConfigs[layout]?.shortcut = shortcut
        let featureID = FeatureID.windowLayout(layout)
        if shortcut.keyCode != 0 || shortcut.modifierFlags != 0 {
            _ = ShortcutRegistry.shared.register(shortcut, for: featureID)
        } else {
            ShortcutRegistry.shared.unregister(featureID)
        }
        notifyConfigChanged()
    }

    func setEnabled(_ enabled: Bool, for layout: WindowLayout) {
        layoutConfigs[layout]?.enabled = enabled
        let featureID = FeatureID.windowLayout(layout)
        if enabled, let config = layoutConfigs[layout],
           config.shortcut.keyCode != 0 || config.shortcut.modifierFlags != 0 {
            _ = ShortcutRegistry.shared.register(config.shortcut, for: featureID)
        } else {
            ShortcutRegistry.shared.unregister(featureID)
        }
        notifyConfigChanged()
    }

    func saveEnabledState() {
        saveAllConfigs()
    }

    private func notifyConfigChanged() {
        let copy = layoutConfigs
        layoutConfigs = copy
    }

    // MARK: - 持久化

    private func saveAllConfigs() {
        let d = UserDefaults.standard
        for (layout, config) in layoutConfigs {
            let key = persistenceKey(for: layout)
            if let data = try? JSONEncoder().encode(config) {
                d.set(data, forKey: key)
            }
        }
    }

    private func loadAllConfigs() {
        let d = UserDefaults.standard
        for layout in WindowLayout.allCases {
            let key = persistenceKey(for: layout)
            if let data = d.data(forKey: key),
               let config = try? JSONDecoder().decode(LayoutConfig.self, from: data) {
                layoutConfigs[layout] = config
            }
        }
        migrateOldShortcuts()
    }

    private func migrateOldShortcuts() {
        let d = UserDefaults.standard
        let migratedMaximize = d.bool(forKey: "migrated_to_layouts_v2")
        guard !migratedMaximize else { return }

        var didMigrate = false
        if let data = d.data(forKey: "maximizeShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            layoutConfigs[.maximize]?.shortcut = shortcut
            didMigrate = true
        }
        if let data = d.data(forKey: "centerShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            layoutConfigs[.center]?.shortcut = shortcut
            didMigrate = true
        }
        if d.object(forKey: "maximizeEnabled") != nil {
            layoutConfigs[.maximize]?.enabled = d.bool(forKey: "maximizeEnabled")
            didMigrate = true
        }
        if d.object(forKey: "centerEnabled") != nil {
            layoutConfigs[.center]?.enabled = d.bool(forKey: "centerEnabled")
            didMigrate = true
        }

        if didMigrate {
            saveAllConfigs()
        }
        d.set(true, forKey: "migrated_to_layouts_v2")
    }

    private func persistenceKey(for layout: WindowLayout) -> String {
        "layout_\(layout.rawValue)"
    }

    // MARK: - 内部类型

    private final class AnimationState {
        var cancelled = false
    }
}

// MARK: - LayoutConfig Codable

extension LayoutConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case shortcut, enabled
    }
}

// MARK: - NSScreen 扩展

private extension NSScreen {
    func axIntersectionArea(with windowFrame: CGRect, primaryScreenMaxY: CGFloat) -> CGFloat {
        let axScreenFrame = CGRect(
            x: frame.origin.x,
            y: primaryScreenMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let intersection = axScreenFrame.intersection(windowFrame)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

// MARK: - CGRect 扩展

private extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }

    func interpolated(to other: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + (other.origin.x - origin.x) * progress,
            y: origin.y + (other.origin.y - origin.y) * progress,
            width: size.width + (other.size.width - size.width) * progress,
            height: size.height + (other.size.height - size.height) * progress
        )
    }

    var pixelAligned: CGRect {
        CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: size.width.rounded(),
            height: size.height.rounded()
        )
    }
}
