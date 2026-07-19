import AppKit
import ApplicationServices
import Combine

#if DEBUG
private func moveLog(_ message: @autoclosure () -> String) { print(message()) }
#else
private func moveLog(_ message: @autoclosure () -> String) {}
#endif

// MARK: - 拖拽移动窗口
// 按住修饰键（默认 ⌘⌃）→ 在窗口任意位置左键拖拽 → 移动窗口
// 使用 CGEvent tap 拦截+消费事件，命中时 return nil 吃掉，窗口内容不会响应
//
// 重要：此功能必须使用修饰键（⌘/⌃/⌥/⇧），不能使用普通按键（如 Tab/空格等）。
// 原因：CGEvent tap 通过鼠标事件中的 modifierFlags 判断是否匹配快捷键，
// 如果 requiredFlags 为空（modifiers=0），tap 会拦截所有鼠标事件，导致系统卡死。

final class MoveWindowService: ObservableObject {
    static let shared = MoveWindowService()

    private static let shortcutKey = "shortcut_move_window"
    private static let defaultMods: UInt = 0x00100000 | 0x00040000
    static let defaultShortcut = KeyboardShortcut(
        keyCode: .max,
        modifiers: [.command, .control]
    )

    @Published var isEnabled = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "moveWindowEnabled")
            if isEnabled { start() } else { stop() }
        }
    }

    // 存储的是 NSEvent.ModifierFlags 格式，但基础修饰键位和 CGEventFlags 一致
    private var requiredFlags: CGEventFlags {
        let dict = UserDefaults.standard.dictionary(forKey: Self.shortcutKey)
        guard let keyCode = dict?["keyCode"] as? Int, keyCode == Int(UInt16.max),
              let raw = dict?["modifiers"] as? UInt else {
            return CGEventFlags(rawValue: UInt64(Self.defaultMods))
        }
        return CGEventFlags(rawValue: UInt64(raw))
            .intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate])
    }

    /// 判断当前快捷键是否有效（至少含一个修饰键）
    private var hasValidModifiers: Bool {
        requiredFlags.rawValue != 0
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    private var isDragging = false
    private var dragWindow: AXUIElement?
    private var startMouse: CGPoint = .zero    // Cocoa
    private var startWindow: CGPoint = .zero   // Cocoa

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.shortcutKey)
        let savedShortcut: KeyboardShortcut? = {
            guard let code = saved?["keyCode"] as? Int,
                  let mods = saved?["modifiers"] as? UInt,
                  code >= 0, code <= Int(UInt16.max) else { return nil }
            return KeyboardShortcut(keyCode: UInt16(code),
                                    modifiers: NSEvent.ModifierFlags(rawValue: mods))
        }()
        if savedShortcut?.isModifierOnlyShortcut != true {
            UserDefaults.standard.set(
                ["keyCode": Int(UInt16.max), "modifiers": Self.defaultShortcut.modifierFlags],
                forKey: Self.shortcutKey
            )
        }
        isEnabled = UserDefaults.standard.bool(forKey: "moveWindowEnabled")
        if isEnabled {
            start()
        }
    }

    // MARK: - 启停

    private func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            moveLog("[MoveWindow] ❌ 无辅助功能权限")
            return
        }

        // 安全保护：快捷键必须包含至少一个修饰键（⌘/⌃/⌥/⇧）
        // 如果 requiredFlags 为空，tap 会拦截所有鼠标事件，导致系统卡死
        guard hasValidModifiers else {
            moveLog("[MoveWindow] ❌ 快捷键不含修饰键，拒绝启动（防止拦截所有鼠标事件）")
            // 清理损坏的快捷键配置，恢复默认值
            UserDefaults.standard.removeObject(forKey: Self.shortcutKey)
            DispatchQueue.main.async { [weak self] in
                self?.isEnabled = false
                let alert = NSAlert()
                alert.messageText = "移动窗口快捷键无效"
                alert.informativeText = "移动窗口功能必须使用修饰键（⌘/⌃/⌥/⇧），不能使用 Tab、空格等普通按键。\n\n快捷键已恢复为默认值 ⌘⌃，请重新设置。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }

        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.leftMouseDragged.rawValue)
                              | (1 << CGEventType.leftMouseUp.rawValue)

        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // 非 listenOnly，可以 return nil 消费事件
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let svc = Unmanaged<MoveWindowService>.fromOpaque(refcon).takeUnretainedValue()
                // 系统在回调超时或用户输入切换时会禁用 CGEvent tap；若不立即重启，
                // 设置开关仍是开启状态但移动窗口会永久失效直到用户手动重开。
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = svc.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return svc.handleTap(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let t = tap else {
            moveLog("[MoveWindow] ❌ CGEvent.tapCreate 失败")
            return
        }
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        moveLog("[MoveWindow] ✅ 已启动 flags=\(requiredFlags.rawValue)")
    }

    private func stop() {
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); tapSource = nil }
        if let t = tap { CFMachPortInvalidate(t); tap = nil }
        isDragging = false
        dragWindow = nil
        moveLog("[MoveWindow] 🛑 已停止")
    }

    /// 权限变化时重建或移除事件 Tap，同时保留用户设置的开关状态。
    func refreshForAccessibilityChange() {
        if AXIsProcessTrusted() {
            if isEnabled { start() }
        } else {
            stop()
        }
    }

    // MARK: - Tap 回调（唯一事件源：移动窗口 + 热区检测 + 分屏吸附）

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        let current = event.flags.intersection(modMask)

        if current != requiredFlags {
            if isDragging {
                DispatchQueue.main.async { DragSplitService.shared.handleExternalDragEnd(cocoaPt: .zero) }
                cancelDrag()
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            beginDrag(event: event)
            guard isDragging else { return Unmanaged.passUnretained(event) }
            // 吞掉按下事件：全程用 AX 控制窗口位置，不让系统启动自己的拖拽
            // 手动激活目标 App（因为事件被吞，系统不会自动激活）
            if let win = dragWindow {
                var pid: pid_t = 0
                AXUIElementGetPid(win, &pid)
                if pid != 0 {
                    DispatchQueue.main.async {
                        NSRunningApplication(processIdentifier: pid)?.activate()
                    }
                }
            }
            return nil

        case .leftMouseDragged:
            guard isDragging, let win = dragWindow else { return Unmanaged.passUnretained(event) }
            moveDrag(event: event)

            // 始终路由给 DragSplitService，由其状态机决定是否显示灵动岛/展开面板。
            // 不能在这里按热区截断，否则光标从顶部热区移入较小的灵动岛时会提前关闭面板。
            let quartz = event.location
            let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            let cocoa = ScreenCoordinates.cocoaPoint(fromQuartz: quartz, primaryScreenMaxY: primaryMaxY)
            if let screen = screenContaining(cocoa) {
                DispatchQueue.main.async {
                    DragSplitService.shared.handleExternalDrag(cocoaPt: cocoa, screen: screen, targetWindow: win)
                }
            } else {
                DispatchQueue.main.async { DragSplitService.shared.handleExternalDragExit() }
            }

            return nil  // 消费事件 → 窗口内容锁住

        case .leftMouseUp:
            let wasDragging = isDragging
            if wasDragging {
                // 与 leftMouseDragged 保持一致：@MainActor 调用需切到主线程
                // 不能在 CGEvent tap 回调中同步调用 @MainActor 方法
                DispatchQueue.main.async {
                    DragSplitService.shared.handleExternalDragEnd(cocoaPt: .zero)
                }
            }
            endDrag()
            // leftMouseDown 已被消费，系统未启动拖拽，放行 leftMouseUp 保持鼠标状态一致
            // 避免"系统结算过期拖拽"导致的窗口闪跳
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - 拖拽

    private func beginDrag(event: CGEvent) {
        let quartzMouse = event.location

        guard let win = windowUnder(quartzPoint: quartzMouse) else {
            moveLog("[MoveWindow] ⚠️ 未找到窗口")
            return
        }

        var pos = CGPoint.zero
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &ref) == .success,
              let v = ref,
              CFGetTypeID(v) == AXValueGetTypeID(),
              AXValueGetValue(v as! AXValue, .cgPoint, &pos) else {
            moveLog("[MoveWindow] ⚠️ AXPosition 获取失败")
            return
        }

        // 存 Quartz 原始坐标，moveDrag 里直接用 Quartz delta
        startMouse = quartzMouse
        startWindow = pos
        dragWindow = win
        // 如果之前被 DragSplit 分屏吸附过，先恢复原始大小，再更新 startWindow
        DragSplitService.shared.tryRestoreSnappedWindow(win)
        var newPos = CGPoint.zero
        if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &ref) == .success,
           let v2 = ref,
           CFGetTypeID(v2) == AXValueGetTypeID(),
           AXValueGetValue(v2 as! AXValue, .cgPoint, &newPos) {
            startWindow = newPos
        }
        isDragging = true
        moveLog("[MoveWindow] 🟢 拖拽开始 pos=\(pos)")
    }

    private func moveDrag(event: CGEvent) {
        guard let win = dragWindow else { return }
        let quartzMouse = event.location

        let deltaX = quartzMouse.x - startMouse.x
        let deltaY = quartzMouse.y - startMouse.y

        var newPos = CGPoint(
            x: startWindow.x + deltaX,
            y: startWindow.y + deltaY
        )
        // 优先 SkyLight 路径（解决 Electron/CEF 应用位置设置失效问题）
        if !SkyLightBridge.setWindowPosition(win, position: newPos) {
            guard let val = AXValueCreate(.cgPoint, &newPos) else {
                moveLog("[MoveWindow] ⚠️ AXValueCreate 失败，取消拖拽")
                cancelDrag()
                return
            }
            let result = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, val)
            if result != .success {
                moveLog("[MoveWindow] ⚠️ AX 设置位置失败 err=\(result.rawValue)，取消拖拽")
                cancelDrag()
                return
            }
        }
    }

    private func endDrag() {
        isDragging = false
        dragWindow = nil
        moveLog("[MoveWindow] 🔴 拖拽结束")
    }

    private func cancelDrag() {
        isDragging = false
        dragWindow = nil
    }

    // MARK: - 窗口定位

    /// CGWindowList → z-order 最上层 → pid → AX window frame 匹配
    /// - quartzPoint: Quartz 坐标（左上原点），用于 CGWindowList bounds 和 AX frame 匹配
    private func windowUnder(quartzPoint: CGPoint) -> AXUIElement? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int32, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"] else { continue }
            let cgRect = CGRect(x: x, y: y, width: w, height: h)
            guard cgRect.contains(quartzPoint) else { continue }   // CGWindowList bounds = Quartz

            let axApp = AXUIElementCreateApplication(pid)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
                  let axWindows = windows as? [AXUIElement] else { continue }

            for axWin in axWindows {
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

                if CGRect(origin: pos, size: size).contains(quartzPoint) {   // AX frame 与 Quartz 同坐标系（左上原点 Y↓）
                    moveLog("[MoveWindow] 🔍 找到窗口 pid=\(pid)")
                    return axWin
                }
            }
        }
        return nil
    }

    // MARK: - 辅助：热区与屏幕检测

    private func screenContaining(_ pt: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSPoint(x: pt.x, y: pt.y), $0.frame, false) }
    }

}
