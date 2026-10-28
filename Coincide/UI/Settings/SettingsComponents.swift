import AppKit
import CoincideKit
import SwiftUI

/// A white symbol on a colored rounded square, like the icons in System Settings.
struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A provider's logo on a light tile, like an app icon.
struct SettingsProviderIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                Image(Theme.logoName(for: kind))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .padding(size * 0.18)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SettingsStatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Key glyphs drawn as individual keycaps, e.g. ⌘ ⇧ K.
struct SettingsKeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, key.count > 1 ? 5 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.background.secondary)
                            .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// Copies text to the pasteboard and briefly confirms it.
struct SettingsCopyButton: View {
    let text: String
    var label: LocalizedStringKey = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.setText(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .help(Text("Copy to the clipboard"))
    }
}

/// Renders `backtick` spans in provider-supplied text as code.
struct SettingsInlineCode: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

extension View {
    /// Scrolls to and briefly highlights the row tagged with `setting` when the model asks for it.
    func settingsRevealable(_ setting: SettingsRowID, highlighted: SettingsRowID?) -> some View {
        id(setting)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted == setting ? 0.16 : 0))
                    .padding(-6)
                    .animation(.easeOut(duration: 0.35), value: highlighted)
            }
    }
}

/// Handles reveal requests for a pane: scrolls to the row, highlights it, then fades the highlight.
struct SettingsRevealHandler: ViewModifier {
    let request: SettingsRevealRequest?
    let proxy: ScrollViewProxy
    @Binding var highlighted: SettingsRowID?

    func body(content: Content) -> some View {
        content.task(id: request?.id) {
            guard let request else { return }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(request.setting, anchor: .center) }
            highlighted = request.setting
            try? await Task.sleep(for: .seconds(1.6))
            highlighted = nil
        }
    }
}
