import SwiftUI
import ServiceManagement

// MARK: - 系统设置页面

struct SystemSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @ObservedObject var updater = UpdaterService.shared
    @ObservedObject private var accessibilityPermission = AccessibilityPermissionCoordinator.shared

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh-Hans")
        f.dateFormat = "yyyy 年 M 月 d 日 HH:mm"
        return f
    }()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                headerView

                generalSection
                permissionsSection
                updateSection

                Spacer()
            }
            .padding(UIConfig.SettingsPage.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            refreshLaunchAtLoginStatus()
            _ = accessibilityPermission.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            _ = accessibilityPermission.refresh()
        }
        .alert("无法更改登录启动设置", isPresented: Binding(
            get: { launchAtLoginError != nil },
            set: { if !$0 { launchAtLoginError = nil } }
        )) {
            Button("确定", role: .cancel) { launchAtLoginError = nil }
        } message: {
            Text(launchAtLoginError ?? "请稍后重试。")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
            Text("系统设置")
                .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
            Text("通用")
                .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

            SettingsCard {
                SettingsRow(title: "登录 macOS 时自动启动") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            setLaunchAtLogin(enabled: newValue)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - 权限

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
            Text("权限")
                .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

            SettingsCard {
                HStack(spacing: 10) {
                    Circle()
                        .fill(accessibilityPermission.isGranted ? Color.green : Color.secondary.opacity(0.32))
                        .frame(width: 9, height: 9)
                        .shadow(color: accessibilityPermission.isGranted ? .green.opacity(0.55) : .clear, radius: 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("检查辅助功能权限")
                            .font(.system(size: UIConfig.Typography.settingsRowTitleSize))
                        Text(accessibilityPermission.isGranted ? "已启用，相关功能正在运行" : "未启用，部分全局功能无法使用")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("检查") {
                        accessibilityPermission.showStatusPanel()
                    }
                    .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .medium))
                }
                .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
                .frame(height: 52)
            }
        }
    }

    // MARK: - 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
            Text("更新")
                .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

            SettingsCard {
                // 当前版本
                versionRow
                SettingsDivider()
                // 检查更新
                checkRow
                SettingsDivider()
                // 自动更新
                autoUpdateRow
            }
        }
    }

    private var versionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("当前版本")
                    .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                    .foregroundColor(.primary)
                Text("版本：\(updater.currentVersion)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if updater.updateCheckFailed {
                Text("网络错误")
                    .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                    .foregroundColor(.red)
            } else if let available = updater.updateAvailable {
                if available {
                    Text("有新版本可用")
                        .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .medium))
                        .foregroundColor(.orange)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text("已是最新版本")
                            .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("正在检查…")
                    .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
        .frame(height: 44)
    }

    private var checkRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("检查更新")
                    .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                    .foregroundColor(.primary)
                if let date = updater.lastUpdateCheckDate {
                    Text("上次检查：\(dateFormatter.string(from: date))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("立即检查") {
                updater.checkForUpdates()
            }
            .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .medium))
            .disabled(!updater.canCheckForUpdates)
        }
        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
        .frame(height: 44)
    }

    private var autoUpdateRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("自动更新")
                    .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                    .foregroundColor(.primary)
                Text("在后台自动检查更新")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { _ in updater.toggleAutomaticChecks() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
        .frame(height: 44)
    }

    // MARK: - 登录自启

    private func setLaunchAtLogin(enabled: Bool) {
        let appService = SMAppService.mainApp
        do {
            if enabled {
                if appService.status != .enabled { try appService.register() }
            } else if appService.status == .enabled || appService.status == .requiresApproval {
                try appService.unregister()
            }
            refreshLaunchAtLoginStatus()
            if enabled, appService.status != .enabled {
                launchAtLoginError = "macOS 尚未允许 MagicStage 登录时启动，请在“系统设置 > 通用 > 登录项”中确认。"
            }
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginError = error.localizedDescription
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
