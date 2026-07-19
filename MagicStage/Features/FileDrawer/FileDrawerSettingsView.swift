import SwiftUI

struct FileDrawerSettingsView: View {
    @ObservedObject private var service = FileDrawerService.shared
    @State private var isRecording = false
    @State private var shortcut = ShortcutRegistry.shared.shortcut(for: .fileDrawer) ?? .empty

    private var springAnimation: Animation {
        .spring(
            response: UIConfig.Animation.toggleSpringResponse,
            dampingFraction: UIConfig.Animation.toggleSpringDamping
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionSpacing) {
                Text("文件抽屉")
                    .font(.system(size: UIConfig.Typography.headerTitleSize, weight: .semibold))

                featureSection
                folderSection
                appearanceSection

                Spacer()
            }
            .padding(UIConfig.SettingsPage.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isRecording else { return }
            isRecording = false
            HotkeyManager.shared.cancelRecording()
        }
    }

    private var featureSection: some View {
        section(title: "呼出与交互") {
            SettingsCard {
                SettingsRow(title: "启用文件抽屉") {
                    Toggle("", isOn: $service.isEnabled.animation(springAnimation))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "屏幕边缘呼出") {
                    Toggle("", isOn: $service.edgeTriggerEnabled.animation(springAnimation))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!service.isEnabled)
                }

                SettingsDivider()

                SettingsRow(title: "呼出快捷键") {
                    ShortcutRecorderView(
                        shortcut: shortcut,
                        isRecording: isRecording,
                        isEnabled: service.isEnabled,
                        onRecord: {
                            isRecording = true
                            HotkeyManager.shared.startRecording(for: .fileDrawer) { value in
                                isRecording = false
                                if value.keyCode != 0 || value.modifierFlags != 0 {
                                    shortcut = value
                                }
                            }
                        },
                        onClear: {
                            HotkeyManager.shared.clearShortcut(for: .fileDrawer)
                            shortcut = .empty
                        }
                    )
                }
            }
        }
    }

    // MARK: - 出现位置（多选）

    private var placementSection: some View {
        section(title: "出现位置") {
            SettingsCard {
                VStack(spacing: 0) {
                    Text("选择文件抽屉可触发的屏幕方位，可多选")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
                        .padding(.vertical, 10)

                    SettingsDivider()

                    ForEach(Array(FileDrawerPlacement.allCases.enumerated()), id: \.element.id) { index, placement in
                        HStack(spacing: 12) {
                            Image(systemName: placement.symbolName)
                                .foregroundStyle(service.placements.contains(placement) ? Color.accentColor : Color.secondary)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 24, height: 24)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                            Text(placement.title)
                                .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .medium))

                            Spacer()

                            Toggle("", isOn: placementToggleBinding(for: placement).animation(springAnimation))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(!service.isEnabled)
                        }
                        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            togglePlacement(placement)
                        }

                        if index < FileDrawerPlacement.allCases.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
    }

    private func placementToggleBinding(for placement: FileDrawerPlacement) -> Binding<Bool> {
        Binding(
            get: { service.placements.contains(placement) },
            set: { isOn in
                if isOn {
                    service.placements.insert(placement)
                } else if service.placements.count > 1 {
                    service.placements.remove(placement)
                }
            }
        )
    }

    private func togglePlacement(_ placement: FileDrawerPlacement) {
        guard service.isEnabled else { return }
        if service.placements.contains(placement) {
            if service.placements.count > 1 {
                service.placements.remove(placement)
            }
        } else {
            service.placements.insert(placement)
        }
    }

    // MARK: - 文件夹标签

    private var folderSection: some View {
        section(title: "文件夹标签") {
            SettingsCard {
                VStack(spacing: 0) {
                    ForEach(Array(service.locations.enumerated()), id: \.element.id) { index, location in
                        HStack(spacing: 12) {
                            Image(systemName: location.symbolName)
                                .foregroundStyle(location.kind == .custom ? Color.secondary : Color.accentColor)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 24, height: 24)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name)
                                    .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .medium))
                                    .lineLimit(1)
                                Text(location.path)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if location.isRemovable {
                                Button {
                                    service.removeLocation(location.id)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .help("移除标签")
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)

                        if index < service.locations.count - 1 {
                            SettingsDivider()
                        }
                    }

                    SettingsDivider()

                    // 默认打开
                    SettingsRow(title: "默认打开") {
                        SettingsOptionMenu(
                            selection: $service.defaultOpenLocation,
                            options: defaultOpenOptions
                        )
                    }

                    SettingsDivider()

                    Button {
                        service.chooseFolder()
                    } label: {
                        Label("添加自定义文件夹…", systemImage: "folder.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 出现位置紧跟在文件夹标签下方
            placementSection
        }
    }

    private var defaultOpenOptions: [SettingsMenuOption<String>] {
        var options: [SettingsMenuOption<String>] = [
            SettingsMenuOption(value: "lastOpened", title: "上次打开")
        ]
        options.append(contentsOf: service.locations.map {
            SettingsMenuOption(value: $0.id, title: $0.name)
        })
        return options
    }

    // MARK: - 浏览

    private var appearanceSection: some View {
        section(title: "浏览") {
            SettingsCard {
                SettingsRow(title: "排序方式") {
                    SettingsOptionMenu(
                        selection: $service.sortMode,
                        options: FileDrawerSortMode.allCases.map {
                            SettingsMenuOption(value: $0, title: $0.title)
                        }
                    )
                }

                SettingsDivider()

                SettingsRow(title: "每行显示") {
                    SettingsOptionMenu(
                        selection: $service.columnCount,
                        options: (2...5).map {
                            SettingsMenuOption(value: $0, title: "\($0) 列")
                        }
                    )
                }

                SettingsDivider()

                SettingsSliderRow(
                    title: "移出后关闭",
                    minimumLabel: "0.2s",
                    maximumLabel: "3s",
                    valueLabel: String(format: "%.2fs", service.dismissDelay),
                    value: $service.dismissDelay,
                    range: 0.2...3,
                    step: 0.2
                )

                SettingsDivider()

                SettingsRow(title: "显示隐藏文件") {
                    Toggle("", isOn: $service.showHiddenFiles.animation(springAnimation))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIConfig.SettingsPage.sectionLabelCardSpacing) {
            Text(title)
                .font(.system(size: UIConfig.Typography.sectionLabelSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, UIConfig.SettingsPage.sectionLabelLeadingPadding)
            content()
        }
    }
}
