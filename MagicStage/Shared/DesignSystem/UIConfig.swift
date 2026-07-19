import Foundation
import SwiftUI
import AppKit

// MARK: - UI 参数配置文件
//
//  所有可调节的 UI 参数集中管理在此文件中。
//  修改任意数值后重新编译即可看到效果，无需改动业务代码。
//
//  注意事项：
//  - 所有尺寸单位为 CGFloat（点），时间单位为秒
//  - 动画参数（spring response / dampingFraction）需配对调整
//  - 标注为 "视觉联动" 的参数与其他参数存在视觉对齐关系，修改时需同步检查
//  - 标注为 "谨慎修改" 的参数改动过大可能导致布局溢出或动画异常

enum UIConfig {

    // MARK: ── 窗口 ───────────────────────────────
    // 偏好设置窗口尺寸（AppDelegate 中创建）
    enum Window {
        /// 窗口宽度（点）
        static let width: CGFloat = 680
        /// 窗口高度（点）
        static let height: CGFloat = 480
        /// 居中后将窗口向下偏移量（点）
        static let centerYOffset: CGFloat = 80
    }

    // MARK: ── 圆角 ───────────────────────────────
    // 所有圆角集中管理，仅 2 个规格
    enum CornerRadius {
        /// 大圆角：卡片、面板等大容器
        static let large: CGFloat = 10
        /// 面板圆角（DragSplit 专用，比 large 略大）
        static let panel: CGFloat = 12
    }

    // MARK: ── 悬浮交互视觉语言 ───────────────────
    /// Dock 预览、分屏面板和分屏落位反馈共用这一组参数。
    /// 目标是让所有“临时出现的窗口控制界面”像同一套系统，而不是彼此独立的浮层。
    enum FloatingSurface {
        static let cornerRadius: CGFloat = 14
        static let borderWidth: CGFloat = 1
        static let borderOpacity: Double = 0.22
        static let activeFillOpacity: Double = 0.20
        static let inactiveFillOpacity: Double = 0.18
        static let activeBorderOpacity: Double = 0.82
        static let glowOpacity: Float = 0.32
        static let glowRadius: CGFloat = 18
    }

    // MARK: ── Dock 窗口预览 ──────────────────
    /// macOS 26 使用系统 Clear 液态玻璃；旧系统使用视觉材质降级。
    enum WindowPreview {
        static let containerCornerRadius: CGFloat = 18
        static let containerHorizontalPadding: CGFloat = 6
        static let containerVerticalPadding: CGFloat = 6
        static let cardCornerRadius: CGFloat = 17
        static let thumbnailCornerRadius: CGFloat = 7
        static let titleFontSize: CGFloat = 13
        static let hoverScale: CGFloat = 1.018
        static let hoverTravelX: CGFloat = 1.7
        static let hoverTravelY: CGFloat = 1.3

        static func titleBarHeight(closeButtonSize: CGFloat) -> CGFloat {
            closeButtonSize + 5
        }
    }

    // MARK: ── 文件抽屉 ──────────────────────────
    enum FileDrawer {
        static let width: CGFloat = 420
        static let height: CGFloat = 720
        static let cornerRadius: CGFloat = 20
        static let screenInset: CGFloat = 16
        static let headerHeight: CGFloat = 120
        static let tabBarHeight: CGFloat = 50
        static let pathBarHeight: CGFloat = 14
        static let toolbarHeight: CGFloat = 42
        static let sideHotZoneDepth: CGFloat = 56
        static let sideHotZoneLength: CGFloat = 212
        static let cornerHotZoneWidth: CGFloat = 56
        static let cornerHotZoneHeight: CGFloat = 150
        static let peekVisibleDepth: CGFloat = 18
        static let peekSideWidth: CGFloat = 32
        static let peekSideHeight: CGFloat = 88
        static let peekCornerTopOffset: CGFloat = 54
        static let peekCornerRadius: CGFloat = 15
        static let peekActivationInset: CGFloat = 8
        static let peekMinimumDwell: TimeInterval = 0.14
        static let peekDismissDelay: TimeInterval = 0.28
        static let peekShowDuration: TimeInterval = 0.26
        static let peekHideDuration: TimeInterval = 0.18
        static let showDuration: TimeInterval = 0.38
        static let hideDuration: TimeInterval = 0.2
        /// 给系统 Quick Look 的原生缩回动画保留 delegate、来源坐标和窗口层级的时间。
        static let quickLookCloseTransitionDuration: TimeInterval = 0.32
        /// 拖拽取消/失败后，幽灵缩略图回到原位的时长。
        static let ghostThumbnailReturnDuration: TimeInterval = 0.28
        /// 幽灵缩略图只在回位末段从完全不透明淡到透明。
        static let ghostThumbnailFadeDuration: TimeInterval = 0.12
        static let panelExitGrace: TimeInterval = 0.55
        static let defaultPanelExitDelay: TimeInterval = 0.8
        static let contentTransitionDuration: TimeInterval = 0.24
    }

    // MARK: ── 侧边栏 ─────────────────────────────
    enum Sidebar {
        /// 侧边栏宽度（点）
        /// 注意：过窄会导致导航文字截断，过宽会挤压右侧内容区
        static let width: CGFloat = 190

        // 品牌区（App 图标 + 名称）
        /// 品牌区距底部（菜单列表）间距
        static let brandBottomPadding: CGFloat = 28
        /// 品牌区水平内边距
        static let brandHorizontalPadding: CGFloat = 16
        /// 品牌图标与名称间距
        static let brandIconTextSpacing: CGFloat = 5

        // 导航菜单项
        /// 菜单项图标与文字间距
        static let navIconTextSpacing: CGFloat = 12
        /// 菜单项内部水平内边距
        static let navInnerHorizontalPadding: CGFloat = 14
        /// 菜单项内部垂直内边距
        /// 注意：影响每个菜单项的行高，改动后与选中背景圆角视觉联动
        static let navInnerVerticalPadding: CGFloat = 10
        /// 菜单项外部水平间距（与侧边栏边缘的距离）
        static let navOuterHorizontalPadding: CGFloat = 8
        /// 菜单项外部垂直间距（菜单项之间的间距）
        static let navOuterVerticalPadding: CGFloat = 2
        /// 菜单项背景圆角
        static let navCornerRadius: CGFloat = 7
        /// 菜单项选中边框宽度
        static let navSelectedBorderWidth: CGFloat = 0.5
        /// 菜单项选中背景透明度
        static let navSelectedBgOpacity: Double = 0.08
        /// 菜单项选中边框透明度
        static let navSelectedBorderOpacity: Double = 0.06
        /// 菜单项悬停背景透明度
        static let navHoverBgOpacity: Double = 0.04
        /// 导航菜单区顶部间距（与右侧 contentPadding 对齐）
        static let navTopPadding: CGFloat = 60
        /// 导航项之间的垂直间距（VStack spacing，替代 navOuterVerticalPadding）
        static let navItemSpacing: CGFloat = 0
    }

    // MARK: ── 字体 ───────────────────────────────
    enum Typography {
        // 侧边栏
        /// 品牌图标大小
        static let brandIconSize: CGFloat = 40
        /// 品牌名称字号
        static let brandTitleSize: CGFloat = 14
        /// 导航菜单图标大小
        static let navIconSize: CGFloat = 15
        /// 导航菜单文字字号
        static let navLabelSize: CGFloat = 12

        // 设置页 Header
        /// 设置页标题字号
        static let headerTitleSize: CGFloat = 15

        // 设置页 Section 标签
        /// Section 分类标签字号
        static let sectionLabelSize: CGFloat = 11

        // 设置行
        /// 设置行标题字号
        static let settingsRowTitleSize: CGFloat = 12

        // 快捷键录制器
        /// 录制器内快捷键文字 / 占位文字字号
        static let recorderTextSize: CGFloat = 12
        /// 录制器内清除按钮图标大小
        static let recorderClearIconSize: CGFloat = 11

        // 警告提示
        /// 权限警告图标大小
        static let warningIconSize: CGFloat = 11
        /// 权限警告文字字号
        static let warningTextSize: CGFloat = 11

        // 降级模式横幅
        /// 降级横幅文字字号
        static let degradationTextSize: CGFloat = 10
        /// 降级横幅图标字号
        static let degradationIconSize: CGFloat = 11
    }

    // MARK: ── 快捷键录制器 ──────────────────────
    enum ShortcutRecorder {
        /// 录制器最小宽度（点）— 与 Menu Picker 视觉宽度对齐
        static let minWidth: CGFloat = 90
        /// 录制器最小高度（点）— 与 Menu Picker 高度一致
        static let minHeight: CGFloat = 22
        /// 录制器水平内边距
        static let horizontalPadding: CGFloat = 10
        /// 录制器圆角（示例图标同步此值，与 Menu Picker 一致）
        static let cornerRadius: CGFloat = 6
        /// 录制器背景色 - 与控件背景一致
        static let backgroundColor: Color = ColorTokens.backgroundControl

        // 光标
        /// 光标宽度（点）
        static let cursorWidth: CGFloat = 1
        /// 光标高度（点）
        /// 注意：应与文字行高匹配，过大或过小都会显得不协调
        static let cursorHeight: CGFloat = 13
        /// 光标距文字左侧偏移（点），光标浮于文字前
        static let cursorOffsetX: CGFloat = -4
        /// 光标可见时透明度
        static let cursorVisibleOpacity: Double = 0.8
        /// 光标闪烁周期（秒）
        /// 注意：太小会刺眼，太大会感觉响应迟钝
        static let cursorBlinkInterval: TimeInterval = 0.53

        // 边框
        /// 描边宽度
        static let borderWidth: CGFloat = 0.8

        // 焦点环（蓝色聚焦动画）
        /// 焦点环描边宽度
        static let focusRingLineWidth: CGFloat = 2
        /// 焦点环动画起始缩放倍数（越大动画幅度越大）
        /// 注意：太大可能溢出父容器
        static let focusRingInitialScale: CGFloat = 1.25

        // 阴影
        /// 阴影 Y 偏移
        static let shadowOffsetY: CGFloat = 1

        // 按压反馈
        /// 按下时缩放比例
        static let pressScale: CGFloat = 0.96

        // 禁用状态
        /// 禁用时背景透明度
        static let disabledBgOpacity: Double = 0.5

        // 文字颜色
        /// 已设置快捷键的文字颜色（使用 Color.primary，此处仅作文档记录）
        /// 占位文字颜色（使用 Color.secondary）
        /// 录制中文字颜色（使用 Color.accentColor）
    }

    // MARK: ── 设置行 & 卡片 ──────────────────────
    enum SettingsRow {
        /// 设置行高度（点）
        static let rowHeight: CGFloat = 40
        /// 设置行水平内边距
        static let horizontalPadding: CGFloat = 14
    }

    // MARK: ── 布局预览图标 ─────────────────────
    enum LayoutPreview {
        /// 预览图标宽度
        static let iconWidth: CGFloat = 28
        /// 预览图标高度
        static let iconHeight: CGFloat = 18
    }

    // MARK: ── 布局卡片（窗口管理网格）──────────
    enum LayoutCard {
        /// 分类区域内边距
        static let sectionPadding: CGFloat = 16
        /// 单元格横向间距
        static let columnSpacing: CGFloat = 14
        /// 单元格纵向间距
        static let rowSpacing: CGFloat = 28
        /// 图标与右侧控件间距
        static let iconTrailingSpacing: CGFloat = 12
        /// 预览图标宽度
        static let iconWidth: CGFloat = 64
        /// 预览图标高度
        static let iconHeight: CGFloat = 42
        /// 标签与录制器间距
        static let labelToRecorderSpacing: CGFloat = 4
        /// 标题字号
        static let labelFontSize: CGFloat = 12

        /// 预览图标内层圆角偏移（外层 cornerRadius 减此值 = 内层圆角）
        static let previewCornerRadiusOffset: CGFloat = 2
    }

    // MARK: ── 拖拽分屏 Peek 条 ──────────────────
    // 拖到顶部中央热区 → HUD Peek 条轻落位 → 继续拖入 Peek 条后展开完整面板。
    enum PeekBar {
        static var width: CGFloat { DragSplitPanel.panelWidth }
        static let height: CGFloat = 18
        /// 与展开面板共用同一圆角规格；Peek 的高度刚好容纳该圆角。
        static let cornerRadius: CGFloat = DragSplitPanel.cornerRadius
        static let topInset: CGFloat = 0
        /// 命中检测水平外扩（点），便于拖到 peek 条时更容易命中
        static let hitHorizontalPadding: CGFloat = 8
        /// 命中检测向下外扩（点），不向上外扩以避免与热区重叠
        static let hitBottomPadding: CGFloat = 8
    }

    // MARK: ── 拖拽分屏面板 ──────────────────────
    // 热区 = 面板展开后的矩形区域（见 panelFrame），与 peek 条位置统一
    enum DragSplitPanel {
        /// 单张卡片宽度
        static let cardWidth: CGFloat = 120
        /// 单张卡片高度
        static let cardHeight: CGFloat = 84
        /// 卡片间距
        static let cardSpacing: CGFloat = 14
        /// 面板水平内边距
        static let horizontalPadding: CGFloat = 14
        /// 面板垂直内边距
        static let verticalPadding: CGFloat = 12
        /// 面板圆角
        static let cornerRadius: CGFloat = 12
        /// 展开面板距菜单栏下缘的悬浮间距；Peek 条仍紧贴菜单栏。
        static let topGap: CGFloat = 8
        /// 悬停高亮动画时长
        static let hoverAnimationDuration: TimeInterval = 0.1
        /// 区域内间距
        static let regionGap: CGFloat = 3
        /// 区域圆角
        static let regionCornerRadius: CGFloat = 3

        // MARK: 派生尺寸（热区 / peek 条 / 面板共用）
        /// 面板宽度（基于卡片布局自动计算）
        static var panelWidth: CGFloat {
            cardWidth * 3 + cardSpacing * 2 + horizontalPadding * 2
        }
        /// 面板高度
        static var panelHeight: CGFloat {
            cardHeight + verticalPadding * 2
        }
        /// 面板在屏幕上的目标 frame（AppKit 坐标，原点左下）
        /// 热区检测、peek 条定位、面板展开均复用此 frame，保证三者完全对齐
        static func panelFrame(in visibleFrame: CGRect) -> CGRect {
            let x = visibleFrame.midX - panelWidth / 2
            let y = visibleFrame.maxY - panelHeight - topGap
            return CGRect(x: x, y: y, width: panelWidth, height: panelHeight)
        }
    }

    enum Card {
        /// 卡片圆角
        static let cornerRadius: CGFloat = 10
        /// 卡片描边透明度
        static let borderOpacity: Double = 0.08
        /// 卡片描边宽度
        static let borderWidth: CGFloat = 0.5
        /// 卡片阴影 Y 偏移
        static let shadowOffsetY: CGFloat = 2
    }

    // MARK: ── 导航图标额外宽度 ────────────────
    /// 导航菜单图标 frame 额外宽度补偿（SF Symbol 内边距）
    static let navIconFrameExtraWidth: CGFloat = 6

    // MARK: ── 颜色 ───────────────────────────────
    enum ColorTokens {
        // 背景
        /// 卡片背景（设置行、分组框）
        static let backgroundCard: Color = Color.primary.opacity(0.035)
        /// 控件背景（录制器、输入框等），跟随系统 controlBackgroundColor
        static let backgroundControl: Color = Color(nsColor: .controlBackgroundColor)
        // 前景 / 文本
        /// 占位文字颜色
        static let foregroundPlaceholder: Color = Color.primary.opacity(0.5)
        /// 禁用态文字颜色
        static let foregroundDisabled: Color = Color.secondary.opacity(0.45)

        // 分隔线透明度（极淡）
        static let dividerOpacity: Double = 0.03

        // 布局预览图标
        /// 预览图标中"窗口色块"透明度
        static let layoutPreviewWindowOpacity: Double = 0.15

        // 录制器
        /// 录制器普通边框透明度
        static let recorderBorderIdleOpacity: Double = 0.15
        /// 录制中文字颜色
        static let recorderRecordingText: Color = .blue

        // 降级横幅
        /// 降级横幅背景色
        static let degradationBackground: Color = Color.orange.opacity(0.08)

        // 分屏面板区域基色
        /// 分屏面板区域基色（配合透明度使用）
        static let dragSplitRegionBase: Color = .gray

    }

    // MARK: ── 设置页通用布局 ─────────────────────
    enum SettingsPage {
        /// 内容区外边距
        static let contentPadding: CGFloat = 22
        /// Header 内标题与副标题间距
        static let headerTitleSubtitleSpacing: CGFloat = 1
        /// Header 与下方区域间距
        static let headerBottomSpacing: CGFloat = 2
        /// Section 之间的间距
        static let sectionSpacing: CGFloat = 16
        /// Section 标题与卡片间距
        static let sectionLabelCardSpacing: CGFloat = 8
        /// Section 标题左侧缩进
        static let sectionLabelLeadingPadding: CGFloat = 6
        /// 卡片内设置行之间的 Divider 水平内边距
        static let dividerHorizontalPadding: CGFloat = 14
        /// Divider 透明度（已废弃，请用 ColorTokens.dividerOpacity）
        static let dividerOpacity: Double = 0.03

        /// 降级横幅水平内边距
        static let degradationBannerHPadding: CGFloat = 16
        /// 降级横幅垂直内边距
        static let degradationBannerVPadding: CGFloat = 8

        /// 行内容水平间距（录制器 ↔ Toggle）
        static let rowContentSpacing: CGFloat = 12
        /// Dock 设置行内容水平间距（Picker ↔ Toggle）
        static let dockRowContentSpacing: CGFloat = 14
        /// 权限警告顶部间距
        static let warningTopPadding: CGFloat = 4
        /// 权限警告图标与文字间距
        static let warningSpacing: CGFloat = 6
        /// Picker 宽度（修饰键选择）
        static let pickerWidth: CGFloat = 100
    }

    // MARK: ── 系统设置页 ─────────────────────────
    // 通用布局复用 SettingsPage 中的参数

    // MARK: ── 动画参数 ───────────────────────────
    enum Animation {
        /// 跟随 macOS“减少动态效果”辅助功能设置。浮层保留淡入淡出，窗口不再插值移动。
        static var shouldReduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        // 内容区切换
        /// 内容区淡入淡出时长
        static let contentTransitionDuration: TimeInterval = 0.18

        // 导航菜单悬停
        /// 悬停高亮动画时长
        static let hoverDuration: TimeInterval = 0.15

        // Toggle 开关弹簧动画
        /// 弹簧响应时间（秒），越小越灵敏
        /// 注意：与 dampingFraction 配对，过小会产生"弹跳"感
        static let toggleSpringResponse: TimeInterval = 0.28
        /// 弹簧阻尼系数（0~1），越小弹跳越明显
        /// 注意：设为 1 则无弹性，完全线性
        static let toggleSpringDamping: Double = 0.82

        // 快捷键录制器
        /// 按压缩放动画时长
        static let pressScaleDuration: TimeInterval = 0.12
        /// 录制状态切换弹簧响应
        static let recordingSpringResponse: TimeInterval = 0.25
        /// 录制状态切换弹簧阻尼
        static let recordingSpringDamping: Double = 0.7
        // 焦点环动画
        /// 焦点环入场弹簧响应
        static let focusRingInSpringResponse: TimeInterval = 0.3
        /// 焦点环入场弹簧阻尼
        static let focusRingInSpringDamping: Double = 0.72
        /// 焦点环退场时长
        static let focusRingOutDuration: TimeInterval = 0.2

        // 光标闪烁
        /// 光标单次闪烁过渡时长
        static let cursorBlinkTransitionDuration: TimeInterval = 0.15

        // 分屏预览浮层
        /// 预览浮层淡入时长
        static let dragSplitPreviewShowDuration: TimeInterval = 0.18
        /// 预览浮层 frame 过渡时长（弹性）
        static let dragSplitPreviewAnimateDuration: TimeInterval = 0.22
        /// Peek 条进入时长
        static let dragSplitPeekDuration: TimeInterval = 0.15
        /// 分屏面板展开时长
        static let dragSplitPanelExpandDuration: TimeInterval = 0.32
        /// 分屏面板内容入场时长；与容器展开重叠，避免布局卡片突然出现。
        static let dragSplitPanelContentRevealDuration: TimeInterval = 0.22
        /// 真实窗口落位时长。短于预览动画，保证操作始终显得干脆。
        static let dragSplitWindowSnapDuration: TimeInterval = 0.24
    }

    // MARK: ── 菜单栏根布局 ──────────────────────
    /// 侧边栏与内容区之间的间距
    static let sidebarContentSpacing: CGFloat = 0
}
