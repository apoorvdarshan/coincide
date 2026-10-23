import CoincideTerminal
import SwiftUI

/// Settings › General › Terminal: font family, size and colors (T3's terminal
/// typography and theme-following palette), plus restored-shell behavior.
struct TerminalSettingsSection: View {
    @AppStorage(TerminalAppearance.fontFamilyKey) private var fontFamily = ""
    @AppStorage(TerminalAppearance.fontSizeKey) private var fontSize = TerminalAppearance.defaultFontSize
    @AppStorage(TerminalAppearance.themeKey) private var theme = TerminalAppearance.Theme.system.rawValue
    @AppStorage(TerminalAppearance.resumeRestoredShellsKey) private var resumeRestoredShells = true
    @AppStorage(TerminalAppearance.closeIdleOnSettleKey) private var closeIdleOnSettle = false
    @State private var families: [String] = []

    private var appearance: TerminalAppearance { .init(fontFamily: fontFamily, fontSize: fontSize, theme: theme) }

    var body: some View {
        Section("Terminal") {
            Picker("Font", selection: $fontFamily) {
                Text("System Monospaced").tag("")
                if !fontFamily.isEmpty, !families.contains(fontFamily) { Text("\(fontFamily) (unavailable)").tag(fontFamily) }
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }.accessibilityIdentifier("terminal-font-family")
            Stepper(value: Binding(get: { appearance.fontSize }, set: { fontSize = TerminalAppearance.clampedSize($0) }),
                    in: TerminalAppearance.fontSizes, step: 1) {
                LabeledContent("Size", value: "\(Int(appearance.fontSize)) pt")
            }.accessibilityIdentifier("terminal-font-size")
            Picker("Colors", selection: $theme) {
                ForEach(TerminalAppearance.Theme.allCases) { Text($0.title).tag($0.rawValue) }
            }.accessibilityIdentifier("terminal-theme")
            TerminalAppearancePreview(appearance: appearance)
            Toggle("Start a new shell in restored terminals", isOn: $resumeRestoredShells)
            Text("Appearance changes apply to open local and remote terminals without restarting them. Restored output stays in its pane. A new shell starts only when its saved checkout still matches; otherwise open a new terminal. Saved commands are never run again.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Close idle shells when settling", isOn: $closeIdleOnSettle)
                .accessibilityIdentifier("terminal-close-idle-on-settle")
            Text("Keep their output in the pane. Shells running commands and managed script jobs stay open.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { families = TerminalAppearance.monospacedFamilies() }
    }
}

/// A static sample in the chosen font with the theme's ANSI colors.
struct TerminalAppearancePreview: View {
    let appearance: TerminalAppearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = appearance.theme == .system ? colorScheme == .dark : appearance.theme == .dark
        let colors = appearance.colors(dark: dark, increasedContrast: contrast == .increased)
        let font = Font(appearance.font)
        let foreground = colors.foreground.map { Color(nsColor: Self.color($0)) } ?? Color(nsColor: .textColor)
        VStack(alignment: .leading, spacing: 2) {
            (Text("~/project ").foregroundStyle(Self.swiftUIColor(colors.palette[4])) + Text("$ ").foregroundStyle(foreground)
                + Text("swift test").foregroundStyle(foreground))
            (Text("✔ ").foregroundStyle(Self.swiftUIColor(colors.palette[2])) + Text("42 tests passed  ").foregroundStyle(foreground)
                + Text("⚠ 1 warning").foregroundStyle(Self.swiftUIColor(colors.palette[3])))
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(Self.swiftUIColor(colors.palette[index])).frame(width: 12, height: 10)
                }
            }.padding(.top, 2)
        }
        .font(font).lineLimit(1)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: appearance.backgroundColor(systemIsDark: colorScheme == .dark)), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal preview")
        .accessibilityIdentifier("terminal-appearance-preview")
    }

    private static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
    private static func swiftUIColor(_ hex: String) -> Color { Color(nsColor: color(hex)) }
}
