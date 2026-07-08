import Cocoa
import ApplicationServices
import Combine

/// Debug 日志 helper（Release 版本不输出）
@inline(__always)
private func dockQuitLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

/// 鼠标悬停 Dock 栏图标 + 全局快捷键 → 退出对应 App
///
/// 工作原理：
/// 1. 全局快捷键在 HotkeyManager 中注册，触发时调用 handleShortcutPressed()
/// 2. 通过 Accessibility API 遍历 Dock 进程的子元素
/// 3. 找到鼠标光标所在位置的 Dock 图标
/// 4. 通过 AXTitle 匹配到 NSRunningApplication，调用 terminate() 退出
@MainActor
final class DockHoverQuitService: ObservableObject {
    static let shared = DockHoverQuitService()

    @Published var isEnabled = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "enableDockQuit")
        }
    }

    /// 退出后触控板震动开关
    @Published var enableHapticFeedback = true {
        didSet {
            UserDefaults.standard.set(enableHapticFeedback, forKey: "enableDockQuitHaptic")
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "enableDockQuit")
        enableHapticFeedback = UserDefaults.standard.object(forKey: "enableDockQuitHaptic") as? Bool ?? true
    }

    /// 处理快捷键事件（由 HotkeyManager 调用）
    func handleShortcutPressed() {
        guard isEnabled else { return }
        guard let app = hoveredDockApp() else { return }

        // 立即隐藏窗口预览面板（避免应用退出过程中预览残留，鼠标无需移开）
        WindowPreviewService.shared.hidePanel()

        app.terminate()

        // 延迟触发触觉反馈（不检测应用是否真正退出，直接隔一点时间震动）
        if enableHapticFeedback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    // MARK: - Dock 图标检测

    /// 返回鼠标光标下方 Dock 图标对应的 NSRunningApplication，无匹配则返回 nil
    private func hoveredDockApp() -> NSRunningApplication? {
        let mouseLocation = NSEvent.mouseLocation
        dockQuitLog("[DockQuit] 🔍 mouseLocation=\(mouseLocation)")

        guard let dockAX = dockAXElement() else {
            dockQuitLog("[DockQuit] ❌ 无法获取 Dock AX 元素")
            return nil
        }

        // Dock 的 AX 子元素是嵌套列表结构，需要递归查找所有有位置信息的元素
        let allItems = flattenAXElements(dockAX)
        dockQuitLog("[DockQuit] 🔍 flattenAXElements 找到 \(allItems.count) 个有位置的元素")

        var bestMatch: NSRunningApplication?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for item in allItems {
            // 只关心 AXDockItem（图标），跳过 AXList 等容器
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == kAXDockItemRole else { continue }

            guard let frame = axElementFrame(item) else { continue }
            // 必须是鼠标在元素范围内
            guard frame.contains(mouseLocation) else { continue }

            let appName = axElementTitle(item)
            dockQuitLog("[DockQuit] 🔍 命中 Dock 项: frame=\(frame) title=\(appName ?? "nil")")

            // 优先选面积最小的（即最精确的命中）
            let area = frame.width * frame.height
            if area < bestArea {
                // 优先用 AXURL → bundleURL 精确匹配
                // VS Code / Cursor 等 Electron 应用 AXTitle 可能相同（都是 "Code"）
                var runningApp: NSRunningApplication?
                var urlRef: CFTypeRef?
                var hasURL = false
                if AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef) == .success {
                    let url: URL? = (urlRef as? NSURL) as URL? ?? (urlRef as? String).flatMap { URL(string: $0) }
                    if let url = url {
                        hasURL = true
                        let standardURL = url.standardizedFileURL
                        runningApp = NSWorkspace.shared.runningApplications.first(where: {
                            $0.bundleURL?.standardizedFileURL == standardURL
                        })
                    }
                }
                // 回退到名称匹配（仅在 AXURL 不可用时，避免同名 App 误匹配）
                if runningApp == nil && !hasURL, let name = appName {
                    runningApp = findRunningApp(named: name)
                }

                if let runningApp = runningApp {
                    bestArea = area
                    bestMatch = runningApp
                    dockQuitLog("[DockQuit] ✅ 匹配到 App: \(appName ?? "?") -> \(runningApp.localizedName ?? "?") bundleID=\(runningApp.bundleIdentifier ?? "?")")
                } else {
                    dockQuitLog("[DockQuit] ⚠️ AX title=\(appName ?? "nil") 但 findRunningApp 返回 nil")
                }
            }
        }

        if bestMatch == nil {
            dockQuitLog("[DockQuit] ❌ 未找到匹配的 App")
        }
        return bestMatch
    }
}
