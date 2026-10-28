import AppKit

extension NSAttributedString.Key {
    /// Marks inline code, drawn with a rounded background by `ChatLayoutManager`.
    nonisolated static let chatInlineCode = NSAttributedString.Key("coincide.chat.inlineCode")
    /// An `NSColor` filled across the whole line, used for diff lines.
    nonisolated static let chatLineBackground = NSAttributedString.Key("coincide.chat.lineBackground")
}

/// The rounded panel behind a fenced code block. Its header shows the language; the copy button
/// is a real button the cell places over the header.
nonisolated final class ChatCodeTextBlock: NSTextBlock {
    static let headerHeight: CGFloat = 26
    static let horizontalPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 10

    var label = ""
    var labelFontSize: CGFloat = 11

    override init() {
        super.init()
        setValue(100, type: .percentageValueType, for: .width)
        setWidth(Self.headerHeight, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(Self.bottomPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
        setWidth(Self.horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(Self.horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let block = copy as? ChatCodeTextBlock {
            block.label = label
            block.labelFontSize = labelFontSize
        }
        return copy
    }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let bounds = boundsRect(withFrame: frameRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        guard !label.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: labelFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.minX + Self.horizontalPadding, y: bounds.minY + (Self.headerHeight - size.height) / 2)
        (label as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// The block's frame without its margins.
    func boundsRect(withFrame frameRect: NSRect) -> NSRect {
        let top = width(for: .margin, edge: .minY)
        let bottom = width(for: .margin, edge: .maxY)
        let left = width(for: .margin, edge: .minX)
        let right = width(for: .margin, edge: .maxX)
        return NSRect(
            x: frameRect.minX + left, y: frameRect.minY + top, width: frameRect.width - left - right,
            height: frameRect.height - top - bottom)
    }
}

/// A block quote: a rounded bar at the leading edge.
nonisolated final class ChatQuoteTextBlock: NSTextBlock {
    static let barWidth: CGFloat = 2

    override init() {
        super.init()
        setValue(100, type: .percentageValueType, for: .width)
        setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let top = width(for: .margin, edge: .minY)
        let bottom = width(for: .margin, edge: .maxY)
        let left = width(for: .margin, edge: .minX)
        let bar = NSRect(x: frameRect.minX + left, y: frameRect.minY + top, width: Self.barWidth, height: frameRect.height - top - bottom)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }
}

/// A horizontal rule, drawn as a hairline through the middle of an empty paragraph.
nonisolated final class ChatRuleTextBlock: NSTextBlock {
    override init() {
        super.init()
        setValue(100, type: .percentageValueType, for: .width)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let top = width(for: .margin, edge: .minY)
        let bottom = width(for: .margin, edge: .maxY)
        let left = width(for: .margin, edge: .minX)
        let content = NSRect(x: frameRect.minX + left, y: frameRect.minY + top, width: frameRect.width - left, height: frameRect.height - top - bottom)
        NSColor.separatorColor.setFill()
        NSRect(x: content.minX, y: (content.midY).rounded(.down), width: content.width, height: 1).fill()
    }
}

/// Draws rounded inline-code backgrounds and full-width line backgrounds.
nonisolated final class ChatLayoutManager: NSLayoutManager {
    /// Selections in the theme's colors, blended over code panels and bubbles rather than painted over them.
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor
    ) {
        let selection: NSColor? =
            switch color {
            case Theme.textSelection, .selectedTextBackgroundColor: Theme.textSelection
            case .unemphasizedSelectedTextBackgroundColor: Theme.inactiveTextSelection
            default: nil
            }
        guard let selection else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        selection.setFill()
        for index in 0..<rectCount { rectArray[index].fill(using: .sourceOver) }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.chatLineBackground, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            color.setFill()
            // Inside a code panel the fill reaches the panel's edges; elsewhere it spans the line.
            let block = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.last as? ChatCodeTextBlock
            let inset = block == nil ? 0 : ChatCodeTextBlock.horizontalPadding
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                let minX = block == nil ? 0 : rect.minX - inset
                let width = block == nil ? container.size.width : rect.width + inset * 2
                NSRect(x: minX + origin.x, y: rect.minY + origin.y, width: width, height: rect.height).fill()
            }
        }

        storage.enumerateAttribute(.chatInlineCode, in: characters) { value, range, _ in
            guard value != nil else { return }
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                // The renderer kerns 3pt around each span; the box grows into that room.
                let glyphBox = rect.offsetBy(dx: origin.x, dy: origin.y)
                let box = NSRect(x: glyphBox.minX - 3, y: glyphBox.minY + 0.5, width: glyphBox.width + 3, height: glyphBox.height - 1)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

/// Read-only, selectable rich text for the transcript. Uses TextKit 1 so that text blocks
/// (code panels, quotes, tables) lay out exactly as `ChatTextMeasurer` measured them.
final class ChatTextView: NSTextView {
    /// Called for link clicks; return true when handled.
    var onOpenLink: ((Any) -> Bool)?

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = ChatLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        allowsUndo = false
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        focusRingType = .none
        setAccessibilityRole(.staticText)
    }

    /// The blocks the text view shows, when its text came from rendered Markdown.
    private var pieces: [ChatRenderedText.Piece] = []
    /// Find matches to highlight, and the current one.
    private var findRanges: [NSRange] = []
    private var currentFindRange: NSRange?
    /// Where highlights were last drawn, to clear just those.
    private var drawnFindRanges: [NSRange] = []

    /// Replaces the text, keeping the selection when it still fits (streamed text only grows).
    func setText(_ text: NSAttributedString) {
        pieces = []
        guard let storage = textStorage, !storage.isEqual(to: text) else { return }
        let selection = selectedRanges
        storage.setAttributedString(text)
        let length = storage.length
        let kept = selection.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= length }
        if !kept.isEmpty { selectedRanges = kept.map { NSValue(range: $0) } }
        drawFindHighlights()
    }

    /// Shows rendered Markdown, replacing only the blocks that changed since the last call: streamed
    /// replies lay out just their tail, and a selection in the unchanged part stays put.
    func setText(_ rendered: ChatRenderedText) {
        guard let storage = textStorage else { return }
        guard !rendered.pieces.isEmpty, !pieces.isEmpty else {
            setText(rendered.string)
            pieces = rendered.pieces
            return
        }
        guard rendered.pieces != pieces else { return }
        ChatIncrementalText.apply(rendered, to: storage, replacing: pieces)
        pieces = rendered.pieces
        drawFindHighlights()
    }

    // MARK: Find

    /// Highlights the find bar's matches in this text, the current one more strongly. They are drawn as
    /// temporary attributes, so neither the text nor its layout changes.
    func setFindHighlights(_ ranges: [NSRange], current: NSRange?) {
        guard ranges != findRanges || current != currentFindRange else { return }
        let hadHighlights = !findRanges.isEmpty || currentFindRange != nil
        findRanges = ranges
        currentFindRange = current
        if hadHighlights || !ranges.isEmpty || current != nil { drawFindHighlights() }
    }

    private func drawFindHighlights() {
        guard let layoutManager, let storage = textStorage else { return }
        let length = storage.length
        for range in drawnFindRanges {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clipped.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clipped)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clipped)
        }
        drawnFindRanges = []
        for range in findRanges where NSMaxRange(range) <= length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: TranscriptFindStyle.match, forCharacterRange: range)
            drawnFindRanges.append(range)
        }
        if let current = currentFindRange, NSMaxRange(current) <= length {
            layoutManager.addTemporaryAttributes(
                [.backgroundColor: TranscriptFindStyle.current, .foregroundColor: TranscriptFindStyle.currentText],
                forCharacterRange: current)
            drawnFindRanges.append(current)
        }
    }

    /// Where `range` is drawn, in the text view's coordinates.
    func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let container = textContainer, let storage = textStorage, NSMaxRange(range) <= storage.length
        else { return nil }
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Find commands go to the chat's find bar, which searches the whole conversation rather than this text.
    override func performTextFinderAction(_ sender: Any?) {
        passTextFinderActionOn(sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performTextFinderAction(_:)) { return validatePassedOnTextFinderAction(menuItem) }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) { return validatePassedOnTextFinderAction(item) }
        return super.validateUserInterfaceItem(item)
    }

    /// Links go only to `onOpenLink`. NSTextView's own handling would give any URL to the system, which
    /// launches apps and runs scripts that agent-written links can point at.
    override func clicked(onLink link: Any, at charIndex: Int) {
        _ = onOpenLink?(link)
    }

    /// The transcript scrolls; the text itself never does.
    override func scrollRangeToVisible(_ range: NSRange) {}

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }
}

/// Measures attributed text the same way `ChatTextView` lays it out.
@MainActor
final class ChatTextMeasurer {
    static let shared = ChatTextMeasurer()

    private let storage = NSTextStorage()
    private let layoutManager = ChatLayoutManager()
    private let container = NSTextContainer()

    private init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    func size(of text: NSAttributedString, width: CGFloat) -> NSSize {
        guard text.length > 0, width > 0 else { return .zero }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        size(of: text, width: width).height
    }

    /// Where `range` of `text` lies when laid out at `width`, as a `ChatTextView` would draw it.
    func rect(of range: NSRange, in text: NSAttributedString, width: CGFloat) -> NSRect? {
        guard width > 0, NSMaxRange(range) <= text.length else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    }
}

/// Measures one text that keeps changing, such as a streaming reply. It keeps its own layout and
/// lays out again only from the first block that changed.
@MainActor
final class ChatLiveMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = ChatLayoutManager()
    private let container = NSTextContainer()
    private var pieces: [ChatRenderedText.Piece] = []

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    func size(of rendered: ChatRenderedText, width: CGFloat) -> NSSize {
        guard rendered.string.length > 0, width > 0 else { return .zero }
        if container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        if pieces.isEmpty || rendered.pieces.isEmpty {
            storage.setAttributedString(rendered.string)
        } else if rendered.pieces != pieces {
            ChatIncrementalText.apply(rendered, to: storage, replacing: pieces)
        }
        pieces = rendered.pieces
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }
}

@MainActor
enum ChatIncrementalText {
    /// Turns `storage`, which holds the text rendered as `previous`, into `rendered` by replacing
    /// everything from the first block that differs.
    static func apply(_ rendered: ChatRenderedText, to storage: NSTextStorage, replacing previous: [ChatRenderedText.Piece]) {
        var common = 0
        while common < previous.count, common < rendered.pieces.count, previous[common] == rendered.pieces[common] { common += 1 }
        // The last block of the previous text has no trailing newline, so it is always replaced.
        common = min(common, previous.count - 1)
        let start = previous.prefix(common).reduce(0) { $0 + $1.length }
        guard common > 0, start <= storage.length, start <= rendered.string.length else {
            storage.setAttributedString(rendered.string)
            return
        }
        let tail = rendered.string.attributedSubstring(from: NSRange(location: start, length: rendered.string.length - start))
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        storage.endEditing()
    }
}
