# Dock 点击隐藏/恢复窗口功能实现

## 1. 设置开关定义

```swift
// consts.swift

// 功能总开关（默认关闭）
static let shouldHideOnDockItemClick = Key<Bool>("shouldHideOnDockItemClick", default: false)

// 点击行为：隐藏应用 或 最小化窗口
static let dockClickAction = Key<DockClickAction>("dockClickAction", default: .hide)

// 是否恢复所有最小化窗口
static let restoreAllMinimizedWindowsOnDockClick = Key<Bool>("restoreAllMinimizedWindowsOnDockClick", default: true)

// 点击行为枚举
enum DockClickAction: String, CaseIterable, Defaults.Serializable {
    case minimize  // 最小化窗口
    case hide      // 隐藏应用
    
    var localizedName: String {
        switch self {
        case .minimize:
            String(localized: "Minimize windows")
        case .hide:
            String(localized: "Hide application")
        }
    }
}
```

## 2. 状态变量（hover 阶段缓存）

```swift
// DockObserver.swift

// Dock 点击行为状态
var currentClickedAppPID: pid_t?
var lastHoveredPID: pid_t?                      // 悬停应用的 PID
var lastHoveredAppWasFrontmost: Bool = false    // 悬停时是否在最前
var lastHoveredAppNeedsRestore: Bool = false    // 是否有最小化窗口或被隐藏
var lastHoveredAppHadWindows: Bool = false      // 是否有窗口
```

## 3. Hover 阶段状态缓存

```swift
// DockObserver.swift - processSelectedDockItemChanged() 中

// 当鼠标悬停在 Dock 图标上时，缓存应用状态
lastHoveredPID = currentApp.processIdentifier
lastHoveredAppWasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == currentApp.processIdentifier
lastHoveredAppNeedsRestore = currentApp.isHidden || cachedWindows.contains(where: \.isMinimized)
lastHoveredAppHadWindows = !cachedWindows.isEmpty
```

## 4. CGEvent Tap 设置

```swift
// DockObserver.swift - setupEventTap()

private func setupEventTap() {
    var eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue)
    
    if Defaults[.enableDockScrollGesture] || Defaults[.enableTitleBarScrollGesture] {
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
    }
    
    guard let eventTap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .tailAppendEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let observer = Unmanaged<DockObserver>.fromOpaque(refcon).takeUnretainedValue()
            return observer.eventTapCallback(proxy: proxy, type: type, event: event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
        print("Failed to create event tap")
        return
    }
    
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    
    self.eventTap = eventTap
    eventTapRunLoopSource = runLoopSource
}
```

## 5. 事件回调处理

```swift
// DockObserver.swift - eventTapCallback()

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if let passthrough = reEnableIfNeeded(tap: eventTap, type: type, event: event) {
        return passthrough
    }
    
    // 滚轮事件处理（省略）
    if type == .scrollWheel {
        // ... 省略滚轮处理逻辑
        return Unmanaged.passUnretained(event)
    }
    
    let appUnderMouse = getDockItemAppStatusUnderMouse()
    
    if case let .success(app) = appUnderMouse.status {
        // Cmd + 右键：退出应用
        if type == .rightMouseDown, event.flags.contains(.maskCommand), Defaults[.enableCmdRightClickQuit] {
            handleCmdRightClickQuit(app: app, event: event)
            return nil
        }
        
        // Shift + 左键：打开新窗口
        if type == .leftMouseDown, event.flags.contains(.maskShift),
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            handleShiftClickNewWindow(app: app)
            return nil
        }
        
        // 普通左键点击：隐藏/恢复窗口
        if type == .leftMouseDown, !previewCoordinator.mouseIsWithinPreviewWindow {
            let shouldIntercept = handleDockClick(app: app)
            if shouldIntercept {
                return nil
            }
        }
    }
    
    // 始终放行事件，保证 Dock 图标点击反馈正常
    return Unmanaged.passUnretained(event)
}
```

## 6. 核心逻辑：handleDockClick

```swift
// DockObserver.swift

private func handleDockClick(app: NSRunningApplication) -> Bool {
    let pid = app.processIdentifier
    let appName = app.localizedName ?? "Unknown"
    
    // 跳过 DockDoor 自身，防止崩溃
    if app.bundleIdentifier == Bundle.main.bundleIdentifier {
        return false
    }
    
    currentClickedAppPID = pid
    
    let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let hasValidHoverState = lastHoveredPID == pid
    let wasFrontmostOnHover = hasValidHoverState ? lastHoveredAppWasFrontmost : isFrontmost
    
    // 检查功能开关
    guard Defaults[.shouldHideOnDockItemClick] else { return false }
    
    // 如果是简单激活（应用不在最前且不需要恢复），交给系统原生行为
    if hasValidHoverState, !lastHoveredAppWasFrontmost, !lastHoveredAppNeedsRestore {
        lastHoveredPID = nil
        return false
    }
    
    // 如果 hover 时应用没有窗口，交给系统原生行为
    // 防止最小化新创建的窗口
    if hasValidHoverState, !lastHoveredAppHadWindows, !app.isHidden {
        lastHoveredPID = nil
        return false
    }
    
    // 如果没有 hover 状态，通过 AX 查询检查窗口是否最小化
    var hasMinimizedWindowsAtClickTime = false
    var hadAnyWindowsAtClickTime = true
    if !hasValidHoverState {
        let axApp = AXUIElementCreateApplication(pid)
        if let windowList = try? axApp.windows() {
            hadAnyWindowsAtClickTime = !windowList.isEmpty
            for window in windowList {
                if (try? window.isMinimized()) == true {
                    hasMinimizedWindowsAtClickTime = true
                    break
                }
            }
        } else {
            hadAnyWindowsAtClickTime = false
        }
    }
    
    // 从 hover 状态或 AX 查询捕获恢复需求
    let restorationNeededFromHover = hasValidHoverState && lastHoveredAppNeedsRestore
    let restorationNeededAtClickTime = restorationNeededFromHover || hasMinimizedWindowsAtClickTime || app.isHidden
    
    // 清除 hover 状态，取消预览窗口显示
    lastHoveredPID = nil
    previewCoordinator.cancelPendingShow()
    
    // 延迟 0.15 秒执行，让系统原生点击处理先完成
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self else { return }
        
        previewCoordinator.hideWindow()
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            if !hadAnyWindowsAtClickTime {
                return
            }
            
            // 获取应用的所有窗口
            let windows = try await WindowUtil.getActiveWindows(of: app, ignoreSingleWindowFilter: true)
            let currentlyHasMinimizedWindows = windows.contains(where: \.isMinimized)
            
            // 使用点击时捕获的状态判断意图
            // 防止系统 Dock 原生恢复行为干扰逻辑
            let needsRestore = restorationNeededAtClickTime || currentlyHasMinimizedWindows
            
            if needsRestore, Defaults[.restoreAllMinimizedWindowsOnDockClick] {
                DebugLogger.log("DockClick", details: "\(appName): restoring (needsRestore=true, minimized=\(currentlyHasMinimizedWindows))")
                restoreAppWindows(windows: windows, app: app, appName: appName)
            } else if wasFrontmostOnHover, !windows.isEmpty {
                DebugLogger.log("DockClick", details: "\(appName): hiding (wasFrontmost=true, windows=\(windows.count))")
                hideAppWindows(windows: windows, app: app, appName: appName)
            }
        }
    }
    
    // 始终返回 false，放行事件
    return false
}
```

## 7. 隐藏窗口实现

```swift
// DockObserver.swift

private func hideAppWindows(windows: [WindowInfo], app: NSRunningApplication, appName: String) {
    let windowsToMinimize = windows.filter { !$0.isMinimized }
    guard !windowsToMinimize.isEmpty else { return }
    
    if Defaults[.dockClickAction] == .hide {
        // 隐藏模式：直接隐藏整个应用
        DispatchQueue.main.async {
            app.hide()
        }
    } else {
        // 最小化模式：逐个最小化窗口
        WindowUtil.minimizeWindowsAsync(windowsToMinimize)
    }
}
```

## 8. 恢复窗口实现

```swift
// DockObserver.swift

private func restoreAppWindows(windows: [WindowInfo], app: NSRunningApplication, appName: String) {
    let windowsToRestore = windows.filter(\.isMinimized)
    guard !windowsToRestore.isEmpty || app.isHidden else { return }
    
    if Defaults[.dockClickAction] == .hide {
        // 隐藏模式：激活应用
        app.activate()
    } else {
        // 最小化模式：逐个恢复最小化窗口，然后激活
        for window in windowsToRestore {
            var mutableWindow = window
            _ = mutableWindow.toggleMinimize()
        }
        app.activate()
    }
}
```

## 核心设计原则

1. **Hover 阶段预缓存状态**：所有 AX 查询在鼠标悬停时完成，click 时直接读内存变量，零开销
2. **事件始终放行**：`handleDockClick` 始终返回 false，不吞事件，保证 Dock 图标点击反馈正常
3. **延迟异步执行**：通过 `asyncAfter(0.15)` 延迟执行，让系统原生点击处理先完成，避免冲突
4. **状态判断代替防抖**：用 hover 时缓存的 `wasFrontmostOnHover` 和 `needsRestore` 区分隐藏/恢复意图，天然互斥
5. **局部变量保护**：异步块使用局部变量而非实例变量，避免状态被提前清除

## 关键时序

```
鼠标悬停 Dock 图标
    ↓
processSelectedDockItemChanged 缓存状态
    ↓
用户点击 Dock 图标
    ↓
CGEvent tap 拦截 leftMouseDown
    ↓
handleDockClick 读取缓存状态到局部变量
    ↓
清除实例状态，返回 false 放行事件
    ↓
延迟 0.15 秒
    ↓
异步获取窗口列表，根据局部变量判断意图
    ↓
┌─ 需要恢复 → restoreAppWindows
└─ 需要隐藏 → hideAppWindows
```
