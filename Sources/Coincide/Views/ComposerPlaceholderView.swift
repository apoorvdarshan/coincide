import AppKit

/// Draw the hint in the editor's own text coordinates, so its baseline follows
/// the native insertion point instead of a separate SwiftUI padding estimate.
@MainActor
final class ComposerPlaceholderView: NSView {
    weak var editor: NSTextView?
    var text = "" { didSet { if oldValue != text { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, editor.string.isEmpty, !editor.hasMarkedText(), let container = editor.textContainer else { return }
        let font = editor.font ?? .systemFont(ofSize: 14)
        let origin = editor.textContainerOrigin
        let paragraph = (editor.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let hint = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
        hint.draw(in: NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y,
                            width: max(0, bounds.width - origin.x * 2 - container.lineFragmentPadding * 2),
                            height: ceil(font.ascender - font.descender + font.leading) + 2))
    }
}
