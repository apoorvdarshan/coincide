import AppKit
import SwiftUI

/// A plain-text editor in the app's theme for instruction files: monospaced, no smart quotes or other substitutions,
/// with Markdown headings, code and comments picked out.
struct InstructionsEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.font = Self.font
        textView.textColor = Theme.ink
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        textView.typingAttributes = [.font: Self.font, .foregroundColor: Theme.ink]
        textView.setAccessibilityLabel(String(localized: "Instructions"))
        textView.string = text
        Self.highlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            textView.undoManager?.removeAllActions()
            Self.highlight(textView)
        }
    }

    static var font: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }

    /// Above this size the text is shown plain, to keep typing responsive.
    static let highlightLimit = 200_000

    /// Colors headings, fenced code, inline code and HTML comments. Runs over the whole text, which instruction files
    /// keep small.
    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let whole = NSRange(location: 0, length: string.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.ink], range: whole)
        if string.length <= highlightLimit {
            let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            var inFence = false
            string.enumerateSubstrings(in: whole, options: [.byLines]) { line, range, _, _ in
                guard let line else { return }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    inFence.toggle()
                    storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: range)
                } else if inFence {
                    storage.addAttribute(.backgroundColor, value: Theme.codeBackground, range: range)
                } else if trimmed.hasPrefix("#") {
                    storage.addAttributes([.font: bold, .foregroundColor: Theme.accent], range: range)
                }
            }
            for (pattern, color) in [("`[^`\\n]+`", Theme.accent), ("<!--[\\s\\S]*?-->", Theme.secondaryText)] {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in expression.matches(in: storage.string, range: whole) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: Theme.ink]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            InstructionsEditor.highlight(textView)
        }
    }
}
