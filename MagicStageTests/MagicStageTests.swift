import AppKit
import Testing
@testable import MagicStage

struct MagicStageTests {
    @Test func screenCoordinateRoundTripSupportsSecondaryDisplays() {
        let primaryMaxY: CGFloat = 1080
        let quartz = CGPoint(x: -640, y: 1320)
        let cocoa = ScreenCoordinates.cocoaPoint(fromQuartz: quartz, primaryScreenMaxY: primaryMaxY)

        #expect(cocoa == CGPoint(x: -640, y: -240))
        #expect(ScreenCoordinates.quartzPoint(fromCocoa: cocoa, primaryScreenMaxY: primaryMaxY) == quartz)
    }

    @Test func cocoaFrameConvertsToQuartzFrame() {
        let cocoa = CGRect(x: 1920, y: 120, width: 1440, height: 900)
        let quartz = ScreenCoordinates.quartzFrame(fromCocoa: cocoa, primaryScreenMaxY: 1080)

        #expect(quartz == CGRect(x: 1920, y: 60, width: 1440, height: 900))
        #expect(ScreenCoordinates.cocoaFrame(fromQuartz: quartz, primaryScreenMaxY: 1080) == cocoa)
    }

    @Test func windowIdentitySeparatesWindowsFromSameApplication() {
        let first = WindowIdentity(pid: 42, windowID: 1001)
        let second = WindowIdentity(pid: 42, windowID: 1002)
        let sameAsFirst = WindowIdentity(pid: 42, windowID: 1001)

        #expect(first != second)
        #expect(first == sameAsFirst)
        #expect(Set([first, second, sameAsFirst]).count == 2)
    }

    @Test func moveWindowShortcutRequiresOnlyModifiers() {
        #expect(KeyboardShortcut(keyCode: .max, modifiers: [.command, .control]).isModifierOnlyShortcut)
        #expect(!KeyboardShortcut(keyCode: 0, modifiers: [.command]).isModifierOnlyShortcut)
        #expect(!KeyboardShortcut(keyCode: .max, modifiers: []).isModifierOnlyShortcut)
    }

    @Test func layoutFramesCoverExpectedScreenRegions() {
        let screen = CGRect(x: 100, y: 40, width: 1200, height: 900)

        #expect(WindowLayout.leftHalf.targetFrame(screenAXFrame: screen, currentSize: .zero)
            == CGRect(x: 100, y: 40, width: 600, height: 900))
        #expect(WindowLayout.rightHalf.targetFrame(screenAXFrame: screen, currentSize: .zero)
            == CGRect(x: 700, y: 40, width: 600, height: 900))
        #expect(WindowLayout.quadBottomRight.targetFrame(screenAXFrame: screen, currentSize: .zero)
            == CGRect(x: 700, y: 490, width: 600, height: 450))
    }

    @Test func centerLayoutPreservesCurrentWindowSize() {
        let frame = WindowLayout.center.targetFrame(
            screenAXFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            currentSize: CGSize(width: 600, height: 400)
        )

        #expect(frame == CGRect(x: 300, y: 200, width: 600, height: 400))
    }

    @Test func fileDrawerSortKeepsFoldersFirst() {
        let file = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/A-file.txt"),
            isDirectory: false,
            modificationDate: Date(timeIntervalSince1970: 200),
            fileSize: 10
        )
        let folder = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/Z-folder", isDirectory: true),
            isDirectory: true,
            modificationDate: Date(timeIntervalSince1970: 100),
            fileSize: nil
        )

        let sorted = FileDrawerService.sortItems([file, folder], mode: .name, direction: .ascending)
        #expect(sorted.map(\.id) == [folder.id, file.id])
    }

    @Test func fileDrawerModifiedSortUsesNewestFirstWithinKind() {
        let older = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/older.txt"),
            isDirectory: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            fileSize: 10
        )
        let newer = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/newer.txt"),
            isDirectory: false,
            modificationDate: Date(timeIntervalSince1970: 200),
            fileSize: 10
        )

        let sorted = FileDrawerService.sortItems([older, newer], mode: .modificationDate, direction: .descending)
        #expect(sorted.map(\.id) == [newer.id, older.id])
    }

    @Test func fileDrawerDateAndSizeSortDoNotForceFoldersFirst() {
        let olderFolder = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/Untitled.icon", isDirectory: true),
            isDirectory: true,
            modificationDate: Date(timeIntervalSince1970: 100),
            fileSize: nil
        )
        let recentScreenshot = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/截屏.png"),
            isDirectory: false,
            modificationDate: Date(timeIntervalSince1970: 200),
            fileSize: 100
        )

        #expect(
            FileDrawerService.sortItems([olderFolder, recentScreenshot], mode: .modificationDate, direction: .descending).map(\.id)
                == [recentScreenshot.id, olderFolder.id]
        )
        #expect(
            FileDrawerService.sortItems([olderFolder, recentScreenshot], mode: .size, direction: .descending).map(\.id)
                == [recentScreenshot.id, olderFolder.id]
        )
    }

    @Test func fileDrawerNameSortIsDeterministicForGridOrder() {
        let names = ["thing", "icon", "ic", "tool2", "new ic", "op", "Untitled.icon"]
        let items = names.map {
            FileDrawerItem(
                url: URL(fileURLWithPath: "/tmp/\($0)", isDirectory: true),
                isDirectory: true,
                modificationDate: nil,
                fileSize: nil
            )
        }

        let ascending = FileDrawerService.sortItems(items, mode: .name, direction: .ascending).map(\.name)
        let descending = FileDrawerService.sortItems(items, mode: .name, direction: .descending).map(\.name)

        #expect(ascending == ["ic", "icon", "new ic", "op", "thing", "tool2", "Untitled.icon"])
        #expect(descending == Array(ascending.reversed()))
    }

    @Test func fileDrawerClassifiesItemsForQuickFiltering() {
        let image = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/Photo.HEIC"),
            isDirectory: false,
            modificationDate: nil,
            fileSize: nil
        )
        let document = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/Report.docx"),
            isDirectory: false,
            modificationDate: nil,
            fileSize: nil
        )
        let folder = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/Photos", isDirectory: true),
            isDirectory: true,
            modificationDate: nil,
            fileSize: nil
        )

        #expect(image.kind == .image)
        #expect(document.kind == .document)
        #expect(folder.kind == .folder)
        #expect(FileDrawerFilter.image.includes(image))
        #expect(!FileDrawerFilter.image.includes(document))
        #expect(FileDrawerFilter.all.includes(folder))
    }

    @Test func fileDrawerTreatsPackagesAsOpenableFiles() {
        let project = FileDrawerItem(
            url: URL(fileURLWithPath: "/tmp/MagicStage.xcodeproj", isDirectory: true),
            isDirectory: true,
            isPackage: true,
            modificationDate: nil,
            fileSize: nil
        )

        #expect(!project.isBrowsableDirectory)
        #expect(project.kind != .folder)
    }

    @Test func fileDrawerSupportsCaseOnlyRenameOnCaseInsensitiveVolumes() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("MagicStage-case-rename-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("Report.PDF")
        let destination = directory.appendingPathComponent("report.pdf")
        try Data([0x41]).write(to: source)
        #expect(FileDrawerService.urlsReferToSameFile(source, source))

        // 大小写敏感卷上 destination 不会预先指向 source，普通 moveItem 路径即可处理；
        // 默认 APFS 大小写不敏感卷会进入这里，覆盖实际发生问题的分支。
        guard fileManager.fileExists(atPath: destination.path) else { return }
        #expect(FileDrawerService.urlsReferToSameFile(source, destination))

        try FileDrawerService.renameExistingItemCase(at: source, to: destination)
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["report.pdf"])
    }

    @MainActor
    @Test func transientKeyInterceptorConsumesAndReleasesPreviewSpace() {
        let manager = HotkeyManager()
        var handledKeyCodes: [UInt16] = []
        let token = manager.installTransientKeyDownInterceptor { keyCode, _ in
            guard keyCode == 49 || keyCode == 53 else { return false }
            handledKeyCodes.append(keyCode)
            return true
        }

        #expect(manager.consumeTransientKeyDown(keyCode: 49, modifiers: []))
        #expect(!manager.consumeTransientKeyDown(keyCode: 0, modifiers: []))
        #expect(handledKeyCodes == [49])

        manager.removeTransientKeyDownInterceptor(token)
        #expect(!manager.consumeTransientKeyDown(keyCode: 49, modifiers: []))
    }
}
