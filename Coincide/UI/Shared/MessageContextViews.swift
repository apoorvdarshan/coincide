import AppKit
import CoincideKit

// MARK: - Sources

/// A view whose selection Edit › Add Selection to Composer (⌘L, as in Cursor) attaches to the message while it has
/// focus: an agent's reply, a terminal or the diff.
@MainActor
protocol ComposerSelectionSource: AnyObject {
    /// The menu item's title for this view's selection, such as "Quote in Composer".
    var addToComposerTitle: String { get }
    var canAddSelectionToComposer: Bool { get }
    func addSelectionToComposer()
}

// MARK: - Presentation

/// How context attached to a message reads on its cards, in the composer and on the sent message.
extension MessageContext {
    var symbolName: String {
        switch content {
        case .quote: "text.quote"
        case .terminal: "apple.terminal"
        case .diffComment: "text.bubble"
        case .file(let file): URL(fileURLWithPath: file.path).pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text"
        }
    }

    /// What the card is called: whose reply, which terminal and lines, which file and lines, or the file's name.
    var title: String {
        switch content {
        case .quote(let quote):
            quote.provider.map { String(localized: "Quote from \($0.displayName)") } ?? String(localized: "Quote")
        case .terminal(let excerpt):
            if let start = excerpt.lineStart, let end = excerpt.lineEnd {
                start == end
                    ? String(localized: "\(excerpt.terminal), line \(start)")
                    : String(localized: "\(excerpt.terminal), lines \(start)–\(end)")
            } else {
                excerpt.terminal
            }
        case .diffComment(let comment):
            comment.isBeforeChange
                ? String(localized: "\(Self.fileName(comment.path)) \(comment.rangeLabel) (before)")
                : "\(Self.fileName(comment.path)) \(comment.rangeLabel)"
        case .file(let file): file.name
        }
    }

    /// A line of what it holds, under the title.
    var preview: String {
        switch content {
        case .quote(let quote): Self.firstLine(quote.text)
        case .terminal(let excerpt): Self.firstLine(excerpt.text)
        case .diffComment(let comment):
            comment.comment.isEmpty ? String(localized: "No comment") : Self.firstLine(comment.comment)
        case .file(let file):
            (URL(fileURLWithPath: file.path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Code and terminal output read in the monospaced font.
    var previewIsCode: Bool {
        if case .terminal = content { return true }
        return false
    }

    var accessibilityDescription: String {
        let kind =
            switch content {
            case .quote: String(localized: "Quote")
            case .terminal: String(localized: "Terminal output")
            case .diffComment: String(localized: "Comment on the diff")
            case .file: String(localized: "File")
            }
        return String(localized: "\(kind): \(title), \(preview)")
    }

    /// The text the details show: the whole quote, output or comment and code. Nil for files, which Quick Look shows.
    var detailText: String? {
        switch content {
        case .quote(let quote): quote.text
        case .terminal(let excerpt): excerpt.text
        case .diffComment(let comment): comment.diff
        case .file: nil
        }
    }

    private static func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

// MARK: - Details

/// The whole of a quote, terminal excerpt or diff comment, in a themed popup over its card.
enum MessageContextDetails {
    private static let width: CGFloat = 440
    private static let maxTextHeight: CGFloat = 300

    /// Opens the context's details beside `anchor`: a popup for text, Quick Look for a file.
    static func show(_ context: MessageContext, from anchor: NSView, previewFile: (URL) -> Void) {
        if let path = context.filePath {
            previewFile(URL(fileURLWithPath: path))
            return
        }
        ThemedPopup.show(ThemedPopupViewHost(view(for: context)), from: anchor)
    }

    static func view(for context: MessageContext) -> NSView {
        let icon = NSImageView(image: Theme.symbol(context.symbolName, size: 12, weight: .medium) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let title = NSTextField(labelWithString: context.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icon, title])
        header.orientation = .horizontal
        header.spacing = 6
        var rows: [NSView] = [header]

        var subtitle: String?
        switch context.content {
        case .terminal(let excerpt):
            subtitle = excerpt.directory.map { ($0 as NSString).abbreviatingWithTildeInPath }
        case .diffComment(let comment):
            subtitle = comment.path
            if !comment.comment.isEmpty {
                let note = NSTextField(wrappingLabelWithString: comment.comment)
                note.font = .systemFont(ofSize: 12)
                note.textColor = Theme.ink
                note.isSelectable = true
                rows.append(note)
            }
        case .quote, .file:
            break
        }
        if let subtitle {
            let label = NSTextField(labelWithString: subtitle)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.insert(label, at: 1)
        }
        if let text = context.detailText, !text.isEmpty {
            rows.append(textArea(text, code: context.previewIsCode || context.isDiffComment))
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(context.accessibilityDescription)
        return stack
    }

    /// Selectable text on the theme's code fill, scrolling once it is taller than the popup allows.
    private static func textArea(_ text: String, code: Bool) -> NSView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = code ? Theme.smallMonoFont : .systemFont(ofSize: 12)
        textView.textColor = Theme.ink
        textView.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.setAccessibilityLabel(String(localized: "Attached text"))

        let contentWidth = width - 28
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 10)
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            container.containerSize = NSSize(width: contentWidth - 16, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
        }
        let textHeight = ceil((textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 16) + 16)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Theme.smallCornerRadius
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.backgroundColor = Theme.codeBackground.cgColor
        scroll.heightAnchor.constraint(equalToConstant: min(textHeight, maxTextHeight)).isActive = true
        return scroll
    }
}

extension MessageContext {
    var isDiffComment: Bool {
        if case .diffComment = content { return true }
        return false
    }
}

// MARK: - Pill

/// A compact, clickable pill naming context on a sent message: its icon in the accent color and its title.
final class MessageContextPill: NSView {
    static let height: CGFloat = 24
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let iconSize: CGFloat = 11
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 5

    private(set) var context: MessageContext?
    var onOpen: ((MessageContext, NSView) -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        icon.contentTintColor = Theme.accent
        label.font = Self.font
        label.textColor = Theme.ink
        label.lineBreakMode = .byTruncatingMiddle
        for view in [icon, label] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ context: MessageContext) {
        self.context = context
        icon.image = Theme.symbol(context.symbolName, size: Self.iconSize, weight: .medium)
        label.stringValue = context.title
        toolTip = context.detailText.map { MessageContext.clamp($0, to: 600) } ?? context.filePath
        setAccessibilityLabel(context.accessibilityDescription)
        needsLayout = true
    }

    /// The pill's width for `context`, at most `maxWidth`.
    static func width(for context: MessageContext, maxWidth: CGFloat) -> CGFloat {
        let text = (context.title as NSString).size(withAttributes: [.font: font]).width
        // NSTextField includes cell padding in addition to the measured glyphs.
        return min(maxWidth, ceil(padding * 2 + iconSize + gap + text) + 10)
    }

    override func layout() {
        super.layout()
        let iconY = ((bounds.height - Self.iconSize) / 2).rounded()
        icon.frame = NSRect(x: Self.padding, y: iconY, width: Self.iconSize + 1, height: Self.iconSize)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        let x = icon.frame.maxX + Self.gap - 1
        label.frame = NSRect(
            x: x, y: ((bounds.height - labelHeight) / 2).rounded(), width: max(0, bounds.width - x - Self.padding),
            height: labelHeight)
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isHovered ? Theme.sidebarHover : Theme.cardBackground).cgColor
        layer?.borderColor = Theme.surfaceBorder.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard let context, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(context, self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let context else { return false }
        onOpen?(context, self)
        return true
    }
}
