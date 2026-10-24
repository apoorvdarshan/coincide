import SwiftUI

/// Shared native rows keep every settings page at the same visual scale.
struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.system(size: 13, weight: .medium)) }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .background(ChatChrome.settingsCard, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)) }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().font(.system(size: 13))
        }
        .padding(.vertical, 14)
        .frame(minHeight: 52)
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
}

struct SettingsActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.09)) }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct SettingsMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(label, content: content)
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)).allowsHitTesting(false) }
    }
}
