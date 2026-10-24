import SwiftUI

/// Shared native rows keep every settings page at the same visual scale.
struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 2).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .background(ChatChrome.settingsCard, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ChatChrome.separator).allowsHitTesting(false) }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        SettingsRowLayout {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8, content: control).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 52)
    }
}

/// Keep the same native controls mounted while their layout changes. Long
/// labels and editable values move onto separate lines instead of squeezing.
private struct SettingsRowLayout: Layout {
    private struct Metrics {
        let width: CGFloat
        let label: CGSize
        let control: CGSize
        let stacked: Bool
        var height: CGFloat { stacked ? label.height + 10 + control.height : max(label.height, control.height) }
    }

    private func metrics(width: CGFloat?, subviews: Subviews) -> Metrics {
        let idealControl = subviews[1].sizeThatFits(.unspecified)
        let availableWidth = width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let idealControlWidth = idealControl.width.isFinite ? max(0, idealControl.width) : (availableWidth ?? 320)
        let idealLabel = subviews[0].sizeThatFits(.unspecified)
        let width = availableWidth ?? (idealLabel.width.isFinite ? idealLabel.width : 200) + 20 + idealControlWidth
        let stacked = width - idealControlWidth - 20 < min(200, width * 0.6)
        let control = subviews[1].sizeThatFits(.init(width: min(width, idealControlWidth), height: nil))
        let labelWidth = stacked ? width : max(0, width - control.width - 20)
        let label = subviews[0].sizeThatFits(.init(width: labelWidth, height: nil))
        return .init(width: width, label: label, control: control, stacked: stacked)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = metrics(width: proposal.width, subviews: subviews)
        return .init(width: sizes.width, height: sizes.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = metrics(width: bounds.width, subviews: subviews)
        let labelWidth = sizes.stacked ? bounds.width : max(0, bounds.width - sizes.control.width - 20)
        subviews[0].place(at: .init(x: bounds.minX, y: sizes.stacked ? bounds.minY : bounds.midY - sizes.label.height / 2),
            proposal: .init(width: labelWidth, height: sizes.label.height))
        subviews[1].place(at: .init(x: sizes.stacked ? bounds.minX : bounds.maxX - sizes.control.width,
            y: sizes.stacked ? bounds.minY + sizes.label.height + 10 : bounds.midY - sizes.control.height / 2),
            proposal: .init(width: sizes.control.width, height: sizes.control.height))
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(ChatChrome.separator).frame(height: 1).accessibilityHidden(true) }
}

struct SettingsActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.13 : isHovered && isEnabled ? 0.085 : 0.045), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(isHovered && isEnabled ? 0.14 : 0.09)).allowsHitTesting(false) }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { isHovered = $0 }
    }
}

struct SettingsMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    var body: some View {
        Menu(content: content) {
            Text(label).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered && isEnabled ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(isHovered && isEnabled ? 0.14 : 0.1)).allowsHitTesting(false) }
        .onHover { isHovered = $0 }
    }
}
