import SwiftUI

// MARK: - Dock 退出快捷键设置页面

struct DockHoverQuitSettingsView: View {
    @State private var isEnabled = DockHoverQuitService.shared.isEnabled
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcut =
        ShortcutRegistry.shared.shortcut(for: .dockQuit) ?? KeyboardShortcut.empty

    private var springAnimation: Animation {
        .spring(response: UIConfig.Animation.toggleSpringResponse,
                dampingFraction: UIConfig.Animation.toggleSpringDamping)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                // Header
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.headerTitleSubtitleSpacing) {
                    Text("Dock 退出")
                        .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))
                }

                // 快捷键设置
                VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
                    Text("快捷键")
                        .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)

                    SettingsCard {
                        SettingsRow(title: "退出 Dock 图标对应 App") {
                            HStack(spacing: UIConfig.SettingsPage.rowContentSpacing) {
                                ShortcutRecorderView(
                                    shortcut: currentShortcut,
                                    isRecording: isRecording,
                                    isEnabled: isEnabled,
                                    onRecord: {
                                        isRecording = true
                                        HotkeyManager.shared.startRecording(for: .dockQuit) { shortcut in
                                            isRecording = false
                                            if shortcut.keyCode != 0 || shortcut.modifierFlags != 0 {
                                                currentShortcut = shortcut
                                            }
                                        }
                                    },
                                    onClear: {
                                        HotkeyManager.shared.clearShortcut(for: .dockQuit)
                                        currentShortcut = KeyboardShortcut.empty
                                    }
                                )
                                Toggle("", isOn: $isEnabled.animation(springAnimation))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .onChange(of: isEnabled) { _, newValue in
                                        DockHoverQuitService.shared.isEnabled = newValue
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
