import AppKit

/// The grip over the divider between the chat and the inspector. The split view's own divider is half a point wide and
/// leaves the width to the layout; this strip gives it a hit area a few points to either side, the column-resize cursor,
/// a line in the theme's accent while the pointer is on it or dragging, and a double-click that restores the default
/// width. It reports where the divider should go; `MainSplitViewController` turns that into the panel's share.
final class InspectorDividerHandle: NSView {
    /// The strip's width, centred on the divider.
    static let hitWidth: CGFloat = 10

    /// The divider's wanted position, in the superview's coordinates, while the user drags.
    var onDrag: ((CGFloat) -> Void)?
    /// The drag ended after moving the divider.
    var onDragEnded: (() -> Void)?
    /// A double-click: back to the default width.
    var onReset: (() -> Void)?

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private(set) var isDragging = false {
        didSet { if isDragging != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = String(localized: "Drag to resize the panel. Double-click to restore its default width.")
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "Panel Divider"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onReset?()
            return
        }
        guard let window, let superview else { return }
        // Keep the grab point under the pointer rather than snapping the divider to it.
        let grab = superview.convert(event.locationInWindow, from: nil).x - frame.midX
        var moved = false
        isDragging = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            moved = true
            NSCursor.columnResize.set()
            onDrag?(superview.convert(next.locationInWindow, from: nil).x - grab)
        }
        isDragging = false
        isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if moved { onDragEnded?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isDragging else { return }
        Theme.accent.withAlphaComponent(isDragging ? 0.9 : 0.6).setFill()
        NSRect(x: bounds.midX - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
    }
}
