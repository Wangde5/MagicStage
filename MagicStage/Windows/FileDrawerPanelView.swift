import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// 始终跟随“系统设置 > 外观 > 强调色”，不受应用资源目录中的 AccentColor 影响。
private enum DrawerSystemColors {
    static var accent: Color { Color(nsColor: .controlAccentColor) }
    static var selectedText: NSColor { .alternateSelectedControlTextColor }
    /// 比直接叠一层黑色透明度更接近权限页卡片的“亮面”质感。
    static var controlSurface: Color { Color(nsColor: .controlBackgroundColor) }
    static var toolbarSeparator: Color { Color(nsColor: .separatorColor).opacity(0.78) }
}

/// 抽屉顶部只使用两种轮廓：承载一组内容的胶囊，以及单个图标的圆形反馈。
private enum DrawerChromeMetrics {
    static let controlHeight: CGFloat = 40
    static let iconButtonSize: CGFloat = 34
    static let pairedControlWidth: CGFloat = 76
    static let pairedButtonWidth: CGFloat = 34
    static let primaryActionSize: CGFloat = 40
    static let searchSlotWidth: CGFloat = 112
    static let rowHorizontalPadding: CGFloat = 18
    static let rowSpacing: CGFloat = 10
    static let toolbarButtonSpacing: CGFloat = 4
    // 左右边距增大后收窄筛选胶囊，保证四项仍能在一行内舒展排列。
    static let filterControlWidth: CGFloat = 98
}

private enum DrawerFilenameMetrics {
    static let fontSize: CGFloat = 11.5
    static let maximumRenameLines: CGFloat = 3
    static let horizontalTextInset: CGFloat = 4
    static let verticalTextInset: CGFloat = 2
    static let displayLineLimit = 2

    static let lineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: font)
    }()

    struct Measurement {
        let editorSize: CGSize
        /// 显示状态严格跟随文件名实际排版宽度。
        let displayTextWidth: CGFloat

        /// 编辑状态仍保留足够的点击和输入区域。
        var editorTextWidth: CGFloat {
            max(1, editorSize.width - DrawerFilenameMetrics.horizontalTextInset * 2)
        }

        var displayTextHeight: CGFloat {
            min(
                max(DrawerFilenameMetrics.lineHeight, editorSize.height - DrawerFilenameMetrics.verticalTextInset * 2),
                DrawerFilenameMetrics.lineHeight * CGFloat(DrawerFilenameMetrics.displayLineLimit)
            )
        }
    }

    private final class CachedMeasurement: NSObject {
        let editorSize: CGSize
        let displayTextWidth: CGFloat

        init(editorSize: CGSize, displayTextWidth: CGFloat) {
            self.editorSize = editorSize
            self.displayTextWidth = displayTextWidth
        }
    }

    private static let measurementCache: NSCache<NSString, CachedMeasurement> = {
        let cache = NSCache<NSString, CachedMeasurement>()
        // 大目录滚动经过的文件名不应马上被淘汰，否则返回原位置时会在主线程
        // 重做 TextKit 测量。缓存只保存少量尺寸值，扩大容量的内存成本很低。
        cache.countLimit = 4_096
        return cache
    }()

    /// 先按显示态的最大宽度排版，再取实际最长一行作为编辑框宽度。
    /// 这样多行名称进入重命名时不会突然撑满整张卡片并重新换行。
    static func measure(_ text: String, maximumTextWidth: CGFloat) -> Measurement {
        let cacheKey = "\(maximumTextWidth)|\(text)" as NSString
        if let cachedMeasurement = measurementCache.object(forKey: cacheKey) {
            return Measurement(
                editorSize: cachedMeasurement.editorSize,
                displayTextWidth: cachedMeasurement.displayTextWidth
            )
        }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let glyphRange = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        var longestLineWidth: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            longestLineWidth = max(longestLineWidth, usedRect.width)
        }

        let horizontalInset = horizontalTextInset * 2
        let verticalInset = verticalTextInset * 2
        // 多留 1pt 给亚像素字形，避免设置最终宽度时发生一次额外换行。
        let fittedTextWidth = min(maximumTextWidth, ceil(longestLineWidth) + 1)
        let editorWidth = min(
            maximumTextWidth + horizontalInset,
            fittedTextWidth + horizontalInset
        )
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let contentHeight = max(lineHeight, layoutManager.usedRect(for: container).height) + verticalInset
        let visibleHeight = min(contentHeight, lineHeight * maximumRenameLines + verticalInset)
        let editorSize = CGSize(width: ceil(editorWidth), height: ceil(visibleHeight))
        let displayTextWidth = max(1, fittedTextWidth)
        measurementCache.setObject(
            CachedMeasurement(editorSize: editorSize, displayTextWidth: displayTextWidth),
            forKey: cacheKey
        )
        return Measurement(editorSize: editorSize, displayTextWidth: displayTextWidth)
    }
}

/// 测量 header 实际高度，用于在 ScrollView 内部留出等高顶部间距，
/// 使文件列表内容从工具栏下方开始，但滚动时可滑入工具栏模糊背景下方。
private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 液态玻璃效果：macOS 26+ 启用，旧系统回退为透明。
private struct GlassEffectModifier: ViewModifier {
    enum Variant { case regular, clear }
    let variant: Variant
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = variant == .regular ? .regular : .clear
            content
                .glassEffect(
                    glass,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
        }
    }
}

/// 菜单栏只使用无边缘折射的系统材质；液态玻璃仅放在独立的可点击控件上。
private struct DrawerToolbarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // Finder 工具栏同类的 header 材质：比 HUD 更通透，且没有 liquid-glass
        // shape 的边缘折射；系统会随 macOS 26 自动采用对应的玻璃调校。
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private enum DrawerGlassControlShape {
    case circle
    case capsule
}

/// macOS 26 使用官方按钮玻璃，旧系统才回退为轻量底板和高光描边。
private struct DrawerGlassControlModifier: ViewModifier {
    let shape: DrawerGlassControlShape
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch shape {
            case .circle:
                content.glassEffect(.regular, in: Circle())
            case .capsule:
                content.glassEffect(.regular, in: Capsule(style: .continuous))
            }
        } else {
            switch shape {
            case .circle:
                content
                    .background(DrawerSystemColors.controlSurface.opacity(0.88), in: Circle())
                    .overlay { Circle().stroke(.white.opacity(isEnabled ? 0.48 : 0.24), lineWidth: 0.8) }
            case .capsule:
                content
                    .background(DrawerSystemColors.controlSurface.opacity(0.84), in: Capsule(style: .continuous))
                    .overlay { Capsule(style: .continuous).stroke(.white.opacity(isEnabled ? 0.42 : 0.24), lineWidth: 0.8) }
            }
        }
    }
}

struct FileDrawerPanelView: View {
    @ObservedObject var service: FileDrawerService
    @State private var timeFilterMenuRequest = 0
    @State private var filterMenuRequest = 0
    @State private var sortMenuRequest = 0
    @State private var itemGeometry = DrawerItemGeometryStore()
    @State private var marqueeTracker = DrawerMarqueeTracker()
    @State private var selectionAutoScroller = DrawerSelectionAutoScroller()
    @State private var headerHeight: CGFloat = 0
    @State private var filterRowVisible = false
    @State private var searchRowVisible = false
    @State private var detailsPopoverVisible = false
    @State private var searchFocusTrigger = 0
    @State private var hoveredPathComponentID: String?
    @State private var isLiveScrolling = false

    private let selectionSpaceName = "fileDrawerSelectionArea"
    // 卡片行距保留足够的呼吸感，让缩略图与两行文件名不会显得拥挤。
    private var horizontalGridSpacing: CGFloat { service.columnCount >= 5 ? 16 : 22 }
    // 收紧文件卡片的纵向节奏，避免较高窗口里出现不必要的大段空白。
    private var verticalGridSpacing: CGFloat { service.columnCount >= 5 ? 24 : 32 }
    private var drawerMotion: Animation {
        .spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.08)
    }
    private var drawerEdgeAnchor: UnitPoint {
        switch service.placement {
        case .left: return .leading
        case .right: return .trailing
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        }
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 48), spacing: horizontalGridSpacing),
            count: service.columnCount
        )
    }

    private var cardMetrics: DrawerCardMetrics {
        switch service.columnCount {
        case 2: return DrawerCardMetrics(cardWidth: 172, thumbnailWidth: 142, thumbnailHeight: 106, cardHeight: 164, lineLimit: 2)
        case 3: return DrawerCardMetrics(cardWidth: 120, thumbnailWidth: 94, thumbnailHeight: 80, cardHeight: 134, lineLimit: 2)
        // Finder 的图标视图在紧凑网格里也保留两行名称；否则长文件名会变成一排难辨识的省略号。
        case 4: return DrawerCardMetrics(cardWidth: 84, thumbnailWidth: 64, thumbnailHeight: 54, cardHeight: 118, lineLimit: 2)
        default: return DrawerCardMetrics(cardWidth: 70, thumbnailWidth: 52, thumbnailHeight: 46, cardHeight: 102, lineLimit: 2)
        }
    }

    /// 所有目录更新都有反馈，但项目越多动画越短。LazyVGrid 只实例化可见项目，
    /// 配合非弹簧动画可避免大目录同时计算数百个弹性布局。
    private var gridUpdateAnimation: Animation {
        switch service.items.count {
        case 0...80: return .easeInOut(duration: 0.18)
        case 81...300: return .easeOut(duration: 0.13)
        default: return .linear(duration: 0.1)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
            header
                .background(
                    DrawerToolbarMaterialBackground()
                        .allowsHitTesting(false)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(DrawerSystemColors.toolbarSeparator)
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        // 液态玻璃只作用于静态背景。若把 modifier 包在整个 ZStack 外层，
        // 每一帧滚动内容都会重新参与玻璃合成，大目录下 GPU 开销非常明显。
        .background {
            Rectangle()
                .fill(Color.clear)
                .modifier(
                    GlassEffectModifier(
                        variant: .regular,
                        cornerRadius: UIConfig.FileDrawer.cornerRadius
                    )
                )
        }
        .onAppear {
            installPreviewSourceFramesProvider()
            selectionAutoScroller.onBoundsChanged = {
                service.refreshPreviewSourceFramesIfPreviewing()
            }
            selectionAutoScroller.onLiveScrollChanged = { scrolling in
                if isLiveScrolling != scrolling {
                    isLiveScrolling = scrolling
                }
                Task {
                    await DrawerThumbnailWorkLimiter.shared.setLiveScrolling(scrolling)
                }
            }
        }
        .onChange(of: service.columnCount) { _, _ in
            installPreviewSourceFramesProvider()
        }
        .onChange(of: service.currentURL) { _, _ in
            // 切换标签会重建 ScrollView。缓存按目录身份隔离，避免新网格已经
            // 上报坐标后，又被 onChange 中迟到的旧状态清空。
            resetMarquee()
            itemGeometry.beginLocation(service.currentURL.path)
            selectionAutoScroller.stop()
            if isLiveScrolling {
                isLiveScrolling = false
            }
            Task {
                await DrawerThumbnailWorkLimiter.shared.setLiveScrolling(false)
            }
        }
        .onDisappear {
            service.setPreviewSourceFramesProvider(nil)
            selectionAutoScroller.onBoundsChanged = nil
            selectionAutoScroller.onLiveScrollChanged = nil
            Task {
                await DrawerThumbnailWorkLimiter.shared.setLiveScrolling(false)
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { newValue in
            if newValue > 0 && newValue != headerHeight {
                headerHeight = newValue
            }
        }
        .task(id: service.presentationID) {
            resetMarquee()
        }
        // 视图本身仍只实例化可见卡片；这里以单路、低优先级预热当前目录前段，
        // 让再次呼出或滚到下一屏时直接命中缓存，而不把 Quick Look 工作塞进滚动热路径。
        .task(id: "\(service.presentationID)|\(service.currentURL.path)|\(service.filteredItems.count)") {
            guard service.isPanelVisible else { return }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, service.isPanelVisible else { return }
            for item in service.filteredItems.prefix(160) {
                guard !Task.isCancelled, service.isPanelVisible else { return }
                _ = await DrawerThumbnailLoader.image(for: item, priority: .prefetch)
            }
        }
        .alert(
            "无法重命名",
            isPresented: Binding(
                get: { service.renameErrorMessage != nil },
                set: { if !$0 { service.renameErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { service.renameErrorMessage = nil }
        } message: {
            Text(service.renameErrorMessage ?? "")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { service.fileOperationErrorMessage != nil },
                set: { if !$0 { service.fileOperationErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { service.fileOperationErrorMessage = nil }
        } message: {
            Text(service.fileOperationErrorMessage ?? "")
        }
    }

    private func installPreviewSourceFramesProvider() {
        let geometry = itemGeometry
        let metrics = cardMetrics
        service.setPreviewSourceFramesProvider { [weak geometry] in
            guard let geometry else { return [:] }
            return DrawerPreviewGeometry.previewFrames(from: geometry.frames, metrics: metrics)
        }
    }

    private var header: some View {
        VStack(spacing: DrawerChromeMetrics.rowSpacing) {
            locationTabs
            toolbarRow
            if filterRowVisible {
                filterRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if searchRowVisible {
                searchRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Rectangle()
                .fill(DrawerSystemColors.toolbarSeparator)
                .frame(height: 1)
            pathBar
                .padding(.horizontal, DrawerChromeMetrics.rowHorizontalPadding)
                .padding(.bottom, 8)
        }
    }

    private var locationTabs: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(service.locations) { location in
                        Button {
                            // 系统液态玻璃自身会处理按压反馈；再套一层弹簧事务会导致
                            // 选中状态重建时出现一次闪白。
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                service.selectLocation(location.id)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: location.symbolName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(
                                        service.selectedLocationID == location.id ? DrawerSystemColors.accent : Color.secondary
                                    )
                                Text(location.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: DrawerChromeMetrics.controlHeight)
                            .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(DrawerTabButtonStyle(isSelected: service.selectedLocationID == location.id))
                        .contextMenu {
                            Button("在访达中打开") {
                                NSWorkspace.shared.open(location.url)
                            }
                            if location.isRemovable {
                                Divider()
                                Button("移除标签", role: .destructive) {
                                    service.removeLocation(location.id)
                                }
                            }
                        }
                    }
                }
            }

            Button {
                service.chooseFolder()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
            .frame(width: DrawerChromeMetrics.controlHeight, height: DrawerChromeMetrics.controlHeight)
            }
            .buttonStyle(DrawerToolbarButtonStyle(drawsSurface: false))
            .help("添加文件夹标签")

            Button {
                service.isPinned.toggle()
            } label: {
                Image(systemName: service.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(service.isPinned ? DrawerSystemColors.accent : Color.primary)
            .frame(width: DrawerChromeMetrics.controlHeight, height: DrawerChromeMetrics.controlHeight)
            }
            .buttonStyle(DrawerToolbarButtonStyle(drawsSurface: false))
            .help(service.isPinned ? "取消固定" : "固定窗口")

            Button {
                service.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
            .frame(width: DrawerChromeMetrics.controlHeight, height: DrawerChromeMetrics.controlHeight)
            }
            .buttonStyle(DrawerToolbarButtonStyle(drawsSurface: false))
            .help("关闭")
        }
        .padding(.horizontal, DrawerChromeMetrics.rowHorizontalPadding)
        .frame(height: 54)
    }

    private var pathBar: some View {
        pathBreadcrumbs
            .frame(maxWidth: .infinity)
            .frame(height: UIConfig.FileDrawer.pathBarHeight)
            .contentShape(Rectangle())
            .contextMenu {
                Button("拷贝文件路径") {
                    copyRelevantPath()
                }
            }
    }

    private var toolbarRow: some View {
        HStack(spacing: 0) {
            navigationGroup

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                circleToolbarButton("square.and.arrow.up", help: "隔空投送", disabled: service.selectedItemIDs.isEmpty) {
                    service.shareSelectedItemsViaAirDrop()
                }
                circleDetailsButton
                circleToolbarButton("trash", help: "移到废纸篓", disabled: service.selectedItemIDs.isEmpty) {
                    service.deleteSelectedItems()
                }
                circleToolbarButton("folder", help: "在访达中打开") {
                    service.revealInFinder()
                }
            }

            Spacer(minLength: 10)

            searchAndFilterGroup
        }
        .padding(.horizontal, DrawerChromeMetrics.rowHorizontalPadding)
        .frame(height: DrawerChromeMetrics.primaryActionSize)
    }

    private var searchRow: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)

            SearchTextField(text: $service.searchText, focusTrigger: $searchFocusTrigger)
                .frame(maxWidth: .infinity)
                .frame(height: 22)

            if !service.searchText.isEmpty {
                Button {
                    service.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(.white.opacity(0.42), lineWidth: 0.8)
        }
        .padding(.horizontal, DrawerChromeMetrics.rowHorizontalPadding)
    }

    private var navigationGroup: some View {
        HStack(spacing: 0) {
            toolbarButton(
                "chevron.left",
                help: "返回",
                disabled: !service.canNavigateBack,
                width: DrawerChromeMetrics.pairedButtonWidth
            ) {
                service.navigateBack()
            }
            Rectangle()
                .fill(DrawerSystemColors.toolbarSeparator)
                .frame(width: 1, height: 17)
                .allowsHitTesting(false)
            toolbarButton(
                "chevron.right",
                help: "前进",
                disabled: !service.canNavigateForward,
                width: DrawerChromeMetrics.pairedButtonWidth
            ) {
                service.navigateForward()
            }
        }
            .padding(2)
            .frame(
                width: DrawerChromeMetrics.pairedControlWidth,
                height: DrawerChromeMetrics.controlHeight
            )
            .modifier(DrawerGlassControlModifier(shape: .capsule, isEnabled: true))
    }

    /// 搜索与筛选共享一个承载胶囊；内部用细分隔线区分两项，避免右侧两个独立圆形
    /// 按钮在收紧后的工具栏中显得零散。
    private var searchAndFilterGroup: some View {
        HStack(spacing: 0) {
            toolbarToggleButton(
                "magnifyingglass",
                isActive: searchRowVisible,
                help: searchRowVisible ? "收起搜索" : "搜索"
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    searchRowVisible.toggle()
                    if searchRowVisible {
                        searchFocusTrigger += 1
                    } else {
                        service.searchText = ""
                    }
                }
            }

            Rectangle()
                .fill(DrawerSystemColors.toolbarSeparator)
                .frame(width: 1, height: 17)
                .allowsHitTesting(false)

            toolbarToggleButton(
                "line.3.horizontal.decrease.circle",
                isActive: filterRowVisible,
                help: filterRowVisible ? "收起筛选" : "展开筛选"
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    filterRowVisible.toggle()
                }
            }
        }
        .padding(2)
        .frame(
            width: DrawerChromeMetrics.pairedControlWidth,
            height: DrawerChromeMetrics.controlHeight
        )
        .modifier(DrawerGlassControlModifier(shape: .capsule, isEnabled: true))
    }

    private func toolbarToggleButton(
        _ symbol: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? DrawerSystemColors.accent : Color.primary)
                .frame(
                    width: DrawerChromeMetrics.pairedButtonWidth,
                    height: DrawerChromeMetrics.iconButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(DrawerToolbarButtonStyle(drawsSurface: false))
        .help(help)
    }

    private func toolbarButton(
        _ symbol: String,
        help: String,
        disabled: Bool = false,
        width: CGFloat = DrawerChromeMetrics.iconButtonSize,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(
                    width: width,
                    height: DrawerChromeMetrics.iconButtonSize
                )
        }
        .buttonStyle(DrawerToolbarButtonStyle(drawsSurface: false))
        .disabled(disabled)
        .help(help)
    }

    private var detailsButton: some View {
        Button {
            detailsPopoverVisible.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .frame(
                    width: DrawerChromeMetrics.iconButtonSize,
                    height: DrawerChromeMetrics.iconButtonSize
                )
        }
        .buttonStyle(DrawerToolbarButtonStyle())
        .disabled(service.selectedItem == nil)
        .help("显示详细信息")
        .popover(isPresented: $detailsPopoverVisible, arrowEdge: .bottom) {
            if let item = service.selectedItem {
                DrawerItemInfoPopover(item: item)
            }
        }
    }

    private var circleDetailsButton: some View {
        Button {
            detailsPopoverVisible.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .frame(
                    width: DrawerChromeMetrics.primaryActionSize,
                    height: DrawerChromeMetrics.primaryActionSize
                )
        }
        .buttonStyle(DrawerCircleButtonStyle())
        .disabled(service.selectedItem == nil)
        .help("显示详细信息")
        .popover(isPresented: $detailsPopoverVisible, arrowEdge: .bottom) {
            if let item = service.selectedItem {
                DrawerItemInfoPopover(item: item)
            }
        }
    }

    private func circleToolbarButton(
        _ symbol: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(
                    width: DrawerChromeMetrics.primaryActionSize,
                    height: DrawerChromeMetrics.primaryActionSize
                )
        }
        .buttonStyle(DrawerCircleButtonStyle())
        .disabled(disabled)
        .help(help)
    }

    private var filterRow: some View {
        HStack(spacing: DrawerChromeMetrics.rowSpacing) {
            filterMenuButton(
                symbol: "clock",
                title: service.timeFilter.title,
                requestID: $timeFilterMenuRequest,
                help: "按时间筛选"
            ) {
                FileDrawerTimeFilter.allCases.map { filter in
                    DrawerMenuOption(
                        title: filter.title,
                        isSelected: service.timeFilter == filter,
                        action: { service.timeFilter = filter }
                    )
                }
            }

            filterMenuButton(
                symbol: "folder",
                title: service.itemFilter.title,
                requestID: $filterMenuRequest,
                help: "按文件类型筛选"
            ) {
                FileDrawerFilter.allCases.map { filter in
                    DrawerMenuOption(
                        title: filter.title,
                        symbolName: filter.symbolName,
                        isSelected: service.itemFilter == filter,
                        action: { service.itemFilter = filter }
                    )
                }
            }

            filterMenuButton(
                symbol: "arrow.up.arrow.down",
                title: service.sortMode.title,
                requestID: $sortMenuRequest,
                help: "排序方式"
            ) {
                FileDrawerSortMode.allCases.map { mode in
                    DrawerMenuOption(
                        title: mode.title,
                        isSelected: service.sortMode == mode,
                        action: { service.sortMode = mode }
                    )
                }
            }

            // 排序方向
            Button {
                service.sortDirection = service.sortDirection == .ascending ? .descending : .ascending
            } label: {
                Image(systemName: service.sortDirection.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(
                        width: DrawerChromeMetrics.controlHeight,
                        height: DrawerChromeMetrics.controlHeight
                    )
            }
            .buttonStyle(DrawerToolbarButtonStyle())
            .help(service.sortDirection.title)

        }
        .padding(.horizontal, DrawerChromeMetrics.rowHorizontalPadding)
        .frame(height: 44)
    }

    private func filterMenuButton(
        symbol: String,
        title: String,
        requestID: Binding<Int>,
        help: String,
        options: @escaping () -> [DrawerMenuOption]
    ) -> some View {
        Button { requestID.wrappedValue &+= 1 } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(width: DrawerChromeMetrics.filterControlWidth, alignment: .leading)
            .frame(height: DrawerChromeMetrics.controlHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(DrawerFilterButtonStyle())
        .background(
            DrawerMenuPresenter(requestID: requestID.wrappedValue, options: options())
        )
        .help(help)
    }

    private var pathBreadcrumbs: some View {
        return GeometryReader { proxy in
            let widths = breadcrumbWidths(
                availableWidth: proxy.size.width
            )
            HStack(spacing: 0) {
                ForEach(Array(service.pathComponents.enumerated()), id: \.element.id) { index, component in
                    if index > 0 { breadcrumbSeparator }

                    let isCurrent = component.url == service.currentURL
                    let allocatedWidth = widths.indices.contains(index)
                        ? widths[index]
                        : breadcrumbCompactWidth
                    Button {
                        withAnimation(drawerMotion) {
                            service.navigate(to: component.url)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .systemBlue))
                                .fixedSize()

                            if allocatedWidth > breadcrumbCompactWidth + 5 {
                                Text(component.name)
                                    .font(.system(size: 10, weight: isCurrent ? .medium : .regular))
                                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .padding(.horizontal, 3)
                        .frame(width: allocatedWidth, height: 16, alignment: .leading)
                        .contentShape(Capsule(style: .continuous))
                        .clipped()
                    }
                    .buttonStyle(DrawerBarePathButtonStyle())
                    .help(component.url.path)
                    .onHover { hovering in
                        if hovering {
                            hoveredPathComponentID = component.id
                        } else if hoveredPathComponentID == component.id {
                            hoveredPathComponentID = nil
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
            .animation(.easeInOut(duration: 0.16), value: hoveredPathComponentID)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: service.currentURL) {
            hoveredPathComponentID = nil
        }
    }

    private var breadcrumbCompactWidth: CGFloat { 17 }
    private var breadcrumbSeparatorWidth: CGFloat { 9 }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: breadcrumbSeparatorWidth)
    }

    /// 先计算全部名称的自然宽度；只有放不下时才压缩。压缩后从当前目录开始
    /// 向前逐级分配剩余空间，因此最后一级完整后才会展开上一级，恰好处在边界
    /// 的那一级允许尾部截断。悬停目录临时取得最高优先级。
    private func breadcrumbWidths(availableWidth: CGFloat) -> [CGFloat] {
        let components = service.pathComponents
        let idealWidths = components.enumerated().map { index, component in
            let isCurrent = component.url == service.currentURL
            let font = NSFont.systemFont(ofSize: 10, weight: isCurrent ? .medium : .regular)
            let textWidth = ceil((component.name as NSString).size(withAttributes: [.font: font]).width)
            // 给 SwiftUI 字形亚像素取整和按钮内部布局留余量，避免“计算能放下，
            // 实际却差 1–2pt 被截断”的情况。
            return breadcrumbCompactWidth + 5 + textWidth
        }

        guard !idealWidths.isEmpty else { return [] }
        let separatorsWidth = CGFloat(max(0, idealWidths.count - 1)) * breadcrumbSeparatorWidth
        let contentWidth = max(0, availableWidth - separatorsWidth)
        if idealWidths.reduce(0, +) <= contentWidth { return idealWidths }

        var widths = Array(repeating: breadcrumbCompactWidth, count: idealWidths.count)
        var remaining = max(0, contentWidth - widths.reduce(0, +))
        var priority = Array(components.indices.reversed())
        if let hoveredPathComponentID,
           let hoveredIndex = components.firstIndex(where: { $0.id == hoveredPathComponentID }) {
            priority.removeAll { $0 == hoveredIndex }
            priority.insert(hoveredIndex, at: 0)
        }
        for index in priority where remaining > 0 {
            let addition = min(idealWidths[index] - breadcrumbCompactWidth, remaining)
            widths[index] += addition
            remaining -= addition
        }
        return widths
    }

    private func copyRelevantPath() {
        let path = service.selectedItem?.url.path ?? service.currentURL.path
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let error = service.errorMessage {
                DrawerEmptyState(
                    icon: "exclamationmark.folder",
                    title: "无法读取这个文件夹",
                    subtitle: error,
                    actionTitle: "重新选择",
                    action: { service.chooseFolder() }
                )
            } else if !service.isLoading && service.filteredItems.isEmpty {
                if service.itemFilter != .all {
                    DrawerEmptyState(
                        icon: service.itemFilter.symbolName,
                        title: "没有\(service.itemFilter.title)",
                        subtitle: "当前文件夹中没有这一类型的项目",
                        actionTitle: "显示全部",
                        action: { service.itemFilter = .all }
                    )
                } else if service.searchText.isEmpty {
                    DrawerEmptyState(
                        icon: "folder",
                        title: "这个文件夹是空的",
                        subtitle: "你可以把文件拖入这个文件夹",
                        actionTitle: "选择其他文件夹",
                        action: { service.chooseFolder() }
                    )
                } else {
                    DrawerEmptyState(
                        icon: "magnifyingglass",
                        title: "没有匹配的文件",
                        subtitle: "试试更短的关键词",
                        actionTitle: nil,
                        action: nil
                    )
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, alignment: .center, spacing: verticalGridSpacing) {
                        ForEach(service.filteredItems) { item in
                            FileDrawerItemCard(
                                item: item,
                                isSelected: service.selectedItemIDs.contains(item.id),
                                selectionCount: service.selectedItemIDs.contains(item.id)
                                    ? service.selectedItemIDs.count
                                    : 1,
                                isRenaming: service.renamingItemID == item.id,
                                allowsHoverEffects: !isLiveScrolling,
                                metrics: cardMetrics,
                                renameText: $service.renameDraft,
                                onSelect: {
                                    service.select(
                                        item,
                                        modifiers: NSEvent.modifierFlags.intersection([.command, .shift])
                                    )
                                },
                                onOpen: { service.open(item) },
                                onBeginRename: {
                                    service.select(item)
                                    service.beginRenamingSelectedItem()
                                },
                                onCommitRename: { service.commitRename() },
                                onCancelRename: { service.cancelRename() },
                                onPreview: { service.preview(item) },
                                onReveal: { service.revealInFinder(item) },
                                onOpenSelection: { service.openSelectedItems() },
                                onCopySelection: { service.copySelectedItems() },
                                onDuplicateSelection: { service.duplicateSelectedItems() },
                                onCopySelectionPaths: { service.copySelectedItemPaths() },
                                onShareSelection: { service.shareSelectedItemsViaAirDrop() },
                                onDeleteSelection: { service.deleteSelectedItems() },
                                onRevealSelection: { service.revealInFinder() },
                                onHover: { hovering in
                                    if hovering {
                                        service.setHoveredItem(item)
                                    } else if service.hoveredItemID == item.id {
                                        service.setHoveredItem(nil)
                                    }
                                }
                            )
                            .equatable()
                            .background {
                                if !isLiveScrolling {
                                    GeometryReader { proxy in
                                        let cellFrame = proxy.frame(in: .named(selectionSpaceName))
                                        // LazyVGrid 的单元格会撑满整列，卡片两侧的视觉空白
                                        // 不能算作“点到了文件”。否则从这些空白处起拖时会被
                                        // 误判为文件拖拽，框选矩形就不会出现。
                                        let hitRegion = DrawerItemHitRegion(
                                            itemName: item.name,
                                            metrics: cardMetrics,
                                            in: cellFrame
                                        )
                                        Color.clear.preference(
                                            key: DrawerItemFramePreferenceKey.self,
                                            value: DrawerItemFrameSnapshot(
                                                locationPath: service.currentURL.path,
                                                frames: [item.id: hitRegion]
                                            )
                                        )
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                    removal: .opacity.combined(with: .scale(scale: 0.985))
                                )
                            )
                            .id(item.id)
                        }
                        }
                        // 第一行与路径栏的间距和网格行距统一，给空白起拖框选留出
                        // 明确的空间，同时避免第一行看起来贴在路径栏下方。
                        .padding(.top, headerHeight + verticalGridSpacing)
                        .padding([.leading, .trailing], DrawerChromeMetrics.rowHorizontalPadding)
                        .padding(.bottom, service.columnCount >= 5 ? 16 : 20)
                        .animation(gridUpdateAnimation, value: service.filterVersion)
                        .animation(.easeOut(duration: 0.18), value: headerHeight)
                        .background {
                            DrawerScrollViewResolver(controller: selectionAutoScroller)
                        }
                    }
                    .onChange(of: service.keyboardFocusedItemID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                // 目录切换动画只替换滚动内容本身。框选覆盖层、手势和原生拖拽
                // 监听放在 identity 边界外，避免过渡期间生成两套交互层。
                .id(service.currentURL.path)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(
                            with: .scale(scale: 0.978, anchor: drawerEdgeAnchor)
                        ),
                        removal: .opacity.combined(
                            with: .scale(scale: 0.992, anchor: drawerEdgeAnchor)
                        )
                    )
                )
                // 命名坐标空间必须在 identity 边界外保持唯一。否则旧、新目录
                // 过渡时会同时存在两个同名空间，DragGesture 的坐标归属不确定。
                .coordinateSpace(name: selectionSpaceName)
                .contentShape(Rectangle())
                .onPreferenceChange(DrawerItemFramePreferenceKey.self) { snapshot in
                    // Preference 在视图销毁/重建交界处可能晚一帧抵达；只收当前
                    // 目录的快照，旧标签不能再污染新的命中判断。
                    guard snapshot.locationPath == service.currentURL.path else { return }
                    itemGeometry.update(snapshot)
                    recordVisibleMarqueeItems(in: snapshot.frames)
                }
                .background {
                    NativeFileDragSource(
                        itemGeometry: itemGeometry,
                        lookupItem: { service.item(withID: $0) },
                        selectForContextMenu: { item in
                            if !service.selectedItemIDs.contains(item.id) {
                                service.select(item)
                            }
                        },
                        prepareItems: { service.beginDragging($0) },
                        onDragEnded: { operation in
                            if operation.contains(.delete) {
                                _ = service.recycleDraggedItem()
                            } else {
                                service.finishDragging()
                            }
                        },
                        cardMetrics: cardMetrics
                    )
                }
                .overlay {
                    DrawerMarqueeOverlay(tracker: marqueeTracker)
                        .allowsHitTesting(false)
                }
                .simultaneousGesture(backgroundTapGesture)
                .simultaneousGesture(marqueeGesture)
            }

            if service.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            service.importDroppedItems(urls)
        }
        .contextMenu {
            Button("新建文件夹") {
                service.createNewFolder()
            }
            Divider()
            Button("粘贴项目") {
                service.pasteItems()
            }
            .disabled(!service.canPasteItems)
        }
        .animation(drawerMotion, value: service.currentURL.path)
        .animation(drawerMotion, value: service.selectedLocationID)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: service.isLoading)
    }

    private var backgroundTapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(selectionSpaceName))
            .onEnded { value in
                guard !itemGeometry.frames.values.contains(where: { $0.contains(value.location) }) else { return }
                service.handleBackgroundClick()
            }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(selectionSpaceName))
            .onChanged { value in
                if marqueeTracker.start == nil {
                    marqueeTracker.start = value.startLocation
                    marqueeTracker.selectionEnabled = !itemGeometry.frames.values.contains { $0.contains(value.startLocation) }
                    guard marqueeTracker.selectionEnabled, service.prepareForMarqueeSelection() else { return }
                    let modifiers = NSEvent.modifierFlags
                    let keepsExisting = modifiers.contains(.command) || modifiers.contains(.shift)
                    marqueeTracker.baseSelection = keepsExisting ? service.selectedItemIDs : []
                    marqueeTracker.currentLocation = value.location
                    marqueeTracker.scrollOffset = 0
                    marqueeTracker.record(
                        frames: itemGeometry.frames,
                        scrollOffset: 0
                    )
                    selectionAutoScroller.beginTracking { delta in
                        marqueeTracker.scrollOffset += delta
                        updateMarqueeSelection()
                    }
                }
                guard marqueeTracker.selectionEnabled else { return }
                marqueeTracker.currentLocation = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                if marqueeTracker.selectionEnabled {
                    service.setSelection(marqueeTracker.pendingSelection)
                }
                resetMarquee()
            }
    }

    private func resetMarquee() {
        service.finishMarqueeSelection()
        marqueeTracker.reset()
        selectionAutoScroller.stop()
    }

    private func recordVisibleMarqueeItems(in frames: [String: DrawerItemHitRegion]) {
        guard marqueeTracker.selectionEnabled else { return }
        marqueeTracker.record(frames: frames, scrollOffset: marqueeTracker.scrollOffset)
        updateMarqueeSelection()
    }

    private func updateMarqueeSelection() {
        guard marqueeTracker.selectionEnabled,
              let start = marqueeTracker.start,
              let current = marqueeTracker.currentLocation else { return }
        let currentInContent = CGPoint(
            x: current.x,
            y: current.y + marqueeTracker.scrollOffset
        )
        let contentRect = CGRect(
            x: min(start.x, currentInContent.x),
            y: min(start.y, currentInContent.y),
            width: abs(currentInContent.x - start.x),
            height: abs(currentInContent.y - start.y)
        )
        let visibleRect = contentRect.offsetBy(dx: 0, dy: -marqueeTracker.scrollOffset)

        // 先直接写入 CALayer，再发布选中集合。后者会让网格刷新；将绘制放在前面
        // 可确保刷新恰好发生在这一帧时，选区矩形也不会短暂丢失。
        marqueeTracker.render(rect: visibleRect)

        let enclosed = marqueeTracker.intersectingIDs(in: contentRect)
        marqueeTracker.pendingSelection = marqueeTracker.baseSelection.union(enclosed)
        // 只在命中集合实际变化时由 service 发布（setSelection 内有等值保护）。
        // 这样卡片直接使用与普通点击完全相同的图标灰底、名称蓝底和文字颜色，
        // 同时不会因每一个 mouseDragged 事件都重复刷新网格。
        service.setSelection(marqueeTracker.pendingSelection)
    }

}

/// 框选期间的所有高频状态都保存在非 Observable 引用中，避免每个鼠标事件
/// 使 FileDrawerPanelView 和 LazyVGrid 重新求值。视觉反馈直接写入 CALayer。
@MainActor
private final class DrawerMarqueeTracker {
    var start: CGPoint?
    var currentLocation: CGPoint?
    var scrollOffset: CGFloat = 0
    var contentFrames: [String: DrawerItemHitRegion] = [:]
    var selectionEnabled = false
    var baseSelection: Set<String> = []
    var pendingSelection: Set<String> = []
    private let bucketHeight: CGFloat = 180
    private var frameBuckets: [Int: Set<String>] = [:]
    private var bucketByID: [String: Int] = [:]

    // 路径切换的 SwiftUI 过渡中，旧、新 NSView 可能短暂共存。弱引用集合可
    // 保证旧层销毁时不会顺带断开仍在屏幕上的新层。
    private let overlayViews = NSHashTable<DrawerMarqueeOverlayView>.weakObjects()
    private var lastRect: CGRect?

    func attach(_ view: DrawerMarqueeOverlayView) {
        overlayViews.add(view)
        view.render(rect: lastRect)
    }

    func detach(_ view: DrawerMarqueeOverlayView) {
        overlayViews.remove(view)
    }

    func render(rect: CGRect) {
        lastRect = rect
        for view in overlayViews.allObjects {
            view.render(rect: rect)
        }
    }

    func record(frames: [String: DrawerItemHitRegion], scrollOffset: CGFloat) {
        for (id, visibleRegion) in frames {
            let region = visibleRegion.offsetBy(dx: 0, dy: scrollOffset)
            let bucket = Int(floor(region.boundingFrame.midY / bucketHeight))
            if let oldBucket = bucketByID[id], oldBucket != bucket {
                frameBuckets[oldBucket]?.remove(id)
            }
            contentFrames[id] = region
            bucketByID[id] = bucket
            frameBuckets[bucket, default: []].insert(id)
        }
    }

    func intersectingIDs(in rect: CGRect) -> Set<String> {
        let firstBucket = Int(floor(rect.minY / bucketHeight))
        let lastBucket = Int(floor(rect.maxY / bucketHeight))
        var result: Set<String> = []
        guard firstBucket <= lastBucket else { return result }
        for bucket in firstBucket...lastBucket {
            guard let ids = frameBuckets[bucket] else { continue }
            for id in ids where contentFrames[id]?.intersects(rect) == true {
                result.insert(id)
            }
        }
        return result
    }

    func reset() {
        start = nil
        currentLocation = nil
        scrollOffset = 0
        contentFrames = [:]
        selectionEnabled = false
        baseSelection = []
        pendingSelection = []
        frameBuckets = [:]
        bucketByID = [:]
        lastRect = nil
        for view in overlayViews.allObjects {
            view.render(rect: nil)
        }
    }
}

private struct DrawerMarqueeOverlay: NSViewRepresentable {
    let tracker: DrawerMarqueeTracker

    final class Coordinator {
        let tracker: DrawerMarqueeTracker

        init(tracker: DrawerMarqueeTracker) {
            self.tracker = tracker
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tracker: tracker)
    }

    func makeNSView(context: Context) -> DrawerMarqueeOverlayView {
        let view = DrawerMarqueeOverlayView(frame: .zero)
        tracker.attach(view)
        return view
    }

    func updateNSView(_ nsView: DrawerMarqueeOverlayView, context: Context) {
        tracker.attach(nsView)
    }

    static func dismantleNSView(_ nsView: DrawerMarqueeOverlayView, coordinator: Coordinator) {
        coordinator.tracker.detach(nsView)
    }
}

private final class DrawerMarqueeOverlayView: NSView {
    private let marqueeLayer = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marqueeLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        marqueeLayer.lineWidth = 1
        layer?.addSublayer(marqueeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marqueeLayer.frame = bounds
        CATransaction.commit()
    }

    func render(rect: CGRect?) {
        let marqueePath = rect.map {
            CGPath(roundedRect: $0, cornerWidth: 5, cornerHeight: 5, transform: nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marqueeLayer.path = marqueePath
        CATransaction.commit()
    }
}

private struct DrawerItemFrameSnapshot: Equatable {
    let locationPath: String
    var frames: [String: DrawerItemHitRegion]
}

private struct DrawerItemFramePreferenceKey: PreferenceKey {
    static var defaultValue = DrawerItemFrameSnapshot(locationPath: "", frames: [:])

    static func reduce(value: inout DrawerItemFrameSnapshot, nextValue: () -> DrawerItemFrameSnapshot) {
        let next = nextValue()
        guard !next.frames.isEmpty else { return }
        if value.locationPath != next.locationPath {
            value = next
        } else {
            value.frames.merge(next.frames, uniquingKeysWith: { _, new in new })
        }
    }
}

private enum DrawerAutoScrollDirection {
    case up
    case down
}

private final class DrawerSelectionAutoScroller {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var isTracking = false
    private var onDidScroll: ((CGFloat) -> Void)?
    private var boundsObserver: NSObjectProtocol?
    private var liveScrollBeginObserver: NSObjectProtocol?
    private var liveScrollEndObserver: NSObjectProtocol?
    var onBoundsChanged: (() -> Void)?
    var onLiveScrollChanged: ((Bool) -> Void)?

    func attach(_ scrollView: NSScrollView?) {
        guard let scrollView else { return }
        if self.scrollView === scrollView { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let liveScrollBeginObserver { NotificationCenter.default.removeObserver(liveScrollBeginObserver) }
        if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.onBoundsChanged?()
        }
        liveScrollBeginObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.onLiveScrollChanged?(true)
        }
        liveScrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.onLiveScrollChanged?(false)
        }
    }

    func beginTracking(onDidScroll: @escaping (CGFloat) -> Void) {
        stop()
        isTracking = true
        self.onDidScroll = onDidScroll

        let refreshRate = max(60, NSScreen.main?.maximumFramesPerSecond ?? 60)
        let timer = Timer(timeInterval: 1.0 / Double(refreshRate), repeats: true) { [weak self] _ in
            self?.scrollStep()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        scrollStep()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isTracking = false
        onDidScroll = nil
    }

    private func scrollStep() {
        guard isTracking,
              let scrollView,
              let documentView = scrollView.documentView,
              let window = scrollView.window else { return }
        let clipView = scrollView.contentView
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointer = clipView.convert(windowPoint, from: nil)
        let visible = clipView.bounds
        let horizontalMargin: CGFloat = 48
        guard pointer.x >= visible.minX - horizontalMargin,
              pointer.x <= visible.maxX + horizontalMargin else { return }

        let edgeZone: CGFloat = 58
        let distanceToTop: CGFloat
        let distanceToBottom: CGFloat
        if documentView.isFlipped {
            distanceToTop = pointer.y - visible.minY
            distanceToBottom = visible.maxY - pointer.y
        } else {
            distanceToTop = visible.maxY - pointer.y
            distanceToBottom = pointer.y - visible.minY
        }

        let direction: DrawerAutoScrollDirection
        let edgeDistance: CGFloat
        if distanceToTop <= edgeZone {
            direction = .up
            edgeDistance = distanceToTop
        } else if distanceToBottom <= edgeZone {
            direction = .down
            edgeDistance = distanceToBottom
        } else {
            return
        }

        let penetration = max(0, edgeZone - edgeDistance)
        let speed = min(18, 4 + penetration * 0.22)
        let logicalDelta: CGFloat = direction == .down ? speed : -speed
        let coordinateDelta = documentView.isFlipped ? logicalDelta : -logicalDelta
        let origin = clipView.bounds.origin
        let minimumY = documentView.bounds.minY
        let maximumY = max(minimumY, documentView.bounds.maxY - visible.height)
        let targetY = min(max(origin.y + coordinateDelta, minimumY), maximumY)
        guard abs(targetY - origin.y) > 0.1 else { return }

        clipView.scroll(to: NSPoint(x: origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        let updatedOrigin = clipView.bounds.origin
        let coordinateMovement = updatedOrigin.y - origin.y
        if abs(coordinateMovement) > 0.1 {
            let logicalMovement = documentView.isFlipped ? coordinateMovement : -coordinateMovement
            onDidScroll?(logicalMovement)
        }
    }

    deinit {
        timer?.invalidate()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let liveScrollBeginObserver { NotificationCenter.default.removeObserver(liveScrollBeginObserver) }
        if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
    }
}

private struct DrawerScrollViewResolver: NSViewRepresentable {
    let controller: DrawerSelectionAutoScroller

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView(frame: .zero)
        view.controller = controller
        view.resolveScrollView()
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.controller = controller
        nsView.resolveScrollView()
    }

    static func dismantleNSView(_ nsView: ResolverView, coordinator: Void) {
        nsView.controller?.stop()
    }

    final class ResolverView: NSView {
        weak var controller: DrawerSelectionAutoScroller?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveScrollView()
        }

        func resolveScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.controller?.attach(self.enclosingScrollView)
            }
        }
    }
}

@MainActor
private final class DrawerItemGeometryStore {
    var frames: [String: DrawerItemHitRegion] = [:]
    private var locationPath: String?

    func beginLocation(_ path: String) {
        guard locationPath != path else { return }
        locationPath = path
        frames = [:]
    }

    func update(_ snapshot: DrawerItemFrameSnapshot) {
        // 如果布局的 Preference 比 currentURL 的 onChange 更早送达，它已经是
        // 新目录的真实数据；直接接管身份，后续 beginLocation 不会误清空它。
        locationPath = snapshot.locationPath
        frames = snapshot.frames
    }
}

private struct DrawerCardMetrics: Equatable {
    let cardWidth: CGFloat
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let cardHeight: CGFloat
    let lineLimit: Int
}

/// 文件卡片不是一个实心可点矩形：缩略图和文件名之间、名字两侧都应仍是空白。
/// 所有点击、框选和原生文件拖拽共用这两个真实占位区域，避免交互范围互相不一致。
private struct DrawerItemHitRegion: Equatable {
    let thumbnailFrame: CGRect
    let nameFrame: CGRect

    init(itemName: String, metrics: DrawerCardMetrics, in cellFrame: CGRect) {
        let thumbnailOuterWidth = min(metrics.thumbnailWidth + 12, cellFrame.width)
        let thumbnailOuterHeight = metrics.thumbnailHeight + 12
        let filenameMeasurement = DrawerFilenameMetrics.measure(
            itemName,
            maximumTextWidth: metrics.cardWidth - 8
        )
        let nameWidth = min(
            metrics.cardWidth,
            filenameMeasurement.displayTextWidth + DrawerFilenameMetrics.horizontalTextInset * 2
        )
        let nameHeight = filenameMeasurement.displayTextHeight
            + DrawerFilenameMetrics.verticalTextInset * 2

        thumbnailFrame = CGRect(
            x: cellFrame.midX - thumbnailOuterWidth / 2,
            y: cellFrame.minY,
            width: thumbnailOuterWidth,
            height: thumbnailOuterHeight
        )
        nameFrame = CGRect(
            x: cellFrame.midX - nameWidth / 2,
            y: cellFrame.minY + thumbnailOuterHeight + 4,
            width: nameWidth,
            height: nameHeight
        )
    }

    var boundingFrame: CGRect {
        thumbnailFrame.union(nameFrame)
    }

    func contains(_ point: CGPoint) -> Bool {
        thumbnailFrame.contains(point) || nameFrame.contains(point)
    }

    func intersects(_ rect: CGRect) -> Bool {
        thumbnailFrame.intersects(rect) || nameFrame.intersects(rect)
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> DrawerItemHitRegion {
        DrawerItemHitRegion(
            thumbnailFrame: thumbnailFrame.offsetBy(dx: dx, dy: dy),
            nameFrame: nameFrame.offsetBy(dx: dx, dy: dy)
        )
    }

    private init(thumbnailFrame: CGRect, nameFrame: CGRect) {
        self.thumbnailFrame = thumbnailFrame
        self.nameFrame = nameFrame
    }
}

private struct DrawerItemHitShape: Shape {
    let itemName: String
    let metrics: DrawerCardMetrics

    func path(in rect: CGRect) -> Path {
        let region = DrawerItemHitRegion(itemName: itemName, metrics: metrics, in: rect)
        var path = Path()
        path.addRoundedRect(in: region.thumbnailFrame, cornerSize: CGSize(width: 9, height: 9))
        path.addRoundedRect(in: region.nameFrame, cornerSize: CGSize(width: 4, height: 4))
        return path
    }
}

@MainActor
private enum DrawerPreviewGeometry {
    static func previewFrames(
        from cardFrames: [String: DrawerItemHitRegion],
        metrics: DrawerCardMetrics
    ) -> [String: CGRect] {
        cardFrames.reduce(into: [:]) { result, entry in
            let cardFrame = entry.value.thumbnailFrame
            let container = CGRect(
                x: cardFrame.midX - metrics.thumbnailWidth / 2,
                y: cardFrame.minY + 6,
                width: min(metrics.thumbnailWidth, cardFrame.width),
                height: min(metrics.thumbnailHeight, cardFrame.height)
            )
            guard let image = DrawerThumbnailCache.shared.image(for: entry.key),
                  image.size.width > 0,
                  image.size.height > 0 else {
                result[entry.key] = container.insetBy(dx: 10, dy: 10)
                return
            }
            let scale = min(container.width / image.size.width, container.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            result[entry.key] = CGRect(
                x: container.midX - size.width / 2,
                y: container.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}

private struct DrawerItemInfoPopover: View {
    let item: FileDrawerItem

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var kindTitle: String {
        item.isBrowsableDirectory ? "文件夹" : item.kind.title
    }

    private var sizeTitle: String {
        guard let size = item.fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: item.isBrowsableDirectory ? "folder.fill" : item.kind.symbolName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(item.isBrowsableDirectory ? DrawerSystemColors.accent : Color.secondary)
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }

            infoRow("类型", kindTitle)
            infoRow("大小", sizeTitle)
            if let date = item.modificationDate {
                infoRow("修改日期", Self.dateFormatter.string(from: date))
            }
            Text(item.url.path)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5))
    }
}

private struct FileDrawerItemCard: View, Equatable {
    let item: FileDrawerItem
    let isSelected: Bool
    let selectionCount: Int
    let isRenaming: Bool
    let allowsHoverEffects: Bool
    let metrics: DrawerCardMetrics
    @Binding var renameText: String
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onOpenSelection: () -> Void
    let onCopySelection: () -> Void
    let onDuplicateSelection: () -> Void
    let onCopySelectionPaths: () -> Void
    let onShareSelection: () -> Void
    let onDeleteSelection: () -> Void
    let onRevealSelection: () -> Void
    let onHover: (Bool) -> Void
    @State private var lastTapDate = Date.distantPast
    @State private var isHovered = false
    @State private var hoverBounds = CGRect.zero

    /// 图标区域选中背景：统一灰色矩形（访达风格）
    private var iconSelectionFill: Color {
        Color.primary.opacity(0.14)
    }

    /// 文件名选中背景：蓝色（访达风格）
    private var nameSelectionFill: Color {
        DrawerSystemColors.accent
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.selectionCount == rhs.selectionCount
            && lhs.isRenaming == rhs.isRenaming
            && lhs.allowsHoverEffects == rhs.allowsHoverEffects
            && lhs.metrics == rhs.metrics
    }

    var body: some View {
        VStack(spacing: 4) {
            // 图标卡片 —— 独占背景框、悬停效果
            DrawerThumbnail(item: item)
                .frame(width: metrics.thumbnailWidth, height: metrics.thumbnailHeight)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            isSelected
                                ? iconSelectionFill
                                : Color.primary.opacity(isHovered ? 0.08 : 0)
                        )
                }
                .scaleEffect(isHovered ? 1.025 : 1)
                .offset(y: isHovered ? -1.5 : 0)
                .shadow(color: .black.opacity(isHovered ? 0.1 : 0), radius: 4, y: 2)
                .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.82), value: isHovered)

            // 名称区域 —— 完全独立，不在任何框内
            if isRenaming {
                DrawerRenameField(
                    text: $renameText,
                    cardWidth: metrics.cardWidth,
                    onCommit: onCommitRename,
                    onCancel: onCancelRename
                )
            } else {
                // 匹配 Finder 网格视图：
                // - lineLimit(2) 允许换行到 2 行，第 2 行放不下时中间截断保留扩展名
                // - truncationMode(.middle) 只在 Text 真正触发截断时生效（即最后一行）
                // - fixedSize(horizontal: false, vertical: true) 让 Text 在固定 maxWidth 内
                //   垂直方向自适应换行，而不是被外层固定高度压缩成单行
                Text(item.name)
                    .font(.system(size: DrawerFilenameMetrics.fontSize, weight: .regular))
                    .foregroundStyle(
                        isSelected
                            ? Color(nsColor: DrawerSystemColors.selectedText)
                            : Color.primary
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(metrics.lineLimit)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(nameSelectionFill)
                        }
                    }
                    .frame(maxWidth: metrics.cardWidth - 8)
                    .help(item.name)
            }
        }
        // 匹配 Finder：重命名时文本框向下扩展覆盖下一行，而不是把整行往下挤。
        // 固定卡片的布局高度为正常显示状态的高度（metrics.cardHeight），
        // 文本框超出部分自然溢出（SwiftUI 默认不裁剪），通过 zIndex 浮于下方卡片之上。
        .frame(height: metrics.cardHeight, alignment: .top)
        .zIndex(isRenaming ? 1 : 0)
        .contentShape(DrawerItemHitShape(itemName: item.name, metrics: metrics))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        hoverBounds = CGRect(origin: .zero, size: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, size in
                        hoverBounds = CGRect(origin: .zero, size: size)
                    }
            }
        }
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onTapGesture(perform: handleTap)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                let region = DrawerItemHitRegion(
                    itemName: item.name,
                    metrics: metrics,
                    in: hoverBounds
                )
                updateHover(region.contains(location))
            case .ended:
                updateHover(false)
            }
        }
        .onChange(of: allowsHoverEffects) { _, allowsHoverEffects in
            if !allowsHoverEffects, isHovered {
                isHovered = false
                onHover(false)
            }
        }
        .contextMenu {
            if selectionCount > 1 {
                Button("打开 \(selectionCount) 个项目", action: onOpenSelection)
                Button("快速查看 \(selectionCount) 个项目", action: onPreview)
                Divider()
                Button("拷贝 \(selectionCount) 个项目", action: onCopySelection)
                Button("制作 \(selectionCount) 个副本", action: onDuplicateSelection)
                Button("拷贝 \(selectionCount) 个文件路径", action: onCopySelectionPaths)
                Button("隔空投送…", action: onShareSelection)
                Button("在访达中显示", action: onRevealSelection)
                Divider()
                Button("移到废纸篓", role: .destructive, action: onDeleteSelection)
            } else {
                Button(item.isBrowsableDirectory ? "打开文件夹" : "打开", action: onOpen)
                Button("快速查看", action: onPreview)
                Divider()
                Button("拷贝", action: onCopySelection)
                Button("制作副本", action: onDuplicateSelection)
                Button("拷贝文件路径") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(item.url.path, forType: .string)
                }
                Button("重命名", action: onBeginRename)
                Button("隔空投送…", action: onShareSelection)
                Button("在访达中显示", action: onReveal)
                Divider()
                Button("移到废纸篓", role: .destructive, action: onDeleteSelection)
            }
        }
    }

    private func handleTap() {
        let now = Date()
        let isDoubleClick = now.timeIntervalSince(lastTapDate) < NSEvent.doubleClickInterval
        onSelect()
        if isDoubleClick {
            lastTapDate = .distantPast
            onOpen()
        } else {
            lastTapDate = now
        }
    }

    private func updateHover(_ hovering: Bool) {
        guard allowsHoverEffects else {
            if isHovered {
                isHovered = false
                onHover(false)
            }
            return
        }
        guard isHovered != hovering else { return }
        isHovered = hovering
        onHover(hovering)
    }
}

private struct DrawerRenameField: View {
    @Binding var text: String
    let cardWidth: CGFloat
    let onCommit: () -> Void
    let onCancel: () -> Void
    @State private var measuredSize: CGSize

    init(
        text: Binding<String>,
        cardWidth: CGFloat,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = text
        self.cardWidth = cardWidth
        self.onCommit = onCommit
        self.onCancel = onCancel
        _measuredSize = State(
            initialValue: DrawerFilenameMetrics.measure(
                text.wrappedValue,
                maximumTextWidth: cardWidth - 16
            ).editorSize
        )
    }

    var body: some View {
        RenameTextViewRepresentable(
            text: $text,
            editorWidth: measuredSize.width,
            cardWidth: cardWidth,
            onMeasure: { size in
                if abs(size.width - measuredSize.width) > 0.5 || abs(size.height - measuredSize.height) > 0.5 {
                    measuredSize = size
                }
            },
            onCommit: onCommit,
            onCancel: onCancel
        )
        .frame(width: measuredSize.width, height: measuredSize.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DrawerSystemColors.accent, lineWidth: 2)
        )
    }

}

private struct RenameTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let editorWidth: CGFloat
    let cardWidth: CGFloat
    let onMeasure: (CGSize) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let width = min(cardWidth, editorWidth)
        let lineHeight: CGFloat = 14
        let verticalInset = DrawerFilenameMetrics.verticalTextInset * 2

        let scrollView = RenameScrollView(frame: NSRect(x: 0, y: 0, width: width, height: lineHeight + verticalInset))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // autohides：只在滚动时显示，平时隐藏，不预留空间
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // overlay 不占布局空间；文本容器会为滚动条预留右侧安全区。
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.controlSize = .small
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.autoresizingMask = [.width]

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: lineHeight + verticalInset))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.font = .systemFont(ofSize: DrawerFilenameMetrics.fontSize, weight: .regular)
        textView.alignment = .center
        // 仅保留必要的内边距：短名称不再因过大的最小编辑区产生可见留白；
        // 右侧仍留出滚动条安全区。
        // textContainerInset=4 + lineFragmentPadding=0：视觉内边距=4pt（和非编辑态 .padding(.horizontal,4) 一致）。
        // containerSize 直接等于文本区宽度，不会因 lineFragmentPadding 导致文本区 < 0。
        textView.textContainerInset = NSSize(
            width: DrawerFilenameMetrics.horizontalTextInset,
            height: DrawerFilenameMetrics.verticalTextInset
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.allowsUndo = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.maximumWidth = cardWidth - 16
        context.coordinator.onMeasure = onMeasure
        context.coordinator.measureAndResize()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.onMeasure = onMeasure
        context.coordinator.maximumWidth = cardWidth - 16

        let width = min(cardWidth, editorWidth)
        if abs(nsView.frame.width - width) > 0.5 {
            var frame = nsView.frame
            frame.size.width = width
            nsView.frame = frame
            // 不在这里设置 containerSize：widthTracksTextView=false，容器宽度完全由 measureAndResize 控制
        }

        if textView.string != text {
            textView.string = text
        }

        if context.coordinator.needsSelectBaseName {
            context.coordinator.needsSelectBaseName = false
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                let ext = (text as NSString).pathExtension
                // NSTextView 使用 UTF-16 NSRange。文件名包含 emoji 或组合字符时不能用 String.count。
                let fullLength = (text as NSString).length
                let baseLen = ext.isEmpty ? fullLength : fullLength - (ext as NSString).length - 1
                textView.setSelectedRange(NSRange(location: 0, length: baseLen))
                context.coordinator.measureAndResize()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onCommit: () -> Void
        let onCancel: () -> Void
        var needsSelectBaseName = true
        weak var textView: NSTextView?
        var maximumWidth: CGFloat = 60
        var onMeasure: ((CGSize) -> Void)?
        private var lastReportedSize: CGSize = .zero

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            _text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            measureAndResize()
            // 输入到第三行以后，确保插入点仍在可见区域；这也是 Finder 重命名长文件名的关键细节。
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }

        func measureAndResize() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let measurement = DrawerFilenameMetrics.measure(
                textView.string,
                maximumTextWidth: maximumWidth
            )
            textContainer.containerSize.width = measurement.editorTextWidth
            layoutManager.ensureLayout(for: textContainer)

            let font = textView.font ?? .systemFont(ofSize: DrawerFilenameMetrics.fontSize)
            let lineHeight = layoutManager.defaultLineHeight(for: font)
            let verticalInset = textView.textContainerInset.height * 2
            let usedRect = layoutManager.usedRect(for: textContainer)
            let contentHeight = max(lineHeight, usedRect.height) + verticalInset
            let maximumHeight = lineHeight * DrawerFilenameMetrics.maximumRenameLines + verticalInset
            let editorSize = CGSize(
                width: measurement.editorSize.width,
                height: min(ceil(contentHeight), ceil(maximumHeight))
            )

            if abs(textView.frame.height - contentHeight) > 0.5 {
                var frame = textView.frame
                frame.size.height = contentHeight
                textView.frame = frame
            }
            if let scrollView = textView.enclosingScrollView {
                if abs(scrollView.frame.height - editorSize.height) > 0.5 {
                    var frame = scrollView.frame
                    frame.size.height = editorSize.height
                    scrollView.frame = frame
                }
            }
            if editorSize != lastReportedSize {
                lastReportedSize = editorSize
                onMeasure?(editorSize)
            }
        }
    }
}

/// 重命名框是一个独立的滚动区域；指针悬停在此处时绝不把滚轮交给外层文件网格。
private final class RenameScrollView: NSScrollView {
    private var bounceGeneration = 0

    override func scrollWheel(with event: NSEvent) {
        guard let documentView,
              documentView.bounds.height > contentView.bounds.height + 0.5 else {
            return
        }

        let clipView = contentView
        let origin = clipView.bounds.origin
        let minY = documentView.bounds.minY
        let maxY = max(minY, documentView.bounds.maxY - clipView.bounds.height)
        // NSTextView 为 flipped 坐标；向下滚动时 scrollingDeltaY 为负。
        let proposedY = origin.y - event.scrollingDeltaY
        let targetY = min(max(proposedY, minY), maxY)

        if abs(targetY - proposedY) > 0.1 {
            bounce(atTop: proposedY < minY, amount: abs(targetY - proposedY))
            return // 不把已到边界的滚轮事件交给外层文件网格。
        }

        clipView.scroll(to: NSPoint(x: origin.x, y: targetY))
        reflectScrolledClipView(clipView)
    }

    private func bounce(atTop: Bool, amount: CGFloat) {
        wantsLayer = true
        guard let layer else { return }
        bounceGeneration &+= 1
        let generation = bounceGeneration
        let distance = min(4, max(1, amount * 0.12)) * (atTop ? -1 : 1)
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = distance
        animation.toValue = 0
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "renameEditorBounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self?.bounceGeneration == generation else { return }
            self?.layer?.removeAnimation(forKey: "renameEditorBounce")
        }
    }
}

private struct DrawerThumbnail: View {
    let item: FileDrawerItem
    @State private var image: NSImage?

    /// Quick Look 对图标资源常返回非方形的预览画布；访达则把它们作为系统文件图标显示。
    private var usesSystemFileIcon: Bool {
        ["icns", "ico", "icon"].contains(item.url.pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // 首次展开目录时 Quick Look 尚未给出最终缩略图/文件图标。与其先
                // 显示一个会立刻替换的 SF Symbol，不如保留图标位为空，避免视觉闪烁。
                Color.clear
            }
        }
        .task(id: item.thumbnailVersion, priority: .utility) {
            image = DrawerThumbnailCache.shared.image(for: item.id, version: item.thumbnailVersion)
            guard image == nil else { return }
            image = await DrawerThumbnailLoader.image(for: item, priority: .visible)
        }
    }
}

private enum DrawerThumbnailLoadPriority {
    case visible
    case prefetch
}

/// 所有 Quick Look 请求统一经过这里，确保可见卡片永远优先于后台预热。
@MainActor
private enum DrawerThumbnailLoader {
    static func image(
        for item: FileDrawerItem,
        priority: DrawerThumbnailLoadPriority
    ) async -> NSImage? {
        let version = item.thumbnailVersion
        if let cached = DrawerThumbnailCache.shared.image(for: item.id, version: version) {
            return cached
        }
        if let data = await DrawerThumbnailDiskCache.load(for: item),
           let diskImage = NSImage(data: data) {
            DrawerThumbnailCache.shared.store(diskImage, for: item.id, version: version)
            return diskImage
        }
        guard await DrawerThumbnailWorkLimiter.shared.acquire(priority: priority) else { return nil }
        defer {
            Task { await DrawerThumbnailWorkLimiter.shared.release() }
        }
        guard !Task.isCancelled else { return nil }

        let usesSystemFileIcon = ["icns", "ico", "icon"].contains(item.url.pathExtension.lowercased())
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 128, height: 96),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: item.isBrowsableDirectory || usesSystemFileIcon
                ? .icon
                : [.thumbnail, .icon]
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              !Task.isCancelled else {
            // 不在滚动热路径同步调用 NSWorkspace.icon(forFile:)；失败时保持空白，
            // 也避免先闪现一个与最终图标不一致的占位符。
            return nil
        }
        DrawerThumbnailCache.shared.store(representation.nsImage, for: item.id, version: version)
        DrawerThumbnailDiskCache.store(representation.cgImage, for: item)
        return representation.nsImage
    }
}

/// 跨应用重启保留小尺寸 Quick Look 缩略图。磁盘 I/O 一律在 utility 任务中进行，
/// 文件版本已经包含修改时间与大小，源文件变更时会自然切换到新缓存键。
private enum DrawerThumbnailDiskCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("MagicStage/DrawerThumbnails", isDirectory: true)
    }()

    static func load(for item: FileDrawerItem) async -> Data? {
        let url = fileURL(for: item)
        return await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }

    static func store(_ image: CGImage, for item: FileDrawerItem) {
        let url = fileURL(for: item)
        let cacheDirectory = directory
        Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.tiff.identifier as CFString,
                1,
                nil
            ) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }

            let manager = FileManager.default
            try? manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? (data as Data).write(to: url, options: .atomic)
            await DrawerThumbnailCachePruner.shared.pruneIfNeeded(
                directory: cacheDirectory,
                using: manager
            )
        }
    }

    private static func fileURL(for item: FileDrawerItem) -> URL {
        directory.appendingPathComponent("\(stableHash(item.thumbnailVersion)).tiff", isDirectory: false)
    }

    private static func stableHash(_ value: String) -> String {
        // FNV-1a：缓存文件名只需稳定、无路径字符，并不承载安全用途。
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

}

/// 写入缩略图时不能每次都枚举整个缓存目录。串行 actor 同时避免多个后台
/// 写入任务重复清理，并将最多每五分钟一次的磁盘扫描移出交互热路径。
private actor DrawerThumbnailCachePruner {
    static let shared = DrawerThumbnailCachePruner()
    private var lastPruneDate = Date.distantPast

    func pruneIfNeeded(directory: URL, using manager: FileManager) {
        let now = Date()
        guard now.timeIntervalSince(lastPruneDate) >= 300 else { return }
        lastPruneDate = now
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ), files.count > 1_400 else { return }
        let oldestFirst = files.sorted {
            let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
        for url in oldestFirst.prefix(300) {
            try? manager.removeItem(at: url)
        }
    }
}

@MainActor
final class DrawerThumbnailCache {
    static let shared = DrawerThumbnailCache()
    private struct RetainedImage {
        let image: NSImage
        let version: String?
    }
    private let versions: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1_024
        return cache
    }()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 1_024
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()
    // NSCache 会在睡眠后的内存回收中主动清空。保留一小段强引用 LRU，让常用目录
    // 再次呼出时不用从空白重新开始；上限约 20 MB，不会挤占抽屉滚动所需的内存。
    private var retainedImages: [String: RetainedImage] = [:]
    private var retainedOrder: [String] = []
    private let retainedLimit = 360

    func image(for id: String, version: String? = nil) -> NSImage? {
        if let retained = retainedImages[id], version == nil || retained.version == version {
            touchRetainedImage(id)
            return retained.image
        }
        if let version,
           versions.object(forKey: id as NSString)?.isEqual(to: version) != true { return nil }
        guard let image = cache.object(forKey: id as NSString) else { return nil }
        let cachedVersion = version ?? (versions.object(forKey: id as NSString) as String?)
        retain(image, for: id, version: cachedVersion)
        return image
    }

    func store(_ image: NSImage, for id: String, version: String? = nil) {
        let key = id as NSString
        let pixelWidth = max(1, Int(image.size.width * 2))
        let pixelHeight = max(1, Int(image.size.height * 2))
        cache.setObject(image, forKey: key, cost: pixelWidth * pixelHeight * 4)
        if let version { versions.setObject(version as NSString, forKey: key) }
        retain(image, for: id, version: version)
    }

    private func retain(_ image: NSImage, for id: String, version: String?) {
        retainedImages[id] = RetainedImage(image: image, version: version)
        touchRetainedImage(id)
        while retainedOrder.count > retainedLimit {
            retainedImages.removeValue(forKey: retainedOrder.removeFirst())
        }
    }

    private func touchRetainedImage(_ id: String) {
        retainedOrder.removeAll { $0 == id }
        retainedOrder.append(id)
    }
}

private actor DrawerThumbnailWorkLimiter {
    static let shared = DrawerThumbnailWorkLimiter(limit: 3)

    private struct Waiter {
        let id: UUID
        let priority: DrawerThumbnailLoadPriority
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var availablePermits: Int
    private var waiters: [Waiter] = []
    private var isLiveScrolling = false

    init(limit: Int) {
        availablePermits = limit
    }

    func acquire(priority: DrawerThumbnailLoadPriority) async -> Bool {
        guard !Task.isCancelled else { return false }
        // 后台预热最多占一条通道，另外两条永远留给当前可见的缩略图。
        let canStartImmediately: Bool
        switch priority {
        case .visible:
            canStartImmediately = availablePermits > 0
        case .prefetch:
            canStartImmediately = availablePermits > 2
        }
        if !isLiveScrolling, canStartImmediately {
            availablePermits -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        availablePermits += 1
        guard !isLiveScrolling else { return }
        resumeWaitingWork()
    }

    func setLiveScrolling(_ scrolling: Bool) {
        guard isLiveScrolling != scrolling else { return }
        isLiveScrolling = scrolling
        guard !scrolling else { return }
        resumeWaitingWork()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func resumeWaitingWork() {
        while availablePermits > 0, !waiters.isEmpty {
            // 能立刻呈现的卡片优先；预热只有在仍空出两条通道时才能继续。
            if let visibleIndex = waiters.firstIndex(where: {
                if case .visible = $0.priority { return true }
                return false
            }) {
                availablePermits -= 1
                waiters.remove(at: visibleIndex).continuation.resume(returning: true)
            } else if availablePermits > 2 {
                availablePermits -= 1
                waiters.removeFirst().continuation.resume(returning: true)
            } else {
                return
            }
        }
    }

}

private struct NativeFileDragSource: NSViewRepresentable {
    let itemGeometry: DrawerItemGeometryStore
    let lookupItem: (String) -> FileDrawerItem?
    let selectForContextMenu: (FileDrawerItem) -> Void
    let prepareItems: (FileDrawerItem) -> [FileDrawerItem]
    let onDragEnded: (NSDragOperation) -> Void
    let cardMetrics: DrawerCardMetrics

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughDragTrackingView {
        let view = PassthroughDragTrackingView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PassthroughDragTrackingView, context: Context) {
        context.coordinator.itemGeometry = itemGeometry
        context.coordinator.lookupItem = lookupItem
        context.coordinator.selectForContextMenu = selectForContextMenu
        context.coordinator.prepareItems = prepareItems
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.cardMetrics = cardMetrics
    }

    static func dismantleNSView(_ nsView: PassthroughDragTrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSDraggingSource {
        weak var view: PassthroughDragTrackingView?
        var itemGeometry: DrawerItemGeometryStore?
        var cardMetrics: DrawerCardMetrics?
        var lookupItem: ((String) -> FileDrawerItem?)?
        var selectForContextMenu: ((FileDrawerItem) -> Void)?
        var prepareItems: ((FileDrawerItem) -> [FileDrawerItem])?
        var onDragEnded: ((NSDragOperation) -> Void)?

        private var eventMonitor: Any?
        private var pressedItemID: String?
        private var pressLocation: CGPoint?
        private var sessionStarted = false
        private var returnGhosts: [ReturnGhost] = []

        private struct ReturnGhost {
            let targetFrame: NSRect
            let image: NSImage
            let stagger: CGFloat
        }

        func attach(to view: PassthroughDragTrackingView) {
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func detach() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            if sessionStarted { onDragEnded?([]) }
            reset()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, event.window === view.window else {
                if event.type == .leftMouseUp { reset() }
                return event
            }
            // beginDraggingSession 进入 AppKit 的拖拽跟踪循环后，本地事件 monitor
            // 仍会收到每一帧 leftMouseDragged。此时无需再做 hitTest 和坐标换算；
            // 旧实现每帧遍历视图层级，是拖拽过程中持续卡顿的主要来源。
            if sessionStarted { return event }
            // 重命名 NSTextView 的文字选择/拖动属于编辑操作，不能被文件拖放层截获；
            // 否则会启动文件拖拽并带动外层网格滚动。
            if isRenameEditorInteraction(event) {
                if event.type == .leftMouseDown || event.type == .leftMouseUp { reset() }
                return event
            }
            let location = view.convert(event.locationInWindow, from: nil)

            switch event.type {
            case .rightMouseDown:
                if let itemID = itemGeometry?.frames.first(where: { $0.value.contains(location) })?.key,
                   let item = lookupItem?(itemID) {
                    selectForContextMenu?(item)
                }
                return event
            case .leftMouseDown:
                pressedItemID = itemGeometry?.frames.first { $0.value.contains(location) }?.key
                pressLocation = location
                sessionStarted = false
                returnGhosts = []
                return event
            case .leftMouseDragged:
                guard !sessionStarted,
                      let pressedItemID,
                      let pressLocation,
                      hypot(location.x - pressLocation.x, location.y - pressLocation.y) >= 4,
                      let item = lookupItem?(pressedItemID),
                      let draggedItems = prepareItems?(item),
                      !draggedItems.isEmpty else { return event }

                sessionStarted = true
                let draggingItems = makeDraggingItems(draggedItems, at: location)
                let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
                // 默认 formation 会让缩略图以带弹性的编队追赶鼠标，视觉上像是卡顿。
                // 坐标已经在 makeDraggingItems 中排好，禁用系统二次编队即可逐帧紧跟指针。
                session.draggingFormation = .none
                // 自定义回位会从放手点开始持续淡出，因此必须从 session 开始就
                // 禁用系统回弹，避免两套图层在结束时重叠。
                session.animatesToStartingPositionsOnCancelOrFail = false
                return nil
            case .leftMouseUp:
                if !sessionStarted { reset() }
                return event
            default:
                return event
            }
        }

        private func isRenameEditorInteraction(_ event: NSEvent) -> Bool {
            guard let contentView = event.window?.contentView else { return false }
            let point = contentView.convert(event.locationInWindow, from: nil)
            var candidate = contentView.hitTest(point)
            while let view = candidate {
                if view is NSTextView || view is RenameScrollView { return true }
                candidate = view.superview
            }
            return false
        }

        private func makeDraggingItems(_ items: [FileDrawerItem], at point: CGPoint) -> [NSDraggingItem] {
            returnGhosts = []

            return items.enumerated().map { index, item in
                let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
                if index < 4 {
                    let stagger = CGFloat(min(index, 3)) * 4
                    let image = Self.dragSourceImage(for: item)
                    let visualSize = aspectFitSize(
                        image.size,
                        inside: dragCanvasSize
                    )
                    // 从第一帧起让缩略图中心贴住鼠标。旧实现使用来源卡片作为
                    // draggingFrame，越过启动阈值后会显得缩略图在追赶指针。
                    let frame = NSRect(
                        x: point.x - visualSize.width / 2 + stagger,
                        y: point.y - visualSize.height / 2 + stagger,
                        width: visualSize.width,
                        height: visualSize.height
                    )
                    let targetFrame: NSRect
                    if let sourceRegion = itemGeometry?.frames[item.id] {
                        let sourceFrame = sourceRegion.thumbnailFrame
                        let thumbX = sourceFrame.midX - visualSize.width / 2
                        let thumbY = sourceFrame.minY + (sourceFrame.height - visualSize.height) / 2
                        targetFrame = NSRect(
                            x: thumbX,
                            y: thumbY,
                            width: visualSize.width,
                            height: visualSize.height
                        )
                    } else {
                        targetFrame = frame.offsetBy(dx: -stagger, dy: -stagger)
                    }
                    // 直接使用缓存位图，并让 draggingFrame 与图片宽高比一致。
                    // 不做 lockFocus、不生成新画布，启动拖拽的关键帧没有同步绘制。
                    draggingItem.setDraggingFrame(frame, contents: image)
                    returnGhosts.append(ReturnGhost(
                        targetFrame: targetFrame,
                        image: image,
                        stagger: stagger
                    ))
                } else {
                    draggingItem.setDraggingFrame(
                        NSRect(x: point.x, y: point.y, width: 1, height: 1),
                        contents: Self.transparentDragImage
                    )
                }
                return draggingItem
            }
        }

        private var dragCanvasSize: NSSize {
            NSSize(
                width: (cardMetrics?.thumbnailWidth ?? 86) + 12,
                height: (cardMetrics?.thumbnailHeight ?? 68) + 12
            )
        }

        private func aspectFitSize(_ source: NSSize, inside bounds: NSSize) -> NSSize {
            guard source.width > 0, source.height > 0 else { return bounds }
            let scale = min(bounds.width / source.width, bounds.height / source.height)
            return NSSize(
                width: max(1, source.width * scale),
                height: max(1, source.height * scale)
            )
        }

        private static func dragSourceImage(for item: FileDrawerItem) -> NSImage {
            if let cached = DrawerThumbnailCache.shared.image(for: item.id) {
                return cached
            }
            // 可见项目通常已有缓存；极端情况下使用内存中的 SF Symbol，避免
            // NSWorkspace.icon(forFile:) 在拖拽启动帧进行磁盘/Quick Look 查询。
            return NSImage(
                systemSymbolName: item.isBrowsableDirectory ? "folder.fill" : "doc.fill",
                accessibilityDescription: item.name
            ) ?? NSImage(size: NSSize(width: 32, height: 32))
        }

        private static let transparentDragImage = NSImage(size: NSSize(width: 1, height: 1))

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .every
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            if let view,
               let window = view.window,
               (operation.isEmpty || window.frame.contains(screenPoint)),
               !returnGhosts.isEmpty {
                let ghosts = returnGhosts.map { ghost in
                    let windowFrame = view.convert(ghost.targetFrame, to: nil)
                    let targetFrame = window.convertToScreen(windowFrame)
                    let startFrame = NSRect(
                        x: screenPoint.x - ghost.targetFrame.width / 2 + ghost.stagger,
                        y: screenPoint.y - ghost.targetFrame.height / 2 + ghost.stagger,
                        width: ghost.targetFrame.width,
                        height: ghost.targetFrame.height
                    )
                    return GhostThumbnailReturnAnimator.Ghost(
                        image: ghost.image,
                        startFrame: startFrame,
                        targetFrame: targetFrame
                    )
                }
                GhostThumbnailReturnAnimator.animateReturn(
                    ghosts,
                    duration: UIConfig.FileDrawer.ghostThumbnailReturnDuration,
                    fadeDuration: UIConfig.FileDrawer.ghostThumbnailReturnDuration,
                    level: NSWindow.Level(rawValue: window.level.rawValue + 2)
                )
            }
            onDragEnded?(operation)
            reset()
        }

        private func reset() {
            pressedItemID = nil
            pressLocation = nil
            sessionStarted = false
            returnGhosts = []
        }
    }
}

private final class PassthroughDragTrackingView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct DrawerToolbarButtonStyle: ButtonStyle {
    let drawsSurface: Bool

    init(drawsSurface: Bool = true) {
        self.drawsSurface = drawsSurface
    }

    func makeBody(configuration: Configuration) -> some View {
        DrawerToolbarButtonBody(configuration: configuration, drawsSurface: drawsSurface)
    }
}

private struct DrawerToolbarSurfaceModifier: ViewModifier {
    let drawsSurface: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if drawsSurface {
            content.modifier(DrawerGlassControlModifier(shape: .circle, isEnabled: isEnabled))
        } else {
            content
        }
    }
}

private struct DrawerFilterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DrawerFilterButtonBody(configuration: configuration)
    }
}

private struct DrawerFilterButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            // 玻璃/材质只负责视觉，完整胶囊必须始终是可点击区域。
            .contentShape(Capsule(style: .continuous))
            .modifier(DrawerGlassControlModifier(shape: .capsule, isEnabled: true))
            .opacity(configuration.isPressed ? 0.68 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DrawerToolbarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let drawsSurface: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            // 分组内的半区也应完整可点，不把命中区域缩成图标周围的小圆。
            .contentShape(Rectangle())
            .foregroundStyle(
                .primary.opacity(isEnabled ? (configuration.isPressed ? 0.62 : 0.88) : 0.28)
            )
            .modifier(DrawerToolbarSurfaceModifier(drawsSurface: drawsSurface, isEnabled: isEnabled))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.82), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private struct DrawerBarePathButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DrawerBarePathButtonBody(configuration: configuration)
    }
}

private struct DrawerBarePathButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .contentShape(Capsule(style: .continuous))
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.08 : (isHovering ? 0.045 : 0)),
                in: Capsule(style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

private struct DrawerTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        DrawerTabButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct DrawerTabButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .contentShape(Capsule(style: .continuous))
            // 标签栏维持轻量扁平样式：不使用玻璃、投影或高光，避免和密集文件名
            // 一起出现视觉噪音。选中态只通过系统强调色传达。
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? DrawerSystemColors.accent.opacity(configuration.isPressed ? 0.17 : 0.105)
                            : Color.primary.opacity(configuration.isPressed ? 0.1 : (isHovering ? 0.05 : 0))
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { isHovering = $0 }
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.82), value: isHovering)
    }
}

/// 圆形工具按钮样式：Circle 背景 + 自然阴影，用于 toolbarRow 中独立的功能键。
private struct DrawerCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DrawerCircleButtonBody(configuration: configuration)
    }
}

private struct DrawerCircleButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .contentShape(Circle())
            .foregroundStyle(
                .primary.opacity(isEnabled ? (configuration.isPressed ? 0.62 : 0.88) : 0.28)
            )
            .background(
                Color.clear
            )
            .modifier(DrawerGlassControlModifier(shape: .circle, isEnabled: isEnabled))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.82), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private struct DrawerMenuOption {
    let title: String
    let symbolName: String?
    let isSelected: Bool
    let action: () -> Void

    init(title: String, symbolName: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbolName
        self.isSelected = isSelected
        self.action = action
    }
}

private struct DrawerMenuPresenter: NSViewRepresentable {
    let requestID: Int
    let options: [DrawerMenuOption]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.options = options
        guard requestID != 0, requestID != context.coordinator.lastRequestID else { return }
        context.coordinator.lastRequestID = requestID
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            guard let nsView, let coordinator else { return }
            coordinator.presentMenu(from: nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var lastRequestID = 0
        var options: [DrawerMenuOption] = []

        func presentMenu(from view: NSView) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            var selectedItem: NSMenuItem?
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(selectOption(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = index
                if let symbolName = option.symbolName {
                    item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: option.title)
                }
                item.state = option.isSelected ? .on : .off
                if option.isSelected { selectedItem = item }
                menu.addItem(item)
            }
            menu.popUp(positioning: selectedItem, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
        }

        @objc private func selectOption(_ sender: NSMenuItem) {
            guard let index = sender.representedObject as? Int, options.indices.contains(index) else { return }
            options[index].action()
        }
    }
}

private struct DrawerEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(30)
    }
}

/// 搜索输入框。NSTextField + currentEditor 在 IME 组合期间也能获取打了一半的拼音。
private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusingSearchField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "搜索…"
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // 搜索行带有插入动画，首次 update 时 NSTextField 往往还没有 window。
        // 保存聚焦请求，等真正挂入窗口的同一轮 run loop 立即接管 firstResponder，
        // 避免用户紧接着输入时第一个拼音字母仍落在搜索按钮上。
        if let field = nsView as? AutoFocusingSearchField {
            field.requestFocus(generation: focusTrigger)
        }
        // NSTextField 编辑时，窗口的 firstResponder 实际是共享的 field editor
        // (NSTextView)，不是 NSTextField 自身。旧判断会在每次拼音组合更新后回写
        // stringValue，从而终止 marked text；必须同时识别 currentEditor。
        let editor = nsView.currentEditor()
        let isActivelyEditing = editor != nil && nsView.window?.firstResponder === editor
        if !isActivelyEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        weak var editingField: NSTextField?
        private var compositionPoller: Timer?

        init(text: Binding<String>) {
            _text = text
        }

        deinit {
            compositionPoller?.invalidate()
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            editingField = field
            startCompositionPolling()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            syncCompositionText(from: field)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                syncCompositionText(from: field)
            }
            compositionPoller?.invalidate()
            compositionPoller = nil
            editingField = nil
        }

        /// 部分中文输入法只在候选词确认后发送 controlTextDidChange。编辑期间以
        /// 60 Hz 读取共享 field editor，能让未确认的 "ji" 同样参与拼音搜索。
        private func startCompositionPolling() {
            compositionPoller?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self, let field = self.editingField else { return }
                self.syncCompositionText(from: field)
            }
            compositionPoller = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func syncCompositionText(from field: NSTextField) {
            // currentEditor 包含 IME marked text，stringValue 只有已确认文本。
            let currentText = field.currentEditor()?.string ?? field.stringValue
            if currentText != text {
                text = currentText
            }
        }
    }
}

private final class AutoFocusingSearchField: NSTextField {
    private var pendingFocusGeneration = 0
    private var completedFocusGeneration = 0
    private var focusScheduled = false

    func requestFocus(generation: Int) {
        pendingFocusGeneration = max(pendingFocusGeneration, generation)
        scheduleFocusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFocusIfPossible()
    }

    private func scheduleFocusIfPossible() {
        guard window != nil,
              pendingFocusGeneration > completedFocusGeneration,
              !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard let window = self.window,
                  self.pendingFocusGeneration > self.completedFocusGeneration else { return }
            if window.makeFirstResponder(self) {
                self.completedFocusGeneration = self.pendingFocusGeneration
            }
        }
    }
}
