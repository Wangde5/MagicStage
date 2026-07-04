import SwiftUI
import ServiceManagement
import Sparkle

// MARK: - 系统设置页面

struct SystemSettingsView: View {
    @AppStorage("enableHaptic") var enableHaptic = true
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @ObservedObject var updater = UpdaterService.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                // Header
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
                    Text("系统设置")
                        .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
                }

                // 通用设置
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("通用")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "执行最小化时触控板震动") {
                            Toggle("", isOn: $enableHaptic)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        SettingsDivider()

                        SettingsRow(title: "登录 macOS 时自动启动") {
                            Toggle("", isOn: Binding(
                                get: { self.launchAtLogin },
                                set: { newValue in
                                    self.launchAtLogin = newValue
                                    setLaunchAtLogin(enabled: newValue)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }
                }

                // 更新
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("更新")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "自动检查更新") {
                            Toggle("", isOn: Binding(
                                get: { updater.automaticallyChecksForUpdates },
                                set: { _ in updater.toggleAutomaticChecks() }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }

                        SettingsDivider()

                        SettingsRow(title: "检查更新") {
                            Button("检查更新") {
                                updater.checkForUpdates()
                            }
                            .disabled(!updater.canCheckForUpdates)
                        }
                    }
                }

                Spacer()
            }
            .padding(UIConfig.SettingsPage.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let appService = SMAppService.mainApp
            do {
                if enabled {
                    if appService.status != .enabled { try appService.register() }
                } else {
                    if appService.status == .enabled { try appService.unregister() }
                }
            } catch { print("自启设置失败") }
        }
    }
}
