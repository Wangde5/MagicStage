import SwiftUI

@main
struct MagicStageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("功能") {
                Button("文件抽屉") {
                    FileDrawerService.shared.toggle()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("偏好设置…") {
                    appDelegate.openPreferences()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
