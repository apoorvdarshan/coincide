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
        #expect(quote.title == "Replying to Claude Code")
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
        pill.frame.size = NSSize(width: MessageContextPill.width(for: comment, maxWidth: 600), height: MessageContextPill.height)
        pill.layoutSubtreeIfNeeded()
        let label = pill.subviews.compactMap { $0 as? NSTextField }.first
        #expect((label?.frame.width ?? 0) >= (label?.intrinsicContentSize.width ?? 0))
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
        // Only text the transcript lets the user reply to takes quotes.
        #expect(!textView.canAddSelectionToComposer)
        var quoted: [String] = []
        textView.onQuote = { quoted.append($0) }
        #expect(textView.canAddSelectionToComposer)
        #expect(textView.addToComposerTitle == "Reply")
        textView.addSelectionToComposer()
        #expect(quoted == ["line"])
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!textView.canAddSelectionToComposer)
    }

    // MARK: Reply

    @Test func aRightClickInASelectionKeepsItAndOpensItsMenuNotTheRows() throws {
        let table = MenuRecordingTable(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let textView = ChatTextView()
        table.addSubview(textView)
        textView.setText(NSAttributedString(string: "Use a lock here."))
        textView.onQuote = { _ in }
        textView.setSelectedRange(NSRange(location: 6, length: 4))
        let menu = try #require(textView.selectionMenu())
        #expect(menu.items.map(\.title) == ["Copy", "Reply"])

        textView.rightMouseDown(with: try Self.mouseEvent(.rightMouseDown, at: 1))
        // The click stays with the text: the table neither gets it nor is asked for its row menu.
        #expect(table.rightClicks == 0 && table.menuRequests == 0)
        #expect(textView.selectedPlainText == "lock")
        textView.mouseDown(with: try Self.mouseEvent(.leftMouseDown, at: 2, modifiers: .control))
        #expect(table.rightClicks == 0 && table.menuRequests == 0)
        #expect(textView.selectedPlainText == "lock")

        // With nothing selected the row's menu opens, once per click however often it is asked for.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(textView.selectionMenu() == nil)
        let click = try Self.mouseEvent(.rightMouseDown, at: 3)
        textView.rightMouseDown(with: click)
        _ = textView.menu(for: click)
        #expect(table.menuRequests == 1 && table.rightClicks == 0)
    }

    @Test func theReplyButtonFollowsTheSelectionAndQuotesItInTheComposer() throws {
        let folder = TemporaryDirectory("composer-reply")
        let store = AppStore(directory: folder.url)
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        let registry = ProviderRegistry(store: store, providers: [])
        let composer = ComposerViewController(store: store, registry: registry, runner: ThreadRunner(store: store, registry: registry))
        _ = composer.view
        composer.threadID = id
        let reply = TranscriptItem(kind: .assistant, text: "Use a lock here. Or an actor.", provider: .claude)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = ChatTextView()
        textView.frame = NSRect(x: 40, y: 200, width: 400, height: 40)
        container.addSubview(textView)
        textView.setText(NSAttributedString(string: reply.text))
        textView.onQuote = { composer.addContext(ChatViewController.quote($0, from: reply)) }
        let replyButton = TranscriptReplyButton()
        container.addSubview(replyButton.button)
        let posts = NotificationCounter(ChatTextView.selectionDidChange, object: textView)

        // While a drag still extends the selection the button waits.
        textView.setSelectedRanges([NSValue(range: NSRange(location: 6, length: 4))], affinity: .downstream, stillSelecting: true)
        #expect(posts.count > 0 && textView.isDraggingSelection)
        replyButton.update(for: textView, within: container.bounds)
        #expect(!replyButton.isShown)
        textView.setSelectedRanges([NSValue(range: NSRange(location: 6, length: 4))], affinity: .downstream, stillSelecting: false)
        replyButton.update(for: textView, within: container.bounds)
        #expect(replyButton.isShown && replyButton.textView === textView)
        // Just below the selection, inside the area.
        let end = try #require(textView.selectionEndRect.map { container.convert($0, from: textView) })
        #expect(replyButton.button.frame.maxY <= end.minY)
        #expect(container.bounds.contains(replyButton.button.frame))
        #expect(replyButton.button.refusesFirstResponder)

        // Streamed text that keeps the selection is not a new selection; text that loses it says so.
        let before = posts.count
        textView.setText(NSAttributedString(string: reply.text + " Or a queue."))
        #expect(posts.count == before && textView.selectedPlainText == "lock")
        let short = ChatTextView()
        short.setText(NSAttributedString(string: "A long enough line"))
        short.onQuote = { _ in }
        short.setSelectedRange(NSRange(location: 2, length: 4))
        let shortPosts = NotificationCounter(ChatTextView.selectionDidChange, object: short)
        short.setText(NSAttributedString(string: "A"))
        #expect(shortPosts.count == 1 && !short.canAddSelectionToComposer)

        // Another text losing its selection leaves the button be.
        let other = ChatTextView()
        other.onQuote = { _ in }
        container.addSubview(other)
        replyButton.update(for: other, within: container.bounds)
        #expect(replyButton.isShown)

        replyButton.button.performClick(nil)
        #expect(!replyButton.isShown)
        let quote = MessageContext(.quote(.init(text: "lock", provider: .claude)))
        #expect(store.thread(id)?.draftContext?.map(\.content) == [quote.content])
        #expect(quote.title == "Replying to Claude Code")

        // Deselecting hides it.
        replyButton.update(for: textView, within: container.bounds)
        #expect(replyButton.isShown)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        replyButton.update(for: textView, within: container.bounds)
        #expect(!replyButton.isShown)
    }

    @Test func theReplyButtonGoesAboveWhenThereIsNoRoomBelow() {
        let size = NSSize(width: 80, height: 28)
        let area = NSRect(x: 0, y: 0, width: 500, height: 300)
        let low = TranscriptReplyButton.frame(size: size, below: NSRect(x: 200, y: 20, width: 8, height: 16), within: area, flipped: false)
        #expect(low.minY >= 36)
        let high = TranscriptReplyButton.frame(size: size, below: NSRect(x: 200, y: 200, width: 8, height: 16), within: area, flipped: false)
        #expect(high.maxY <= 200 && high.midX == 208)
        // Never past the area's edges.
        let edge = TranscriptReplyButton.frame(size: size, below: NSRect(x: 495, y: 200, width: 4, height: 16), within: area, flipped: false)
        #expect(edge.maxX <= area.maxX - TranscriptReplyButton.margin)
        let flipped = TranscriptReplyButton.frame(size: size, below: NSRect(x: 200, y: 100, width: 8, height: 16), within: area, flipped: true)
        #expect(flipped.minY >= 116)
    }

    @Test func aReplyToTheUsersOwnMessageIsNotFromTheAgent() {
        let mine = TranscriptItem(kind: .user, text: "Fix the login", provider: .codex)
        let theirs = TranscriptItem(kind: .assistant, text: "Done", provider: .codex)
        #expect(ChatViewController.quote("login", from: mine).content == .quote(.init(text: "login", provider: nil)))
        #expect(ChatViewController.quote("Done", from: theirs).title == "Replying to Codex")
    }

    @Test func unsentContextSurvivesReopeningTheStoreAndComposer() throws {
        let folder = TemporaryDirectory("composer-context-draft")
        let store = AppStore(directory: folder.url)
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let composer = ComposerViewController(store: store, registry: registry, runner: runner)
        _ = composer.view
        composer.threadID = id
        composer.addContext(quote)
        composer.addContext(file)
        store.flush()
        #expect(store.summary(id)?.hasDraft == true)

        let reopened = AppStore(directory: folder.url)
        #expect(reopened.thread(id)?.draftContext == [quote, file])
        #expect(reopened.summary(id)?.hasDraft == true)
        let newRegistry = ProviderRegistry(store: reopened, providers: [])
        let newRunner = ThreadRunner(store: reopened, registry: newRegistry)
        let restored = ComposerViewController(store: reopened, registry: newRegistry, runner: newRunner)
        _ = restored.view
        restored.threadID = id
        let strip = try #require(Self.findView(ComposerAttachmentStrip.self, in: restored.view))
        let row = try #require(Self.chipRow(in: strip))
        #expect(row.arrangedSubviews.compactMap { ($0 as? ComposerContextCard)?.context } == [quote, file])
    }

    private static func findView<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        return root.subviews.lazy.compactMap { findView(type, in: $0) }.first
    }

    // MARK: Helpers

    private static func mouseEvent(_ type: NSEvent.EventType, at time: TimeInterval, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 60, y: 8), modifierFlags: modifiers, timestamp: time, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
    }

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

/// Counts the notifications of one name an object posts.
private final class NotificationCounter: NSObject {
    private(set) var count = 0

    init(_ name: Notification.Name, object: AnyObject?) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(received), name: name, object: object)
    }

    @objc private func received() {
        count += 1
    }
}

/// A table that counts the right-clicks that reach it and the times its row menu is asked for.
private final class MenuRecordingTable: NSTableView {
    var rightClicks = 0
    var menuRequests = 0

    override func rightMouseDown(with event: NSEvent) {
        rightClicks += 1
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuRequests += 1
        return nil
    }
}
