import Combine
import Sparkle
import SwiftUI

final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterService()

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = false
    @Published var updateAvailable: Bool? = nil

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
}
