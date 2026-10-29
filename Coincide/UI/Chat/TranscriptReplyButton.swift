import AppKit

/// "Reply" over selected text, as ChatGPT and Claude offer it: a small pill just below where a selection in a reply,
/// plan or message ends (above it when there is no room below) that puts the selection in the composer as a quote.
/// It goes when the selection does, while a drag is still extending it, and when the transcript scrolls. Edit › Reply
/// (⌘L) and the selection's context menu do the same from the keyboard and the menu.
@MainActor
final class TranscriptReplyButton: NSObject {
    static let gap: CGFloat = 6
    /// Kept clear between the button and the edges of the area it floats in.
    static let margin: CGFloat = 8

    let button: ThemedButton
    /// The text whose selection the button replies to, while it shows.
    private(set) weak var textView: ChatTextView?

    override init() {
        button = ThemedButton(title: String(localized: "Reply"), style: .secondary, target: nil, action: nil)
        super.init()
        button.target = self
        button.action = #selector(reply)
        button.isCapsule = true
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.image = Theme.symbol("arrowshape.turn.up.left", size: 11, weight: .semibold)
        button.imagePosition = .imageLeading
        // A click must leave the keyboard with the text: taking it would clear the selection being replied to.
        button.refusesFirstResponder = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        button.shadow = shadow
        button.setAccessibilityHelp(String(localized: "Quotes the selected text in your next message"))
        button.translatesAutoresizingMaskIntoConstraints = true
        button.isHidden = true
        refreshToolTip()
    }

    var isShown: Bool { !button.isHidden }

    /// Names the shortcut that does the same, which the user may have changed.
    func refreshToolTip() {
        let help = String(localized: "Quotes the selected text in your next message")
        let keys = KeyBindingsController.shared.displayString(for: .addToComposer)
        button.toolTip = keys.map { String(localized: "\(help) (\($0))") } ?? help
    }

    /// Shows the button by `textView`'s selection, inside `area` of the button's superview, or hides it when that
    /// text has nothing to reply to. Another text's selection going away leaves the button where it is.
    func update(for textView: ChatTextView, within area: NSRect) {
        guard let container = button.superview, textView.window === container.window, !textView.isDraggingSelection,
            textView.canAddSelectionToComposer, let end = textView.selectionEndRect
        else {
            if textView === self.textView { hide() }
            return
        }
        let anchor = container.convert(end, from: textView)
        guard area.intersects(anchor) else {
            hide()
            return
        }
        self.textView = textView
        refreshToolTip()
        button.frame = Self.frame(size: button.intrinsicContentSize, below: anchor, within: area, flipped: container.isFlipped)
        button.isHidden = false
    }

    func hide() {
        textView = nil
        button.isHidden = true
    }

    /// Where the button goes: under `anchor` (the selection's last line), centered on where it ends, or over it when
    /// the area has no room below; always inside the area.
    static func frame(size: NSSize, below anchor: NSRect, within area: NSRect, flipped: Bool) -> NSRect {
        let inner = area.insetBy(dx: margin, dy: margin)
        var x = anchor.maxX - size.width / 2
        x = min(max(x, inner.minX), inner.maxX - size.width)
        // In unflipped coordinates "below" is toward smaller y.
        let downward = flipped ? anchor.maxY + gap : anchor.minY - gap - size.height
        let upward = flipped ? anchor.minY - gap - size.height : anchor.maxY + gap
        let fitsBelow = flipped ? downward + size.height <= inner.maxY : downward >= inner.minY
        var y = fitsBelow ? downward : upward
        y = min(max(y, inner.minY), inner.maxY - size.height)
        return NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    @objc private func reply() {
        guard let textView, textView.canAddSelectionToComposer else { return hide() }
        textView.addSelectionToComposer()
        hide()
    }
}
