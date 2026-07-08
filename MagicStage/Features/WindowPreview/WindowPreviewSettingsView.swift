import SwiftUI

// MARK: - 滑块行（标题左 / 滑块撑满 / 值右）

/// 自定义 Slider 行：标题左对齐固定宽度，Slider 在中间撑满剩余空间，最小/最大/当前值在右侧。
/// 不复用 SettingsRow（SettingsRow 内 Spacer 把内容推到最右，Slider 无法撑满）。
private struct SliderSettingsRow<V: BinaryFloatingPoint & Strideable>: View
    where V.Stride: BinaryFloatingPoint {
    let title: String
    let minimumLabel: String
    let maximumLabel: String
    let valueLabel: String
    let value: Binding<V>
    let range: ClosedRange<V>
    let step: V.Stride?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 110, alignment: .leading)

            Text(minimumLabel)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .leading)

            Group {
                if let step = step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
            }
            .frame(maxWidth: .infinity)

            Text(maximumLabel)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .trailing)

            Text(valueLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
        .frame(height: UIConfig.SettingsRow.rowHeight)
    }
}

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
                        if #available(macOS 26.0, *) {
                            SettingsRow(title: "液态玻璃材质") {
                                Toggle("", isOn: $service.useLiquidGlass.animation(springAnim))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }

                            SettingsDivider()
                        }

                        SliderSettingsRow(
                            title: "缩略图大小",
                            minimumLabel: "160",
                            maximumLabel: "400",
                            valueLabel: "\(Int(service.customCardWidth))",
                            value: $service.customCardWidth,
                            range: 160...400,
                            step: 10
                        )

                        SettingsDivider()

                        SliderSettingsRow(
                            title: "卡片间距",
                            minimumLabel: "8",
                            maximumLabel: "32",
                            valueLabel: "\(Int(service.cardSpacing))",
                            value: $service.cardSpacing,
                            range: 8...32,
                            step: 2
                        )

                        SettingsDivider()

                        SliderSettingsRow(
                            title: "关闭按钮",
                            minimumLabel: "12",
                            maximumLabel: "20",
                            valueLabel: "\(Int(service.closeButtonSize))",
                            value: $service.closeButtonSize,
                            range: 12...20,
                            step: 1
                        )

                        SettingsDivider()

                        SliderSettingsRow(
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
                        SliderSettingsRow(
                            title: "悬停触发延迟",
                            minimumLabel: "0s",
                            maximumLabel: "1s",
                            valueLabel: String(format: "%.2fs", service.triggerDelay),
                            value: $service.triggerDelay,
                            range: 0...1,
                            step: 0.05
                        )

                        SettingsDivider()

                        SliderSettingsRow(
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
