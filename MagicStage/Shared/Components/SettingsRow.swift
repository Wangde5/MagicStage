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
