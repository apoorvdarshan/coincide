import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Context attached to a message as the user sees it: cards in the composer, pills on the sent message, the diff's
/// comment field and the selections that feed them.
@MainActor
struct ComposerContextTests {
    private let quote = MessageContext(.quote(.init(text: "\n  Use a lock here.\nOr an actor.", provider: .claude)))
    private let excerpt = MessageContext(
        .terminal(.init(terminal: "Terminal 2", directory: "/tmp/repo", lineStart: 12, lineEnd: 13, text: "$ make\nerror: boom")))
    private let comment = MessageContext(
        .diffComment(.init(path: "Sources/App.swift", lineStart: 4, lineEnd: 5, isBeforeChange: false, diff: "+a\n+b", comment: "")))
    private let file = MessageContext(.file(.init(path: "/tmp/docs/spec.pdf")))

    @Test func cardsNameWhatTheyHold() {
        #expect(quote.title == "Quote from Claude Code")
        #expect(quote.preview == "Use a lock here.")
        #expect(MessageContext(.quote(.init(text: "x", provider: nil))).title == "Quote")
        #expect(excerpt.title == "Terminal 2, lines 12–13")
        #expect(excerpt.preview == "$ make" && excerpt.previewIsCode)
        #expect(comment.title == "App.swift L4–5")
        #expect(comment.preview == "No comment")
        let removed = MessageContext(
            .diffComment(.init(path: "a.swift", lineStart: 7, lineEnd: 7, isBeforeChange: true, diff: "-x", comment: "Why?")))
        #expect(removed.title == "a.swift L7 (before)" && removed.preview == "Why?")
        #expect(file.title == "spec.pdf" && file.preview == "/tmp/docs" && file.symbolName == "doc.richtext")
        #expect(MessageContext(.file(.init(path: "/tmp/a.swift"))).symbolName == "doc.text")
        // Files open in Quick Look; the rest show their text.
        #expect(file.detailText == nil && quote.detailText?.contains("Or an actor.") == true)
        #expect(excerpt.accessibilityDescription == "Terminal output: Terminal 2, lines 12–13, $ make")
    }

    @Test func theStripShowsImagesThenContextAndHidesWhenEmpty() throws {
        let strip = ComposerAttachmentStrip()
        let image = ComposerAttachment(path: "/tmp/shot.png", name: "shot.png")
        strip.show([image], context: [quote, file], warning: nil)
        #expect(!strip.isHidden)
        let row = try #require(Self.chipRow(in: strip))
        #expect(row.arrangedSubviews.count == 3)
        #expect(row.arrangedSubviews.first is ComposerAttachmentChip)
        #expect(row.arrangedSubviews.compactMap { ($0 as? ComposerContextCard)?.context } == [quote, file])

        // Showing again keeps the cards that stay and drops the removed one.
        let kept = row.arrangedSubviews[2]
        strip.show([], context: [file], warning: nil)
        #expect(row.arrangedSubviews == [kept])
        strip.show([], context: [], warning: nil)
        #expect(strip.isHidden && row.arrangedSubviews.isEmpty)
    }

    @Test func aCardOpensAndRemovesItsContext() throws {
        let strip = ComposerAttachmentStrip()
        var opened: [MessageContext] = []
        var removed: [MessageContext] = []
        strip.onOpenContext = { context, _ in opened.append(context) }
        strip.onRemoveContext = { context in removed.append(context) }
        strip.show([], context: [excerpt], warning: nil)
        let card = try #require(Self.chipRow(in: strip)?.arrangedSubviews.first as? ComposerContextCard)
        let buttons = card.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        buttons.first?.performClick(nil)
        buttons.last?.performClick(nil)
        #expect(opened == [excerpt] && removed == [excerpt])
    }

    @Test func pillsFitTheirTitleWithinTheBubble() {
        let narrow = MessageContextPill.width(for: excerpt, maxWidth: 60)
        let wide = MessageContextPill.width(for: excerpt, maxWidth: 600)
        #expect(narrow == 60)
        #expect(wide > 80 && wide < 600)
        let pill = MessageContextPill()
        var opened: MessageContext?
        pill.onOpen = { context, _ in opened = context }
        pill.configure(comment)
        #expect(pill.accessibilityPerformPress())
        #expect(opened == comment)
        #expect(pill.accessibilityLabel() == comment.accessibilityDescription)
    }

    @Test func theDetailsShowTheWholeText() throws {
        let view = MessageContextDetails.view(for: excerpt)
        #expect(view.accessibilityLabel() == excerpt.accessibilityDescription)
        let texts = Self.textViews(in: view).map(\.string)
        #expect(texts == ["$ make\nerror: boom"])
    }

    @Test func theCommentFieldPreviewsTheLinesWithoutHunkHeaders() {
        #expect(DiffCommentEditor.preview(of: "@@ -1,1 +1,2 @@\n-a\n+b\n+c") == "-a\n+b\n+c")
        let long = (1...9).map { "+line \($0)" }.joined(separator: "\n")
        #expect(DiffCommentEditor.preview(of: "@@ -0,0 +1,9 @@\n" + long).split(separator: "\n").count == 7)
        #expect(DiffCommentEditor.preview(of: long).hasSuffix("+line 6\n…"))
    }

    @Test func aRepliesSelectionIsQuotedAndOtherTextIsNot() {
        let textView = ChatTextView()
        textView.setText(NSAttributedString(string: "First line\nSecond line"))
        textView.setSelectedRange(NSRange(location: 6, length: 4))
        #expect(textView.selectedPlainText == "line")
        // Only agents' replies take quotes.
        #expect(!textView.canAddSelectionToComposer)
        var quoted: [String] = []
        textView.onQuote = { quoted.append($0) }
        #expect(textView.canAddSelectionToComposer)
        #expect(textView.addToComposerTitle == "Quote in Composer")
        textView.addSelectionToComposer()
        #expect(quoted == ["line"])
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!textView.canAddSelectionToComposer)
    }

    // MARK: Helpers

    private static func chipRow(in strip: ComposerAttachmentStrip) -> NSStackView? {
        let scroll = strip.arrangedSubviews.first as? NSScrollView
        return scroll?.documentView?.subviews.first as? NSStackView
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        view.subviews.flatMap { subview -> [NSTextView] in
            if let scroll = subview as? NSScrollView, let text = scroll.documentView as? NSTextView { return [text] }
            return textViews(in: subview)
        }
    }
}
