import SwiftUI

// MARK: - 设置类别

enum SettingsCategory: String, CaseIterable, Identifiable {
    case windowManagement = "窗口管理"
    case windowMinimize = "窗口最小化"
    case windowPreview = "窗口预览"
    case fileDrawer = "文件抽屉"
    case dockQuit = "Dock 退出"
    case hapticFeedback = "触控反馈"
    case systemSettings = "系统设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .windowManagement: return "macwindow"
        case .windowMinimize: return "arrow.down.right.and.arrow.up.left"
        case .windowPreview: return "rectangle.3.group"
        case .fileDrawer: return "tray.full"
        case .dockQuit: return "xmark.square"
        case .hapticFeedback: return "hand.point.up"
        case .systemSettings: return "gearshape"
        }
    }

    /// 是否需要在此分类前增加间距（用于视觉分组，功能性 vs 设置性）
    var hasTopSpacing: Bool {
        self == .hapticFeedback
    }
}

// MARK: - 主内容视图

struct ContentView: View {
    @EnvironmentObject var windowService: WindowManagementService
    @State private var selectedCategory: SettingsCategory = .windowManagement
    @State private var hoveredCategory: SettingsCategory? = nil
    @State private var tapUnavailable = false

    var body: some View {
        HStack(spacing: UIConfig.sidebarContentSpacing) {
            // 侧边栏
            sidebarView
                .frame(width: UIConfig.Sidebar.width)
                .background(HudWindowBackground())

            // 主体内容区域
            VStack(spacing: 0) {
                // 降级模式提示
                if tapUnavailable {
                    degradationBanner
                }

                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            tapUnavailable = !HotkeyManager.shared.tapAvailable
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyTapAvailabilityChanged)) { notification in
            if let unavailable = notification.object as? Bool {
                tapUnavailable = unavailable
            }
        }
    }

    // MARK: - 降级模式横幅

    private var degradationBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: UIConfig.Typography.degradationIconSize))
                .foregroundStyle(.orange)
            Text("当前处于兼容模式，不支持纯修饰键快捷键和系统保留组合键录制。请在「系统设置 > 隐私与安全性 > 辅助功能」中授权 MagicStage 以获得完整体验。")
                .font(.system(size: UIConfig.Typography.degradationTextSize))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, UIConfig.SettingsPage.degradationBannerHPadding)
        .padding(.vertical, UIConfig.SettingsPage.degradationBannerVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UIConfig.ColorTokens.degradationBackground)
    }

    // MARK: - 侧边栏

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: UIConfig.Sidebar.navItemSpacing) {
            // 顶部留白
            Color.clear.frame(height: UIConfig.Sidebar.navTopPadding)

            // 导航菜单
            ForEach(SettingsCategory.allCases) { category in
                if category.hasTopSpacing {
                    Color.clear.frame(height: 16)
                }
                categoryButton(for: category)
            }

            Spacer()

            // 品牌区（侧边栏底部）
            HStack(spacing: UIConfig.Sidebar.brandIconTextSpacing) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: UIConfig.Typography.brandIconSize,
                               height: UIConfig.Typography.brandIconSize)
                }
                Text("MagicStage")
                    .font(.system(size: UIConfig.Typography.brandTitleSize, weight: .bold))
            }
            .padding(.horizontal, UIConfig.Sidebar.brandHorizontalPadding)
            .padding(.bottom, UIConfig.Sidebar.brandBottomPadding)
        }
    }

    private func categoryButton(for category: SettingsCategory) -> some View {
        let isSelected = selectedCategory == category
        let isHovered = hoveredCategory == category && !isSelected
        return Button(action: {
            selectedCategory = category
        }) {
            HStack(spacing: UIConfig.Sidebar.navIconTextSpacing) {
                Image(systemName: category.icon)
                    .font(.system(size: UIConfig.Typography.navIconSize, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: UIConfig.Typography.navIconSize + UIConfig.navIconFrameExtraWidth)

                Text(category.rawValue)
                    .font(.system(size: UIConfig.Typography.navLabelSize,
                                  weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, UIConfig.Sidebar.navInnerHorizontalPadding)
            .padding(.vertical, UIConfig.Sidebar.navInnerVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: UIConfig.Sidebar.navCornerRadius, style: .continuous)
                    .fill(isSelected
                        ? Color.primary.opacity(UIConfig.Sidebar.navSelectedBgOpacity)
                        : (isHovered ? Color.primary.opacity(UIConfig.Sidebar.navHoverBgOpacity) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIConfig.Sidebar.navCornerRadius, style: .continuous)
                    .stroke(isSelected
                        ? Color.primary.opacity(UIConfig.Sidebar.navSelectedBorderOpacity)
                        : Color.clear,
                        lineWidth: UIConfig.Sidebar.navSelectedBorderWidth)
            )
            .padding(.horizontal, UIConfig.Sidebar.navOuterHorizontalPadding)
            .padding(.vertical, UIConfig.Sidebar.navOuterVerticalPadding)
            .contentShape(RoundedRectangle(cornerRadius: UIConfig.Sidebar.navCornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: UIConfig.Animation.hoverDuration)) {
                hoveredCategory = hovering ? category : nil
            }
        }
    }

    // MARK: - 内容区域（纯淡化过渡）

    private var contentArea: some View {
        ZStack {
            WindowManagementSettingsView()
                .environmentObject(windowService)
                .opacity(selectedCategory == .windowManagement ? 1 : 0)

            WindowMinimizeSettingsView()
                .opacity(selectedCategory == .windowMinimize ? 1 : 0)

            WindowPreviewSettingsView()
                .opacity(selectedCategory == .windowPreview ? 1 : 0)

            FileDrawerSettingsView()
                .opacity(selectedCategory == .fileDrawer ? 1 : 0)

            DockHoverQuitSettingsView()
                .opacity(selectedCategory == .dockQuit ? 1 : 0)

            HapticFeedbackSettingsView()
                .opacity(selectedCategory == .hapticFeedback ? 1 : 0)

            SystemSettingsView()
                .opacity(selectedCategory == .systemSettings ? 1 : 0)
        }
        .animation(.easeInOut(duration: UIConfig.Animation.contentTransitionDuration), value: selectedCategory)
    }
}
