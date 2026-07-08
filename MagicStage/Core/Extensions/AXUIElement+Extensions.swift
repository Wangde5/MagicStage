import Cocoa
import ApplicationServices

// MARK: - Dock AX 工具方法

/// 获取 Dock 进程的 AX 根元素
func dockAXElement() -> AXUIElement? {
    let dockApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
    guard let dock = dockApps.first else { return nil }
    return AXUIElementCreateApplication(dock.processIdentifier)
}

/// 递归展开 AX 元素树，收集所有有 frame 信息的元素（限制深度防止意外）
func flattenAXElements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 10 else { return [] }
    var result: [AXUIElement] = []

    if hasAXPosition(element) {
        result.append(element)
    }

    var children: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
       let childArray = children as? [AXUIElement] {
        for child in childArray {
            result.append(contentsOf: flattenAXElements(child, depth: depth + 1))
        }
    }

    return result
}

/// 检查 AX 元素是否有有效的位置和尺寸
/// 过滤零尺寸、全屏尺寸元素（容器元素）
func hasAXPosition(_ element: AXUIElement) -> Bool {
    var pos: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success else {
        return false
    }
    var pt = CGPoint.zero
    var sz = CGSize.zero
    guard let pv = pos, CFGetTypeID(pv) == AXValueGetTypeID(), AXValueGetValue(pv as! AXValue, .cgPoint, &pt),
          let sv = size, CFGetTypeID(sv) == AXValueGetTypeID(), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return false }
    return sz.width > 0 && sz.height > 0 && sz.width < 500 && sz.height < 500
}

/// 获取 AX 元素的屏幕坐标 frame（已翻转 Y 轴）
/// AX 坐标系原点在主屏左上角 y 向下，转换为左下角坐标系以匹配 NSEvent.mouseLocation
func axElementFrame(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
        return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID(), AXValueGetValue(pv as! AXValue, .cgPoint, &position),
          let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID(), AXValueGetValue(sv as! AXValue, .cgSize, &size) else {
        return nil
    }

    // AX 坐标原点始终在主屏左上角，必须用主屏高度做翻转
    if let screen = NSScreen.screens.first {
        let flippedY = screen.frame.height - position.y - size.height
        return CGRect(x: position.x, y: flippedY, width: size.width, height: size.height)
    }
    return CGRect(origin: position, size: size)
}

/// 获取 AX 元素的标题
func axElementTitle(_ element: AXUIElement) -> String? {
    var title: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else {
        return nil
    }
    return title as? String
}

// MARK: - 运行中应用查找

/// 根据名称查找正在运行的应用（宽松匹配）
/// 解决 VS Code 等 localizedName 与 Dock 显示名不一致的问题
///
/// 匹配策略：精确匹配 → 大小写不敏感 → 包含匹配 → bundleIdentifier 匹配 → 兜底（非 regular 应用）
func findRunningApp(named name: String) -> NSRunningApplication? {
    let currentApp = NSRunningApplication.current
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0 != currentApp && $0.activationPolicy == .regular
    }

    // 1. 精确匹配 localizedName
    if let match = apps.first(where: { $0.localizedName == name }) { return match }

    // 2. 大小写不敏感匹配
    if let match = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }) { return match }

    // 3. localizedName 包含匹配（处理 "Visual Studio Code" vs "Code"）
    if let match = apps.first(where: {
        guard let loc = $0.localizedName else { return false }
        return loc.contains(name) || name.contains(loc)
    }) { return match }

    // 4. bundleIdentifier 匹配
    let cleanName = name.lowercased().replacingOccurrences(of: " ", with: "")
    if let match = apps.first(where: {
        guard let bid = $0.bundleIdentifier?.lowercased() else { return false }
        return bid.contains(cleanName) || cleanName.contains(bid.replacingOccurrences(of: "com.", with: "").replacingOccurrences(of: "microsoft.", with: ""))
    }) { return match }

    // 5. 兜底：activationPolicy != .prohibited
    let allApps = NSWorkspace.shared.runningApplications.filter {
        $0 != currentApp && $0.activationPolicy != .prohibited
    }
    return allApps.first(where: { $0.localizedName == name })
}