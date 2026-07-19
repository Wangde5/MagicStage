import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let accessibilityPermissionDidChange = Notification.Name("accessibilityPermissionDidChange")
}

@MainActor
final class AccessibilityPermissionCoordinator: ObservableObject {
    static let shared = AccessibilityPermissionCoordinator()

    enum PanelPage {
        case welcome
        case permissions
    }

    @Published private(set) var isGranted: Bool
    @Published private(set) var screenRecordingGranted: Bool
    @Published fileprivate var panelPage: PanelPage = .permissions

    private enum Keys {
        static let hasPresentedOnboarding = "accessibilityPermissionOnboardingPresented"
        static let wasPreviouslyGranted = "accessibilityPermissionWasPreviouslyGranted"
        static let lastRecoveryPromptVersion = "accessibilityPermissionLastRecoveryPromptVersion"
    }

    // 两个步骤共享同一尺寸；权限页只改变位置，不会在步骤切换时突然缩放。
    private let panelContentSize = NSSize(width: 370, height: 520)
    private var statusPanel: NSPanel?

    private init() {
        isGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// 从系统设置返回后重新读取 TCC；绝不依赖启动时缓存的权限状态。
    @discardableResult
    func refresh() -> Bool {
        let accessibilityValue = AXIsProcessTrusted()
        let screenRecordingValue = CGPreflightScreenCaptureAccess()
        if isGranted != accessibilityValue {
            isGranted = accessibilityValue
            NotificationCenter.default.post(name: .accessibilityPermissionDidChange, object: accessibilityValue)
        }
        if screenRecordingGranted != screenRecordingValue {
            screenRecordingGranted = screenRecordingValue
        }
        if accessibilityValue {
            UserDefaults.standard.set(true, forKey: Keys.wasPreviouslyGranted)
        }
        return accessibilityValue
    }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 首次安装进入欢迎页。曾授权但更新后 TCC 丢失时，每个版本最多补一次引导。
    func presentOnboardingIfNeeded() {
        guard !refresh() else { return }
        let defaults = UserDefaults.standard
        let isFirstPresentation = !defaults.bool(forKey: Keys.hasPresentedOnboarding)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let needsRecoveryPresentation = defaults.bool(forKey: Keys.wasPreviouslyGranted)
            && defaults.string(forKey: Keys.lastRecoveryPromptVersion) != version
        guard isFirstPresentation || needsRecoveryPresentation else { return }

        defaults.set(true, forKey: Keys.hasPresentedOnboarding)
        if needsRecoveryPresentation {
            defaults.set(version, forKey: Keys.lastRecoveryPromptVersion)
        }
        showWelcomePanel()
    }

    /// 系统设置的入口直接打开权限页。
    func showStatusPanel() {
        showPanel(.permissions)
    }

    func showWelcomePanel() {
        showPanel(.welcome)
    }

    func showPermissionsPage() {
        showPanel(.permissions)
    }

    private func showPanel(_ page: PanelPage) {
        refresh()
        let previousPage = panelPage
        panelPage = page
        let panel: NSPanel
        let wasVisible: Bool
        if let statusPanel {
            panel = statusPanel
            wasVisible = panel.isVisible
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelContentSize),
                styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: PermissionFlowView(coordinator: self))
            statusPanel = panel
            wasVisible = false
        }

        panel.setContentSize(panelContentSize)
        let targetFrame = targetFrame(for: page, panel: panel)
        let shouldAnimate = wasVisible && previousPage != page
        if shouldAnimate {
            // 欢迎页进入权限页时采用较从容的曲线位移，给用户足够时间感知步骤切换。
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.82
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.24, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func targetFrame(for page: PanelPage, panel: NSPanel) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? panel.screen ?? NSScreen.main
        guard let screen else { return panel.frame }

        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let originY = visibleFrame.midY - size.height / 2
        switch page {
        case .welcome:
            return NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: originY,
                width: size.width,
                height: size.height
            )
        case .permissions:
            // 左侧留出安全边距，使右侧的系统设置和右上角的系统提示完全可见。
            return NSRect(
                x: visibleFrame.minX + 30,
                y: originY,
                width: size.width,
                height: size.height
            )
        }
    }

    func dismissStatusPanel() {
        statusPanel?.orderOut(nil)
    }
}

private struct PermissionFlowView: View {
    @ObservedObject var coordinator: AccessibilityPermissionCoordinator

    var body: some View {
        Group {
            switch coordinator.panelPage {
            case .welcome:
                WelcomePermissionView(coordinator: coordinator)
            case .permissions:
                PermissionsStatusView(coordinator: coordinator)
            }
        }
        .frame(width: 370, height: 520)
        .background(.regularMaterial)
    }
}

private struct WelcomePermissionView: View {
    @ObservedObject var coordinator: AccessibilityPermissionCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 38)

            Group {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "sparkles")
                        .resizable()
                        .scaledToFit()
                        .padding(17)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .frame(width: 154, height: 154)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            VStack(spacing: 10) {
                Text("欢迎使用 MagicStage")
                    .font(.system(size: 25, weight: .bold))
                Text("让窗口整理、分屏与快捷操作更自然。")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            Spacer()

            HStack {
                Spacer()
                Button("继续") {
                    coordinator.showPermissionsPage()
                }
                .buttonStyle(MonochromeCapsuleButtonStyle())
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }
}

private struct PermissionsStatusView: View {
    @ObservedObject var coordinator: AccessibilityPermissionCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 44)

            Text("完成权限设置")
                .font(.system(size: 25, weight: .bold))
            Text("MagicStage 需要以下系统权限来提供完整体验")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "hand.raised.fill",
                    title: "辅助功能权限",
                    detail: "用于快捷键、窗口管理和 Dock 交互",
                    isGranted: coordinator.isGranted,
                    action: coordinator.requestAccessibilityAccess
                )
                permissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "屏幕录制权限",
                    detail: "用于生成窗口预览缩略图（可选）",
                    isGranted: coordinator.screenRecordingGranted,
                    action: coordinator.requestScreenRecordingAccess
                )
            }
            .padding(.top, 21)
            .padding(.horizontal, 20)

            Button {
                _ = coordinator.refresh()
            } label: {
                Label("重新检查权限", systemImage: "arrow.clockwise")
            }
            .buttonStyle(MonochromeCapsuleOutlineStyle())
            .padding(.top, 15)

            Spacer(minLength: 18)

            HStack {
                Button("返回") {
                    coordinator.showWelcomePanel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button(coordinator.isGranted ? "完成" : "稍后设置") {
                    coordinator.dismissStatusPanel()
                }
                .buttonStyle(MonochromeCapsuleButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(isGranted ? .green : .primary.opacity(0.72))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button("授权", action: action)
                    .buttonStyle(MonochromeCapsuleButtonStyle())
            }
        }
        .padding(.horizontal, 17)
        .frame(height: 78)
        // 授权状态由绿色图标和勾号表达；卡片本身交给系统玻璃绘制，避免
        // 自定义白色高光边框在深色模式里显得突兀。
        .modifier(AccessibilityGlassCardModifier())
    }
}

private struct MonochromeCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 17)
            .padding(.vertical, 8)
            .modifier(AccessibilityGlassCapsuleModifier())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct MonochromeCapsuleOutlineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .modifier(AccessibilityGlassCapsuleModifier())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// 统一使用系统原生玻璃，避免权限页按钮叠加自定义的高光边框。
private struct AccessibilityGlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Color.primary.opacity(0.08), in: Capsule())
        }
    }
}

private struct AccessibilityGlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else {
            content.background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }
}
