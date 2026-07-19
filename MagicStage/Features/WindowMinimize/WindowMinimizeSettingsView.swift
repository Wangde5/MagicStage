import SwiftUI

// MARK: - 窗口最小化设置页面

struct WindowMinimizeSettingsView: View {
    @AppStorage("enableExcludeKey") var enableExcludeKey = true
    @AppStorage("excludeKeyType") var excludeKeyType = 0
    @AppStorage("enableHotkeyAll") var enableHotkeyAll = true
    @AppStorage("enableHotkeyOthers") var enableHotkeyOthers = true
    @AppStorage("enableDockToggleKeyWindow") var enableDockToggleKeyWindow = false

    @State private var isRecordingAll = false
    @State private var isRecordingOthers = false
    @State private var shortcutAll: KeyboardShortcut =
        ShortcutRegistry.shared.shortcut(for: .minimizeAll) ?? KeyboardShortcut.empty
    @State private var shortcutOthers: KeyboardShortcut =
        ShortcutRegistry.shared.shortcut(for: .minimizeOthers) ?? KeyboardShortcut.empty

    private var springAnimation: Animation {
        .spring(response: UIConfig.Animation.toggleSpringResponse,
                dampingFraction: UIConfig.Animation.toggleSpringDamping)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                // Header
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerBottomSpacing) {
                    VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
                        Text("窗口最小化")
                            .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
                    }
                }

                // 快捷键功能
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("快捷键")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "隐藏所有窗口") {
                            HStack(spacing: UIConfig.SettingsPage.rowContentSpacing) {
                                ShortcutRecorderView(
                                    shortcut: shortcutAll,
                                    isRecording: isRecordingAll,
                                    isEnabled: enableHotkeyAll,
                                    onRecord: {
                                        isRecordingAll = true
                                        HotkeyManager.shared.startRecording(for: .minimizeAll) { shortcut in
                                            isRecordingAll = false
                                            if shortcut.keyCode != 0 || shortcut.modifierFlags != 0 {
                                                shortcutAll = shortcut
                                            }
                                        }
                                    },
                                    onClear: {
                                        HotkeyManager.shared.clearShortcut(for: .minimizeAll)
                                        shortcutAll = KeyboardShortcut.empty
                                    }
                                )
                                Toggle("", isOn: $enableHotkeyAll.animation(springAnimation))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }

                        SettingsDivider()

                        SettingsRow(title: "隐藏其他窗口") {
                            HStack(spacing: UIConfig.SettingsPage.rowContentSpacing) {
                                ShortcutRecorderView(
                                    shortcut: shortcutOthers,
                                    isRecording: isRecordingOthers,
                                    isEnabled: enableHotkeyOthers,
                                    onRecord: {
                                        isRecordingOthers = true
                                        HotkeyManager.shared.startRecording(for: .minimizeOthers) { shortcut in
                                            isRecordingOthers = false
                                            if shortcut.keyCode != 0 || shortcut.modifierFlags != 0 {
                                                shortcutOthers = shortcut
                                            }
                                        }
                                    },
                                    onClear: {
                                        HotkeyManager.shared.clearShortcut(for: .minimizeOthers)
                                        shortcutOthers = KeyboardShortcut.empty
                                    }
                                )
                                Toggle("", isOn: $enableHotkeyOthers.animation(springAnimation))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }
                    }
                }

                // Dock 鼠标交互
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("DOCK 交互")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "窗口反转") {
                            HStack(spacing: UIConfig.SettingsPage.rowContentSpacing) {
                                Toggle("", isOn: $enableDockToggleKeyWindow.animation(springAnimation))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }

                        SettingsDivider()

                        SettingsRow(title: "点击 Dock 启用修饰键排除") {
                            HStack(spacing: UIConfig.SettingsPage.dockRowContentSpacing) {
                                SettingsOptionMenu(
                                    selection: $excludeKeyType,
                                    options: [
                                        SettingsMenuOption(value: 0, title: "Fn 键"),
                                        SettingsMenuOption(value: 1, title: "Shift 键")
                                    ]
                                )
                                .disabled(!enableExcludeKey)
                                .opacity(enableExcludeKey ? 1 : UIConfig.ShortcutRecorder.disabledBgOpacity)
                                Toggle("", isOn: $enableExcludeKey.animation(springAnimation))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(UIConfig.SettingsPage.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isRecordingAll || isRecordingOthers {
                isRecordingAll = false
                isRecordingOthers = false
                HotkeyManager.shared.cancelRecording()
            }
        }
    }
}
