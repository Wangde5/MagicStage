import Combine
import Sparkle
import SwiftUI

final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = false

    private var updater: SPUUpdater?

    private init() {}

    func configure(with updater: SPUUpdater) {
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    func toggleAutomaticChecks() {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
}