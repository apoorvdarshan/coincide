import AppKit
import CoincideMarkdown
import SwiftUI

/// Native text editing, with UTF-16 line selection for coding-agent file links.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    let path: String
    let navigation: FileNavigation?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8); editor.setAccessibilityLabel("File editor")
        editor.delegate = context.coordinator; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if context.coordinator.path != path { editor.undoManager?.removeAllActions(); context.coordinator.path = path }
        if editor.string != text { editor.string = text; editor.undoManager?.removeAllActions() }
        guard let navigation, context.coordinator.navigationID != navigation.id else { return }
        context.coordinator.navigationID = navigation.id
        if let line = navigation.line {
            let range = SourceTextLocation.range(in: text, line: line)
            editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor
        var navigationID: UUID?
        var path: String?
        init(_ parent: SourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }; parent.text = editor.string
        }
    }
}
