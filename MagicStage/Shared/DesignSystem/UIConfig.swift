import Foundation
import SwiftUI

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
        /// 小圆角：录制器、输入框等小型控件
        static let small: CGFloat = 6
        /// 大圆角：卡片、面板等大容器
        static let large: CGFloat = 10
        /// 面板圆角（DragSplit 专用，比 large 略大）
        static let panel: CGFloat = 12
    }

    // MARK: ── 侧边栏 ─────────────────────────────
    enum Sidebar {
        /// 侧边栏宽度（点）
        /// 注意：过窄会导致导航文字截断，过宽会挤压右侧内容区
        static let width: CGFloat = 190

        // 品牌区（App 图标 + 名称）
        /// 品牌区距顶部间距
        static let brandTopPadding: CGFloat = 40
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
        /// 设置页标题图标大小
        static let headerIconSize: CGFloat = 18
        /// 设置页标题字号
        static let headerTitleSize: CGFloat = 15
        /// 设置页副标题字号（已移除描述，保留供兼容）
        static let headerSubtitleSize: CGFloat = 11

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
        /// 文字与光标/清除按钮之间的间距
        static let contentSpacing: CGFloat = 3
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
        /// 普通状态描边透明度
        static let borderIdleOpacity: Double = 0.12
        /// 录制中描边透明度
        static let borderRecordingOpacity: Double = 0.3
        /// 禁用状态描边透明度
        static let borderDisabledOpacity: Double = 0.06
        /// 描边宽度
        static let borderWidth: CGFloat = 0.8

        // 焦点环（蓝色聚焦动画）
        /// 焦点环描边宽度
        static let focusRingLineWidth: CGFloat = 2
        /// 焦点环动画起始缩放倍数（越大动画幅度越大）
        /// 注意：太大可能溢出父容器
        static let focusRingInitialScale: CGFloat = 1.25

        // 阴影
        /// 普通状态阴影半径
        static let shadowIdleRadius: CGFloat = 1.5
        /// 录制中阴影半径
        static let shadowRecordingRadius: CGFloat = 4
        /// 阴影 Y 偏移
        static let shadowOffsetY: CGFloat = 1
        /// 普通状态阴影透明度
        static let shadowIdleOpacity: Double = 0.03
        /// 录制中阴影透明度
        static let shadowRecordingOpacity: Double = 0.12

        // 按压反馈
        /// 按下时缩放比例
        static let pressScale: CGFloat = 0.96

        // 禁用状态
        /// 禁用时文字透明度
        static let disabledTextOpacity: Double = 0.45
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
        /// 图标与标题间距
        static let iconTextSpacing: CGFloat = 10
        /// 单元格内图标与文字间距（紧凑模式）
        static let cellIconTextSpacing: CGFloat = 6
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
    // Wins 风格两阶段触发：拖到顶部热区 → peek 条从菜单栏上方滑入
    // 拖到 peek 条 → 展开完整分屏面板
    // 注意：宽度、圆角、热区与 DragSplitPanel 共用 panelWidth/panelHeight/cornerRadius，
    // 改 DragSplitPanel 参数即可同步所有位置，无需单独调整
    enum PeekBar {
        /// peek 条高度（点），与面板高度独立
        static let height: CGFloat = 16
        /// peek 条底部圆角（高度较小时需独立控制，避免圆角过大）
        static let cornerRadius: CGFloat = 6
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
        /// 面板距屏幕顶部间距
        static let topGap: CGFloat = 4
        /// 非悬停区域灰度透明度（请用 ColorTokens.dragSplitRegionIdleOpacity）
        static let idleRegionOpacity: Double = 0.3
        /// 悬停区域灰度（请用 ColorTokens.dragSplitRegionHoveredOpacity）
        static let hoveredRegionOpacity: Double = 0.7
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
        /// 卡片阴影半径
        static let shadowRadius: CGFloat = 6
        /// 卡片阴影 Y 偏移
        static let shadowOffsetY: CGFloat = 2
        /// 卡片阴影透明度
        static let shadowOpacity: Double = 0.06
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
        /// 内容区背景
        static let backgroundContent: Color = Color(nsColor: .controlBackgroundColor)

        // 前景 / 文本
        /// 占位文字颜色
        static let foregroundPlaceholder: Color = Color.primary.opacity(0.5)
        /// 禁用态文字颜色
        static let foregroundDisabled: Color = Color.secondary.opacity(0.45)

        // 卡片装饰
        /// 卡片边框透明度
        static let cardBorderOpacity: Double = 0.08
        /// 卡片边框宽度
        static let cardBorderWidth: CGFloat = 0.5

        // 分隔线透明度（极淡）
        static let dividerOpacity: Double = 0.03

        // 布局预览图标
        /// 预览图标中"窗口色块"透明度
        static let layoutPreviewWindowOpacity: Double = 0.15

        // 分屏面板区域
        /// 非悬停区域灰度透明度
        static let dragSplitRegionIdleOpacity: Double = 0.3
        /// 悬停区域灰度透明度
        static let dragSplitRegionHoveredOpacity: Double = 0.7

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

        /// 旧名兼容（废弃，请用 backgroundCard）
        static let rowBackground: Color = backgroundCard
    }

    // MARK: ── 设置页通用布局 ─────────────────────
    enum SettingsPage {
        /// 内容区外边距
        static let contentPadding: CGFloat = 22
        /// Header 内图标与文字间距
        static let headerIconTextSpacing: CGFloat = 10
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
        // 导航菜单切换
        /// 选中类别切换动画时长
        static let categorySwitchDuration: TimeInterval = 0.2

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
        /// 录制完成文字更新动画
        static let recordingTextUpdateDuration: TimeInterval = 0.15

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
        static let dragSplitPreviewShowDuration: TimeInterval = 0.25
        /// 预览浮层 frame 过渡时长（弹性）
        static let dragSplitPreviewAnimateDuration: TimeInterval = 0.35
    }

    // MARK: ── 菜单栏根布局 ──────────────────────
    /// 侧边栏与内容区之间的间距
    static let sidebarContentSpacing: CGFloat = 0
}
