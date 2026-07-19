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

/// 实时桌面采样由 AppKit 底层提供；这里仅绘制低浓度染色与方向性边缘高光。
/// 染色和缩略图处于不同层，因此提高通透度不会降低内容清晰度。
private struct TransparentGlassChrome: View {
    @Environment(\.colorScheme) private var colorScheme
    let isTransparent: Bool

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: UIConfig.WindowPreview.containerCornerRadius,
            style: .continuous
        )

        shape
            .fill(
                colorScheme == .dark
                    ? Color.black.opacity(isTransparent ? 0.035 : 0.10)
                    : Color.white.opacity(isTransparent ? 0.055 : 0.10)
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.28 : 0.42),
                            Color.white.opacity(0.06),
                            Color.black.opacity(colorScheme == .dark ? 0.18 : 0.11)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.65
                )
            }
            .allowsHitTesting(false)
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
            .padding(.horizontal, UIConfig.WindowPreview.containerHorizontalPadding)
            .padding(.vertical, UIConfig.WindowPreview.containerVerticalPadding)
            .scaleEffect(manager.isPanelVisible ? 1.0 : 0.99, anchor: .bottom)
            .opacity(manager.isPanelVisible ? 1.0 : 0.0)
            .offset(y: manager.isPanelVisible ? 0 : 2)
        }
        .background(.clear)
        .ignoresSafeArea()

        content
            .background {
                if !manager.usesNativeClearGlass {
                    TransparentGlassChrome(isTransparent: manager.useLiquidGlass)
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
// 紧凑标题栏与缩略图组成单一卡片；静止时不额外绘制卡片底色，
// 悬停时只通过柔和高光、阴影和轻微缩放建立层级。
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
    @State private var isCardHovered = false
    @State private var isThumbnailHovered = false
    @State private var hoverOffset: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    private var titleBarHeight: CGFloat {
        UIConfig.WindowPreview.titleBarHeight(closeButtonSize: closeButtonSize)
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
        .onHover { hovering in
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.76)) {
                isCardHovered = hovering
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: vStackSpacing) {
            HStack(spacing: 7) {
                // 关闭按钮（左上角，红色）
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: max(9, closeButtonSize * 0.66), weight: .semibold))
                        .foregroundStyle(Color(red: 0.55, green: 0.06, blue: 0.06))
                        .frame(width: closeButtonSize + 4, height: closeButtonSize + 4)
                        .background {
                            Circle()
                                .fill(Color(red: 0.94, green: 0.27, blue: 0.27))
                        }
                }
                .buttonStyle(.plain)
                .opacity(isCardHovered ? 1 : 0)
                .scaleEffect(isCardHovered ? 1 : 0.72)
                .allowsHitTesting(isCardHovered)
                .frame(width: closeButtonSize + 4, height: closeButtonSize + 4)
                .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.74), value: isCardHovered)

                Spacer(minLength: 4)

                Text(window.title)
                    .font(.system(size: UIConfig.WindowPreview.titleFontSize, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: titleBarHeight, alignment: .center)

            // 缩略图主体
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: window.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: UIConfig.WindowPreview.thumbnailCornerRadius,
                            style: .continuous
                        )
                    )
                    .shadow(
                        color: .black.opacity(isThumbnailHovered ? 0.18 : 0.11),
                        radius: isThumbnailHovered ? 5 : 2.5,
                        y: isThumbnailHovered ? 2.5 : 1
                    )

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
            .frame(width: imageSize.width, height: imageSize.height)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: UIConfig.WindowPreview.thumbnailCornerRadius,
                    style: .continuous
                )
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    if !isThumbnailHovered {
                        withAnimation(.interactiveSpring(response: 0.23, dampingFraction: 0.78)) {
                            isThumbnailHovered = true
                        }
                    }
                    let normalizedX = min(1, max(-1, location.x / imageSize.width * 2 - 1))
                    let normalizedY = min(1, max(-1, location.y / imageSize.height * 2 - 1))
                    hoverOffset = CGSize(
                        width: normalizedX * UIConfig.WindowPreview.hoverTravelX,
                        height: normalizedY * UIConfig.WindowPreview.hoverTravelY
                    )
                case .ended:
                    withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.76)) {
                        isThumbnailHovered = false
                        hoverOffset = .zero
                    }
                }
            }
            .scaleEffect(isThumbnailHovered ? UIConfig.WindowPreview.hoverScale : 1.0)
            .offset(hoverOffset)
            .animation(
                .interactiveSpring(response: 0.16, dampingFraction: 0.84, blendDuration: 0.05),
                value: hoverOffset
            )
        }
        .padding(cardPadding)
        .contentShape(
            RoundedRectangle(
                cornerRadius: UIConfig.WindowPreview.cardCornerRadius,
                style: .continuous
            )
        )
    }
}
