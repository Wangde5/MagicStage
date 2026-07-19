import Foundation

struct FileDrawerItem: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let name: String
    let searchablePinyin: String
    let thumbnailVersion: String
    let url: URL
    let isDirectory: Bool
    let isPackage: Bool
    let modificationDate: Date?
    let creationDate: Date?
    let dateAdded: Date?
    let lastOpenedDate: Date?
    let fileSize: Int64?
    let kind: FileDrawerItemKind

    nonisolated init(
        url: URL,
        isDirectory: Bool,
        isPackage: Bool = false,
        modificationDate: Date?,
        creationDate: Date? = nil,
        dateAdded: Date? = nil,
        lastOpenedDate: Date? = nil,
        fileSize: Int64?,
        kind: FileDrawerItemKind? = nil
    ) {
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.id = standardizedURL.path
        self.name = standardizedURL.lastPathComponent
        self.searchablePinyin = Self.makeSearchablePinyin(standardizedURL.lastPathComponent)
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.dateAdded = dateAdded
        self.lastOpenedDate = lastOpenedDate
        self.fileSize = fileSize
        self.kind = kind ?? FileDrawerItemKind.classify(url: url, isDirectory: isDirectory && !isPackage)
        if isDirectory && !isPackage {
            self.thumbnailVersion = standardizedURL.path
        } else {
            let timestamp = modificationDate?.timeIntervalSinceReferenceDate ?? 0
            self.thumbnailVersion = "\(standardizedURL.path)|\(timestamp)|\(fileSize ?? -1)"
        }
    }

    nonisolated var isBrowsableDirectory: Bool { isDirectory && !isPackage }

    private nonisolated static func makeSearchablePinyin(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    nonisolated func renamed(to url: URL) -> Self {
        Self(
            url: url,
            isDirectory: isDirectory,
            isPackage: isPackage,
            modificationDate: modificationDate,
            creationDate: creationDate,
            dateAdded: dateAdded,
            lastOpenedDate: lastOpenedDate,
            fileSize: fileSize,
            kind: kind
        )
    }
}

enum FileDrawerItemKind: String, CaseIterable, Identifiable, Sendable {
    case folder, image, video, audio, document, archive, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: return "文件夹"
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .document: return "文稿"
        case .archive: return "压缩包"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .folder: return "folder"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }

    nonisolated static func classify(url: URL, isDirectory: Bool) -> Self {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if archiveExtensions.contains(ext) { return .archive }
        return .other
    }

    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "dng"
    ]
    private nonisolated static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp"
    ]
    private nonisolated static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus"
    ]
    private nonisolated static let documentExtensions: Set<String> = [
        "pdf", "txt", "rtf", "md", "csv", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key"
    ]
    private nonisolated static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg"
    ]
}

enum FileDrawerFilter: String, CaseIterable, Identifiable {
    case all, folder, image, video, audio, document, archive, other

    var id: String { rawValue }
    var itemKind: FileDrawerItemKind? { self == .all ? nil : FileDrawerItemKind(rawValue: rawValue) }
    var title: String { self == .all ? "全部文件" : (itemKind?.title ?? "全部文件") }
    var symbolName: String { self == .all ? "line.3.horizontal.decrease.circle" : (itemKind?.symbolName ?? "doc") }

    func includes(_ item: FileDrawerItem) -> Bool {
        itemKind == nil || item.kind == itemKind
    }
}

enum FileDrawerSortMode: Int, CaseIterable, Identifiable {
    case name = 0
    case modificationDate = 1
    case dateAdded = 2
    case kind = 4
    case size = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .modificationDate: return "修改日期"
        case .dateAdded: return "添加时间"
        case .kind: return "类型"
        case .size: return "大小"
        }
    }

    var symbolName: String {
        switch self {
        case .name: return "textformat.abc"
        case .modificationDate: return "calendar"
        case .dateAdded: return "clock.badge.plus"
        case .kind: return "list.bullet"
        case .size: return "arrow.down.forward.and.arrow.up.backward"
        }
    }
}

enum FileDrawerSortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: return "递增"
        case .descending: return "递减"
        }
    }

    var symbolName: String {
        switch self {
        case .ascending: return "arrow.up"
        case .descending: return "arrow.down"
        }
    }
}

struct FileDrawerLocation: Identifiable, Codable, Hashable, @unchecked Sendable {
    enum Kind: String, Codable {
        case downloads
        case desktop
        case custom
    }

    let id: String
    let kind: Kind
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
    var isRemovable: Bool { kind == .custom }

    var symbolName: String {
        switch kind {
        case .downloads: return "arrow.down.circle"
        case .desktop: return "desktopcomputer"
        case .custom: return "folder.fill"
        }
    }
}

struct FileDrawerPathComponent: Identifiable, Hashable {
    let url: URL
    let name: String

    var id: String { url.standardizedFileURL.path }
}

enum FileDrawerSelectionDirection {
    case left
    case right
    case up
    case down
    case pageUp
    case pageDown
    case home
    case end
}

enum FileDrawerTimeFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case yesterday
    case thisWeek
    case thisMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部时间"
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .thisMonth: return "本月"
        }
    }

    func includes(_ item: FileDrawerItem) -> Bool {
        guard self != .all, let date = item.modificationDate else { return true }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .all:
            return true
        case .today:
            return date >= startOfToday
        case .yesterday:
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return date >= startOfYesterday && date < startOfToday
        case .thisWeek:
            let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return date >= calendar.startOfDay(for: startOfWeek)
        case .thisMonth:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return date >= startOfMonth
        }
    }
}

enum FileDrawerPlacement: Int, CaseIterable, Identifiable {
    case left = 0
    case right = 1
    case topLeft = 3
    case topRight = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .left: return "左侧"
        case .right: return "右侧"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        }
    }

    var symbolName: String {
        switch self {
        case .left: return "rectangle.lefthalf.inset.filled"
        case .right: return "rectangle.righthalf.inset.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        }
    }
}
