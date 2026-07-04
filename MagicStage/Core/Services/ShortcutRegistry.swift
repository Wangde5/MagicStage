import AppKit

// MARK: - 功能标识

/// 所有可使用快捷键的功能模块唯一标识
enum FeatureID: Hashable, Codable {
    case minimizeAll
    case minimizeOthers
    case dockQuit
    case moveWindow
    case windowLayout(WindowLayout)

    var displayName: String {
        switch self {
        case .minimizeAll:      return "隐藏所有窗口"
        case .minimizeOthers:   return "隐藏其他窗口"
        case .dockQuit:         return "Dock 退出"
        case .moveWindow:       return "移动窗口"
        case .windowLayout(let l): return "窗口布局-\(l.displayName)"
        }
    }
}

// MARK: - 冲突类型

enum ShortcutConflict {
    /// 完全相同的快捷键已被其他功能占用
    case exact(by: FeatureID)

    var alertMessage: String {
        switch self {
        case .exact(let feature):
            return "该快捷键已分配给『\(feature.displayName)』，是否替换？"
        }
    }
}

// MARK: - 全局快捷键注册表

/// 统一管理所有功能模块的快捷键注册、冲突检测和运行时分发。
/// BTT 风格：软件内部冲突拦截提示，系统级/其他 App 冲突靠 CGEvent tap 优先级天然取胜。
///
/// **注册** = 映射关系（快捷键 ↔ 功能），不包含 handler。
/// **Handler** 通过 `setHandler` 单独注入，不受重新录制影响。
final class ShortcutRegistry {

    static let shared = ShortcutRegistry()

    // MARK: 存储

    /// 快捷键 → 功能映射
    private var shortcutToFeature: [KeyboardShortcut: FeatureID] = [:]

    /// 功能 → 快捷键映射（快速反向查找）
    private var featureToShortcut: [FeatureID: KeyboardShortcut] = [:]

    /// 功能 → 执行回调（独立于映射关系，录制不会覆盖）
    private var handlers: [FeatureID: () -> Void] = [:]

    // MARK: 注册（仅映射）

    /// 注册快捷键→功能映射。返回冲突信息（如有）。
    @discardableResult
    func register(_ shortcut: KeyboardShortcut, for feature: FeatureID) -> ShortcutConflict? {
        guard shortcut.keyCode != 0 || shortcut.modifierFlags != 0 else {
            unregister(feature)
            return nil
        }

        // 检查冲突（在写入前，快照冲突信息）
        let conflict = findConflict(for: shortcut, excluding: feature)

        // 移除本功能旧映射
        if let oldShortcut = featureToShortcut[feature] {
            shortcutToFeature.removeValue(forKey: oldShortcut)
        }

        // 如果有冲突，清除冲突功能的旧映射（替换场景）
        if let conflictingFeature = conflictingFeature(for: shortcut, excluding: feature) {
            featureToShortcut.removeValue(forKey: conflictingFeature)
        }

        // 写入新映射
        shortcutToFeature[shortcut] = feature
        featureToShortcut[feature] = shortcut

        return conflict
    }

    /// 返回与给定快捷键冲突的功能标识
    private func conflictingFeature(for shortcut: KeyboardShortcut, excluding feature: FeatureID) -> FeatureID? {
        guard shortcut.keyCode != 0 || shortcut.modifierFlags != 0 else { return nil }
        if let existing = shortcutToFeature[shortcut], existing != feature {
            return existing
        }
        return nil
    }

    // MARK: Handler（独立注入）

    /// 为功能注册执行回调。handler 独立于快捷键映射，重新录制不会覆盖。
    func setHandler(_ handler: @escaping () -> Void, for feature: FeatureID) {
        handlers[feature] = handler
    }

    // MARK: 注销

    /// 注销某个功能的快捷键
    func unregister(_ feature: FeatureID) {
        if let shortcut = featureToShortcut.removeValue(forKey: feature) {
            shortcutToFeature.removeValue(forKey: shortcut)
        }
        // 不删除 handler，功能可能稍后重新注册
    }

    // MARK: 查询

    /// 查询功能对应的快捷键
    func shortcut(for feature: FeatureID) -> KeyboardShortcut? {
        featureToShortcut[feature]
    }

    /// 查询快捷键对应的功能
    func feature(for shortcut: KeyboardShortcut) -> FeatureID? {
        shortcutToFeature[shortcut]
    }

    // MARK: 冲突检测

    /// 检测新快捷键与已注册快捷键的冲突（排除自身）。
    /// 仅检测完全匹配；subset/superset 由运行时手势抑制逻辑处理，无需警告。
    func findConflict(for shortcut: KeyboardShortcut, excluding feature: FeatureID) -> ShortcutConflict? {
        guard shortcut.keyCode != 0 || shortcut.modifierFlags != 0 else { return nil }

        if let existing = shortcutToFeature[shortcut], existing != feature {
            return .exact(by: existing)
        }
        return nil
    }

    // MARK: 运行时分发

    /// 根据 keyDown 事件分发到对应的功能处理器。
    /// 返回 true 表示已匹配并执行（事件应被吞掉）。
    func dispatchKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let candidate = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        guard let feature = shortcutToFeature[candidate],
              let handler = handlers[feature] else {
            return false
        }
        DispatchQueue.main.async { handler() }
        return true
    }

    /// 根据 modifier peak 查找纯修饰键快捷键并分发。
    func dispatchModifierOnly(modifiers: NSEvent.ModifierFlags) -> Bool {
        let candidate = KeyboardShortcut(keyCode: .max, modifiers: modifiers)
        guard let feature = shortcutToFeature[candidate],
              let handler = handlers[feature] else {
            return false
        }
        DispatchQueue.main.async { handler() }
        return true
    }
}
