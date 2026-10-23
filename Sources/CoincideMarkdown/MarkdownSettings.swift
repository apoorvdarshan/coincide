import SwiftUI

/// Rendering preferences, stored per device in user defaults like other app settings.
public enum MarkdownPreferences {
    /// T3's `wordWrap`: wrap code blocks and tables by default. Default on.
    public static let wordWrapKey = "wordWrap"
    /// T3's `mathRenderingEnabled`. Default on here because Coincide already typeset
    /// closed display formulas before inline math existed; off shows TeX as written.
    public static let renderMathKey = "renderMath"
}

/// Settings rows for message rendering, placed in the app's Settings form.
public struct MarkdownSettingsSection: View {
    @AppStorage(MarkdownPreferences.wordWrapKey) private var wordWrap = true
    @AppStorage(MarkdownPreferences.renderMathKey) private var renderMath = true
    public init() {}
    public var body: some View {
        Toggle("Word wrap", isOn: $wordWrap).accessibilityIdentifier("settings.wordWrap")
        Text("Wrap long lines in code blocks and tables by default. Each block keeps its own wrap button.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Render math", isOn: $renderMath).accessibilityIdentifier("settings.renderMath")
        Text(verbatim: "Typeset LaTeX math, such as $x^2$, \\(x^2\\) or \\[x^2\\], in messages. Off shows the TeX as written.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
