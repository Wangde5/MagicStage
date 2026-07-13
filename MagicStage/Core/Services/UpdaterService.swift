import Combine
import Sparkle
import SwiftUI

final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterService()

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = false
    @Published var updateAvailable: Bool? = nil
    @Published var updateCheckFailed: Bool = false

    private var updater: SPUUpdater?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "1.0"
    }

    private override init() { super.init() }

    func configure(with updater: SPUUpdater) {
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        // 如果之前已经检查过且我们正处于当前版本，默认显示"已是最新版本"
        if lastUpdateCheckDate != nil {
            updateAvailable = false
        }
    }

    func checkForUpdates() {
        updateCheckFailed = false
        updater?.checkForUpdates()
    }

    func toggleAutomaticChecks() {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateAvailable = false
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    /// 抑制 Sparkle 默认错误弹窗，改为友好提示
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // 过滤掉非真正的网络错误：
        // - SUNoUpdateError (1001): 已是最新版本，不是错误
        // - SUInstallationCanceledError (4007): 用户取消安装
        let nsError = error as NSError
        let isNotRealError = nsError.domain == SUSparkleErrorDomain &&
            (nsError.code == 1001 || nsError.code == 4007)

        if isNotRealError {
            // "已是最新版本"或"用户取消"，不是网络错误
            updateAvailable = false
        } else {
            print("[Updater] 更新检查失败: \(error.localizedDescription)")
            updateCheckFailed = true
        }
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }
}
