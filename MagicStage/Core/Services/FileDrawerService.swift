import AppKit
import Combine
import Darwin
import Foundation

private nonisolated enum FileTransferOperation: Sendable {
    case copy
    case move
}

private nonisolated struct FileTransferResult: Sendable {
    var createdURLs: [URL] = []
    var failures: [String] = []
}

private nonisolated enum DestinationCollisionStyle: Sendable {
    case copy
    case numbered
}

@MainActor
final class FileDrawerService: NSObject, ObservableObject {
    static let shared = FileDrawerService()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            refreshEdgeMonitoring()
            if !isEnabled { hide() }
        }
    }
    @Published var edgeTriggerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(edgeTriggerEnabled, forKey: Keys.edgeTrigger)
            refreshEdgeMonitoring()
        }
    }
    @Published var placements: Set<FileDrawerPlacement> {
        didSet {
            persistPlacements()
            panelController.placementDidChange()
        }
    }
    /// 兼容旧代码：返回首选位置（第一个选中的方位）
    var placement: FileDrawerPlacement { placements.first ?? .right }
    @Published var defaultOpenLocation: String {
        didSet {
            UserDefaults.standard.set(defaultOpenLocation, forKey: Keys.defaultOpenLocation)
        }
    }
    @Published var showHiddenFiles: Bool {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: Keys.showHidden)
            reload()
        }
    }
    @Published var sortMode: FileDrawerSortMode {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: Keys.sortMode)
            if items.isEmpty {
                reload()
            } else {
                items = Self.sortItems(items, mode: sortMode, direction: sortDirection)
            }
        }
    }
    @Published var sortDirection: FileDrawerSortDirection {
        didSet {
            UserDefaults.standard.set(sortDirection.rawValue, forKey: Keys.sortDirection)
            if items.isEmpty {
                reload()
            } else {
                items = Self.sortItems(items, mode: sortMode, direction: sortDirection)
            }
        }
    }
    @Published var itemFilter: FileDrawerFilter {
        didSet {
            UserDefaults.standard.set(itemFilter.rawValue, forKey: Keys.itemFilter)
            rebuildFilteredItems()
        }
    }
    @Published var timeFilter: FileDrawerTimeFilter {
        didSet {
            UserDefaults.standard.set(timeFilter.rawValue, forKey: Keys.timeFilter)
            rebuildFilteredItems()
        }
    }
    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: Keys.isPinned) }
    }
    @Published var enableHapticFeedback: Bool {
        didSet { UserDefaults.standard.set(enableHapticFeedback, forKey: Keys.hapticFeedback) }
    }
    @Published var columnCount: Int {
        didSet {
            let value = min(5, max(2, columnCount))
            if value != columnCount {
                columnCount = value
            }
            UserDefaults.standard.set(value, forKey: Keys.columnCount)
        }
    }
    @Published var dismissDelay: Double {
        didSet {
            let value = min(3, max(0.2, dismissDelay))
            if value != dismissDelay {
                dismissDelay = value
            }
            UserDefaults.standard.set(value, forKey: Keys.dismissDelay)
        }
    }

    @Published private(set) var locations: [FileDrawerLocation]
    @Published private(set) var selectedLocationID: String
    @Published private(set) var rootURL: URL
    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileDrawerItem] = [] {
        didSet {
            var nextItemByID: [String: FileDrawerItem] = [:]
            var nextIndexByID: [String: Int] = [:]
            nextItemByID.reserveCapacity(items.count)
            nextIndexByID.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                nextItemByID[item.id] = item
                nextIndexByID[item.id] = index
            }
            itemByID = nextItemByID
            itemIndexByID = nextIndexByID
            rebuildFilteredItems()
        }
    }
    @Published private(set) var filteredItems: [FileDrawerItem] = []
    @Published private(set) var filterVersion = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPanelVisible = false
    @Published private(set) var presentationID: UInt64 = 0
    @Published var searchText = "" {
        didSet { scheduleSearchRebuild() }
    }
    @Published private(set) var selectedItemIDs: Set<String> = []
    /// 仅由键盘导航更新。视图据此将新选中的项目带入可见区域，鼠标点击不会打断当前滚动位置。
    @Published private(set) var keyboardFocusedItemID: String?
    private var primarySelectedItemID: String?
    private var selectionAnchorID: String?
    private(set) var hoveredItemID: String?
    /// 仅用于阻止面板在系统拖拽期间自动隐藏。它不参与任何视图绘制，不能用
    /// @Published；否则大目录会在 beginDraggingSession 前同步重算整个网格。
    private(set) var draggedItemID: String?
    /// 仅用于面板驻留判断，不参与绘制；发布它会让框选开始/结束各刷新一次整个网格。
    private(set) var isMarqueeSelecting = false
    private var draggedItemIDs: Set<String> = []
    @Published var renamingItemID: String?
    /// 编辑器自身持有实时文本；renamingItemID 的发布负责创建/销毁编辑器。
    /// 草稿逐键发布会导致整个文件抽屉随每个字符重新求值。
    var renameDraft = ""
    @Published var renameErrorMessage: String?
    @Published var fileOperationErrorMessage: String?
    /// 由面板注入的 UndoManager，用于支持 Command+Z 撤销重命名。
    /// lazy 确保在使用时才创建，不依赖 SwiftUI onAppear（panel 可能不触发）。
    lazy var undoManager: UndoManager = UndoManager()

    private enum Keys {
        static let enabled = "fileDrawer_enabled"
        static let rootPath = "fileDrawer_rootPath"
        static let customLocations = "fileDrawer_customLocations"
        static let selectedLocation = "fileDrawer_selectedLocation"
        static let edgeTrigger = "fileDrawer_edgeTrigger"
        static let placement = "fileDrawer_placement"
        static let placements = "fileDrawer_placements"
        static let showHidden = "fileDrawer_showHidden"
        static let sortMode = "fileDrawer_sortMode"
        static let sortDirection = "fileDrawer_sortDirection"
        static let itemFilter = "fileDrawer_itemFilter"
        static let timeFilter = "fileDrawer_timeFilter"
        static let isPinned = "fileDrawer_isPinned"
        static let hapticFeedback = "fileDrawer_hapticFeedback"
        static let columnCount = "fileDrawer_columnCount"
        static let dismissDelay = "fileDrawer_dismissDelay"
        static let defaultOpenLocation = "fileDrawer_defaultOpenLocation"
    }

    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var searchRebuildTask: Task<Void, Never>?
    private var loadedURL: URL?
    private var itemByID: [String: FileDrawerItem] = [:]
    private var itemIndexByID: [String: Int] = [:]
    private var filteredItemIDs: Set<String> = []
    private var previewSourceFramesInDrawer: [String: CGRect] = [:]
    private var previewSourceFramesProvider: (() -> [String: CGRect])?
    private var filteredIndexByID: [String: Int] = [:]
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var monitoredDirectoryURL: URL?
    private var directoryRefreshWorkItem: DispatchWorkItem?
    private var airDropService: NSSharingService?
    private var folderPicker: NSOpenPanel?
    private var activeOpenProcesses: [ObjectIdentifier: Process] = [:]
    private lazy var panelController = FileDrawerPanelController(service: self)

    override private init() {
        UserDefaults.standard.register(defaults: [
            Keys.enabled: true,
            Keys.edgeTrigger: true,
            Keys.placement: FileDrawerPlacement.right.rawValue,
            Keys.showHidden: false,
            Keys.sortMode: FileDrawerSortMode.name.rawValue,
            Keys.sortDirection: FileDrawerSortDirection.ascending.rawValue,
            Keys.itemFilter: FileDrawerFilter.all.rawValue,
            Keys.timeFilter: FileDrawerTimeFilter.all.rawValue,
            Keys.isPinned: false,
            Keys.hapticFeedback: true,
            Keys.columnCount: 3,
            Keys.dismissDelay: UIConfig.FileDrawer.defaultPanelExitDelay,
            Keys.defaultOpenLocation: "lastOpened"
        ])

        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        edgeTriggerEnabled = defaults.bool(forKey: Keys.edgeTrigger)
        // 加载多方位 placements；优先读新字段，回退到旧的单值字段
        if let rawValues = defaults.array(forKey: Keys.placements) as? [Int],
           !rawValues.isEmpty {
            placements = Set(rawValues.compactMap { FileDrawerPlacement(rawValue: $0) })
        } else {
            let legacy = FileDrawerPlacement(rawValue: defaults.integer(forKey: Keys.placement)) ?? .right
            placements = [legacy]
        }
        defaultOpenLocation = defaults.string(forKey: Keys.defaultOpenLocation) ?? "lastOpened"
        showHiddenFiles = defaults.bool(forKey: Keys.showHidden)
        sortMode = FileDrawerSortMode(rawValue: defaults.integer(forKey: Keys.sortMode)) ?? .name
        sortDirection = FileDrawerSortDirection(rawValue: defaults.string(forKey: Keys.sortDirection) ?? "") ?? .ascending
        itemFilter = FileDrawerFilter(rawValue: defaults.string(forKey: Keys.itemFilter) ?? "") ?? .all
        timeFilter = FileDrawerTimeFilter(rawValue: defaults.string(forKey: Keys.timeFilter) ?? "") ?? .all
        isPinned = defaults.bool(forKey: Keys.isPinned)
        enableHapticFeedback = defaults.bool(forKey: Keys.hapticFeedback)
        columnCount = min(5, max(2, defaults.integer(forKey: Keys.columnCount)))
        dismissDelay = min(3, max(0.2, defaults.double(forKey: Keys.dismissDelay)))

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        var initialLocations = [
            FileDrawerLocation(id: "downloads", kind: .downloads, name: "下载", path: downloads.path),
            FileDrawerLocation(id: "desktop", kind: .desktop, name: "桌面", path: desktop.path)
        ]
        if let data = defaults.data(forKey: Keys.customLocations),
           let custom = try? JSONDecoder().decode([FileDrawerLocation].self, from: data) {
            initialLocations.append(contentsOf: custom.filter { $0.kind == .custom })
        } else if let legacyPath = defaults.string(forKey: Keys.rootPath),
                  legacyPath != downloads.path,
                  legacyPath != desktop.path {
            initialLocations.append(FileDrawerLocation(
                id: "custom-\(UUID().uuidString)",
                kind: .custom,
                name: URL(fileURLWithPath: legacyPath).lastPathComponent,
                path: legacyPath
            ))
        }
        // defaultOpenLocation 决定启动时打开哪个标签：
        // - "lastOpened"：使用上次打开的标签（savedLocationID）
        // - 其他值：使用指定的标签 ID
        let savedLocationID = defaults.string(forKey: Keys.selectedLocation) ?? "downloads"
        let savedDefaultOpen = defaults.string(forKey: Keys.defaultOpenLocation) ?? "lastOpened"
        let effectiveLocationID: String
        if savedDefaultOpen == "lastOpened" {
            effectiveLocationID = savedLocationID
        } else {
            effectiveLocationID = savedDefaultOpen
        }
        let initialLocation = initialLocations.first { $0.id == effectiveLocationID } ?? initialLocations[0]
        locations = initialLocations
        selectedLocationID = initialLocation.id
        rootURL = initialLocation.url
        currentURL = initialLocation.url
        super.init()
        reload()
        refreshEdgeMonitoring()
    }

    /// 拼音匹配：将文件名转为无空格拼音，检查是否包含搜索词。
    /// 例如 "截屏" → "jieping"，搜索 "ji" 命中。
    private static func matchesPinyin(_ item: FileDrawerItem, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return item.searchablePinyin.contains(query)
    }

    private func rebuildFilteredItems() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = query.lowercased()
        let nextItems = items.filter { item in
            itemFilter.includes(item)
                && timeFilter.includes(item)
                && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query)
                    || Self.matchesPinyin(item, query: normalizedQuery))
        }
        guard nextItems != filteredItems else { return }
        filteredItems = nextItems
        filterVersion &+= 1
        var nextIDs = Set<String>()
        var nextIndexByID: [String: Int] = [:]
        nextIDs.reserveCapacity(nextItems.count)
        nextIndexByID.reserveCapacity(nextItems.count)
        for (index, item) in nextItems.enumerated() {
            nextIDs.insert(item.id)
            nextIndexByID[item.id] = index
        }
        filteredItemIDs = nextIDs
        filteredIndexByID = nextIndexByID
        selectedItemIDs.formIntersection(filteredItemIDs)
        if let primarySelectedItemID, !filteredItemIDs.contains(primarySelectedItemID) {
            self.primarySelectedItemID = selectedItemIDs.first
        }
        if let hoveredItemID, !filteredItemIDs.contains(hoveredItemID) {
            self.hoveredItemID = nil
        }
    }

    /// 搜索输入会连续产生多次变更。轻微防抖可避免每个按键都同步重建大列表，
    /// 清空搜索时则立即恢复全部内容，保持关闭搜索框的反馈及时。
    private func scheduleSearchRebuild() {
        searchRebuildTask?.cancel()
        searchRebuildTask = nil
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rebuildFilteredItems()
            return
        }
        searchRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, let self else { return }
            self.searchRebuildTask = nil
            self.rebuildFilteredItems()
        }
    }

    var selectedItem: FileDrawerItem? {
        guard let primarySelectedItemID else { return nil }
        return itemByID[primarySelectedItemID]
    }

    var selectedItems: [FileDrawerItem] {
        selectedItemIDs.compactMap { itemByID[$0] }.sorted {
            (itemIndexByID[$0.id] ?? .max) < (itemIndexByID[$1.id] ?? .max)
        }
    }

    var hoveredItem: FileDrawerItem? {
        guard let hoveredItemID else { return nil }
        return itemByID[hoveredItemID]
    }

    var draggedItems: [FileDrawerItem] {
        draggedItemIDs.compactMap { itemByID[$0] }.sorted {
            (itemIndexByID[$0.id] ?? .max) < (itemIndexByID[$1.id] ?? .max)
        }
    }

    var isPointerInteractionActive: Bool {
        isMarqueeSelecting || draggedItemID != nil
    }

    var selectedLocation: FileDrawerLocation {
        locations.first { $0.id == selectedLocationID } ?? locations[0]
    }

    var canNavigateBack: Bool {
        currentURL.standardizedFileURL != rootURL.standardizedFileURL
    }

    @Published private(set) var canNavigateForward = false
    private var forwardStack: [URL] = []

    var pathComponents: [FileDrawerPathComponent] {
        let root = rootURL.standardizedFileURL
        let current = currentURL.standardizedFileURL
        var result = [FileDrawerPathComponent(
            url: root,
            name: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        )]
        guard current != root else { return result }

        let suffix = current.path.dropFirst(root.path.count)
        var accumulated = root
        for name in suffix.split(separator: "/").map(String.init) {
            accumulated.appendPathComponent(name, isDirectory: true)
            result.append(FileDrawerPathComponent(url: accumulated.standardizedFileURL, name: name))
        }
        return result
    }

    func toggle() {
        guard isEnabled else { return }
        if isPanelVisible { hide() } else { show() }
    }

    func show() {
        guard isEnabled else { return }
        prepareForPresentation()
        panelController.show()
    }

    func hide() {
        panelController.hide()
    }

    func panelDidHide() {
        panelController.hidePreview(animated: false)
        isPanelVisible = false
        searchText = ""
        clearSelection()
        hoveredItemID = nil
        // 面板隐藏时，如果正在重命名，先尝试提交（匹配 Finder 行为）；
        // 提交失败（如名称非法）则静默取消，不阻止面板隐藏。
        if renamingItemID != nil {
            commitRename()
            if renamingItemID != nil { cancelRename() }
        }
        // 清理可能残留的框选/拖拽交互状态:框选或拖拽中按 Esc、快捷键隐藏面板时,
        // SwiftUI 手势的 onEnded 不会触发(窗口 orderOut),导致 isMarqueeSelecting/draggedItemID
        // 残留,使 isPointerInteractionActive 长期为 true,下次显示后 schedulePanelDismiss
        // 被守卫拦截,面板无法自动隐藏。
        if isMarqueeSelecting { finishMarqueeSelection() }
        if draggedItemID != nil {
            draggedItemID = nil
            draggedItemIDs = []
            panelController.pointerInteractionDidEnd()
        }
        // 取消在途加载,防止完成后写回 loadedURL 覆盖 directoryDidChange 设置的 nil 标记,
        // 否则下次呼出会因 loadedURL == currentURL 跳过刷新而展示旧数据。
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        searchRebuildTask?.cancel()
        searchRebuildTask = nil
        directoryRefreshWorkItem?.cancel()
        directoryRefreshWorkItem = nil
        refreshEdgeMonitoring()
    }

    func panelDidShow() {
        if !isPanelVisible { presentationID &+= 1 }
        isPanelVisible = true
    }

    func prepareForPresentation() {
        if loadedURL != currentURL.standardizedFileURL, !isLoading {
            reload()
        }
        panelDidShow()
    }

    private func persistPlacements() {
        let rawValues = placements.map(\.rawValue).sorted()
        UserDefaults.standard.set(rawValues, forKey: Keys.placements)
        // 同步旧字段，保证兼容
        UserDefaults.standard.set(placements.first?.rawValue ?? FileDrawerPlacement.right.rawValue, forKey: Keys.placement)
    }

    private func refreshEdgeMonitoring() {
        guard isEnabled, edgeTriggerEnabled, AXIsProcessTrusted() else {
            panelController.stopEdgeMonitoring()
            return
        }
        panelController.startEdgeMonitoring()
    }

    /// 辅助功能权限在启动后才授予时，必须销毁授权前创建的事件监听并重新建立；
    /// 仅保持 UI 开关为开不足以让全局 mouseMoved 开始投递。
    func refreshForAccessibilityChange() {
        panelController.restartEdgeMonitoring()
        refreshEdgeMonitoring()
    }

    func chooseFolder() {
        guard folderPicker == nil else {
            folderPicker?.makeKeyAndOrderFront(nil)
            return
        }
        let shouldRestoreDrawer = isPanelVisible
        if shouldRestoreDrawer { panelController.hide() }

        let picker = NSOpenPanel()
        picker.title = "选择文件抽屉文件夹"
        picker.message = "所选文件夹会作为新的标签固定在文件抽屉顶部"
        picker.prompt = "添加标签"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = rootURL
        folderPicker = picker
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.folderPicker = nil
                if response == .OK, let url = picker.url {
                    self.addCustomFolder(url)
                }
                if shouldRestoreDrawer { self.show() }
            }
        }
    }

    func addCustomFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let existing = locations.first(where: { $0.url == standardized }) {
            selectLocation(existing.id)
            return
        }
        let location = FileDrawerLocation(
            id: "custom-\(UUID().uuidString)",
            kind: .custom,
            name: standardized.lastPathComponent,
            path: standardized.path
        )
        locations.append(location)
        persistCustomLocations()
        selectLocation(location.id)
    }

    func selectLocation(_ id: String) {
        guard let location = locations.first(where: { $0.id == id }) else { return }
        cancelRename()
        panelController.hidePreview(animated: true)
        selectedLocationID = id
        rootURL = location.url
        currentURL = location.url
        searchText = ""
        clearSelection()
        hoveredItemID = nil
        items = []
        UserDefaults.standard.set(id, forKey: Keys.selectedLocation)
        reload()
    }

    func removeLocation(_ id: String) {
        guard let location = locations.first(where: { $0.id == id }), location.isRemovable else { return }
        locations.removeAll { $0.id == id }
        persistCustomLocations()
        if selectedLocationID == id { selectLocation("downloads") }
    }

    private func persistCustomLocations() {
        let custom = locations.filter(\.isRemovable)
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Keys.customLocations)
        }
    }

    func navigate(to item: FileDrawerItem) {
        guard item.isBrowsableDirectory else { return }
        cancelRename()
        panelController.hidePreview(animated: true)
        forwardStack.removeAll()
        canNavigateForward = false
        currentURL = item.url.standardizedFileURL
        searchText = ""
        clearSelection()
        hoveredItemID = nil
        items = []
        reload()
    }

    func navigateBack() {
        guard canNavigateBack else { return }
        cancelRename()
        panelController.hidePreview(animated: true)
        forwardStack.append(currentURL)
        canNavigateForward = true
        let parent = currentURL.deletingLastPathComponent().standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        guard parent.path == rootPath || parent.path.hasPrefix(rootPath + "/") else {
            currentURL = rootURL
            reload()
            return
        }
        currentURL = parent
        searchText = ""
        clearSelection()
        hoveredItemID = nil
        items = []
        reload()
    }

    func navigateForward() {
        guard canNavigateForward, let next = forwardStack.popLast() else { return }
        cancelRename()
        panelController.hidePreview(animated: true)
        currentURL = next
        canNavigateForward = !forwardStack.isEmpty
        searchText = ""
        clearSelection()
        hoveredItemID = nil
        items = []
        reload()
    }

    func navigate(to folderURL: URL) {
        let destination = folderURL.standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        guard destination.path == rootPath || destination.path.hasPrefix(rootPath + "/") else { return }
        guard destination != currentURL.standardizedFileURL else { return }
        cancelRename()
        panelController.hidePreview(animated: true)
        forwardStack.removeAll()
        canNavigateForward = false
        currentURL = destination
        searchText = ""
        clearSelection()
        hoveredItemID = nil
        items = []
        reload()
    }

    func navigateToRoot() {
        cancelRename()
        panelController.hidePreview(animated: true)
        currentURL = rootURL
        searchText = ""
        clearSelection()
        hoveredItemID = nil
        items = []
        reload()
    }

    func select(
        _ item: FileDrawerItem,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        keyboardFocusedItemID = nil
        // 选择其他文件时，如果正在重命名，先尝试提交（匹配 Finder 行为）。
        if renamingItemID != nil, renamingItemID != item.id {
            commitRename()
            if renamingItemID != nil { cancelRename() }
        }

        if modifiers.contains(.shift),
           let anchorID = selectionAnchorID,
           let anchorIndex = filteredIndexByID[anchorID],
           let itemIndex = filteredIndexByID[item.id] {
            let range = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
            selectedItemIDs = Set(range.map { filteredItems[$0].id })
        } else if modifiers.contains(.command) {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
                if primarySelectedItemID == item.id {
                    primarySelectedItemID = selectedItemIDs.first
                }
            } else {
                selectedItemIDs.insert(item.id)
                primarySelectedItemID = item.id
            }
            selectionAnchorID = item.id
        } else {
            selectedItemIDs = [item.id]
            primarySelectedItemID = item.id
            selectionAnchorID = item.id
        }
        if primarySelectedItemID == nil { primarySelectedItemID = selectedItemIDs.first }
        panelController.restoreKeyFocus()
        panelController.clearTextFocus()
    }

    func clearSelection() {
        selectedItemIDs = []
        primarySelectedItemID = nil
        selectionAnchorID = nil
    }

    func setSelection(_ itemIDs: Set<String>) {
        let nextSelection = itemIDs.intersection(filteredItemIDs)
        guard nextSelection != selectedItemIDs else { return }
        selectedItemIDs = nextSelection
        // 框选拖动时只更新真正参与绘制的集合。primary/anchor 不参与即时高亮，
        // 若在每次跨过卡片时扫描整个目录确定它们，会重新制造明显的拖动卡顿。
        guard !isMarqueeSelecting else { return }
        primarySelectedItemID = filteredItems.first { selectedItemIDs.contains($0.id) }?.id
        selectionAnchorID = primarySelectedItemID
    }

    func handleBackgroundClick() {
        if renamingItemID != nil {
            commitRename()
            guard renamingItemID == nil else { return }
        }
        clearSelection()
        panelController.clearTextFocus()
    }

    func prepareForMarqueeSelection() -> Bool {
        if renamingItemID != nil {
            commitRename()
            guard renamingItemID == nil else { return false }
        }
        panelController.clearTextFocus()
        if !isMarqueeSelecting {
            isMarqueeSelecting = true
            panelController.pointerInteractionDidBegin()
        }
        return true
    }

    func finishMarqueeSelection() {
        guard isMarqueeSelecting else { return }
        primarySelectedItemID = selectedItemIDs.min {
            (filteredIndexByID[$0] ?? .max) < (filteredIndexByID[$1] ?? .max)
        }
        selectionAnchorID = primarySelectedItemID
        isMarqueeSelecting = false
        panelController.pointerInteractionDidEnd()
    }

    func selectAll() {
        let visibleItems = filteredItems
        selectedItemIDs = Set(visibleItems.map(\.id))
        primarySelectedItemID = visibleItems.first?.id
        selectionAnchorID = visibleItems.first?.id
        panelController.clearTextFocus()
    }

    /// 按 Finder 图标视图的阅读顺序移动选择。Shift 会从原锚点扩展连续选择。
    func moveSelection(by direction: FileDrawerSelectionDirection, extendingSelection: Bool = false) {
        guard !filteredItems.isEmpty else { return }

        let currentIndex: Int
        if let primarySelectedItemID, let index = filteredIndexByID[primarySelectedItemID] {
            currentIndex = index
        } else {
            switch direction {
            case .left, .up, .pageUp, .home: currentIndex = filteredItems.count - 1
            case .right, .down, .pageDown, .end: currentIndex = 0
            }
        }

        let pageStep = max(columnCount * 3, columnCount)
        let offset: Int
        switch direction {
        case .left: offset = -1
        case .right: offset = 1
        case .up: offset = -columnCount
        case .down: offset = columnCount
        case .pageUp: offset = -pageStep
        case .pageDown: offset = pageStep
        case .home: offset = -filteredItems.count
        case .end: offset = filteredItems.count
        }
        let targetIndex = min(max(currentIndex + offset, 0), filteredItems.count - 1)
        let target = filteredItems[targetIndex]
        select(target, modifiers: extendingSelection ? [.shift] : [])
        keyboardFocusedItemID = target.id
    }

    func setHoveredItem(_ item: FileDrawerItem?) {
        hoveredItemID = item?.id
        if item != nil { panelController.claimKeyboardFocus() }
    }

    func item(withID id: String) -> FileDrawerItem? {
        itemByID[id]
    }

    func beginRenamingSelectedItem() {
        guard selectedItemIDs.count == 1, let item = selectedItem else { return }
        // 先准备好文本，再显示编辑器；否则 SwiftUI 会在两个 @Published 更新之间
        // 创建一帧空输入框，表现为按 Return 后文件名闪烁。
        renameDraft = item.name
        renamingItemID = item.id
        renameErrorMessage = nil
    }

    func commitRename() {
        guard let item = selectedItem,
              renamingItemID == item.id else {
            cancelRename()
            return
        }
        // 文件名不允许包含换行符；多行编辑时合并为单行，再去除首尾空白。
        let rawName = renameDraft.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            renameErrorMessage = "名称不能为空，也不能包含“/”。"
            return
        }
        guard name != item.name else {
            cancelRename()
            return
        }

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(
            name,
            isDirectory: item.isDirectory
        )
        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        let isCaseOnlyRename = destinationExists && Self.urlsReferToSameFile(item.url, destination)
        guard !destinationExists || isCaseOnlyRename else {
            renameErrorMessage = "这个文件夹中已经有一个同名项目。"
            return
        }

        do {
            let originalURL = item.url
            if isCaseOnlyRename {
                try Self.renameExistingItemCase(at: item.url, to: destination)
            } else {
                try fileManager.moveItem(at: item.url, to: destination)
            }
            // 先更新内存模型，避免文件系统监视和 reload 之间短暂闪回旧名称。
            items = items.map { $0.id == item.id ? $0.renamed(to: destination) : $0 }
            renamingItemID = nil
            renameDraft = ""
            selectedItemIDs = [destination.standardizedFileURL.path]
            primarySelectedItemID = destination.standardizedFileURL.path
            selectionAnchorID = destination.standardizedFileURL.path
            // 注册撤销操作：Command+Z 可恢复原名
            undoManager.registerUndo(withTarget: self) { svc in
                svc.performRename(from: destination, to: originalURL)
            }
            reload()
        } catch {
            renameErrorMessage = error.localizedDescription
        }
    }

    func cancelRename() {
        renamingItemID = nil
        renameDraft = ""
    }

    /// 撤销/重做时调用的文件重命名，不触发新的撤销注册（避免无限循环）。
    private func performRename(from source: URL, to destination: URL) {
        let fileManager = FileManager.default
        do {
            let destinationExists = fileManager.fileExists(atPath: destination.path)
            let isCaseOnlyRename = destinationExists && Self.urlsReferToSameFile(source, destination)
            if isCaseOnlyRename {
                try Self.renameExistingItemCase(at: source, to: destination)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
            // 更新内存模型
            let destinationID = destination.standardizedFileURL.path
            items = items.map { $0.id == source.standardizedFileURL.path ? $0.renamed(to: destination) : $0 }
            selectedItemIDs = [destinationID]
            primarySelectedItemID = destinationID
            selectionAnchorID = destinationID
            // 注册反向撤销（重做）
            undoManager.registerUndo(withTarget: self) { svc in
                svc.performRename(from: destination, to: source)
            }
            reload()
        } catch {
            renameErrorMessage = error.localizedDescription
        }
    }

    func open(_ item: FileDrawerItem) {
        if item.isBrowsableDirectory {
            navigate(to: item)
        } else {
            panelController.hideImmediatelyForExternalOpen()
            openInDefaultApplication(item)
        }
    }

    private func openInDefaultApplication(_ item: FileDrawerItem) {
        let process = Process()
        let processID = ObjectIdentifier(process)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [item.url.path]
        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeOpenProcesses.removeValue(forKey: processID)
                guard finishedProcess.terminationReason != .exit || finishedProcess.terminationStatus != 0 else { return }
                self.fileOperationErrorMessage = "无法使用默认应用打开“\(item.name)”。"
                self.show()
            }
        }

        activeOpenProcesses[processID] = process
        do {
            try process.run()
        } catch {
            activeOpenProcesses.removeValue(forKey: processID)
            fileOperationErrorMessage = "无法使用默认应用打开“\(item.name)”。\n\(error.localizedDescription)"
            show()
        }
    }

    func openSelectedItem() {
        guard let selectedItem else { return }
        open(selectedItem)
    }

    /// Finder 在多选时会把每个项目交给系统打开；文件夹也应在 Finder 中分别打开，
    /// 而不是让抽屉导航进其中任意一个目录。
    func openSelectedItems() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        if items.count == 1 {
            open(items[0])
            return
        }
        panelController.hideImmediatelyForExternalOpen()
        for item in items {
            NSWorkspace.shared.open(item.url)
        }
    }

    func revealInFinder(_ item: FileDrawerItem? = nil) {
        if let item {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else if !selectedItems.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
        } else {
            NSWorkspace.shared.open(currentURL)
        }
    }

    func preview(_ item: FileDrawerItem) {
        refreshPreviewSourceFrames()
        let previewItems = selectedItemIDs.contains(item.id) ? selectedItems : [item]
        panelController.togglePreview(
            items: previewItems,
            startingAt: item,
            sourceFramesInDrawer: previewSourceFramesInDrawer
        )
    }

    func updatePreviewSourceFrames(_ frames: [String: CGRect]) {
        guard frames != previewSourceFramesInDrawer else { return }
        // 仅保存当前 LazyVGrid 已布局的卡片，不发布状态，避免滚动时刷新整个网格。
        previewSourceFramesInDrawer = frames
        // Quick Look 未打开时不需要在每个滚动帧执行窗口坐标换算。
        if panelController.isPreviewVisible {
            panelController.updatePreviewSourceFrames(frames)
        }
    }

    func setPreviewSourceFramesProvider(_ provider: (() -> [String: CGRect])?) {
        previewSourceFramesProvider = provider
    }

    /// 普通滚动时不做 Quick Look 几何计算；仅预览会话期间按需同步来源位置。
    func refreshPreviewSourceFramesIfPreviewing() {
        guard panelController.isPreviewVisible else { return }
        refreshPreviewSourceFrames()
    }

    private func refreshPreviewSourceFrames() {
        guard let previewSourceFramesProvider else { return }
        updatePreviewSourceFrames(previewSourceFramesProvider())
    }

    func previewSelectedItem() {
        if panelController.isPreviewVisible {
            panelController.hidePreview(animated: true)
            return
        }
        // 键盘移动选择后，鼠标可能仍停在另一张卡片上；此时 Space 应始终预览
        // 当前选中项。未选中任何项目时才退回到悬停项。
        guard let item = selectedItem ?? hoveredItem else { return }
        preview(item)
    }

    // MARK: - Drag actions

    func beginDragging(_ item: FileDrawerItem) -> [FileDrawerItem] {
        // 拖动未选中的项目时不要在启动关键路径里发布 selection 变化。
        // 选择高亮可由普通点击处理；拖拽本身只需要确定 pasteboard 项目。
        let isPartOfCurrentSelection = selectedItemIDs.contains(item.id)
        draggedItemID = item.id
        draggedItemIDs = isPartOfCurrentSelection ? selectedItemIDs : [item.id]
        panelController.pointerInteractionDidBegin()
        // AppKit 以第一个 NSDraggingItem 作为首帧视觉来源。多选集合按目录顺序
        // 排列时，被按住的可见文件可能排在后面，偶尔会让预览框取到离屏项目而
        // 不显示。始终把实际按住的项目放在第一位，其他选中项保持原有排序。
        let items = draggedItems
        return [item] + items.filter { $0.id != item.id }
    }

    func finishDragging() {
        endDragging()
    }

    func shareDraggedItemViaAirDrop() -> Bool {
        let urls = draggedItems.map(\.url)
        guard !urls.isEmpty,
              let sharingService = NSSharingService(named: .sendViaAirDrop) else {
            fileOperationErrorMessage = "无法启动隔空投送。"
            endDragging()
            return false
        }
        airDropService?.delegate = nil
        airDropService = sharingService
        sharingService.delegate = self
        sharingService.perform(withItems: urls)
        endDragging()
        return true
    }

    nonisolated static func urlsReferToSameFile(_ source: URL, _ destination: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let sourceIdentifier = try? source.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject,
              let destinationIdentifier = try? destination.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject else {
            return false
        }
        return sourceIdentifier.isEqual(destinationIdentifier)
    }

    nonisolated static func renameExistingItemCase(at source: URL, to destination: URL) throws {
        let errorCode: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            guard let sourcePath else { return EINVAL }
            return destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else { return EINVAL }
                return Darwin.rename(sourcePath, destinationPath) == 0 ? 0 : errno
            }
        }
        guard errorCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
    }

    func recycleDraggedItem() -> Bool {
        let draggedURLs = draggedItems.map(\.url)
        guard !draggedURLs.isEmpty else { return false }
        let urls = draggedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        endDragging()
        // 某些系统目标可能已经完成文件操作后再回报 .delete；此时只需刷新，
        // 不应把“文件已不存在”显示成一次失败。
        guard !urls.isEmpty else {
            reload()
            return true
        }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.fileOperationErrorMessage = error.localizedDescription
                }
                self.reload()
            }
        }
        return true
    }

    private func endDragging() {
        draggedItemID = nil
        draggedItemIDs = []
        panelController.pointerInteractionDidEnd()
    }

    func deleteSelectedItems() {
        let urls = selectedItems.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.fileOperationErrorMessage = error.localizedDescription
                }
                self.reload()
            }
        }
    }

    func copySelectedItems() {
        let urls = selectedItems.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    var canPasteItems: Bool {
        !fileURLsOnPasteboard().isEmpty
    }

    /// Finder 的 Command+V 会把剪贴板中的本地文件复制到当前目录；
    /// Option+Command+V 则执行“将项目移到这里”。文本框获得焦点时由 AppKit
    /// 自己处理粘贴，不会落入这个文件操作入口。
    func pasteItems(moving: Bool = false) {
        let urls = fileURLsOnPasteboard()
        guard !urls.isEmpty else { return }
        transferFiles(urls, operation: moving ? .move : .copy)
    }

    func duplicateSelectedItems() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        transferFiles(urls, operation: .copy)
    }

    /// 拖入抽屉时复制到当前目录。来自当前目录自身的项目不重复复制，匹配
    /// Finder 在同一文件夹内普通拖放的行为；需要副本时使用 Command+D。
    @discardableResult
    func importDroppedItems(_ urls: [URL]) -> Bool {
        let destination = currentURL.standardizedFileURL
        let sources = Self.uniqueExistingFileURLs(urls).filter {
            $0.deletingLastPathComponent().standardizedFileURL != destination
        }
        guard !sources.isEmpty else { return false }
        transferFiles(sources, operation: .copy)
        return true
    }

    /// 创建后立即选中并进入重命名，名称冲突时依次使用“未命名文件夹 2、3…”。
    func createNewFolder() {
        let destinationDirectory = currentURL.standardizedFileURL
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let folderURL = Self.availableDestinationURL(
                    named: "未命名文件夹",
                    isDirectory: true,
                    in: destinationDirectory,
                    collisionStyle: .numbered
                )
                do {
                    try FileManager.default.createDirectory(
                        at: folderURL,
                        withIntermediateDirectories: false
                    )
                    return FileTransferResult(createdURLs: [folderURL])
                } catch {
                    return FileTransferResult(failures: ["未命名文件夹：\(error.localizedDescription)"])
                }
            }.value
            guard let self else { return }
            self.finishFileTransfer(
                result,
                in: destinationDirectory,
                beginRenamingCreatedItem: true
            )
        }
    }

    private func fileURLsOnPasteboard() -> [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        return Self.uniqueExistingFileURLs(objects.compactMap { $0 as URL })
    }

    private func transferFiles(_ urls: [URL], operation: FileTransferOperation) {
        let sources = Self.uniqueExistingFileURLs(urls)
        guard !sources.isEmpty else { return }
        let destinationDirectory = currentURL.standardizedFileURL
        cancelRename()

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.performFileTransfer(
                    sources,
                    to: destinationDirectory,
                    operation: operation
                )
            }.value
            guard let self else { return }
            self.finishFileTransfer(result, in: destinationDirectory)
        }
    }

    private func finishFileTransfer(
        _ result: FileTransferResult,
        in destinationDirectory: URL,
        beginRenamingCreatedItem: Bool = false
    ) {
        if !result.failures.isEmpty {
            fileOperationErrorMessage = result.failures.joined(separator: "\n")
        }
        guard currentURL.standardizedFileURL == destinationDirectory else { return }
        let createdIDs = Set(result.createdURLs.map { $0.standardizedFileURL.path })
        reload(
            selectingItemIDs: createdIDs.isEmpty ? nil : createdIDs,
            renamingItemIDAfterLoad: beginRenamingCreatedItem ? createdIDs.first : nil
        )
    }

    nonisolated private static func uniqueExistingFileURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard standardized.isFileURL,
                  FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    nonisolated private static func performFileTransfer(
        _ sources: [URL],
        to destinationDirectory: URL,
        operation: FileTransferOperation
    ) -> FileTransferResult {
        let fileManager = FileManager.default
        var result = FileTransferResult()

        for source in sources {
            let sourceName = source.lastPathComponent
            let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let sourceParent = source.deletingLastPathComponent().standardizedFileURL

            if operation == .move, sourceParent == destinationDirectory {
                continue
            }
            if sourceIsDirectory {
                let sourcePath = source.standardizedFileURL.path
                let destinationPath = destinationDirectory.standardizedFileURL.path
                if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
                    result.failures.append("\(sourceName)：不能将文件夹放入其自身。")
                    continue
                }
            }

            let destination = availableDestinationURL(
                named: sourceName,
                isDirectory: sourceIsDirectory,
                in: destinationDirectory,
                collisionStyle: .copy
            )
            do {
                switch operation {
                case .copy:
                    try fileManager.copyItem(at: source, to: destination)
                case .move:
                    try fileManager.moveItem(at: source, to: destination)
                }
                result.createdURLs.append(destination)
            } catch {
                result.failures.append("\(sourceName)：\(error.localizedDescription)")
            }
        }
        return result
    }

    nonisolated private static func availableDestinationURL(
        named originalName: String,
        isDirectory: Bool,
        in directory: URL,
        collisionStyle: DestinationCollisionStyle
    ) -> URL {
        let fileManager = FileManager.default
        let original = directory.appendingPathComponent(originalName, isDirectory: isDirectory)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let name = originalName as NSString
        let fileExtension = isDirectory ? "" : name.pathExtension
        let stem = fileExtension.isEmpty ? originalName : name.deletingPathExtension
        var index = 1
        while true {
            let suffix: String
            switch collisionStyle {
            case .copy:
                suffix = index == 1 ? " 副本" : " 副本 \(index)"
            case .numbered:
                suffix = " \(index + 1)"
            }
            let candidateName = fileExtension.isEmpty
                ? stem + suffix
                : stem + suffix + "." + fileExtension
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: isDirectory)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    func copySelectedItemPaths() {
        let paths = selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func shareSelectedItemsViaAirDrop() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty,
              let sharingService = NSSharingService(named: .sendViaAirDrop) else {
            fileOperationErrorMessage = "无法启动隔空投送。"
            return
        }
        airDropService?.delegate = nil
        airDropService = sharingService
        sharingService.delegate = self
        sharingService.perform(withItems: urls)
    }

    func reload(
        showLoading: Bool = true,
        selectingItemIDs: Set<String>? = nil,
        renamingItemIDAfterLoad: String? = nil
    ) {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        let folder = currentURL
        let includesHidden = showHiddenFiles
        let sorting = sortMode
        let direction = sortDirection
        startDirectoryMonitoring(folder)
        if showLoading { isLoading = true }
        errorMessage = nil

        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.readItems(in: folder, showHidden: includesHidden, sortMode: sorting, sortDirection: direction)
            }.value
            guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
            self.items = result.items
            self.errorMessage = result.error
            self.loadedURL = folder.standardizedFileURL
            if let selectingItemIDs {
                self.selectedItemIDs = selectingItemIDs.intersection(self.itemByID.keys)
                self.primarySelectedItemID = self.filteredItems.first {
                    self.selectedItemIDs.contains($0.id)
                }?.id
                self.selectionAnchorID = self.primarySelectedItemID
            } else {
                self.selectedItemIDs.formIntersection(self.itemByID.keys)
            }
            if let primary = self.primarySelectedItemID, self.itemByID[primary] == nil {
                self.primarySelectedItemID = self.selectedItemIDs.first
            }
            if let anchor = self.selectionAnchorID, self.itemByID[anchor] == nil {
                self.selectionAnchorID = self.primarySelectedItemID
            }
            if let hovered = self.hoveredItemID, self.itemByID[hovered] == nil {
                self.hoveredItemID = nil
            }
            if let renamingItemIDAfterLoad,
               let item = self.itemByID[renamingItemIDAfterLoad] {
                self.selectedItemIDs = [item.id]
                self.primarySelectedItemID = item.id
                self.selectionAnchorID = item.id
                self.renameDraft = item.name
                self.renamingItemID = item.id
            }
            self.isLoading = false
        }
    }

    private func startDirectoryMonitoring(_ folder: URL) {
        let standardized = folder.standardizedFileURL
        guard monitoredDirectoryURL != standardized || directoryMonitor == nil else { return }

        directoryRefreshWorkItem?.cancel()
        directoryRefreshWorkItem = nil
        directoryMonitor?.cancel()
        directoryMonitor = nil
        monitoredDirectoryURL = nil

        let descriptor = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_EVTONLY)
        }
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.directoryDidChange(at: standardized)
            }
        }
        source.setCancelHandler { close(descriptor) }
        directoryMonitor = source
        monitoredDirectoryURL = standardized
        source.resume()
    }

    private func directoryDidChange(at folder: URL) {
        guard currentURL.standardizedFileURL == folder else { return }
        directoryRefreshWorkItem?.cancel()

        guard isPanelVisible else {
            loadedURL = nil
            directoryRefreshWorkItem = nil
            return
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentURL.standardizedFileURL == folder else { return }
                self.directoryRefreshWorkItem = nil
                self.reload(showLoading: false)
            }
        }
        directoryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    nonisolated private static func readItems(
        in folder: URL,
        showHidden: Bool,
        sortMode: FileDrawerSortMode,
        sortDirection: FileDrawerSortDirection
    ) -> (items: [FileDrawerItem], error: String?) {
        do {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isPackageKey, .isHiddenKey,
                .contentModificationDateKey, .creationDateKey,
                .addedToDirectoryDateKey, .contentAccessDateKey,
                .fileSizeKey
            ]
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: options
            )
            let result = urls.compactMap { url -> FileDrawerItem? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                if !showHidden, values.isHidden == true { return nil }
                return FileDrawerItem(
                    url: url,
                    isDirectory: values.isDirectory == true,
                    isPackage: values.isPackage == true,
                    modificationDate: values.contentModificationDate,
                    creationDate: values.creationDate,
                    dateAdded: values.addedToDirectoryDate,
                    lastOpenedDate: values.contentAccessDate,
                    fileSize: values.fileSize.map(Int64.init)
                )
            }
            return (sortItems(result, mode: sortMode, direction: sortDirection), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    nonisolated static func sortItems(
        _ items: [FileDrawerItem],
        mode: FileDrawerSortMode,
        direction: FileDrawerSortDirection
    ) -> [FileDrawerItem] {
        let ascending = (direction == .ascending)
        return items.sorted { lhs, rhs in
            let groupsFoldersFirst: Bool
            switch mode {
            case .name, .kind:
                groupsFoldersFirst = true
            case .modificationDate, .dateAdded, .size:
                groupsFoldersFirst = false
            }
            if groupsFoldersFirst, lhs.isBrowsableDirectory != rhs.isBrowsableDirectory {
                return lhs.isBrowsableDirectory
            }

            let nameOrder = deterministicNameOrder(lhs, rhs)
            switch mode {
            case .name:
                return ascending ? nameOrder == .orderedAscending : nameOrder == .orderedDescending
            case .modificationDate:
                return compareDates(lhs.modificationDate, rhs.modificationDate, newestFirst: !ascending, nameOrder: nameOrder)
            case .dateAdded:
                return compareDates(lhs.dateAdded, rhs.dateAdded, newestFirst: !ascending, nameOrder: nameOrder)
            case .kind:
                if lhs.isBrowsableDirectory { return ascending ? nameOrder == .orderedAscending : nameOrder == .orderedDescending }
                let left = lhs.url.pathExtension.localizedLowercase
                let right = rhs.url.pathExtension.localizedLowercase
                let typeOrder = left.localizedStandardCompare(right)
                if typeOrder == .orderedSame {
                    return ascending ? nameOrder == .orderedAscending : nameOrder == .orderedDescending
                }
                return ascending ? typeOrder == .orderedAscending : typeOrder == .orderedDescending
            case .size:
                let left = lhs.fileSize ?? (ascending ? .max : -1)
                let right = rhs.fileSize ?? (ascending ? .max : -1)
                if left == right {
                    return ascending ? nameOrder == .orderedAscending : nameOrder == .orderedDescending
                }
                return ascending ? left < right : left > right
            }
        }
    }

    nonisolated private static func deterministicNameOrder(
        _ lhs: FileDrawerItem,
        _ rhs: FileDrawerItem
    ) -> ComparisonResult {
        let localized = lhs.name.localizedStandardCompare(rhs.name)
        guard localized == .orderedSame else { return localized }
        return lhs.id.compare(rhs.id, options: [.caseInsensitive, .numeric])
    }

    nonisolated private static func compareDates(
        _ lhs: Date?,
        _ rhs: Date?,
        newestFirst: Bool,
        nameOrder: ComparisonResult
    ) -> Bool {
        if lhs == rhs { return nameOrder == .orderedAscending }
        guard let lhs else { return false }
        guard let rhs else { return true }
        return newestFirst ? lhs > rhs : lhs < rhs
    }

}

extension FileDrawerService: NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        releaseAirDropServiceIfCurrent(sharingService)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        releaseAirDropServiceIfCurrent(sharingService)
    }

    private func releaseAirDropServiceIfCurrent(_ sharingService: NSSharingService) {
        guard airDropService === sharingService else { return }
        sharingService.delegate = nil
        airDropService = nil
    }
}
