import SwiftUI
import ApplicationServices

// C风格回调：只监听鼠标抬起，玩一个“移花接木”的魔法
func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    
    // 防超时保护
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = delegate.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    
    // 我们只在鼠标“抬起”的瞬间介入，保证“按下”时的系统动画完美触发
    if type == .leftMouseUp {
        delegate.handleMouseUp(event)
    }
    
    return Unmanaged.passUnretained(event)
}

@main
struct dockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() } // 隐藏多余主窗口
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var runLoopSource: CFRunLoopSource?
    var eventTap: CFMachPort?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 纯后台模式
        if checkAccessibilityPermissions() {
            setupEventTap()
        }
    }
    
    func setupEventTap() {
        // 【关键改动】：现在我们只监听 leftMouseUp (鼠标抬起)，不干扰任何鼠标按下和移动，极大提升系统流畅度
        let eventMask = (1 << CGEventType.leftMouseUp.rawValue)
        
        eventTap = CGEvent.tapCreate(tap: .cghidEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: CGEventMask(eventMask),
                                     callback: eventTapCallback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())
        
        guard let tap = eventTap else {
            print("未能创建事件拦截，请确认是否【删除了App Sandbox】并【赋予了无障碍权限】！")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    func handleMouseUp(_ cgEvent: CGEvent) {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }
        
        let point = cgEvent.location
        let systemWideElement = AXUIElementCreateSystemWide()
        var clickedElement: AXUIElement?
        
        if AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &clickedElement) != .success { return }
        guard let element = clickedElement else { return }
        
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let clickedApp = NSRunningApplication(processIdentifier: pid),
              clickedApp.bundleIdentifier == "com.apple.dock" else {
            return
        }
        
        guard let clickedTitle = getDockItemTitle(from: element) else { return }
        
        let appName = activeApp.localizedName ?? ""
        let bundleName = activeApp.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
        
        if clickedTitle == appName || clickedTitle == bundleName || clickedTitle.hasPrefix(appName) {
            
            // 找到该软件最前面且尚未最小化的窗口
            if let windowToMinimize = getFirstUnminimizedWindow(of: activeApp) {
                
                // 1. 在后台线程执行最小化，绝不卡死鼠标
                DispatchQueue.global(qos: .userInitiated).async {
                    AXUIElementSetAttributeValue(windowToMinimize, kAXMinimizedAttribute as CFString, true as CFBoolean)
                }
                
                // 2. 【核心魔法】：把这次鼠标抬起的坐标，瞬间瞬移到屏幕左上角 (0, 0)
                // 这样 Dock 就会以为：“用户点了我，但是把鼠标拖到屏幕外面才松手，我要取消这次点击，并恢复图标的高亮动画！”
                // 完美实现了：有视觉动画反馈 + 窗口成功最小化 + 系统不会再自动把窗口弹出来！
                cgEvent.location = CGPoint(x: 0, y: 0)
            }
        }
    }
    
    func getFirstUnminimizedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            
            for window in windows {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
                if let role = roleRef as? String, role != kAXWindowRole { continue }
                
                var isMinimizedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimizedRef) == .success,
                   let isMinimized = isMinimizedRef as? Bool, isMinimized {
                    continue
                }
                return window
            }
        }
        return nil
    }
    
    func getDockItemTitle(from element: AXUIElement) -> String? {
        var currentElement = element
        for _ in 0..<5 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXDockItem" {
                
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(currentElement, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String, !title.isEmpty {
                    return title
                }
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef {
                currentElement = parent as! AXUIElement
            } else { break }
        }
        return nil
    }
    
    func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        
        if !isTrusted {
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = "请在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许本软件。\n（注意：如果之前允许过，由于重写逻辑，请先点【-】号删除旧的，再重新添加运行！）"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "我知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
        return isTrusted
    }
}