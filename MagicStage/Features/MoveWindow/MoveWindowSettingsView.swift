import SwiftUI

// MARK: - 移动窗口设置页面

struct MoveWindowSettingsView: View {
    @State private var isEnabled = MoveWindowService.shared.isEnabled
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcut =
        ShortcutRegistry.shared.shortcut(for: .moveWindow) ?? KeyboardShortcut.empty

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                // Header
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
                    Text("移动窗口")
                        .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
                }

                // 快捷键设置
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("快捷键")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "启用移动窗口") {
                            HStack(spacing: UIConfig.SettingsPage.rowContentSpacing) {
                                ShortcutRecorderView(
                                    shortcut: currentShortcut,
                                    isRecording: isRecording,
                                    isEnabled: isEnabled,
                                    onRecord: {
                                        isRecording = true
                                        HotkeyManager.shared.startRecording(for: .moveWindow) { shortcut in
                                            isRecording = false
                                            if shortcut.keyCode != 0 || shortcut.modifierFlags != 0 {
                                                currentShortcut = shortcut
                                            }
                                        }
                                    },
                                    onClear: {
                                        HotkeyManager.shared.clearShortcut(for: .moveWindow)
                                        currentShortcut = KeyboardShortcut.empty
                                    }
                                )
                                Toggle("", isOn: $isEnabled)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .onChange(of: isEnabled) { _, newValue in
                                        MoveWindowService.shared.isEnabled = newValue
                                    }
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
            if isRecording { stopRecording() }
        }
    }

    private func stopRecording() {
        isRecording = false
        HotkeyManager.shared.cancelRecording()
    }
}
