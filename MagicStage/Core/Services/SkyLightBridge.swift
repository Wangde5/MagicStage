import Foundation
import AppKit
import ApplicationServices

// MARK: - Debug 日志 helper（Release 版本不输出）

/// SkyLight 私有 API 加载日志，仅在 DEBUG 模式输出
@inline(__always)
private func slsLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

// MARK: - SkyLight 私有 API 全局声明（参考 DockDoor PrivateApis.swift）
//
// 使用 @_silgen_name 直接映射到 C 符号，比 dlsym + unsafeBitCast 更可靠
// SkyLight.framework 已被 AppKit 间接加载，符号在 RTLD_DEFAULT 中可找到

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(
    _ cid: UInt32,
    _ windowList: UnsafePointer<UInt32>,
    _ count: UInt32,
    _ options: UInt32  // CGSWindowCaptureOptions.rawValue
) -> CFArray?

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

    // 截图私有 API（参考 DockDoor PrivateApis.swift）
    // CGSHWCaptureWindowList 比 SCScreenshotManager 更可靠：
    // - 支持跨 Space 窗口截图
    // - 支持全屏窗口截图
    // - 支持已最小化窗口截图（部分场景）
    typealias CGSConnectionID = UInt32
    typealias CGSWindowCount = UInt32

    struct CGSWindowCaptureOptions: OptionSet {
        let rawValue: UInt32
        static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
        static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
        static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
        // Stage Manager 启用时截图会变形，此选项获取完整尺寸
        static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
    }

    // 注意：@convention(c) 闭包不能使用 Swift 自定义 struct（如 CGSWindowCaptureOptions），
    // 必须使用 C 兼容的 raw 类型（UInt32）。参考 DockDoor PrivateApis.swift
    private typealias CGSHWCaptureWindowListFunc = @convention(c) (
        CGSConnectionID,
        UnsafePointer<UInt32>,
        CGSWindowCount,
        UInt32  // CGSWindowCaptureOptions.rawValue
    ) -> CFArray?

    // 窗口置顶私有 API（参考 DockDoor PrivateApis.swift + WindowInfo.bringToFront）
    // _SLPSSetFrontProcessWithOptions + SLPSPostEventRecordTo 是 WindowServer 层级的
    // 窗口激活 API，比 NSRunningApplication.activate + AX kAXRaiseAction 更可靠：
    // - 直接操作 WindowServer 合成层，绕过应用层协商
    // - 解决 Electron/CEF 应用激活后窗口仍在其他窗口下方的问题
    // - 解决 Chrome 等浏览器激活后仍在 QQ/微信下方的问题
    struct ProcessSerialNumber {
        var highLongOfPSN: UInt32 = 0
        var lowLongOfPSN: UInt32 = 0
    }

    enum SLPSMode: UInt32 {
        case allWindows = 0x100
        case userGenerated = 0x200
        case noWindows = 0x400
    }

    // 注意：@convention(c) 闭包不能使用 Swift 自定义 struct（如 ProcessSerialNumber），
    // 必须使用 UnsafeMutableRawPointer。参考 DockDoor PrivateApis.swift
    private typealias SLPSSetFrontProcessWithOptionsFunc = @convention(c) (
        UnsafeMutableRawPointer,  // UnsafeMutablePointer<ProcessSerialNumber>
        UInt32,  // CGWindowID
        UInt32   // SLPSMode.RawValue
    ) -> CGError

    private typealias SLPSPostEventRecordToFunc = @convention(c) (
        UnsafeMutableRawPointer,  // UnsafeMutablePointer<ProcessSerialNumber>
        UnsafeMutablePointer<UInt8>
    ) -> CGError

    private typealias GetProcessForPIDFunc = @convention(c) (
        pid_t,
        UnsafeMutableRawPointer  // UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    // MARK: - SkyLight 框架句柄

    private static let slsHandle: UnsafeMutableRawPointer? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else {
            let err = String(cString: dlerror())
            slsLog("[SLS] ❌ dlopen(SkyLight.framework) 失败: \(err)")
            return nil
        }
        slsLog("[SLS] ✅ dlopen(SkyLight.framework) 成功 handle=\(String(describing: handle))")
        return handle
    }()

    // MARK: - 已加载的函数指针

    private static let slsConnection: Int32 = {
        guard let handle = slsHandle,
              let sym = dlsym(handle, "SLSMainConnectionID") else {
            slsLog("[SLS] ❌ SLSMainConnectionID dlsym 返回 NULL")
            return -1
        }
        let fn = unsafeBitCast(sym, to: SLSMainConnectionIDFunc.self)
        let cid = fn()
        slsLog("[SLS] 🔗 SLSMainConnectionID = \(cid)")
        return cid
    }()

    private static let orderWindow: SLSOrderWindowFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSOrderWindow") {
            slsLog("[SLS] ✅ dlsym(SLSOrderWindow)")
            return unsafeBitCast(sym, to: SLSOrderWindowFunc.self)
        }
        slsLog("[SLS] ❌ dlsym(SLSOrderWindow) → NULL")
        return nil
    }()

    private static let getWindowList: SLSGetWindowListFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSGetWindowList") {
            slsLog("[SLS] ✅ dlsym(SLSGetWindowList)")
            return unsafeBitCast(sym, to: SLSGetWindowListFunc.self)
        }
        slsLog("[SLS] ❌ dlsym(SLSGetWindowList) → NULL")
        return nil
    }()

    private static let getWindowOwner: SLSGetWindowOwnerFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSGetWindowOwner") {
            slsLog("[SLS] ✅ dlsym(SLSGetWindowOwner)")
            return unsafeBitCast(sym, to: SLSGetWindowOwnerFunc.self)
        }
        slsLog("[SLS] ❌ dlsym(SLSGetWindowOwner) → NULL")
        return nil
    }()

    private static let setBounds: SLSSetWindowBoundsFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLSSetWindowBounds") {
            slsLog("[SLS] ✅ dlsym(SLSSetWindowBounds)")
            return unsafeBitCast(sym, to: SLSSetWindowBoundsFunc.self)
        }
        slsLog("[SLS] ⚠️ dlsym(SLSSetWindowBounds) → NULL")
        if let sym = dlsym(handle, "SLSWindowSetBounds") {
            slsLog("[SLS] ✅ dlsym(SL。。988 SWindowSetBounds)")
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

    // CGSHWCaptureWindowList 截图函数（主路径，比 SC 更可靠）
    private static let captureWindowList: CGSHWCaptureWindowListFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "CGSHWCaptureWindowList") {
            slsLog("[SLS] ✅ dlsym(CGSHWCaptureWindowList)")
            return unsafeBitCast(sym, to: CGSHWCaptureWindowListFunc.self)
        }
        slsLog("[SLS] ❌ dlsym(CGSHWCaptureWindowList) → NULL")
        return nil
    }()

    // _SLPSSetFrontProcessWithOptions 置顶窗口函数
    private static let setFrontProcessWithOptions: SLPSSetFrontProcessWithOptionsFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") {
            slsLog("[SLS] ✅ dlsym(_SLPSSetFrontProcessWithOptions)")
            return unsafeBitCast(sym, to: SLPSSetFrontProcessWithOptionsFunc.self)
        }
        slsLog("[SLS] ❌ dlsym(_SLPSSetFrontProcessWithOptions) → NULL")
        return nil
    }()

    // SLPSPostEventRecordTo 发送原始事件字节函数（makeKeyWindow 用）
    private static let postEventRecordTo: SLPSPostEventRecordToFunc? = {
        guard let handle = slsHandle else { return nil }
        if let sym = dlsym(handle, "SLPSPostEventRecordTo") {
            slsLog("[SLS] ✅ dlsym(SLPSPostEventRecordTo)")
            return unsafeBitCast(sym, to: SLPSPostEventRecordToFunc.self)
        }
        slsLog("[SLS] ❌ dlsym(SLPSPostEventRecordTo) → NULL")
        return nil
    }()

    // GetProcessForPID（HIToolbox 公开 API，但用函数指针保持一致）
    private static let getProcessForPID: GetProcessForPIDFunc? = {
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "GetProcessForPID") {
            return unsafeBitCast(sym, to: GetProcessForPIDFunc.self)
        }
        return nil
    }()

    // MARK: - 可用性标志

    /// SLSOrderWindow 最小化路径是否可用
    static let orderWindowAvailable: Bool = {
        guard slsHandle != nil else { return false }
        guard slsConnection != -1 else { return false }
        guard orderWindow != nil else { return false }
        slsLog("[SLS] ✅ orderWindow 最小化路径可用 (cid=\(slsConnection))")
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

    /// CGSHWCaptureWindowList 截图路径是否可用
    static let captureAvailable: Bool = {
        guard slsHandle != nil else { return false }
        guard slsConnection != -1 else { return false }
        guard captureWindowList != nil else { return false }
        return true
    }()

    /// _SLPSSetFrontProcessWithOptions 置顶路径是否可用
    static let frontProcessAvailable: Bool = {
        guard slsHandle != nil else { return false }
        guard setFrontProcessWithOptions != nil else { return false }
        guard getProcessForPID != nil else { return false }
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
            slsLog("[SLS] ⚠️ minimizeWindows: SLSOrderWindow 不可用，回退 AX")
            return 0
        }

        let windowIDs = getNormalWindowIDs(pid: pid, onScreenOnly: true)
        guard !windowIDs.isEmpty else {
            slsLog("[SLS] ⚠️ minimizeWindows: pid=\(pid) 无正常层级窗口")
            return 0
        }

        // 缓存窗口 ID，供 restore 使用
        cacheLock.lock()
        minimizedWindowCache[pid] = windowIDs
        cacheLock.unlock()

        var count = 0
        for wid in windowIDs {
            let result = orderFn(slsConnection, wid, 0, 0) // mode=0 = order out
            if result == .success {
                if verboseLogging { slsLog("[SLS] ✅ SLSOrderWindow(OUT) wid=\(wid)") }
                count += 1
            } else {
                slsLog("[SLS] ❌ SLSOrderWindow(OUT) wid=\(wid) CGError=\(result.rawValue)")
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
            slsLog("[SLS] ⚠️ restoreWindows: SLSOrderWindow 不可用")
            return 0
        }

        // 优先使用缓存，否则查询所有窗口（含 off-screen，因为 order out 后不再 on-screen）
        let windowIDs: [UInt32]
        cacheLock.lock()
        if let cached = minimizedWindowCache[pid], !cached.isEmpty {
            windowIDs = cached
            minimizedWindowCache[pid] = nil
            cacheLock.unlock()
            slsLog("[SLS] 🔄 restoreWindows: 使用缓存 \(windowIDs.count) 个窗口 ID")
        } else {
            cacheLock.unlock()
            windowIDs = getNormalWindowIDs(pid: pid, onScreenOnly: false)
        }
        guard !windowIDs.isEmpty else {
            slsLog("[SLS] ⚠️ restoreWindows: pid=\(pid) 无正常层级窗口")
            return 0
        }

        var count = 0
        for wid in windowIDs {
            let result = orderFn(slsConnection, wid, 1, 0) // mode=1 = order above
            if result == .success {
                if verboseLogging { slsLog("[SLS] ✅ SLSOrderWindow(IN) wid=\(wid)") }
                count += 1
            } else {
                slsLog("[SLS] ❌ SLSOrderWindow(IN) wid=\(wid) CGError=\(result.rawValue)")
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
            slsLog("[SLS] 🔍 getNormalWindowIDs: CGWindowListCopyWindowInfo 返回 nil")
            return []
        }

        // 诊断日志：打印该 PID 的所有窗口（不论层级）
        let allForPid = winInfo.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
        slsLog("[SLS] 🔍 getNormalWindowIDs(pid=\(pid), onScreenOnly=\(onScreenOnly)): 共 \(winInfo.count) 个窗口, 该 PID 有 \(allForPid.count) 个")
        for info in allForPid {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let wid = info[kCGWindowNumber as String] as? UInt32 ?? 0
            let name = info[kCGWindowName as String] as? String ?? "?"
            let alpha = info[kCGWindowAlpha as String] as? Double ?? -1
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            slsLog("[SLS] 🔍   wid=\(wid) layer=\(layer) alpha=\(alpha) name=\(name) bounds=\(bounds)")
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
        slsLog("[SLS] 🔍 getNormalWindowIDs: 过滤后 layer=0 窗口: \(result)")
        return result
    }

    /// 缓存被 order-out 的窗口 ID，供 restore 使用
    private static var minimizedWindowCache: [pid_t: [UInt32]] = [:]
    private static let cacheLock = NSLock()

    /// 清除指定 PID 的缓存
    static func clearMinimizedCache(pid: pid_t) {
        cacheLock.lock()
        minimizedWindowCache[pid] = nil
        cacheLock.unlock()
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

    static func getWindowID(from axElement: AXUIElement) -> UInt32? {
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

    // MARK: - 窗口截图（CGSHWCaptureWindowList 主路径）
    //
    // 参考 DockDoor WindowUtil.captureWindowImage：
    // CGSHWCaptureWindowList 直接通过 WindowServer 合成层截图，比 SCScreenshotManager 更可靠：
    // - 跨 Space 窗口：SC 在窗口位于其他 Space 时会失败，CGS 仍可截图
    // - 全屏窗口：SC 对全屏窗口截图可能失败，CGS 不受影响
    // - Stage Manager：CGS + fullSize 选项可获取完整尺寸
    //
    // 返回 CGImage?，失败返回 nil（调用方降级到 SC / CGWindowListCreateImage）

    /// 使用 CGSHWCaptureWindowList 截取指定窗口 ID 的图像
    /// - Parameters:
    ///   - windowID: 目标窗口的 CGWindowID
    ///   - bestResolution: true=最佳分辨率（Retina 2x），false=标称分辨率（1x，体积更小）
    static func captureWindow(windowID: UInt32, bestResolution: Bool = true) -> CGImage? {
        // 使用 @_silgen_name 声明的全局函数（与 DockDoor 完全一致）
        // 比 dlsym + unsafeBitCast 更可靠，避免类型转换问题
        let connectionID = CGSMainConnectionID()
        guard connectionID != 0 else {
            #if DEBUG
            slsLog("[SLS] ❌ CGSMainConnectionID 返回 0")
            #endif
            return nil
        }

        var wid = windowID
        // 选项与 DockDoor WindowUtil.captureWindowImage 完全一致：
        // 只用 ignoreGlobalClipShape + bestResolution/nominalResolution
        let optionsRaw: UInt32 = bestResolution
            ? CGSWindowCaptureOptions.ignoreGlobalClipShape.rawValue | CGSWindowCaptureOptions.bestResolution.rawValue
            : CGSWindowCaptureOptions.ignoreGlobalClipShape.rawValue | CGSWindowCaptureOptions.nominalResolution.rawValue

        guard let captured = CGSHWCaptureWindowList(
            connectionID,
            &wid,
            1,
            optionsRaw
        ) as? [CGImage], let image = captured.first else {
            #if DEBUG
            slsLog("[SLS] ❌ CGSHWCaptureWindowList 返回 nil 或空数组 wid=\(windowID)")
            #endif
            return nil
        }
        return image
    }

    // MARK: - 窗口置顶（_SLPSSetFrontProcessWithOptions + makeKeyWindow）
    //
    // 参考 DockDoor WindowInfo.bringToFront：
    // _SLPSSetFrontProcessWithOptions + SLPSPostEventRecordTo 是 WindowServer 层级的
    // 窗口激活 API，比 NSRunningApplication.activate + AX kAXRaiseAction 更可靠：
    // - 直接操作 WindowServer 合成层，绕过应用层协商
    // - 解决 Electron/CEF 应用激活后窗口仍在其他窗口下方的问题
    // - 解决 Chrome 等浏览器激活后仍在 QQ/微信下方的问题
    //
    // 组合：
    // 1. _SLPSSetFrontProcessWithOptions(psn, windowID, userGenerated) — 将进程置前
    // 2. SLPSPostEventRecordTo(psn, bytes) — makeKeyWindow 原始事件，让窗口成为 key window
    //
    // 与上层 AX kAXRaiseAction + kAXMainAttribute 配合形成完整激活链路

    /// 将指定 PID + windowID 的窗口置顶到最前
    /// - Parameters:
    ///   - pid: 目标进程 PID
    ///   - windowID: 目标窗口的 CGWindowID
    /// - Returns: true=成功调用私有 API（不保证窗口一定置顶，但通常有效），false=私有 API 不可用
    @discardableResult
    static func bringWindowToFront(pid: pid_t, windowID: UInt32) -> Bool {
        guard frontProcessAvailable,
              let setFrontFn = setFrontProcessWithOptions,
              let getPidFn = getProcessForPID else {
            return false
        }

        var psn = ProcessSerialNumber()
        // 用 withUnsafeMutablePointer 确保指针在整个闭包内有效，避免指针逃逸
        return withUnsafeMutablePointer(to: &psn) { psnPtr -> Bool in
            let rawPtr = UnsafeMutableRawPointer(psnPtr)
            guard getPidFn(pid, rawPtr) == noErr else {
                slsLog("[SLS] ❌ GetProcessForPID 失败 pid=\(pid)")
                return false
            }

            // 步骤 1：将进程的所有窗口置前（userGenerated 模式模拟用户操作）
            let setFrontResult = setFrontFn(rawPtr, windowID, SLPSMode.userGenerated.rawValue)
            if setFrontResult != .success {
                slsLog("[SLS] ⚠️ _SLPSSetFrontProcessWithOptions CGError=\(setFrontResult.rawValue) wid=\(windowID)")
            }

            // 步骤 2：makeKeyWindow 原始事件，让指定 windowID 成为 key window
            // 字节布局参考 DockDoor WindowUtil.makeKeyWindow（源自 Hammerspoon）
            if let postFn = postEventRecordTo {
                var bytes = [UInt8](repeating: 0, count: 0xF8)
                bytes[0x04] = 0xF8
                bytes[0x3A] = 0x10
                var wid = windowID
                memcpy(&bytes[0x3C], &wid, MemoryLayout<UInt32>.size)
                memset(&bytes[0x20], 0xFF, 0x10)
                bytes[0x08] = 0x01
                _ = postFn(rawPtr, &bytes)
                bytes[0x08] = 0x02
                _ = postFn(rawPtr, &bytes)
            }

            if verboseLogging {
                slsLog("[SLS] ✅ bringWindowToFront pid=\(pid) wid=\(windowID)")
            }
            return true
        }
    }
}
