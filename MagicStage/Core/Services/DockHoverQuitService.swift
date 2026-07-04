import Cocoa
import ApplicationServices
import Combine

/// 鼠标悬停 Dock 栏图标 + 全局快捷键 → 退出对应 App
///
/// 工作原理：
/// 1. 全局快捷键在 HotkeyManager 中注册，触发时调用 handleShortcutPressed()
/// 2. 通过 Accessibility API 遍历 Dock 进程的子元素
/// 3. 找到鼠标光标所在位置的 Dock 图标
/// 4. 通过 AXTitle 匹配到 NSRunningApplication，调用 terminate() 退出
@MainActor
final class DockHoverQuitService {
    static let shared = DockHoverQuitService()

    @Published var isEnabled = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "enableDockQuit")
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "enableDockQuit")
    }

    /// 处理快捷键事件（由 HotkeyManager 调用）
    func handleShortcutPressed() {
        guard isEnabled else { return }
        guard let app = hoveredDockApp() else { return }

        // 触觉反馈
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        app.terminate()
    }

    // MARK: - Dock 图标检测

    /// 返回鼠标光标下方 Dock 图标对应的 NSRunningApplication，无匹配则返回 nil
    private func hoveredDockApp() -> NSRunningApplication? {
        let mouseLocation = NSEvent.mouseLocation
        print("[DockQuit] 🔍 mouseLocation=\(mouseLocation)")

        guard let dockAX = dockAXElement() else {
            print("[DockQuit] ❌ 无法获取 Dock AX 元素")
            return nil
        }

        // Dock 的 AX 子元素是嵌套列表结构，需要递归查找所有有位置信息的元素
        let allItems = flattenAXElements(dockAX)
        print("[DockQuit] 🔍 flattenAXElements 找到 \(allItems.count) 个有位置的元素")

        var bestMatch: NSRunningApplication?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for item in allItems {
            guard let frame = axElementFrame(item) else { continue }
            // 必须是鼠标在元素范围内
            guard frame.contains(mouseLocation) else { continue }

            let appName = axElementTitle(item)
            print("[DockQuit] 🔍 命中 Dock 项: frame=\(frame) title=\(appName ?? "nil")")

            // 优先选面积最小的（即最精确的命中）
            let area = frame.width * frame.height
            if area < bestArea {
                if let name = appName,
                   let runningApp = findRunningApp(named: name) {
                    bestArea = area
                    bestMatch = runningApp
                    print("[DockQuit] ✅ 匹配到 App: \(name) -> \(runningApp.localizedName ?? "?") bundleID=\(runningApp.bundleIdentifier ?? "?")")
                } else {
                    print("[DockQuit] ⚠️ AX title=\(appName ?? "nil") 但 findRunningApp 返回 nil")
                }
            }
        }

        if bestMatch == nil {
            print("[DockQuit] ❌ 未找到匹配的 App")
        }
        return bestMatch
    }

    /// 递归展开 AX 元素树，收集所有有 frame 信息的叶子元素（限制深度防止意外）
    private func flattenAXElements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 10 else { return [] }
        var result: [AXUIElement] = []

        // 检查当前元素自身是否有位置
        if hasAXPosition(element) {
            result.append(element)
        }

        // 递归子元素
        var children: AnyObject?
        let axResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if axResult == .success, let childArray = children as? [AXUIElement] {
            for child in childArray {
                result.append(contentsOf: flattenAXElements(child, depth: depth + 1))
            }
        }

        return result
    }

    /// 检查元素是否有有效的位置属性
    private func hasAXPosition(_ element: AXUIElement) -> Bool {
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
        // 过滤掉零尺寸或全屏幕尺寸的元素（容器元素）
        return sz.width > 0 && sz.height > 0 && sz.width < 500 && sz.height < 500
    }

    // MARK: - Accessibility 工具方法

    /// 获取 Dock 进程的 AXUIElement
    private func dockAXElement() -> AXUIElement? {
        let dockApps = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.apple.dock" }
        guard let dock = dockApps.first else { return nil }
        return AXUIElementCreateApplication(dock.processIdentifier)
    }

    /// 获取 AXUIElement 的 frame（屏幕坐标系）
    /// AX 坐标系原点在主屏左上角 y 向下，转换为左下角坐标系以匹配 NSEvent.mouseLocation
    private func axElementFrame(_ element: AXUIElement) -> CGRect? {
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

    /// 获取 AXUIElement 的标题（应用名称）
    private func axElementTitle(_ element: AXUIElement) -> String? {
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    /// 根据名称查找正在运行的应用
    private func findRunningApp(named name: String) -> NSRunningApplication? {
        let currentApp = NSRunningApplication.current
        let apps = NSWorkspace.shared.runningApplications.filter { $0 != currentApp && $0.activationPolicy == .regular }
        
        print("[DockQuit] 🔍 findRunningApp: 搜索 '\(name)', 共 \(apps.count) 个 regular 应用")
        
        // 1. 精确匹配 localizedName
        if let match = apps.first(where: { $0.localizedName == name }) {
            print("[DockQuit] ✅ 精确匹配: \(match.localizedName ?? "?")")
            return match
        }
        
        // 2. 大小写不敏感匹配
        if let match = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }) {
            print("[DockQuit] ✅ 大小写不敏感匹配: \(match.localizedName ?? "?")")
            return match
        }
        
        // 3. localizedName 包含 name（处理 "Visual Studio Code" vs "Code"）
        if let match = apps.first(where: {
            guard let loc = $0.localizedName else { return false }
            return loc.contains(name) || name.contains(loc)
        }) {
            print("[DockQuit] ✅ 包含匹配: \(match.localizedName ?? "?")")
            return match
        }
        
        // 4. bundleIdentifier 匹配
        let cleanName = name.lowercased().replacingOccurrences(of: " ", with: "")
        if let match = apps.first(where: {
            guard let bid = $0.bundleIdentifier?.lowercased() else { return false }
            return bid.contains(cleanName) || cleanName.contains(bid.replacingOccurrences(of: "com.", with: "").replacingOccurrences(of: "microsoft.", with: ""))
        }) {
            print("[DockQuit] ✅ bundleID 匹配: \(match.localizedName ?? "?") bundleID=\(match.bundleIdentifier ?? "?")")
            return match
        }
        
        // 5. 兜底：activationPolicy != .prohibited
        let allApps = NSWorkspace.shared.runningApplications.filter { $0 != currentApp && $0.activationPolicy != .prohibited }
        if let match = allApps.first(where: { $0.localizedName == name }) {
            print("[DockQuit] ✅ 兜底匹配(非regular): \(match.localizedName ?? "?")")
            return match
        }
        
        // 打印所有运行中的应用帮助调试
        print("[DockQuit] ❌ 无法匹配 '\(name)'，运行中的应用:")
        for app in apps {
            print("[DockQuit]   \(app.localizedName ?? "?") | \(app.bundleIdentifier ?? "?")")
        }
        
        return nil
    }
}
