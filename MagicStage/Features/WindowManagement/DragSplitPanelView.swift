import SwiftUI

struct PanelCard: Identifiable {
    let id = UUID()
    let layouts: [WindowLayout]
    let mode: CardMode
    /// 宽度比例（仅 horizontal 模式使用）；nil = 等分
    let ratios: [CGFloat]?

    enum CardMode {
        case horizontal
        case grid
    }
}

struct DragSplitPanelView: View {
    @ObservedObject var service: DragSplitService

    private let cards: [PanelCard] = [
        PanelCard(layouts: [.leftHalf, .rightHalf], mode: .horizontal, ratios: nil),
        PanelCard(layouts: [.leftTwoThirds, .rightOneThird], mode: .horizontal, ratios: [2.0/3.0, 1.0/3.0]),
        PanelCard(layouts: [.quadTopLeft, .quadTopRight, .quadBottomLeft, .quadBottomRight], mode: .grid, ratios: nil)
    ]

    private let cardWidth: CGFloat = UIConfig.DragSplitPanel.cardWidth
    private let cardHeight: CGFloat = UIConfig.DragSplitPanel.cardHeight
    private let cardSpacing: CGFloat = UIConfig.DragSplitPanel.cardSpacing
    private let horizontalPadding: CGFloat = UIConfig.DragSplitPanel.horizontalPadding
    private let verticalPadding: CGFloat = UIConfig.DragSplitPanel.verticalPadding

    var body: some View {
        HStack(spacing: cardSpacing) {
            ForEach(cards) { card in
                CardView(card: card, hoveredLayout: service.hoveredLayout)
                    .frame(width: cardWidth, height: cardHeight)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    func layout(at point: CGPoint) -> WindowLayout? {
        guard point.x >= 0, point.y >= 0 else { return nil }

        for (i, card) in cards.enumerated() {
            let cardX = horizontalPadding + CGFloat(i) * (cardWidth + cardSpacing)
            let cardFrame = CGRect(x: cardX, y: verticalPadding, width: cardWidth, height: cardHeight)

            guard cardFrame.contains(point) else { continue }

            let relX = point.x - cardFrame.origin.x
            let relY = point.y - cardFrame.origin.y

            switch card.mode {
            case .horizontal:
                let splitX = (card.ratios?[0] ?? 0.5) * cardFrame.width
                return relX < splitX ? card.layouts[0] : card.layouts[1]
            case .grid:
                let midX = cardFrame.width / 2
                let midY = cardFrame.height / 2
                if relX < midX {
                    return relY < midY ? card.layouts[0] : card.layouts[2]
                } else {
                    return relY < midY ? card.layouts[1] : card.layouts[3]
                }
            }
        }
        return nil
    }
}

// MARK: - 单张卡片

private struct CardView: View {
    let card: PanelCard
    let hoveredLayout: WindowLayout?

    private let regionGap: CGFloat = UIConfig.DragSplitPanel.regionGap
    private let cornerRadius: CGFloat = UIConfig.DragSplitPanel.regionCornerRadius

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                ForEach(Array(card.layouts.enumerated()), id: \.offset) { idx, layout in
                    let rect = regionRect(for: idx, total: card.layouts.count, mode: card.mode, ratios: card.ratios, size: size)
                    let isHovered = hoveredLayout == layout

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isHovered
                            ? UIConfig.ColorTokens.dragSplitRegionBase.opacity(UIConfig.ColorTokens.dragSplitRegionHoveredOpacity)
                            : UIConfig.ColorTokens.dragSplitRegionBase.opacity(UIConfig.ColorTokens.dragSplitRegionIdleOpacity))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.easeInOut(duration: UIConfig.DragSplitPanel.hoverAnimationDuration),
                                   value: isHovered)
                }
            }
        }
    }

    private func regionRect(for index: Int, total: Int, mode: PanelCard.CardMode, ratios: [CGFloat]?, size: CGSize) -> CGRect {
        let inset = regionGap / 2
        let w = size.width - regionGap
        let h = size.height - regionGap

        switch mode {
        case .horizontal:
            let widthRatios = ratios ?? Array(repeating: 1.0 / CGFloat(total), count: total)
            var xOffset: CGFloat = inset
            for i in 0..<index {
                xOffset += widthRatios[i] * w
            }
            let colW = widthRatios[index] * w
            return CGRect(x: xOffset, y: inset, width: colW - regionGap, height: h - regionGap)
        case .grid:
            let colW = w / 2, rowH = h / 2
            let col = index % 2, row = index / 2
            return CGRect(x: inset + CGFloat(col) * colW, y: inset + CGFloat(row) * rowH,
                          width: colW - regionGap, height: rowH - regionGap)
        }
    }
}
