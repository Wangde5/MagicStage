import SwiftUI

// MARK: - 移动窗口设置页面

struct MoveWindowSettingsView: View {
    @State private var isEnabled = MoveWindowService.shared.isEnabled
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcut =
        ShortcutRegistry.shared.shortcut(for: .moveWindow) ?? KeyboardShortcut.empty
    @State private var showModifierWarning = false

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
                                                // 校验：移动窗口功能必须使用修饰键，防止拦截所有鼠标事件
                                                if shortcut.modifierFlags == 0 {
                                                    showModifierWarning = true
                                                    HotkeyManager.shared.clearShortcut(for: .moveWindow)
                                                    currentShortcut = KeyboardShortcut.empty
                                                } else {
                                                    currentShortcut = shortcut
                                                }
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
        .alert("快捷键无效", isPresented: $showModifierWarning) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("移动窗口功能必须使用修饰键（⌘/⌃/⌥/⇧），不能使用 Tab、空格等普通按键。\n\n按住修饰键时拖拽窗口即可移动。")
        }
    }

    private func stopRecording() {
        isRecording = false
        HotkeyManager.shared.cancelRecording()
    }
}
