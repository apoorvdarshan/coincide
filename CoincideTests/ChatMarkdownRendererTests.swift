import AppKit
import Testing

@testable import Coincide

struct ChatMarkdownRendererTests {
    private let style = ChatMarkdownStyle(fontSize: 13)

    private func render(_ markdown: String, style: ChatMarkdownStyle? = nil) -> ChatRenderedText {
        ChatMarkdownRenderer.render(markdown, style: style ?? self.style)
    }

    private func location(of text: String, in rendered: ChatRenderedText, occurrence: Int = 1) -> Int {
        let string = rendered.string.string as NSString
        var range = NSRange(location: 0, length: 0)
        var searchStart = 0
        for _ in 0..<occurrence {
            range = string.range(of: text, range: NSRange(location: searchStart, length: string.length - searchStart))
            searchStart = NSMaxRange(range)
        }
        #expect(range.location != NSNotFound, "\(text) not in \(rendered.string.string.debugDescription)")
        return range.location
    }

    private func attribute<T>(_ key: NSAttributedString.Key, of text: String, in rendered: ChatRenderedText) -> T? {
        rendered.string.attribute(key, at: location(of: text, in: rendered), effectiveRange: nil) as? T
    }

    // MARK: Text and inline styles

    @Test func markdownSyntaxIsRemovedFromTheText() {
        #expect(render("Hello **world**, *you* and ~~them~~").string.string == "Hello world, you and them")
        #expect(render("# Title\n\nBody").string.string == "Title\nBody")
        #expect(render("").string.string == "")
    }

    @Test func emphasisChangesTheFont() throws {
        let rendered = render("plain **bold** *italic* ***both***")
        let plain: NSFont = try #require(attribute(.font, of: "plain", in: rendered))
        let bold: NSFont = try #require(attribute(.font, of: "bold", in: rendered))
        let italic: NSFont = try #require(attribute(.font, of: "italic", in: rendered))
        let both: NSFont = try #require(attribute(.font, of: "both", in: rendered))
        #expect(plain.pointSize == 13)
        #expect(!plain.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(both.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(both.fontDescriptor.symbolicTraits.contains(.italic))
        let strike = render("~~gone~~")
        #expect(strike.string.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func headingsAreLargerAndSemibold() throws {
        let rendered = render("# One\n\n## Two\n\n### Three\n\n#### Four\n\nbody")
        let sizes = try ["One", "Two", "Three", "Four", "body"].map { text -> CGFloat in
            let font: NSFont = try #require(attribute(.font, of: text, in: rendered))
            return font.pointSize
        }
        #expect(sizes == [18, 16, 14, 13, 13])
        let heading: NSFont = try #require(attribute(.font, of: "One", in: rendered))
        #expect(heading.fontDescriptor.symbolicTraits.contains(.bold))
        // A sixth-level heading reads as secondary text.
        let six = render("###### small")
        #expect(six.string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }

    @Test func inlineCodeIsMonospacedAndMarked() throws {
        let rendered = render("run `make test` now")
        let font: NSFont = try #require(attribute(.font, of: "make", in: rendered))
        #expect(font.isFixedPitch)
        let marked: Bool? = attribute(.chatInlineCode, of: "make", in: rendered)
        #expect(marked == true)
        #expect(rendered.string.attribute(.chatInlineCode, at: 0, effectiveRange: nil) == nil)
        // The neighbours get kerning to make room for the rounded background.
        let before = location(of: "make", in: rendered) - 1
        #expect(rendered.string.attribute(.kern, at: before, effectiveRange: nil) as? Int == 3)
    }

    @Test func softBreaksJoinLinesExceptInUserMessages() {
        #expect(render("one\ntwo").string.string == "one two")
        #expect(render("one\ntwo", style: ChatMarkdownStyle(fontSize: 13, preservesLineBreaks: true)).string.string == "one\u{2028}two")
        #expect(render("one  \ntwo").string.string == "one\u{2028}two")
    }

    // MARK: Links

    @Test func webLinksBecomeURLsAndPathsStayStrings() throws {
        let rendered = render("[site](https://example.com/a) and [file](src/App.swift:12)")
        let site: URL = try #require(attribute(.link, of: "site", in: rendered))
        #expect(site.absoluteString == "https://example.com/a")
        let file: String = try #require(attribute(.link, of: "file", in: rendered))
        #expect(file == "src/App.swift:12")
        // Both show where they lead before they are clicked.
        let siteTip: String? = attribute(.toolTip, of: "site", in: rendered)
        #expect(siteTip == "https://example.com/a")
        let fileTip: String? = attribute(.toolTip, of: "file", in: rendered)
        #expect(fileTip == "src/App.swift:12")
        #expect(rendered.string.attribute(.link, at: location(of: " and ", in: rendered), effectiveRange: nil) == nil)
    }

    @Test func imagesRenderAsLinksToTheirSource() throws {
        let rendered = render("![Logo](assets/logo.png) ![](docs/diagram.svg)")
        #expect(rendered.string.string == "Logo diagram.svg")
        let logo: String? = attribute(.link, of: "Logo", in: rendered)
        #expect(logo == "assets/logo.png")
        let diagram: String? = attribute(.toolTip, of: "diagram.svg", in: rendered)
        #expect(diagram == "docs/diagram.svg")
    }

    @Test func linkedCodeKeepsItsLink() throws {
        let rendered = render("[`README`](https://x.dev/readme)")
        let link: URL = try #require(attribute(.link, of: "README", in: rendered))
        #expect(link.host == "x.dev")
    }

    // MARK: Blocks

    @Test func codeBlocksAreRecordedForTheirCopyButtons() throws {
        let rendered = render("Intro\n\n```swift\nlet x = 1\n```\n\n```\n```")
        #expect(rendered.codeBlocks.count == 2)
        let first = rendered.codeBlocks[0]
        #expect(first.code == "let x = 1")
        #expect((rendered.string.string as NSString).substring(with: first.range) == "let x = 1")
        #expect(first.textBlock.label == "swift")
        let font = try #require(rendered.string.attribute(.font, at: first.range.location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
        // An empty block still has a line to draw its box around.
        let empty = rendered.codeBlocks[1]
        #expect(empty.code == "")
        #expect((rendered.string.string as NSString).substring(with: empty.range) == " ")
        #expect(empty.textBlock.label == "")
    }

    @Test func codeBlocksAreSyntaxHighlighted() throws {
        let rendered = render("```swift\nlet value = 1\n```")
        let keyword = try #require(rendered.string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let plain = try #require(rendered.string.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor)
        #expect(plain == .labelColor)
        #expect(keyword != .labelColor)
    }

    @Test func listsGetMarkersAndTabs() {
        #expect(render("- a\n- b").string.string == "•\ta\n•\tb")
        #expect(render("3. three\n4. four").string.string == "3.\tthree\n4.\tfour")
        #expect(render("- top\n  - inner\n    - deep").string.string == "•\ttop\n◦\tinner\n▪︎\tdeep")
    }

    @Test func taskItemsShowABoxAndPlansDimDoneTasks() throws {
        let plain = render("- [x] done\n- [ ] todo")
        #expect(plain.string.string == "\u{FFFC}\tdone\n\u{FFFC}\ttodo")
        #expect(plain.string.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        let plan = render("- [x] done\n- [ ] todo", style: ChatMarkdownStyle(fontSize: 13, dimsCompletedTasks: true))
        let done: NSColor? = plan.string.attribute(.foregroundColor, at: location(of: "done", in: plan), effectiveRange: nil) as? NSColor
        let todo: NSColor? = plan.string.attribute(.foregroundColor, at: location(of: "todo", in: plan), effectiveRange: nil) as? NSColor
        #expect(done == .secondaryLabelColor)
        #expect(todo == .labelColor)
    }

    @Test func quotesUseSecondaryTextInAQuoteBlock() throws {
        let rendered = render("> quoted")
        #expect(rendered.string.string == "quoted")
        #expect(rendered.string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        let paragraph = try #require(rendered.string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.textBlocks.contains { $0 is ChatQuoteTextBlock })
    }

    @Test func rulesAndTablesUseTextBlocks() throws {
        let rule = render("above\n\n---\n\nbelow")
        #expect(rule.string.string == "above\n\u{00A0}\nbelow")
        let ruleStyle = try #require(rule.string.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        #expect(ruleStyle.textBlocks.contains { $0 is ChatRuleTextBlock })

        let table = render("| Name | Qty |\n|:--|--:|\n| a | 1 |")
        #expect(table.string.string == "Name\nQty\na\n1")
        let cell = try #require(table.string.attribute(.paragraphStyle, at: location(of: "1", in: table), effectiveRange: nil) as? NSParagraphStyle)
        let block = try #require(cell.textBlocks.last as? NSTextTableBlock)
        #expect(block.startingRow == 1 && block.startingColumn == 1)
        #expect(cell.alignment == .right)
        let header: NSFont = try #require(attribute(.font, of: "Name", in: table))
        #expect(header.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func piecesListEachTopLevelBlockInOrder() {
        let rendered = render("# Title\n\npara\n\n- a\n- b\n\n```\ncode\n```")
        #expect(rendered.pieces.count == 4)
        // Each piece ends with its newline; the last one is dropped from the text.
        #expect(rendered.pieces.reduce(0) { $0 + $1.length } == rendered.string.length + 1)
        #expect(Set(rendered.pieces.map(\.key)).count == 4)
    }

    // MARK: Streaming with a cache

    @Test(arguments: [
        "# Plan\n\nFirst, **read** the [docs](https://x.dev).\n\n- [ ] one\n- [x] two\n\n```swift\nlet a = 1\nprint(a)\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nDone.",
        "Intro\n#123 fixed\n\n> quote\n> more\n\n1. one\n2. two\n\n---\n\n    indented\n\nend",
    ])
    func renderingWithACacheWhileStreamingMatchesAFreshRender(source: String) {
        let cache = ChatRenderCache()
        var text = ""
        for character in source {
            text.append(character)
            let cached = ChatMarkdownRenderer.render(text, style: style, cache: cache)
            let fresh = ChatMarkdownRenderer.render(text, style: style)
            guard cached.string.string == fresh.string.string else {
                Issue.record("Text diverged at \(text.debugDescription)")
                return
            }
            #expect(cached.pieces == fresh.pieces)
            #expect(cached.codeBlocks.map(\.range) == fresh.codeBlocks.map(\.range))
            #expect(cached.codeBlocks.map(\.code) == fresh.codeBlocks.map(\.code))
            #expect(fontRuns(cached.string) == fontRuns(fresh.string), "\(text.debugDescription)")
            #expect(linkRuns(cached.string) == linkRuns(fresh.string))
        }
    }

    @Test func aStyleChangeRendersAgainInsteadOfReusingTheCache() throws {
        let cache = ChatRenderCache()
        let text = "# Title\n\nbody text\n\nmore"
        _ = ChatMarkdownRenderer.render(text, style: style, cache: cache)
        let bigger = ChatMarkdownStyle(fontSize: 20)
        let rendered = ChatMarkdownRenderer.render(text + " and more", style: bigger, cache: cache)
        let body = try #require(rendered.string.attribute(.font, at: location(of: "body", in: rendered), effectiveRange: nil) as? NSFont)
        #expect(body.pointSize == 20)
        let title = try #require(rendered.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // `ChatRenderCache` keys its blocks by content and spacing only, so the first block (spacing 0) rendered
        // in the old style is reused. The app clears its caches when the font size changes (ChatViewController),
        // so this does not show today; it would if a cache outlived a style change.
        withKnownIssue("ChatRenderCache reuses a block rendered with another style") {
            #expect(title.pointSize == 28)
            #expect(fontRuns(rendered.string) == fontRuns(ChatMarkdownRenderer.render(text + " and more", style: bigger).string))
        }
    }

    private func fontRuns(_ string: NSAttributedString) -> [String] {
        var runs: [String] = []
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            let font = value as? NSFont
            runs.append("\(range.location)+\(range.length):\(font?.fontName ?? "-")@\(font?.pointSize ?? 0)")
        }
        return runs
    }

    private func linkRuns(_ string: NSAttributedString) -> [String] {
        var runs: [String] = []
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let value else { return }
            runs.append("\(range.location)+\(range.length):\(value)")
        }
        return runs
    }
}
