import SwiftUI
import AppKit

// MARK: - 流式布局（自动换行）
//
// macOS 13+ Layout 协议实现
// 卡片按顺序排列，超出容器宽度自动换行
// 每行左对齐，行间距 = cardSpacing
//
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        guard !subviews.isEmpty else { return .zero }

        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // 如果当前行放不下，换行
            if lineWidth + size.width > maxWidth && lineWidth > 0 {
                maxLineWidth = max(maxLineWidth, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += size.width + (lineWidth > 0 ? spacing : 0)
                lineHeight = max(lineHeight, size.height)
            }
        }
        // 最后一行
        maxLineWidth = max(maxLineWidth, lineWidth)
        totalHeight += lineHeight

        return CGSize(width: maxLineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        guard !subviews.isEmpty else { return }

        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // 如果当前行放不下，换行
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - 缩略图容器视图
//
// 设计（v5，严格按 Anime.md + memory 规范）：
// 1. 容器背景：controlBackgroundColor 白色不透明（不再用 HUD 半透明材质）
//    - 解决与桌面背景融合可读性下降问题
//    - 符合 memory: Peek bar/floating window 用 controlBackgroundColor
// 2. 圆角：RoundedRectangle cornerRadius: 16，无 overlay 干扰，确保四边圆角正常
// 3. 容器动画：底部锚定 scaleEffect(0.97→1.0) + opacity + offset(y: 4→0)
//    - 模拟从 Dock 栏吸附冒出质感（Anime.md §2）
// 4. 卡片动画：本地 @State animateIn + onAppear 触发
//    - opacity + offset(y: 25→0) + scale(0.94→1.0)
//    - spring(response: 0.32, dampingFraction: 0.72) + delay(index * 0.05)
//    - transition(.asymmetric(insertion: .identity, removal: .opacity + scale 0.95))
// 5. 卡片布局：保持原有 VStack（标题栏在上 + 灰色矩形缩略图背景）
//

// MARK: - 液态玻璃修饰符（macOS 26+）
//
// 注意：nonactivatingPanel 是非激活窗口，macOS 会把液态玻璃降级为静态磨砂。
// 完整液态玻璃（折射/高光/实时采样）需要窗口激活，但那会抢 Dock 焦点，不符合 peek bar 需求。
// 这里保留开关，接受降级效果，与 .hudWindow 传统方案二选一。
//
@available(macOS 26.0, *)
private struct LiquidGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ThumbnailContainerView: View {
    @ObservedObject var manager: WindowPreviewService

    var body: some View {
        let cardPadding = manager.cardPadding
        let vStackSpacing = manager.vStackSpacing
        let maxImageWidth = manager.effectiveCardWidth - cardPadding * 2
        let maxImageHeight = manager.effectiveImageHeight

        let content = GeometryReader { geometry in
            FlowLayout(spacing: manager.cardSpacing) {
                ForEach(Array(manager.activeWindows.enumerated()), id: \.element.id) { index, window in
                    if manager.visibleWindowIDs.contains(window.id) {
                        StaggeredCardWrapper(
                            window: window,
                            index: index,
                            maxImageWidth: maxImageWidth,
                            maxImageHeight: maxImageHeight,
                            cardPadding: cardPadding,
                            vStackSpacing: vStackSpacing,
                            closeButtonSize: manager.closeButtonSize,
                            isFirstPreview: manager.isFirstPreview,
                            containerHeight: geometry.size.height,
                            onActivate: { manager.activateWindow(window) },
                            onClose: { manager.closeWindowAndAnimate(window: window) }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
            .scaleEffect(manager.isPanelVisible ? 1.0 : 0.99, anchor: .bottom)
            .opacity(manager.isPanelVisible ? 1.0 : 0.0)
            .offset(y: manager.isPanelVisible ? 0 : 2)
        }
        .background(.clear)
        .ignoresSafeArea()

        Group {
            if manager.useLiquidGlass, #available(macOS 26.0, *) {
                content
                    .modifier(LiquidGlassBackground())
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.gray.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            } else {
                content
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.gray.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            }
        }
    }
}

// MARK: - 卡片级联包装（Anime.md §3）
//
// 解决重排乱跳和末尾闪烁的终极方案：
// - 登场动效锁在卡片内部 @State animateIn，不受父组件重绘/index 移位影响
// - 插入/移除动画完全解耦
// - 不对称过渡：登场用本地状态驱动，离场用 opacity + scale 温柔消散
//
struct StaggeredCardWrapper: View {
    let window: AppWindow
    let index: Int
    let maxImageWidth: CGFloat
    let maxImageHeight: CGFloat
    let cardPadding: CGFloat
    let vStackSpacing: CGFloat
    let closeButtonSize: CGFloat
    let isFirstPreview: Bool
    /// 容器高度，用于计算入场偏移（从容器高度 1/3 处向上弹入）
    let containerHeight: CGFloat
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var animateIn = false

    var body: some View {
        // 入场起始位移（固定值，方便直观调节）
        // 数值越大 = 从越远的位置弹入；数值越小 = 位移越微妙
        let startOffset: CGFloat = 5

        WindowCardView(
            window: window,
            maxImageWidth: maxImageWidth,
            maxImageHeight: maxImageHeight,
            cardPadding: cardPadding,
            vStackSpacing: vStackSpacing,
            closeButtonSize: closeButtonSize,
            onActivate: onActivate,
            onClose: onClose
        )
        // 入场：淡化 + 位移 + 轻微缩放同时进行，带级联错位
        // 注意：offset 在 scaleEffect 之后，避免位移被缩放比例压缩
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98, anchor: .bottom)
        .offset(y: animateIn ? 0 : startOffset)
        .animation(
            .spring(response: 0.3, dampingFraction: 0.8),
            value: animateIn
        )
        .onAppear {
            guard !animateIn else { return }
            // 分类讨论：
            // - 首次预览：容器淡入动画，面板已就位，缩略图紧随容器淡入，延迟极短（0.02s）
            // - 连续切换：容器正在 resize（0.2s），缩略图等容器展开到 40% 再开始，延迟 0.08s
            let baseDelay: Double = isFirstPreview ? 0.02 : 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay + Double(index) * 0.04) {
                animateIn = true
            }
        }
        // 不对称过渡：登场由本地 onAppear 驱动，离场与入场镜像（向下沉）
        .transition(.asymmetric(
            insertion: .identity,
            removal: .opacity.combined(with: .move(edge: .bottom))
        ))
    }
}

// MARK: - 单个窗口卡片
//
// 设计恢复（v4）：
// 1. 恢复原本的 VStack 布局：标题栏（叉叉+标题）在上，缩略图在下
// 2. 保留灰色矩形背景（RoundedRectangle fill）
// 3. padding(8) + 标题栏(18) + spacing(8) 给缩略图足够空间
// 4. 阴影应用到最外层 RoundedRectangle（卡片整体阴影），避免被内层 clipShape 截断
// 5. 卡片尺寸仍按窗口宽高比自适应
//

struct WindowCardView: View {
    let window: AppWindow
    let maxImageWidth: CGFloat
    let maxImageHeight: CGFloat
    let cardPadding: CGFloat
    let vStackSpacing: CGFloat
    let closeButtonSize: CGFloat
    let onActivate: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    /// 标题栏高度 = 关闭按钮尺寸 + 2（上下各 1pt 余量）
    /// 跟随 closeButtonSize 变化，避免按钮放大后被截断
    private var titleBarHeight: CGFloat {
        closeButtonSize + 2
    }

    /// 卡片图像实际尺寸（基于窗口宽高比）
    private var imageSize: (width: CGFloat, height: CGFloat) {
        window.scaledImageSize(maxWidth: maxImageWidth, maxHeight: maxImageHeight)
    }

    /// 卡片宽度 = 图像宽度 + padding * 2
    private var cardWidth: CGFloat {
        imageSize.width + cardPadding * 2
    }

    /// 卡片高度 = 图像高度 + padding*2 + 标题栏 + vStackSpacing
    private var cardHeight: CGFloat {
        imageSize.height + cardPadding * 2 + titleBarHeight + vStackSpacing
    }

    var body: some View {
        Button(action: onActivate) {
            cardContent
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: cardWidth, height: cardHeight)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: vStackSpacing) {
            // 标题栏：叉叉按钮 + 窗口名（在缩略图上方）
            // 用 fixedSize + frame 确保按钮和文字垂直居中对齐，避免不同尺寸错位
            HStack(spacing: 4) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: closeButtonSize))
                        .foregroundColor(Color.red.opacity(0.85))
                        .frame(width: closeButtonSize, height: closeButtonSize, alignment: .center)
                }
                .buttonStyle(PlainButtonStyle())
                .opacity(isHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.2), value: isHovered)

                Text(window.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(height: closeButtonSize, alignment: .center)
            }
            .padding(.top, 2)   // 标题栏上方 2pt，总计 6+2=8pt 与左边一致
            .padding(.leading, 2)  // 关闭按钮左边 2pt，总计 6+2=8pt 与上方一致
            .frame(height: titleBarHeight, alignment: .center)

            // 缩略图主体
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: window.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageSize.width, height: imageSize.height)
                    // 浅色背景避免黑闪（渲染前不显示刺眼黑色）
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if window.isMinimized {
                    Text("已最小化")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)
                        .padding(6)
                }
            }
        }
        .padding(cardPadding)
        // hover 阴影
        .shadow(
            color: Color.black.opacity(isHovered ? 0.15 : 0.08),
            radius: isHovered ? 2 : 1,
            x: 0,
            y: isHovered ? 1 : 0
        )
        .onHover { hovering in
            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.7)) {
                self.isHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .contentShape(Rectangle())
    }
}
