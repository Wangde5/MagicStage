import SwiftUI

// MARK: - 窗口预览设置页面

struct WindowPreviewSettingsView: View {
    @ObservedObject var service = WindowPreviewService.shared

    private var springAnim: Animation {
        .spring(response: UIConfig.Animation.toggleSpringResponse,
                dampingFraction: UIConfig.Animation.toggleSpringDamping)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                // Header
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
                    Text("窗口预览")
                        .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
                }

                // 功能开关
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("功能")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "启用窗口预览") {
                            Toggle("", isOn: $service.isEnabled.animation(springAnim))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }

                // 权限检查提示
                if service.isEnabled && !AXIsProcessTrusted() {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 11))
                            Text("需要辅助功能权限才能使用窗口预览功能")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                }

                // 预览外观
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("预览外观")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "通透液态玻璃") {
                            Toggle("", isOn: $service.useLiquidGlass.animation(springAnim))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        SettingsDivider()

                        SettingsSliderRow(
                            title: "缩略图大小",
                            minimumLabel: "160",
                            maximumLabel: "400",
                            valueLabel: "\(Int(service.customCardWidth))",
                            value: $service.customCardWidth,
                            range: 160...400,
                            step: 10
                        )

                        SettingsDivider()

                        SettingsSliderRow(
                            title: "卡片间距",
                            minimumLabel: "8",
                            maximumLabel: "32",
                            valueLabel: "\(Int(service.cardSpacing))",
                            value: $service.cardSpacing,
                            range: 8...32,
                            step: 2
                        )

                        SettingsDivider()

                        SettingsSliderRow(
                            title: "关闭按钮",
                            minimumLabel: "12",
                            maximumLabel: "20",
                            valueLabel: "\(Int(service.closeButtonSize))",
                            value: $service.closeButtonSize,
                            range: 12...20,
                            step: 1
                        )

                        SettingsDivider()

                        SettingsSliderRow(
                            title: "Dock 间距",
                            minimumLabel: "0",
                            maximumLabel: "40",
                            valueLabel: "\(Int(service.dockOffset))",
                            value: $service.dockOffset,
                            range: 0...40,
                            step: nil
                        )
                    }
                }

                // 触发与消失
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("触发与消失")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsSliderRow(
                            title: "悬停触发延迟",
                            minimumLabel: "0s",
                            maximumLabel: "1s",
                            valueLabel: String(format: "%.2fs", service.triggerDelay),
                            value: $service.triggerDelay,
                            range: 0...1,
                            step: 0.05
                        )

                        SettingsDivider()

                        SettingsSliderRow(
                            title: "离开后消失延迟",
                            minimumLabel: "0.1s",
                            maximumLabel: "1s",
                            valueLabel: String(format: "%.2fs", service.dismissDelay),
                            value: $service.dismissDelay,
                            range: 0.1...1,
                            step: 0.05
                        )
                    }
                }

                Spacer()
            }
            .padding(UIConfig.SettingsPage.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
