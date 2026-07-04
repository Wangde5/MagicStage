import Foundation
import AppKit
import ApplicationServices

// MARK: - SkyLight 私有框架桥接

/// 通过 SkyLight 私有框架直接操作 WindowServer 合成层，
/// 绕开应用层协商，解决 Electron/CEF 应用（VS Code、网易云等）窗口操作失效问题。
enum SkyLightBridge {

    // MARK: - 调试开关

    static var verboseLogging = true

    // MARK: - 函数指针类型

    private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
    private typealias SLSOrderWindowFunc = @convention(c) (Int32, UInt32, Int32, UInt32) -> CGError
    private typealias SLSGetWindowListFunc = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32) -> Int32
    private typealias SLSGetWindowOwnerFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> CGError
    private typealias SLSSetWindowBoundsFunc = @convention(c) (Int32, UInt32, CGRect) -> CGError
    private typealias SLSGetWindowBoundsFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
    private typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    // MARK: - SkyLight 框架句柄

    private static let slsHandle: UnsafeMutableRawPointer? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else {
            let err = String(cString: dlerror())
            print("[SLS] ❌ dlopen(SkyLight.framework) 失败: \(err)")
            return nil
        }
        print("[SLS] ✅ dlopen(SkyLight.framework) 成功 handle=\(String(describing: handle))")
        return handle
    }()

    // MARK: - 已加载的函数指针

    private static let slsConnection: Int32 = {
        guard let handle = slsHandle,
              let sym = dlsym(handle, "SLSMainConnectionID") else {
            print("[SLS] ❌ SLSMainConnectionID dlsym 返回 NULL")
            return -1
        }
        let fn = unsafeBitCast(sym, to: SLSMainConnectionIDFunc.self)
        let cid = fn()
        print("[SLS] 🔗 SLSMainConnectionID = \(cid)")
        return cid
    }()

    private static let orderWindow: SLSOrderWindowFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSOrderWindow") {
            print("[SLS] ✅ dlsym(SLSOrderWindow)")
            return unsafeBitCast(sym, to: SLSOrderWindowFunc.self)
        }
        print("[SLS] ❌ dlsym(SLSOrderWindow) → NULL")
        return nil
    }()

    private static let getWindowList: SLSGetWindowListFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSGetWindowList") {
            print("[SLS] ✅ dlsym(SLSGetWindowList)")
            return unsafeBitCast(sym, to: SLSGetWindowListFunc.self)
        }
        print("[SLS] ❌ dlsym(SLSGetWindowList) → NULL")
        return nil
    }()

    private static let getWindowOwner: SLSGetWindowOwnerFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSGetWindowOwner") {
            print("[SLS] ✅ dlsym(SLSGetWindowOwner)")
            return unsafeBitCast(sym, to: SLSGetWindowOwnerFunc.self)
        }
        print("[SLS] ❌ dlsym(SLSGetWindowOwner) → NULL")
        return nil
    }()

    private static let setBounds: SLSSetWindowBoundsFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSSetWindowBounds") {
            print("[SLS] ✅ dlsym(SLSSetWindowBounds)")
            return unsafeBitCast(sym, to: SLSSetWindowBoundsFunc.self)
        }
        print("[SLS] ⚠️ dlsym(SLSSetWindowBounds) → NULL")
        if let sym = dlsym(handle, "SLSWindowSetBounds") {
            print("[SLS] ✅ dlsym(SLSWindowSetBounds)")
            return unsafeBitCast(sym, to: SLSSetWindowBoundsFunc.self)
        }
        return nil
    }()

    private static let getBounds: SLSGetWindowBoundsFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSGetWindowBounds") {
            return unsafeBitCast(sym, to: SLSGetWindowBoundsFunc.self)
        }
        if let sym = dlsym(handle, "SLSWindowGetBounds") {
            return unsafeBitCast(sym, to: SLSGetWindowBoundsFunc.self)
        }
        return nil
    }()

    private static let axGetWindow: AXUIElementGetWindowFunc? = {
        guard let globalHandle = dlopen(nil, RTLD_NOW) else { return nil }
        if let sym = dlsym(globalHandle, "_AXUIElementGetWindow") {
            return unsafeBitCast(sym, to: AXUIElementGetWindowFunc.self)
        }
        return nil
    }()

    // MARK: - 可用性标志

    /// SLSOrderWindow 最小化路径是否可用
    static let orderWindowAvailable: Bool = {
        guard slsHandle != nil else { return false }
        guard slsConnection != -1 else { return false }
        guard orderWindow != nil else { return false }
        print("[SLS] ✅ orderWindow 最小化路径可用 (cid=\(slsConnection))")
        return true
    }()

    /// SkyLight frame 设置路径是否可用
    static let isAvailable: Bool = {
        guard slsHandle != nil else { return false }
        guard slsConnection != -1 else { return false }
        guard setBounds != nil else { return false }
        guard axGetWindow != nil else { return false }
        return true
    }()

    // MARK: - 坐标转换

    private static var primaryScreenMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    private static func axToCG(_ frame: CGRect) -> CGRect {
        let maxY = primaryScreenMaxY
        return CGRect(
            x: frame.origin.x,
            y: maxY - frame.origin.y - frame.size.height,
            width: frame.size.width,
            height: frame.size.height
        )
    }

    private static func cgToAX(_ frame: CGRect) -> CGRect {
        let maxY = primaryScreenMaxY
        return CGRect(
            x: frame.origin.x,
            y: maxY - frame.origin.y - frame.size.height,
            width: frame.size.width,
            height: frame.size.height
        )
    }

    // MARK: - CGWindowList 枚举 + SLSOrderWindow 最小化（主路径）

    /// 使用 CGWindowList 枚举目标 App 的所有正常层级窗口，
    /// 通过 SLSOrderWindow 将其 order out（等同于最小化）。
    /// 返回成功最小化的窗口数量。
    @discardableResult
    static func minimizeWindows(pid: pid_t) -> Int {
        guard orderWindowAvailable, let orderFn = orderWindow else {
            print("[SLS] ⚠️ minimizeWindows: SLSOrderWindow 不可用，回退 AX")
            return 0
        }

        let windowIDs = getNormalWindowIDs(pid: pid, onScreenOnly: true)
        guard !windowIDs.isEmpty else {
            print("[SLS] ⚠️ minimizeWindows: pid=\(pid) 无正常层级窗口")
            return 0
        }

        // 缓存窗口 ID，供 restore 使用
        minimizedWindowCache[pid] = windowIDs

        var count = 0
        for wid in windowIDs {
            let result = orderFn(slsConnection, wid, 0, 0) // mode=0 = order out
            if result == .success {
                if verboseLogging { print("[SLS] ✅ SLSOrderWindow(OUT) wid=\(wid)") }
                count += 1
            } else {
                print("[SLS] ❌ SLSOrderWindow(OUT) wid=\(wid) CGError=\(result.rawValue)")
            }
        }
        return count
    }

    /// 将之前 order out 的窗口重新 order in（恢复显示）。
    /// 优先使用缓存的窗口 ID（minimize 时记录），否则查询所有窗口（含 off-screen）
    /// 返回成功恢复的窗口数量。
    @discardableResult
    static func restoreWindows(pid: pid_t) -> Int {
        guard orderWindowAvailable, let orderFn = orderWindow else {
            print("[SLS] ⚠️ restoreWindows: SLSOrderWindow 不可用")
            return 0
        }

        // 优先使用缓存，否则查询所有窗口（含 off-screen，因为 order out 后不再 on-screen）
        let windowIDs: [UInt32]
        if let cached = minimizedWindowCache[pid], !cached.isEmpty {
            windowIDs = cached
            minimizedWindowCache[pid] = nil
            print("[SLS] 🔄 restoreWindows: 使用缓存 \(windowIDs.count) 个窗口 ID")
        } else {
            windowIDs = getNormalWindowIDs(pid: pid, onScreenOnly: false)
        }
        guard !windowIDs.isEmpty else {
            print("[SLS] ⚠️ restoreWindows: pid=\(pid) 无正常层级窗口")
            return 0
        }

        var count = 0
        for wid in windowIDs {
            let result = orderFn(slsConnection, wid, 1, 0) // mode=1 = order above
            if result == .success {
                if verboseLogging { print("[SLS] ✅ SLSOrderWindow(IN) wid=\(wid)") }
                count += 1
            } else {
                print("[SLS] ❌ SLSOrderWindow(IN) wid=\(wid) CGError=\(result.rawValue)")
            }
        }
        return count
    }

    /// 通过 CGWindowListCopyWindowInfo 获取指定 PID 的所有正常层级窗口 ID
    /// - Parameters:
    ///   - pid: 目标进程 PID
    ///   - onScreenOnly: true=仅屏幕可见窗口（用于最小化），false=所有窗口含 off-screen（用于恢复）
    private static func getNormalWindowIDs(pid: pid_t, onScreenOnly: Bool = true) -> [UInt32] {
        let option: CGWindowListOption = onScreenOnly ? .optionOnScreenOnly : .optionAll
        guard let winInfo = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            print("[SLS] 🔍 getNormalWindowIDs: CGWindowListCopyWindowInfo 返回 nil")
            return []
        }

        // 诊断日志：打印该 PID 的所有窗口（不论层级）
        let allForPid = winInfo.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
        print("[SLS] 🔍 getNormalWindowIDs(pid=\(pid), onScreenOnly=\(onScreenOnly)): 共 \(winInfo.count) 个窗口, 该 PID 有 \(allForPid.count) 个")
        for info in allForPid {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let wid = info[kCGWindowNumber as String] as? UInt32 ?? 0
            let name = info[kCGWindowName as String] as? String ?? "?"
            let alpha = info[kCGWindowAlpha as String] as? Double ?? -1
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print("[SLS] 🔍   wid=\(wid) layer=\(layer) alpha=\(alpha) name=\(name) bounds=\(bounds)")
        }

        let result = winInfo.compactMap { info -> UInt32? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0, // 正常层级
                  let wid = info[kCGWindowNumber as String] as? UInt32
            else { return nil }
            return wid
        }
        print("[SLS] 🔍 getNormalWindowIDs: 过滤后 layer=0 窗口: \(result)")
        return result
    }

    /// 缓存被 order-out 的窗口 ID，供 restore 使用
    private static var minimizedWindowCache: [pid_t: [UInt32]] = [:]

    /// 清除指定 PID 的缓存
    static func clearMinimizedCache(pid: pid_t) {
        minimizedWindowCache[pid] = nil
    }

    /// 检查指定 PID 是否有可见（未 order out）的窗口
    static func hasVisibleWindows(pid: pid_t) -> Bool {
        guard let winInfo = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return winInfo.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            (info[kCGWindowLayer as String] as? Int) == 0
        }
    }

    // MARK: - AXUIElement → CGWindowID 桥接

    private static func getWindowID(from axElement: AXUIElement) -> UInt32? {
        guard let fn = axGetWindow else { return nil }
        var windowID: UInt32 = 0
        guard fn(axElement, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    // MARK: - Frame 设置（保留原有接口）

    @discardableResult
    static func setWindowFrame(_ window: AXUIElement, frame: CGRect) -> Bool {
        guard isAvailable, let setBoundsFn = setBounds, let windowID = getWindowID(from: window) else {
            return false
        }
        let cgFrame = axToCG(frame)
        return setBoundsFn(slsConnection, windowID, cgFrame) == .success
    }

    @discardableResult
    static func setWindowPosition(_ window: AXUIElement, position: CGPoint) -> Bool {
        guard isAvailable, let windowID = getWindowID(from: window) else { return false }
        let currentSize: CGSize
        if let getBoundsFn = getBounds {
            var cgBounds = CGRect.zero
            if getBoundsFn(slsConnection, windowID, &cgBounds) == .success {
                currentSize = cgBounds.size
            } else {
                currentSize = getAXSize(window) ?? CGSize(width: 800, height: 600)
            }
        } else {
            currentSize = getAXSize(window) ?? CGSize(width: 800, height: 600)
        }
        return setWindowFrame(window, frame: CGRect(origin: position, size: currentSize))
    }

    @discardableResult
    static func setWindowSize(_ window: AXUIElement, size: CGSize) -> Bool {
        guard isAvailable, let windowID = getWindowID(from: window) else { return false }
        if let getBoundsFn = getBounds {
            var cgBounds = CGRect.zero
            if getBoundsFn(slsConnection, windowID, &cgBounds) == .success {
                return setWindowFrame(window, frame: CGRect(origin: cgToAX(cgBounds).origin, size: size))
            }
        }
        let axOrigin = getAXPosition(window) ?? .zero
        return setWindowFrame(window, frame: CGRect(origin: axOrigin, size: size))
    }

    static func getWindowFrame(_ window: AXUIElement) -> CGRect? {
        guard isAvailable, let getBoundsFn = getBounds, let windowID = getWindowID(from: window) else { return nil }
        var cgBounds = CGRect.zero
        guard getBoundsFn(slsConnection, windowID, &cgBounds) == .success else { return nil }
        return cgToAX(cgBounds)
    }

    // MARK: - AX 辅助

    private static func getAXSize(_ window: AXUIElement) -> CGSize? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &val) == .success,
              let axVal = val else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axVal as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func getAXPosition(_ window: AXUIElement) -> CGPoint? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &val) == .success,
              let axVal = val else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axVal as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
}