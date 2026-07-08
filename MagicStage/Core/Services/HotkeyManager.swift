import AppKit
import SwiftUI

// MARK: - Notification

extension Notification.Name {
    static let hotkeyTapAvailabilityChanged = Notification.Name("hotkeyTapAvailabilityChanged")
}

// MARK: - HotkeyManager

/// 快捷键录制与运行时分发管理器。
///
/// **录制**：CGEvent tap 在最外层严格分流 keyDown / flagsChanged 到两条独立代码路径，
/// 互不共享中间状态读取逻辑。普通组合键（如 ⌘A）走 Path A，纯修饰键（如 ⌘⌃）走 Path B。
///
/// **运行时分发**：统一通过 `ShortcutRegistry` 查找并分发，不硬编码 if/else 链。
///
/// **降级**：CGEvent tap 不可用时自动回退到 NSEvent monitor。
final class HotkeyManager {
    static let shared = HotkeyManager()

    // MARK: - 事件截取

    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private(set) var tapAvailable = false {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hotkeyTapAvailabilityChanged,
                                                object: !self.tapAvailable)
            }
        }
    }

    /// 修饰键 keyCode 集合（54=⌘右, 55=⌘左, 56=⇧左, 57=⇪, 58=⌥左, 59=⌃左, 60=⇧右, 61=⌥右, 62=⌃右, 63=fn）
    private let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    // MARK: - 录制状态

    private(set) var isRecording = false
    private var recordingFeatureID: FeatureID?
    private var recordingCompletion: ((KeyboardShortcut) -> Void)?
    private var pendingKeyCode: UInt16?
    private var pendingModifiers: NSEvent.ModifierFlags = []

    // MARK: - 正常模式修饰键跟踪

    /// 非录制期间修饰键峰值，用于在 flagsChanged 松手时触发纯修饰键快捷键
    private var normalModifierPeak: NSEvent.ModifierFlags = []

    /// 当前修饰键手势中是否有普通键 keyDown 已被消费（用于抑制修饰键松手重复触发）
    private var keyDownConsumedInGesture = false

    // MARK: - 外部回调

    /// 录制保存前检测到冲突时回调。
    var onConflict: ((ShortcutConflict, KeyboardShortcut, FeatureID, @escaping (Bool) -> Void) -> Void)?

    // MARK: - 生命周期

    func startListening() {
        createEventTap()

        if !tapAvailable {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleNSEventTrigger(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isRecording, self.tapAvailable {
                return event
            }
            if self.isRecording, !self.tapAvailable {
                self.handleNSEventRecording(event)
                return nil
            }
            if self.handleNSEventTrigger(event) {
                return nil
            }
            return event
        }

        // 用户去系统设置授权辅助功能后返回 app，自动重建 tap（带重试，对抗 TCC 延迟）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tryRecreateTapWithRetry),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// 带重试的 tap 恢复：TCC 权限传播有延迟，didBecomeActive 时 AXIsProcessTrusted 可能尚未更新
    @objc private func tryRecreateTapWithRetry() {
        attemptRecreateTap(retryCount: 0)
    }

    private func attemptRecreateTap(retryCount: Int) {
        guard !tapAvailable else { return }
        if AXIsProcessTrusted() {
            createEventTap()
            if tapAvailable, let m = globalMonitor {
                NSEvent.removeMonitor(m)
                globalMonitor = nil
            }
            return
        }
        guard retryCount < 5 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.attemptRecreateTap(retryCount: retryCount + 1)
        }
    }

    // MARK: - CGEvent Tap

    private func createEventTap() {
        destroyEventTap()

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                return mgr.handleTap(event, type: type) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            tapAvailable = false
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapRunLoopSource = source
        tapAvailable = true
    }

    private func destroyEventTap() {
        if let source = tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            tapRunLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        // 不在这里改 tapAvailable，防止 didSet 触发通知时状态不一致
    }

    /// tap 回调入口：严格按事件类型分流
    private func handleTap(_ event: CGEvent, type: CGEventType) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // tap 被系统禁用（主线程 runloop 阻塞超时，如退出系统应用时同步保存）
            // 必须重新启用，否则快捷键永久失效直到应用重启
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        case .keyDown:
            return handleTapKeyDown(event)
        case .flagsChanged:
            return handleTapFlagsChanged(event)
        default:
            return false
        }
    }

    // MARK: - 路径 A：keyDown（普通组合键）

    private func handleTapKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let nsMods = event.flags.toNSEventModifiers.intersection(.deviceIndependentFlagsMask)

        if isRecording {
            guard !modifierKeyCodes.contains(keyCode) else { return false }
            pendingKeyCode = keyCode
            pendingModifiers = nsMods
            finishRecording()
            return true
        }

        if ShortcutRegistry.shared.dispatchKeyDown(keyCode: keyCode, modifiers: nsMods) {
            keyDownConsumedInGesture = true
            return true
        }
        return false
    }

    // MARK: - 路径 B：flagsChanged（纯修饰键组合）

    private func handleTapFlagsChanged(_ event: CGEvent) -> Bool {
        let nsMods = event.flags.toNSEventModifiers.intersection(.deviceIndependentFlagsMask)

        if isRecording {
            if !nsMods.isEmpty {
                pendingModifiers.formUnion(nsMods)
                return false
            }
            guard !pendingModifiers.isEmpty else { return false }
            guard pendingKeyCode == nil else {
                pendingKeyCode = nil
                pendingModifiers = []
                return false
            }
            finishRecording()
            return true
        }

        // ── 正常模式修饰键跟踪 ──
        if !nsMods.isEmpty {
            if normalModifierPeak.isEmpty {
                keyDownConsumedInGesture = false // 新手势开始
            }
            normalModifierPeak.formUnion(nsMods)
            return false
        }
        guard !normalModifierPeak.isEmpty else { return false }
        let peak = normalModifierPeak
        normalModifierPeak = []

        // 如果本次手势中已有普通键被消费，不再触发修饰键快捷键
        if keyDownConsumedInGesture {
            keyDownConsumedInGesture = false
            return false
        }

        return ShortcutRegistry.shared.dispatchModifierOnly(modifiers: peak)
    }

    // MARK: - 统一录制出口（防重入保护）

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false

        // keyCode：Path A 用实际 keyCode，Path B（修饰键组合）用 UInt16.max 哨兵避免与 A 键(0) 冲突
        let keyCode: UInt16
        if let pending = pendingKeyCode {
            keyCode = pending
        } else {
            keyCode = .max
        }

        let modifiers = pendingModifiers
        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        let featureID = recordingFeatureID
        let completion = recordingCompletion

        pendingKeyCode = nil
        pendingModifiers = []
        recordingFeatureID = nil
        recordingCompletion = nil

        guard keyCode != 0 || modifiers.rawValue != 0 else {
            DispatchQueue.main.async { completion?(KeyboardShortcut.empty) }
            return
        }

        if let fid = featureID, let conflict = ShortcutRegistry.shared.findConflict(for: shortcut, excluding: fid) {
            DispatchQueue.main.async {
                self.onConflict?(conflict, shortcut, fid) { [weak self] userApproved in
                    guard let self else { return }
                    if userApproved {
                        self.commitShortcut(shortcut, for: fid, completion: completion)
                    } else {
                        completion?(KeyboardShortcut.empty)
                    }
                }
            }
            return
        }

        commitShortcut(shortcut, for: featureID, completion: completion)
    }

    private func commitShortcut(_ shortcut: KeyboardShortcut, for featureID: FeatureID?,
                                completion: ((KeyboardShortcut) -> Void)?) {
        if let fid = featureID {
            _ = ShortcutRegistry.shared.register(shortcut, for: fid)
            persistShortcut(shortcut, for: fid)
        }

        DispatchQueue.main.async {
            completion?(shortcut)
        }
    }

    // MARK: - 持久化

    private func persistShortcut(_ shortcut: KeyboardShortcut, for feature: FeatureID) {
        let key = userDefaultsKey(for: feature)
        UserDefaults.standard.set(
            ["keyCode": Int(shortcut.keyCode), "modifiers": shortcut.modifierFlags] as [String: Any],
            forKey: key
        )
    }

    private func removePersistedShortcut(for feature: FeatureID) {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey(for: feature))
    }

    func userDefaultsKey(for feature: FeatureID) -> String {
        switch feature {
        case .minimizeAll:      return "shortcut_all"
        case .minimizeOthers:   return "shortcut_others"
        case .dockQuit:         return "shortcut_dock_quit"
        case .moveWindow:       return "shortcut_move_window"
        case .windowLayout:     return ""
        }
    }

    func loadShortcut(for feature: FeatureID) -> KeyboardShortcut? {
        let key = userDefaultsKey(for: feature)
        guard key.isEmpty == false,
              let dict = UserDefaults.standard.dictionary(forKey: key),
              let savedCode = dict["keyCode"] as? Int,
              let savedMods = dict["modifiers"] as? UInt else { return nil }
        let maskedMods = NSEvent.ModifierFlags(rawValue: savedMods)
            .intersection(.deviceIndependentFlagsMask)
        let shortcut = KeyboardShortcut(keyCode: UInt16(savedCode),
                                        modifiers: maskedMods)
        _ = ShortcutRegistry.shared.register(shortcut, for: feature)
        return shortcut
    }

    func clearShortcut(for feature: FeatureID) {
        ShortcutRegistry.shared.unregister(feature)
        removePersistedShortcut(for: feature)
    }

    // MARK: - 录制 API

    func startRecording(for feature: FeatureID, completion: @escaping (KeyboardShortcut) -> Void) {
        cancelRecording()
        isRecording = true
        recordingFeatureID = feature
        recordingCompletion = completion
        pendingKeyCode = nil
        pendingModifiers = []
    }

    func startRecording(completion: @escaping (KeyboardShortcut) -> Void) {
        cancelRecording()
        isRecording = true
        recordingFeatureID = nil
        recordingCompletion = completion
        pendingKeyCode = nil
        pendingModifiers = []
    }

    func cancelRecording() {
        isRecording = false
        recordingFeatureID = nil
        recordingCompletion = nil
        pendingKeyCode = nil
        pendingModifiers = []
    }

    // MARK: - NSEvent 降级路径

    private func handleNSEventRecording(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        guard !modifierKeyCodes.contains(keyCode) else { return }

        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        let fid = recordingFeatureID
        let completion = recordingCompletion
        isRecording = false
        recordingFeatureID = nil
        recordingCompletion = nil

        if let featureID = fid, let conflict = ShortcutRegistry.shared.findConflict(for: shortcut, excluding: featureID) {
            DispatchQueue.main.async {
                self.onConflict?(conflict, shortcut, featureID) { [weak self] userApproved in
                    if userApproved {
                        self?.commitShortcut(shortcut, for: featureID, completion: completion)
                    } else {
                        completion?(KeyboardShortcut.empty)
                    }
                }
            }
            return
        }

        commitShortcut(shortcut, for: fid, completion: completion)
    }

    @discardableResult
    private func handleNSEventTrigger(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return ShortcutRegistry.shared.dispatchKeyDown(keyCode: event.keyCode, modifiers: modifiers)
    }
}
