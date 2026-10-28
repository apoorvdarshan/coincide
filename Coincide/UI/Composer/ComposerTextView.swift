import AppKit

/// The composer's plain-text editor: draws a placeholder, takes pasted and dropped images and files,
/// tints `@` mentions, and reports how tall its text is so the composer can grow with it.
final class ComposerTextView: NSTextView {
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            if string.isEmpty { needsDisplay = true }
        }
    }
    /// Images pasted or dropped onto the text.
    var onImages: (([ComposerImageSource]) -> Void)?
    /// Other files pasted or dropped onto the text; the composer mentions them by path.
    var onFiles: (([URL]) -> Void)?
    /// Keys the composer handles before the text system does. Returns true when handled.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Whether files or images are being dragged over the text.
    var onDragHover: ((Bool) -> Void)?

    private static let mentionPattern = try? NSRegularExpression(pattern: "(?<![\\w@])@(?:\"[^\"\\n]+\"|[^\\s@\"]+)")
    /// Mentions are only tinted below this length, so pasting a huge log stays fast.
    private static let highlightLimit = 20_000

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = true
        textContainerInset = NSSize(width: 0, height: 3)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        updateDragTypeRegistration()
    }

    /// Replaces the whole text without registering an undo step, for loading drafts.
    func setText(_ text: String) {
        string = text
        needsDisplay = true
        highlightMentions()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    /// ⌘F, ⌘G and ⌘E search the conversation above, not the message being written.
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

    /// Whether the caret sits on the first or last visual line, where Up or Down would leave the text.
    func caretIsOnEdgeLine(top: Bool) -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let length = (string as NSString).length
        guard length > 0 else { return true }
        let caret = firstRect(forCharacterRange: selection, actualRange: nil)
        let edge = firstRect(forCharacterRange: NSRange(location: top ? 0 : length, length: 0), actualRange: nil)
        return abs(caret.midY - edge.midY) < 1
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rect = bounds.insetBy(dx: textContainerInset.width + padding, dy: textContainerInset.height)
        (placeholder as NSString).draw(
            with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        highlightMentions()
    }

    /// Height of the laid-out text, at least `minimumLines` tall, measuring no further than `limit`.
    func contentHeight(upTo limit: CGFloat, minimumLines: Int) -> CGFloat {
        var height: CGFloat = 0
        if let layoutManager = textLayoutManager {
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
            ) { fragment in
                height = fragment.layoutFragmentFrame.maxY
                return height < limit
            }
        }
        let lineHeight = font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
        return ceil(max(height, lineHeight * CGFloat(minimumLines)) + textContainerInset.height * 2)
    }

    private func highlightMentions() {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: layoutManager.documentRange)
        let length = (string as NSString).length
        guard length > 0, length < Self.highlightLimit, let pattern = Self.mentionPattern else { return }
        for match in pattern.matches(in: string, range: NSRange(location: 0, length: length)) {
            guard let start = content.location(content.documentRange.location, offsetBy: match.range.location),
                let end = content.location(start, offsetBy: match.range.length),
                let range = NSTextRange(location: start, end: end)
            else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: Theme.mention, for: range)
        }
    }

    // MARK: Paste and drop

    // Text types stay first, so text that carries a picture (copied from a web page) pastes as text.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL] + ComposerAttachmentImporter.pasteboardTypes
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL] + ComposerAttachmentImporter.pasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if takeAttachments(from: pboard) || super.readSelection(from: pboard, type: type) { return true }
        return type != .string && pboard.availableType(from: [.string]) != nil
            && super.readSelection(from: pboard, type: .string)
    }

    /// Hands files and images on the pasteboard to the composer. Returns false when it holds text instead.
    func takeAttachments(from pboard: NSPasteboard) -> Bool {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            let images = urls.filter(ComposerAttachmentImporter.isImage)
            let files = urls.filter { !ComposerAttachmentImporter.isImage($0) }
            if !images.isEmpty { onImages?(images.map { .file($0) }) }
            if !files.isEmpty { onFiles?(files) }
            return true
        }
        // Copied rich text can carry a picture too; that should paste as text.
        if let text = pboard.string(forType: .string), text.contains(where: \.isWhitespace) { return false }
        for type in ComposerAttachmentImporter.pasteboardTypes {
            if let data = pboard.data(forType: type) {
                onImages?([.data(data)])
                return true
            }
        }
        return false
    }

    static func carriesAttachments(_ pboard: NSPasteboard) -> Bool {
        pboard.availableType(from: [.fileURL] + ComposerAttachmentImporter.pasteboardTypes) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        let carries = Self.carriesAttachments(sender.draggingPasteboard)
        onDragHover?(carries)
        return carries ? .copy : operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return Self.carriesAttachments(sender.draggingPasteboard) ? .copy : operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragHover?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragHover?(false)
    }
}
