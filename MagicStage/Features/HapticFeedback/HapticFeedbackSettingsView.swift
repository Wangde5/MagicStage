import SwiftUI

// MARK: - 触控反馈设置页面

struct HapticFeedbackSettingsView: View {
    @ObservedObject var dragSplit = DragSplitService.shared
    @ObservedObject var windowPreview = WindowPreviewService.shared
    @ObservedObject var dockQuit = DockHoverQuitService.shared
    @AppStorage("enableHaptic") var enableMinimizeHaptic = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                headerView

                SettingsCard {
                    SettingsRow(title: "拖拽分屏震动") {
                        Toggle("", isOn: $dragSplit.enableDragSplitHaptic)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsDivider()

                    SettingsRow(title: "窗口预览弹出震动") {
                        Toggle("", isOn: $windowPreview.enablePreviewHaptic)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsDivider()

                    SettingsRow(title: "窗口最小化震动") {
                        Toggle("", isOn: $enableMinimizeHaptic)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsDivider()

                    SettingsRow(title: "Dock 退出震动") {
                        Toggle("", isOn: $dockQuit.enableHapticFeedback)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                Spacer()
            }
            .padding(UIConfig.SettingsPage.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
            Text("触控反馈")
                .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
        }
    }
}
