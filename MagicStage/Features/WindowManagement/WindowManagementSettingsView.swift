import SwiftUI

// MARK: - 窗口管理设置页面

struct WindowManagementSettingsView: View {
    @EnvironmentObject var service: WindowManagementService
    @ObservedObject var dragSplit = DragSplitService.shared

    private let columns = [
        GridItem(.flexible(), spacing: UIConfig.LayoutCard.columnSpacing),
        GridItem(.flexible(), spacing: UIConfig.LayoutCard.columnSpacing)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                headerView

                dragSplitSection

                ForEach(LayoutCategory.allCases, id: \.self) { category in
                    layoutSection(category: category)
                }

                if !service.accessibilityGranted {
                    HStack(spacing: UIConfig.SettingsPage.warningSpacing) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: UIConfig.Typography.warningIconSize))
                            .foregroundStyle(.orange)
                        Text("需要辅助功能权限才能响应快捷键")
                            .font(.system(size: UIConfig.Typography.warningTextSize))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, UIConfig.SettingsPage.warningTopPadding)
                }

                Spacer()
            }
            .padding(UIConfig.SettingsPage.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if service.isRecording {
                service.cancelShortcutRecording()
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
            Text("窗口管理")
                .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
        }
    }

    // MARK: - 拖拽分屏开关

    private var dragSplitSection: some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
            Text("分屏")
                .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

            SettingsCard {
                HStack {
                    Text("拖拽分屏")
                        .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                        .foregroundColor(.primary)

                    Spacer()

                    Toggle("", isOn: $dragSplit.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
                .frame(height: UIConfig.SettingsRow.rowHeight)

                Divider()
                    .padding(.horizontal, UIConfig.SettingsPage.dividerHorizontalPadding)

                HStack {
                    Text("分屏后拖动恢复尺寸")
                        .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                        .foregroundColor(.primary)

                    Spacer()

                    Toggle("", isOn: $dragSplit.dragSplitRestoreEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
                .frame(height: UIConfig.SettingsRow.rowHeight)
            }
        }
    }

    // MARK: - Section

    private func layoutSection(category: LayoutCategory) -> some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
            Text(category.displayName)
                .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

            SettingsCard {
                LazyVGrid(
                    columns: columns,
                    spacing: UIConfig.LayoutCard.rowSpacing
                ) {
                    ForEach(category.layouts, id: \.self) { layout in
                        layoutCell(layout)
                    }
                }
                .padding(UIConfig.LayoutCard.sectionPadding)
            }
        }
    }

    // MARK: - Cell

    private func layoutCell(_ layout: WindowLayout) -> some View {
        let config = service.layoutConfigs[layout] ?? LayoutConfig(shortcut: KeyboardShortcut.empty, enabled: true)
        let isRecording = service.recordingLayout == layout

        return HStack(spacing: UIConfig.LayoutCard.iconTrailingSpacing) {
            LayoutPreviewIcon(layout: layout)
                .frame(width: UIConfig.LayoutCard.iconWidth,
                       height: UIConfig.LayoutCard.iconHeight)

            VStack(alignment: .leading, spacing: UIConfig.LayoutCard.labelToRecorderSpacing) {
                Text(layout.displayName)
                    .font(.system(size: UIConfig.LayoutCard.labelFontSize, weight: .medium))
                    .foregroundColor(.primary)

                ShortcutRecorderView(
                    shortcut: config.shortcut,
                    isRecording: isRecording,
                    isEnabled: true,
                    onRecord: { service.recordShortcut(for: layout) },
                    onClear: { service.clearShortcut(for: layout) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 布局预览图标（精致版）

struct LayoutPreviewIcon: View {
    let layout: WindowLayout

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = layout.previewRect(in: size)

            ZStack(alignment: .topLeading) {
                // 屏幕外框 - 控件背景色
                RoundedRectangle(cornerRadius: UIConfig.ShortcutRecorder.cornerRadius, style: .continuous)
                    .fill(UIConfig.ColorTokens.backgroundControl)
                // 窗口色块 - HUD 风格（自适应亮暗模式）
                RoundedRectangle(cornerRadius: UIConfig.ShortcutRecorder.cornerRadius - UIConfig.LayoutCard.previewCornerRadiusOffset, style: .continuous)
                    .fill(Color.primary.opacity(UIConfig.ColorTokens.layoutPreviewWindowOpacity))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.origin.x, y: rect.origin.y)
            }
        }
        .accessibilityLabel(layout.displayName)
    }
}
