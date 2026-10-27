import AppKit

struct ChatMarkdownStyle: Hashable {
    var fontSize: CGFloat
    var textColor: NSColor = .labelColor
    /// User messages keep their line breaks; Markdown otherwise joins soft-wrapped lines.
    var preservesLineBreaks = false
    /// Plans dim the tasks that are done.
    var dimsCompletedTasks = false
}

/// A rendered code block, so its cell can place a copy button over the block's header.
struct ChatCodeBlock {
    var range: NSRange
    var code: String
    var textBlock: ChatCodeTextBlock
}

struct ChatRenderedText {
    /// One top-level block of the text: what it renders and how long it is, newline included.
    struct Piece: Equatable {
        var key: Int
        var length: Int
    }

    var string: NSAttributedString
    var codeBlocks: [ChatCodeBlock]
    /// The text's top-level blocks in order, so views can replace only the blocks that changed.
    /// Empty for text that was not rendered from Markdown.
    var pieces: [Piece] = []

    static let empty = ChatRenderedText(string: NSAttributedString(), codeBlocks: [])
}

/// Top-level blocks rendered for one text, kept between renders while the text streams in, so
/// each update renders only the blocks that changed.
@MainActor
final class ChatRenderCache {
    fileprivate struct Entry {
        var block: ChatMarkdown.Block
        var spacing: CGFloat
        var string: NSAttributedString
        var codeBlocks: [ChatCodeBlock]
    }

    fileprivate var entries: [Int: Entry] = [:]
}

/// Turns Markdown into one attributed string for a `ChatTextView`: paragraphs and lists use
/// paragraph styles, code blocks, quotes and rules use text blocks, and tables use `NSTextTable`.
@MainActor
struct ChatMarkdownRenderer {
    private let style: ChatMarkdownStyle
    /// Whether text comes before this renderer's output, so its first block keeps its spacing.
    private let followsContent: Bool
    private let output = NSMutableAttributedString()
    private var codeBlocks: [ChatCodeBlock] = []

    private struct Context {
        var indent: CGFloat = 0
        var textBlocks: [NSTextBlock] = []
        var spacingBefore: CGFloat = 0
        var isTight = false
        var color: NSColor
    }

    static func render(_ markdown: String, style: ChatMarkdownStyle, cache: ChatRenderCache? = nil) -> ChatRenderedText {
        render(ChatMarkdown.parse(markdown), style: style, cache: cache)
    }

    /// Renders each top-level block on its own, reusing the cache's rendering of blocks that did not change.
    static func render(_ blocks: [ChatMarkdown.Block], style: ChatMarkdownStyle, cache: ChatRenderCache? = nil) -> ChatRenderedText {
        let output = NSMutableAttributedString()
        var codeBlocks: [ChatCodeBlock] = []
        var pieces: [ChatRenderedText.Piece] = []
        var used: [Int: ChatRenderCache.Entry] = [:]
        var previous: ChatMarkdown.Block?
        for block in blocks {
            let spacing = previous.map { Self.spacing(after: $0, isTight: false, style: style) } ?? 0
            var hasher = Hasher()
            hasher.combine(block)
            hasher.combine(spacing)
            let key = hasher.finalize()
            let entry: ChatRenderCache.Entry
            if let cached = cache?.entries[key], cached.spacing == spacing, cached.block == block {
                entry = cached
            } else {
                var renderer = ChatMarkdownRenderer(style: style, followsContent: previous != nil)
                renderer.block(block, Context(spacingBefore: spacing, color: style.textColor))
                entry = ChatRenderCache.Entry(block: block, spacing: spacing, string: renderer.output, codeBlocks: renderer.codeBlocks)
            }
            used[key] = entry
            let offset = output.length
            codeBlocks += entry.codeBlocks.map { code in
                var code = code
                code.range.location += offset
                return code
            }
            output.append(entry.string)
            pieces.append(ChatRenderedText.Piece(key: key, length: entry.string.length))
            previous = block
        }
        cache?.entries = used
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return ChatRenderedText(string: output, codeBlocks: codeBlocks, pieces: pieces)
    }

    private init(style: ChatMarkdownStyle, followsContent: Bool) {
        self.style = style
        self.followsContent = followsContent
    }

    private var hasContent: Bool { followsContent || output.length > 0 }

    // MARK: Metrics

    private var blockSpacing: CGFloat { (style.fontSize * 0.7).rounded() }
    private var itemSpacing: CGFloat { (style.fontSize * 0.3).rounded() }
    private var lineSpacing: CGFloat { (style.fontSize * 0.25).rounded() }

    /// Space between a block and the one before it; headings sit close to what follows them.
    private static func spacing(after previous: ChatMarkdown.Block, isTight: Bool, style: ChatMarkdownStyle) -> CGFloat {
        if case .heading = previous { return (style.fontSize * 0.4).rounded() }
        return (style.fontSize * (isTight ? 0.3 : 0.7)).rounded()
    }
    private var listGutter: CGFloat { (style.fontSize * 1.5).rounded() }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: (style.fontSize * 1.38).rounded()
        case 2: (style.fontSize * 1.23).rounded()
        case 3: (style.fontSize * 1.08).rounded()
        default: style.fontSize
        }
    }

    // MARK: Blocks

    private mutating func blocks(_ blocks: [ChatMarkdown.Block], _ context: Context) {
        var context = context
        var previous: ChatMarkdown.Block?
        for block in blocks {
            if let previous { context.spacingBefore = Self.spacing(after: previous, isTight: context.isTight, style: style) }
            self.block(block, context)
            previous = block
        }
    }

    private mutating func block(_ block: ChatMarkdown.Block, _ context: Context) {
        switch block {
        case .paragraph(let inlines):
            paragraph(inlines, context, font: ChatFonts.body(style.fontSize))
        case .heading(let level, let inlines):
            var heading = context
            if hasContent { heading.spacingBefore = max(context.spacingBefore, (style.fontSize * 1.1).rounded()) }
            let color = level >= 6 ? NSColor.secondaryLabelColor : context.color
            heading.color = color
            paragraph(inlines, heading, font: ChatFonts.body(headingSize(level), weight: .semibold))
        case .code(let language, let text):
            code(text, language: language, context)
        case .quote(let children):
            let quote = ChatQuoteTextBlock()
            quote.setWidth(context.spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
            quote.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            var inner = context
            inner.indent = 0
            inner.textBlocks.append(quote)
            inner.spacingBefore = 0
            inner.isTight = false
            inner.color = .secondaryLabelColor
            blocks(children, inner)
        case .list(let list):
            self.list(list, context)
        case .table(let table):
            self.table(table, context)
        case .rule:
            let rule = ChatRuleTextBlock()
            rule.setWidth(max(context.spacingBefore, blockSpacing), type: .absoluteValueType, for: .margin, edge: .minY)
            rule.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            rule.setValue(9, type: .absoluteValueType, for: .height)
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = context.textBlocks + [rule]
            paragraph.minimumLineHeight = 1
            paragraph.maximumLineHeight = 1
            output.append(NSAttributedString(string: "\u{00A0}\n", attributes: [.font: ChatFonts.body(1), .paragraphStyle: paragraph]))
        }
    }

    private func paragraphStyle(_ context: Context, firstLineIndent: CGFloat? = nil) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacingBefore = hasContent ? context.spacingBefore : 0
        paragraph.firstLineHeadIndent = firstLineIndent ?? context.indent
        paragraph.headIndent = context.indent
        paragraph.textBlocks = context.textBlocks
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    private mutating func paragraph(
        _ inlines: [ChatMarkdown.Inline], _ context: Context, font: NSFont, prefix: NSAttributedString? = nil,
        paragraph: NSParagraphStyle? = nil
    ) {
        let style = paragraph ?? paragraphStyle(context)
        let start = output.length
        if let prefix { output.append(prefix) }
        self.inlines(inlines, font: font, color: context.color, traits: [])
        output.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: start, length: output.length - start)
        output.addAttribute(.paragraphStyle, value: style, range: range)
        output.addAttribute(.font, value: font, range: NSRange(location: output.length - 1, length: 1))
    }

    private mutating func code(_ text: String, language: String?, _ context: Context) {
        let block = ChatCodeTextBlock()
        block.label = language ?? ""
        block.labelFontSize = max(9, style.fontSize - 2)
        block.setWidth(context.spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = context.textBlocks + [block]
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 1
        let font = ChatFonts.mono(style.fontSize - 1)
        let start = output.length
        let body = text.isEmpty ? " " : text
        output.append(
            NSAttributedString(
                string: body + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        let codeRange = NSRange(location: start, length: (body as NSString).length)
        ChatSyntaxHighlighter.highlight(output, range: codeRange, language: language)
        codeBlocks.append(ChatCodeBlock(range: codeRange, code: text, textBlock: block))
    }

    private mutating func list(_ list: ChatMarkdown.List, _ context: Context) {
        let font = ChatFonts.body(style.fontSize)
        let markerFont = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular)
        let lastNumber = list.start + max(0, list.items.count - 1)
        let widestMarker = list.isOrdered ? ("\(lastNumber)." as NSString).size(withAttributes: [.font: markerFont]).width : 0
        let gutter = max(listGutter, (widestMarker + style.fontSize * 0.5).rounded(.up))
        let depth = context.textBlocks.count + Int(context.indent / max(1, listGutter))
        var itemContext = context
        itemContext.isTight = list.isTight
        for (offset, item) in list.items.enumerated() {
            if offset > 0 { itemContext.spacingBefore = list.isTight ? itemSpacing : blockSpacing }
            let marker: NSAttributedString
            if let checked = item.task {
                marker = taskMarker(checked: checked, font: font)
            } else {
                let symbol = list.isOrdered ? "\(list.start + offset)." : ["•", "◦", "▪︎"][depth % 3]
                marker = NSAttributedString(
                    string: symbol, attributes: [.font: list.isOrdered ? markerFont : font, .foregroundColor: NSColor.secondaryLabelColor])
            }
            let prefix = NSMutableAttributedString(attributedString: marker)
            prefix.append(NSAttributedString(string: "\t", attributes: [.font: font]))

            var content = itemContext
            content.indent = context.indent + gutter
            if item.task == true, style.dimsCompletedTasks { content.color = .secondaryLabelColor }
            let blocks = item.blocks.isEmpty ? [ChatMarkdown.Block.paragraph([])] : item.blocks
            for (index, block) in blocks.enumerated() {
                if index == 0, case .paragraph(let inlines) = block {
                    let paragraph = paragraphStyle(content, firstLineIndent: context.indent)
                    paragraph.paragraphSpacingBefore = hasContent ? itemContext.spacingBefore : 0
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: context.indent + gutter)]
                    paragraph.defaultTabInterval = gutter
                    self.paragraph(inlines, content, font: font, prefix: prefix, paragraph: paragraph)
                } else {
                    if index == 0 {
                        // An item that starts with a block other than a paragraph still gets its marker.
                        let paragraph = paragraphStyle(content, firstLineIndent: context.indent)
                        paragraph.paragraphSpacingBefore = hasContent ? itemContext.spacingBefore : 0
                        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: context.indent + gutter)]
                        self.paragraph([], content, font: font, prefix: prefix, paragraph: paragraph)
                    }
                    var nested = content
                    nested.spacingBefore = list.isTight ? itemSpacing : blockSpacing
                    self.block(block, nested)
                }
            }
        }
    }

    private func taskMarker(checked: Bool, font: NSFont) -> NSAttributedString {
        let name = checked ? "checkmark.square.fill" : "square"
        let color: NSColor = checked ? .controlAccentColor : .tertiaryLabelColor
        let size = (font.pointSize * 1.05).rounded()
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: checked ? [.white, color] : [color]))
        let description = checked ? String(localized: "Done") : String(localized: "Not done")
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(configuration)
        else {
            return NSAttributedString(string: checked ? "☑" : "☐", attributes: [.font: font])
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let imageSize = image.size
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
        let marker = NSMutableAttributedString(attachment: attachment)
        marker.addAttribute(.font, value: font, range: NSRange(location: 0, length: marker.length))
        return marker
    }

    private mutating func table(_ table: ChatMarkdown.Table, _ context: Context) {
        let columns = table.alignments.count
        guard columns > 0 else { return }
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setWidth(context.spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        textTable.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        let font = ChatFonts.body(style.fontSize - 1)
        let headerFont = ChatFonts.body(style.fontSize - 1, weight: .semibold)
        let rows = [table.header] + table.rows
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: textTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor.separatorColor)
                cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                if rowIndex == 0 { cell.backgroundColor = Theme.tableHeaderFill }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = context.textBlocks + [cell]
                paragraph.lineSpacing = 1
                switch table.alignments[column] {
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                case .left, .none: paragraph.alignment = .natural
                }
                var cellContext = context
                cellContext.spacingBefore = 0
                cellContext.indent = 0
                cellContext.textBlocks = paragraph.textBlocks
                self.paragraph(column < row.count ? row[column] : [], cellContext, font: rowIndex == 0 ? headerFont : font, paragraph: paragraph)
            }
        }
    }

    // MARK: Inlines

    private struct Traits: OptionSet {
        let rawValue: Int
        static let italic = Traits(rawValue: 1)
        static let bold = Traits(rawValue: 2)
        static let strike = Traits(rawValue: 4)
    }

    private func font(_ base: NSFont, _ traits: Traits) -> NSFont {
        guard !traits.intersection([.italic, .bold]).isEmpty else { return base }
        return ChatFonts.styled(base, bold: traits.contains(.bold), italic: traits.contains(.italic))
    }

    private mutating func inlines(_ inlines: [ChatMarkdown.Inline], font base: NSFont, color: NSColor, traits: Traits, link: Any? = nil) {
        for inline in inlines {
            switch inline {
            case .text(let text):
                var attributes: [NSAttributedString.Key: Any] = [.font: font(base, traits), .foregroundColor: color]
                if traits.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link { attributes[.link] = link }
                output.append(NSAttributedString(string: text, attributes: attributes))
            case .code(let code):
                let codeFont = ChatFonts.mono((base.pointSize * 0.9).rounded())
                // Kerning on the neighbours makes room for the rounded background.
                let before = output.length
                if before > 0, output.attribute(.chatInlineCode, at: before - 1, effectiveRange: nil) == nil {
                    output.addAttribute(.kern, value: 3, range: NSRange(location: before - 1, length: 1))
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: codeFont, .foregroundColor: color, .chatInlineCode: true,
                ]
                if let link { attributes[.link] = link }
                let text = NSMutableAttributedString(string: code, attributes: attributes)
                if text.length > 0 { text.addAttribute(.kern, value: 3, range: NSRange(location: text.length - 1, length: 1)) }
                output.append(text)
            case .emphasis(let children):
                self.inlines(children, font: base, color: color, traits: traits.union(.italic), link: link)
            case .strong(let children):
                self.inlines(children, font: base, color: color, traits: traits.union(.bold), link: link)
            case .strikethrough(let children):
                self.inlines(children, font: base, color: color, traits: traits.union(.strike), link: link)
            case .link(let destination, let children):
                let start = output.length
                self.inlines(children, font: base, color: color, traits: traits, link: Self.linkValue(destination))
                if output.length > start { output.addAttribute(.toolTip, value: destination, range: NSRange(location: start, length: output.length - start)) }
            case .image(let alt, let source):
                let label = alt.isEmpty ? (source as NSString).lastPathComponent : alt
                self.inlines([.text(label)], font: base, color: color, traits: traits, link: Self.linkValue(source))
            case .softBreak:
                output.append(NSAttributedString(string: style.preservesLineBreaks ? "\u{2028}" : " ", attributes: [.font: base]))
            case .lineBreak:
                output.append(NSAttributedString(string: "\u{2028}", attributes: [.font: base]))
            }
        }
    }

    /// Absolute URLs become `URL`s; anything else (usually a file path) stays a string for the cell to resolve.
    private static func linkValue(_ destination: String) -> Any {
        if let url = URL(string: destination), let scheme = url.scheme, scheme.count > 1 { return url }
        return destination
    }
}

/// Cached transcript fonts.
@MainActor
enum ChatFonts {
    private struct Key: Hashable {
        var size: CGFloat
        var weight: CGFloat
        var mono: Bool
    }

    private static var cache: [Key: NSFont] = [:]
    private static var styledCache: [String: NSFont] = [:]

    static func body(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = Key(size: size, weight: weight.rawValue, mono: false)
        if let font = cache[key] { return font }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = Key(size: size, weight: weight.rawValue, mono: true)
        if let font = cache[key] { return font }
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    static func styled(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        let key = "\(base.fontName)|\(base.pointSize)|\(bold)|\(italic)"
        if let font = styledCache[key] { return font }
        var font = base
        if bold {
            font = base.isFixedPitch ? mono(base.pointSize, weight: .semibold) : body(base.pointSize, weight: .semibold)
        }
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        styledCache[key] = font
        return font
    }
}
