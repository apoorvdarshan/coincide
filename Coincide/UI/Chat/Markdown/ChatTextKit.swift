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
final class ChatTextView: NSTextView, ComposerSelectionSource {
    /// Called for link clicks; return true when handled. Web links arrive as a `WebLinkRequest` saying where to open
    /// them (`LinkRouting`); any other link arrives as it is in the text.
    var onOpenLink: ((Any) -> Bool)?
    /// Whether a plain click opens web links in the default browser rather than Coincide's; the setting by default.
    var opensLinksInDefaultBrowser: () -> Bool = { LinkRouting.opensInDefaultBrowser }
    /// Where Copy Link writes.
    var linkPasteboard: NSPasteboard = .general
    /// Set on text the user can reply to (agents' replies and plans, the user's messages): "Reply" attaches the
    /// selected text to the message as a quote.
    var onQuote: ((String) -> Void)?

    /// Posted with the text view whenever the user changes its selection, also while a drag still extends it
    /// (`isDraggingSelection`), and when new text loses it. The chat places its Reply button by it.
    static let selectionDidChange = Notification.Name("ChatTextView.selectionDidChange")
    /// True while the mouse is still dragging out the selection.
    private(set) var isDraggingSelection = false

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
        replacingText {
            storage.setAttributedString(text)
            let length = storage.length
            let kept = selection.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= length }
            if !kept.isEmpty { selectedRanges = kept.map { NSValue(range: $0) } }
        }
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
        replacingText { ChatIncrementalText.apply(rendered, to: storage, replacing: pieces) }
        pieces = rendered.pieces
        drawFindHighlights()
    }

    /// Set while new text goes in: the selection it keeps is not a new one of the user's.
    private var isReplacingText = false

    /// Makes a change to the text that reports no selection change, unless the selection is lost.
    private func replacingText(_ change: () -> Void) {
        let hadSelection = canAddSelectionToComposer
        let wasReplacing = isReplacingText
        isReplacingText = true
        change()
        isReplacingText = wasReplacing
        if hadSelection, !wasReplacing, !canAddSelectionToComposer {
            NotificationCenter.default.post(name: Self.selectionDidChange, object: self)
        }
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
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        openLink(link, commandKey: flags.contains(.command), optionKey: flags.contains(.option))
    }

    /// Opens a clicked link: a web link where the click asks (`LinkRouting`), anything else as before.
    func openLink(_ link: Any, commandKey: Bool, optionKey: Bool = false) {
        let request = LinkRouting.request(
            for: link, commandKey: commandKey, optionKey: optionKey, opensInDefaultBrowser: opensLinksInDefaultBrowser())
        _ = onOpenLink?(request ?? link)
    }

    /// The link at a point in the view's coordinates, when the point is over its text.
    func link(at point: NSPoint) -> Any? {
        guard let layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: location, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs,
            layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(location)
        else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.link, at: index, effectiveRange: nil)
    }

    /// The menu for a web link: open it in Coincide or the default browser, or copy it.
    func linkMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (destination, action) in [
            (LinkDestination.coincideBrowser, #selector(openLinkInCoincide(_:))),
            (.coincideBrowserNewTab, #selector(openLinkInNewTab(_:))), (.defaultBrowser, #selector(openLinkInDefaultBrowser(_:))),
        ] {
            let item = NSMenuItem(title: LinkRouting.menuTitle(destination), action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: String(localized: "Copy Link"), action: #selector(copyLink(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = url
        menu.addItem(copy)
        return menu
    }

    @objc private func openLinkInCoincide(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = onOpenLink?(WebLinkRequest(url: url, destination: .coincideBrowser))
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = onOpenLink?(WebLinkRequest(url: url, destination: .coincideBrowserNewTab))
    }

    @objc private func openLinkInDefaultBrowser(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = onOpenLink?(WebLinkRequest(url: url, destination: .defaultBrowser))
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        linkPasteboard.clearContents()
        linkPasteboard.setString(url.absoluteString, forType: .string)
    }

    /// The transcript scrolls; the text itself never does.
    override func scrollRangeToVisible(_ range: NSRange) {}

    /// How deep in `setFrameSize` the view is: AppKit can size it again while it takes a size.
    private var resizeDepth = 0

    /// A text view that takes a new size scrolls whatever encloses it to keep its selection in view. In the transcript
    /// that moved the reader whenever a row laid out again (a setting that lays every row out anew, a narrower panel),
    /// so a resize never scrolls; dragging out a selection past the edge still does.
    override func setFrameSize(_ newSize: NSSize) {
        resizeDepth += 1
        defer { resizeDepth -= 1 }
        super.setFrameSize(newSize)
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        resizeDepth > 0 ? false : super.scrollToVisible(rect)
    }

    // MARK: Context menu and quoting

    /// The selected text as it reads, its ranges joined by line breaks.
    var selectedPlainText: String {
        let text = string as NSString
        return selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= text.length }
            .map { text.substring(with: $0) }.joined(separator: "\n")
    }

    /// Where the selection ends: the box of its last character that is not whitespace, in the text view's coordinates.
    var selectionEndRect: NSRect? {
        let text = string as NSString
        guard let last = selectedRanges.map(\.rangeValue).filter({ $0.length > 0 && NSMaxRange($0) <= text.length })
            .max(by: { NSMaxRange($0) < NSMaxRange($1) })
        else { return nil }
        var index = NSMaxRange(last) - 1
        let blank = CharacterSet.whitespacesAndNewlines
        while index > last.location, let scalar = UnicodeScalar(text.character(at: index)), blank.contains(scalar) { index -= 1 }
        return rect(for: text.rangeOfComposedCharacterSequence(at: index))
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        isDraggingSelection = stillSelecting
        guard onQuote != nil, !isReplacingText else { return }
        NotificationCenter.default.post(name: Self.selectionDidChange, object: self)
    }

    /// The themed text menu over a selection: Copy and, where the text can be replied to, Reply. Anywhere else the
    /// row's menu shows, as it does around the text.
    override func menu(for event: NSEvent) -> NSMenu? {
        // One click opens one menu, however many ways AppKit asks for it.
        guard event.timestamp != lastMenuEventTime else { return nil }
        lastMenuEventTime = event.timestamp
        if onOpenLink != nil, let link = link(at: convert(event.locationInWindow, from: nil)), let url = LinkRouting.webURL(link) {
            return ThemedContextMenu.show(linkMenu(for: url), for: event, in: window)
        }
        guard let menu = selectionMenu() else { return enclosingTable?.menu(for: event) }
        return ThemedContextMenu.show(menu, for: event, in: window)
    }

    /// When the last context menu was asked for.
    private var lastMenuEventTime: TimeInterval?

    private var enclosingTable: NSTableView? {
        var view = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        return view as? NSTableView
    }

    /// Copy and Reply for the selected text; nil when nothing but whitespace is selected.
    func selectionMenu() -> NSMenu? {
        guard selectedPlainText.contains(where: { !$0.isWhitespace }) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        if onQuote != nil {
            let quote = NSMenuItem(title: addToComposerTitle, action: #selector(quoteSelection), keyEquivalent: "")
            quote.target = self
            menu.addItem(quote)
        }
        return menu
    }

    /// Opens the menu here and nowhere else. `menu(for:)` always returns nil, the themed popup having opened in place
    /// of the system menu, and NSView passes a click whose menu is nil up the responder chain: the transcript table
    /// then opened its row menu (Copy, Fork from Here) over the selection's, so Reply could never be reached.
    override func rightMouseDown(with event: NSEvent) {
        // Outside the transcript, with nothing selected and no web link under the pointer, the click goes on as before.
        guard selectionMenu() != nil || enclosingTable != nil || webLink(under: event) != nil else {
            return super.rightMouseDown(with: event)
        }
        _ = menu(for: event)
    }

    /// A Control-click opens the same menu rather than starting a new selection over the one it is meant for. A
    /// ⌘-click on a web link opens it, as NSTextView would otherwise add to the selection instead.
    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, let link = webLink(under: event) {
            return openLink(link, commandKey: true)
        }
        guard modifiers == .control else { return super.mouseDown(with: event) }
        rightMouseDown(with: event)
    }

    /// The web link under the pointer, for views whose links are handled.
    private func webLink(under event: NSEvent) -> URL? {
        guard onOpenLink != nil, let link = link(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return LinkRouting.webURL(link)
    }

    @objc private func quoteSelection() {
        let text = selectedPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onQuote?(text)
    }

    var addToComposerTitle: String { String(localized: "Reply") }

    var canAddSelectionToComposer: Bool {
        onQuote != nil && selectedPlainText.contains { !$0.isWhitespace }
    }

    func addSelectionToComposer() {
        quoteSelection()
    }

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
