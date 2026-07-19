import AppKit
import SwiftUI

// MARK: - 设置行组件

struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                .foregroundColor(.primary)
            Spacer()
            content
        }
        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
        .frame(height: UIConfig.SettingsRow.rowHeight)
    }
}

// MARK: - 标准参数滑杆行

/// 设置页统一使用的参数滑杆布局：标题、最小值、系统滑杆、最大值与当前值。
struct SettingsSliderRow<V: BinaryFloatingPoint & Strideable>: View
    where V.Stride: BinaryFloatingPoint {
    let title: String
    let minimumLabel: String
    let maximumLabel: String
    let valueLabel: String
    let value: Binding<V>
    let range: ClosedRange<V>
    let step: V.Stride?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 110, alignment: .leading)

            Text(minimumLabel)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .leading)

            Group {
                if let step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
            }
            .frame(maxWidth: .infinity)

            Text(maximumLabel)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .trailing)

            Text(valueLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, UIConfig.SettingsRow.horizontalPadding)
        .frame(height: UIConfig.SettingsRow.rowHeight)
    }
}

// MARK: - 无边框设置选项菜单

struct SettingsMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let symbolName: String?

    var id: Value { value }

    init(value: Value, title: String, symbolName: String? = nil) {
        self.value = value
        self.title = title
        self.symbolName = symbolName
    }
}

struct SettingsOptionMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsMenuOption<Value>]

    @State private var isHovering = false

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? options.first?.title ?? ""
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(selectedTitle)
                .font(.system(size: UIConfig.Typography.settingsRowTitleSize, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(isHovering ? 0 : 0.075))
                }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.075 : 0))
        }
        .overlay {
            NativeSettingsPopUpButton(selection: $selection, options: options)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct NativeSettingsPopUpButton<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [SettingsMenuOption<Value>]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.controlSize = .regular
        button.font = .systemFont(ofSize: UIConfig.Typography.settingsRowTitleSize, weight: .regular)
        button.alignment = .right
        button.imagePosition = .noImage
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.arrowPosition = .noArrow
            cell.altersStateOfSelectedItem = true
            cell.lineBreakMode = .byTruncatingTail
        }
        update(button)
        return button
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        update(nsView)
    }

    private func update(_ button: NSPopUpButton) {
        let titles = options.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            for option in options {
                button.addItem(withTitle: option.title)
                if let symbolName = option.symbolName,
                   let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: option.title) {
                    image.size = NSSize(width: 15, height: 15)
                    button.lastItem?.image = image
                }
            }
        }
        if let index = options.firstIndex(where: { $0.value == selection }),
           button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        button.isEnabled = isEnabled
        button.toolTip = options.first(where: { $0.value == selection })?.title
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeSettingsPopUpButton

        init(parent: NativeSettingsPopUpButton) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

// MARK: - 卡片背景修饰符

struct CardBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: UIConfig.Card.cornerRadius, style: .continuous)
                    .fill(UIConfig.ColorTokens.backgroundCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIConfig.Card.cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(UIConfig.Card.borderOpacity),
                            lineWidth: UIConfig.Card.borderWidth)
            )
    }
}

// MARK: - 统一设置卡片

/// 统一卡片容器：内部 VStack(spacing:0) + CardBackgroundModifier + 边框
/// 所有设置页的卡片都使用此组件，保证底色矩形、圆角、描边完全一致
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .modifier(CardBackgroundModifier())
    }
}

// MARK: - 统一设置行分隔线

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.primary.opacity(UIConfig.ColorTokens.dividerOpacity))
            .padding(.horizontal, UIConfig.SettingsPage.dividerHorizontalPadding)
    }
}
