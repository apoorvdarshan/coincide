import SwiftUI

/// Rendering preferences, stored per device in user defaults like other app settings.
public enum MarkdownPreferences {
    /// T3's `wordWrap`: wrap code blocks and tables by default. Default on.
    public static let wordWrapKey = "wordWrap"
    /// The app's existing math setting. Product callers pass its default-false
    /// value explicitly; the reusable renderer keeps its default-true API.
    public static let renderMathKey = "renderMathInMarkdown"
}

/// Settings rows for message rendering, placed in the app's Settings form.
public struct MarkdownSettingsSection: View {
    @AppStorage(MarkdownPreferences.wordWrapKey) private var wordWrap = true
    public init() {}
    public var body: some View {
        Toggle("Word wrap", isOn: $wordWrap).accessibilityIdentifier("settings.wordWrap")
        Text("Wrap long lines in code blocks and tables by default. Each block keeps its own wrap button.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
