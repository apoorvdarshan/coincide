import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// A transcript host with fixed items and nothing to act on.
@MainActor
final class StubTranscriptHost: TranscriptHost {
    var items: [UUID: TranscriptItem] = [:]
    var files: [UUID: [ChangedFile]] = [:]
    var rails: [TranscriptRowID: TranscriptRail] = [:]
    var expanded: Set<TranscriptRowID> = []
    let textCache = TranscriptTextCache()
    var threadID: UUID? { nil }
    var isThreadRunning: Bool { false }

    func item(_ id: UUID) -> TranscriptItem? { items[id] }
    func isExpanded(_ id: TranscriptRowID) -> Bool { expanded.contains(id) }
    func toggle(_ id: TranscriptRowID) {}
    func copyToPasteboard(_ text: String) {}
    func rewindTurn(_ itemID: UUID) {}
    func forkTurn(_ itemID: UUID) {}
    func canFork(_ itemID: UUID) -> Bool { false }
    func openThread(_ threadID: UUID) {}
    func showDiff(turnID: UUID, path: String?) {}
    func openLink(_ link: Any) -> Bool { false }
    func previewAttachments(_ paths: [String], selected: Int) {}
    func quote(_ text: String, from itemID: UUID) {}
    func openContext(_ context: MessageContext, from anchor: NSView) {}
    func changedFiles(for turnID: UUID) -> [ChangedFile] { files[turnID] ?? [] }
    func modelLabel(for meta: AssistantMeta) -> String { "" }
    func modelName(for meta: AssistantMeta) -> String? { nil }
    func rail(for id: TranscriptRowID) -> TranscriptRail? { rails[id] }
    func findHighlights(for itemID: UUID) -> TranscriptFindHighlights? { nil }
}

/// The transcript table in an offscreen window: every row must sit where the table lays it out, as tall as
/// what it draws, so no row draws over another.
///
/// The list finishes its work (measuring rows on screen, following a width change) on the main queue after
/// each change, so the tests wait with `Task.sleep` rather than spinning the run loop, which would not run it.
@MainActor @Suite(.serialized) struct TranscriptListHeightTests {
    private let host = StubTranscriptHost()
    private let list = TranscriptListController()
    private let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 720, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)

    init() {
        list.host = host
        window.contentView = list.scrollView
        // The list follows AppKit's layout and display passes, which only a window in the window list gets. It goes
        // in behind everything, transparent and far offscreen, so nothing ever shows on a display.
        window.alphaValue = 0
        window.orderBack(nil)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
        window.layoutIfNeeded()
    }

    private func reply(_ words: Int, seed: Int = 0) -> TranscriptRow {
        let vocabulary = ["the", "change", "keeps", "**rows**", "in", "`place`", "while", "replies", "stream", "and", "wrap"]
        let text = (0..<words).map { vocabulary[($0 * 7 + seed) % vocabulary.count] }.joined(separator: " ")
        let item = TranscriptItem(kind: .assistant, text: text)
        host.items[item.id] = item
        return TranscriptRow(id: .item(item.id), kind: .assistant(meta: nil), revision: 0)
    }

    private func exactHeight(of row: TranscriptRow) -> CGFloat {
        let type = TranscriptListController.cellType(for: row.kind)
        return max(1, ceil(type.height(for: row, width: list.tableView.bounds.width, host: host)))
    }

    /// Row views sit where the table lays their rows out, rows on screen are as tall as they measure, and the
    /// text in them fits.
    private func expectRowsInPlace(_ comment: Comment) {
        let tableView = list.tableView
        // The table works out where rows go lazily; asking for every row has it settle where each one belongs.
        let rects = (0..<list.rows.count).map { tableView.rect(ofRow: $0) }
        tableView.enumerateAvailableRowViews { rowView, index in
            #expect(abs(rowView.frame.minY - rects[index].minY) < 0.5, "\(comment): row \(index) is drawn away from its place")
            guard let cell = rowView.view(atColumn: 0) as? NSView else { return }
            cell.layoutSubtreeIfNeeded()
            for case let text as ChatTextView in cell.subviews {
                guard let layoutManager = text.layoutManager, let container = text.textContainer else { continue }
                layoutManager.ensureLayout(for: container)
                let drawn = text.frame.minY + layoutManager.usedRect(for: container).height
                #expect(drawn <= cell.bounds.height + 0.5, "\(comment): row \(index)'s text runs into the next row")
            }
        }
        let visible = tableView.rows(in: list.scrollView.contentView.documentVisibleRect)
        for index in visible.location..<NSMaxRange(visible) {
            #expect(rects[index].height == exactHeight(of: list.rows[index]), "\(comment): row \(index) is not measured")
        }
    }

    @Test func rowsBelowAReplyInsertedAboveTheViewStayInPlace() async {
        var rows = (0..<40).map { reply(20 + ($0 * 37) % 160, seed: $0) }
        list.update(rows, reload: true)
        list.scrollToBottom()
        await settle()
        expectRowsInPlace("loaded")

        // A long reply comes in above what the reader sees, as when a finished turn folds its work and lays
        // out its reply again: the table only guesses its height until it measures it.
        rows.insert(reply(900), at: 18)
        list.update(rows)
        await settle()
        expectRowsInPlace("after a reply was inserted above the view")

        rows.remove(at: 10)
        rows.insert(reply(700, seed: 3), at: 25)
        list.update(rows)
        await settle()
        expectRowsInPlace("after rows came and went above the view")
    }

    @Test func rowsBelowAReplyThatGrewAboveTheViewStayInPlace() async {
        var rows = (0..<40).map { reply(20 + ($0 * 37) % 160, seed: $0) }
        list.update(rows, reload: true)
        list.scrollToBottom()
        await settle()

        // A reply above what the reader sees takes in the rest of its text, as when the app catches up on a turn
        // that went on while it was closed.
        guard case .item(let id) = rows[30].id else { return }
        host.items[id]?.text += String(repeating: " and then some more words that wrap", count: 60)
        rows[30].revision += 1
        list.update(rows)
        await settle()
        expectRowsInPlace("after a reply above the view grew")
    }

    /// Opening or closing the panel beside the chat, or dragging its divider, narrows or widens the transcript: the
    /// reader stays at the same row, or at the bottom when following.
    @Test func aPanelOpeningBesideTheChatKeepsTheReadersPlace() async {
        let rows = (0..<40).map { reply(30 + ($0 * 37) % 160, seed: $0) }
        list.update(rows, reload: true)
        list.scrollToBottom()
        await settle()
        for width in [360, 720] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 480))
            await settle()
            await settle()
            #expect(list.distanceFromBottom <= 1, "following at \(width)")
        }

        // Scrolled up to a row, the row stays at the top through the narrowing and back.
        let rowID = rows[12].id
        let clip = list.scrollView.contentView
        list.restore(.anchor(rowID, offset: 0))
        await settle()
        #expect(!list.isPinnedToBottom)
        func offset() -> CGFloat? {
            guard let index = list.rows.firstIndex(where: { $0.id == rowID }) else { return nil }
            return list.tableView.rect(ofRow: index).minY - clip.bounds.minY
        }
        let before = offset()
        for width in [360, 520, 720] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 480))
            await settle()
            await settle()
            if let before, let after = offset() {
                #expect(abs(after - before) <= 1, "row moved at \(width): \(before) -> \(after)")
            }
            expectRowsInPlace("at \(width)")
        }
    }

    @Test func aNewTurnAfterAStreamedReplyAndItsChangedFiles() async {
        var items: [TranscriptItem] = []
        var revisions: [UUID: Int] = [:]
        var running: UUID?
        var signatures: [UUID: Int] = [:]
        func add(_ kind: TranscriptItem.Kind, _ text: String, status: ItemStatus? = nil) -> UUID {
            let item = TranscriptItem(
                kind: kind, text: text, title: kind == .tool ? "Run" : nil, category: kind == .tool ? .command : nil, status: status,
                provider: kind == .assistant ? .claude : nil)
            items.append(item)
            return item.id
        }
        func change(_ id: UUID, _ edit: (inout TranscriptItem) -> Void) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            edit(&items[index])
            revisions[id, default: 0] += 1
        }
        func rows() -> [TranscriptRow] {
            for item in items { host.items[item.id] = item }
            var builder = TranscriptBuilder(items: items)
            builder.runningTurnID = running
            builder.revisions = revisions
            builder.changedFiles = signatures
            return builder.build()
        }
        func text(_ paragraphs: Int) -> String {
            String(repeating: "A reply that explains the change with **bold** words, `code` and a list.\n\n- one\n- two\n\n", count: paragraphs)
        }
        func apply(_ comment: Comment) async {
            list.update(rows())
            await settle()
            expectRowsInPlace(comment)
        }

        for turn in 0..<12 {
            _ = add(.user, "Question \(turn)")
            _ = add(.tool, "ok", status: .completed)
            _ = add(.assistant, text(2 + turn % 3))
        }
        let user = add(.user, "Make the change")
        running = user
        for _ in 0..<6 { _ = add(.tool, "ok", status: .completed) }
        let reply = add(.assistant, "", status: .running)
        list.update(rows(), reload: true)
        list.scrollToBottom()
        await settle()

        window.setContentSize(NSSize(width: 980, height: 520))
        await settle()
        expectRowsInPlace("resized")

        for step in 1...8 {
            change(reply) { $0.text = text(step) }
            await apply("streamed step \(step)")
        }
        // The turn ends: its work folds under "Worked for…" and its reply is laid out again with its footer.
        change(reply) { $0.status = .completed }
        running = nil
        await apply("turn ended")

        host.files[user] = (0..<6).map { ChangedFile(path: "Sources/File\($0).swift", status: .modified, additions: 3, deletions: 1) }
        signatures[user] = host.files[user]?.hashValue
        await apply("changed files")

        let next = add(.user, "Now the next part")
        running = next
        await apply("new turn")
        _ = add(.tool, "ok", status: .completed)
        let nextReply = add(.assistant, text(3))
        await apply("new turn's work")
        change(nextReply) { $0.status = .completed }
        running = nil
        await apply("new turn ended")
    }

    // MARK: The user's messages

    private func userMessage(_ index: Int) -> TranscriptRow {
        let texts = [
            "Short one",
            String(repeating: "A message long enough to wrap over a few lines of its card. ", count: 1 + index % 5),
            "Here is the trace:\n\n```swift\nlet rows = builder.build()\nprint(rows.count)\n```\n\nand " + "https://example.com/"
                + String(repeating: "segment", count: 30),
            String(repeating: "x", count: 300),
            "مرحبا، هل يمكنك نقل رسائلي إلى اليمين؟\nAnd an English line under it.",
        ]
        let item = TranscriptItem(
            kind: .user, text: texts[index % texts.count], attachments: index % 4 == 1 ? ["/nonexistent/a.png", "/nonexistent/b.png"] : nil,
            steered: index % 6 == 5 ? true : nil)
        host.items[item.id] = item
        return TranscriptRow(id: .item(item.id), kind: .user, revision: 0)
    }

    /// Messages of the user's on either side measure as tall as they draw, at every width, and switching sides keeps
    /// the reader at the bottom when following, or on the row they were reading.
    @Test func userMessagesStayInPlaceOnEitherSide() async {
        let saved = AppStore.shared.settings.userMessageSide
        defer { AppStore.shared.updateSettings { $0.userMessageSide = saved } }
        var rows: [TranscriptRow] = []
        for index in 0..<30 {
            rows.append(userMessage(index))
            rows.append(reply(20 + (index * 37) % 160, seed: index))
        }
        AppStore.shared.updateSettings { $0.userMessageSide = .right }
        list.update(rows, reload: true)
        list.scrollToBottom()
        await settle()
        expectRowsInPlace("right")
        #expect(list.isPinnedToBottom)
        let bottom = list.distanceFromBottom

        // As the Settings switch does (`ChatViewController.settingsChanged`): every height measured again.
        func switchSide(to side: UserMessageSide) async {
            AppStore.shared.updateSettings { $0.userMessageSide = side }
            list.invalidateHeights()
            list.update(rows, reload: true)
            await settle()
            await settle()
        }
        for side in [UserMessageSide.left, .right] {
            await switchSide(to: side)
            // Still following, as far from the end as before.
            #expect(list.isPinnedToBottom, "following after switching to \(side)")
            #expect(abs(list.distanceFromBottom - bottom) <= 1, "following after switching to \(side): \(list.distanceFromBottom)")
            expectRowsInPlace("following after switching to \(side)")
            for width in [360, 1100, 720] as [CGFloat] {
                window.setContentSize(NSSize(width: width, height: 480))
                await settle()
                await settle()
                expectRowsInPlace("\(side) at \(width)")
            }
        }

        // Scrolled up to a message, the switch keeps it where it was.
        let rowID = rows[24].id
        list.restore(.anchor(rowID, offset: 40))
        await settle()
        let clip = list.scrollView.contentView
        func offset() -> CGFloat? {
            guard let index = list.rows.firstIndex(where: { $0.id == rowID }) else { return nil }
            return list.tableView.rect(ofRow: index).minY - clip.bounds.minY
        }
        let before = offset()
        for side in [UserMessageSide.left, .right] {
            await switchSide(to: side)
            if let before, let after = offset() {
                #expect(abs(after - before) <= 1, "row moved switching to \(side): \(before) -> \(after)")
            }
            expectRowsInPlace("scrolled up, \(side)")
        }
    }

    /// Draws a transcript with every kind of message of the user's, on either side, in light and dark, narrow and
    /// wide, when `COINCIDE_TRANSCRIPT_PNG_DIR` names a folder (`TEST_RUNNER_COINCIDE_TRANSCRIPT_PNG_DIR` on the
    /// command line). The suite's window stays transparent and far offscreen.
    @Test func rendersUserMessagesForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_TRANSCRIPT_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let images = TemporaryDirectory("user-message-images")
        var paths: [String] = []
        for (index, color) in [NSColor.systemTeal, .systemOrange].enumerated() {
            let image = NSImage(size: NSSize(width: 160, height: 120), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
            let url = images.url.appendingPathComponent("shot-\(index).png")
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            paths.append(url.path)
        }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func user(_ text: String, attachments: [String]? = nil, context: [MessageContext]? = nil, steered: Bool = false) -> TranscriptItem {
            TranscriptItem(kind: .user, text: text, attachments: attachments, context: context, steered: steered ? true : nil, createdAt: date)
        }
        func reply(_ text: String, _ provider: ProviderKind) -> TranscriptItem {
            TranscriptItem(kind: .assistant, text: text, status: .completed, provider: provider, createdAt: date, completedAt: date)
        }
        let quote = MessageContext(.quote(MessageContext.Quote(text: "The rail runs down the transcript's left gutter", provider: .claude)))
        let file = MessageContext(.file(MessageContext.AttachedFile(path: "/tmp/Coincide/UI/Chat/TranscriptRows.swift")))
        let items = [
            user("Can my messages sit on the right, like a normal chat?"),
            reply("Yes. Your messages now sit on the **right**, across from my replies, and hug their text up to three quarters of the column.", .claude),
            user("Also keep the time under the card.", steered: true),
            user(
                "Here is the trace:\n\n```swift\nlet rows = builder.build()\nprint(rows.count)\n```\n\nand the link https://example.com/"
                    + String(repeating: "segment", count: 18) + "?q=1"),
            reply("The code block and the long link wrap inside the card.", .codex),
            user("What about these?", attachments: paths, context: [quote, file]),
            user("مرحبا، هل يمكنك نقل رسائلي إلى اليمين؟\nAnd an English line under it."),
            user(String(repeating: "x", count: 160)),
            user(String(repeating: "A long message that wraps over several lines of its card, to show the widest it gets. ", count: 4)),
            reply("Done.", .codex),
        ]
        for item in items { host.items[item.id] = item }
        let rows = TranscriptBuilder(items: items).build()
        let providers = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.provider ?? .claude) })
        // The user's messages take the color of the agent they go to.
        var provider: [UUID: ProviderKind] = [:]
        for (index, item) in items.enumerated() {
            provider[item.id] = item.kind == .user ? (items[index...].first { $0.provider != nil }?.provider ?? .claude) : providers[item.id]
        }
        host.rails = TranscriptRail.rails(for: rows, provider: { provider[$0] }, runningProvider: nil)

        let background = RenderBackground()
        background.frame = NSRect(x: 0, y: 0, width: 720, height: 1600)
        list.scrollView.frame = background.bounds
        list.scrollView.autoresizingMask = [.width, .height]
        background.addSubview(list.scrollView)
        window.contentView = background
        defer { window.contentView = list.scrollView }
        let saved = AppStore.shared.settings.userMessageSide
        defer { AppStore.shared.updateSettings { $0.userMessageSide = saved } }
        for side in UserMessageSide.allCases {
            AppStore.shared.updateSettings { $0.userMessageSide = side }
            for width in [460, 1100] as [CGFloat] {
                window.setContentSize(NSSize(width: width, height: 1700))
                list.invalidateHeights()
                list.update(rows, reload: true)
                await settle()
                list.restore(.anchor(rows[0].id, offset: 0))
                await settle()
                try? await Task.sleep(for: .milliseconds(200))
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    await settle()
                    let view = background
                    view.needsDisplay = true
                    view.layoutSubtreeIfNeeded()
                    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: "\(folder)/\(side)-\(Int(width))-\(name).png"))
                }
                // The same rows laid out right to left, as a right-to-left interface would.
                window.appearance = NSAppearance(named: .aqua)
                list.tableView.enumerateAvailableRowViews { rowView, _ in
                    guard let cell = rowView.view(atColumn: 0) as? NSView else { return }
                    cell.userInterfaceLayoutDirection = .rightToLeft
                    cell.needsLayout = true
                }
                await settle()
                background.layoutSubtreeIfNeeded()
                let rep = try #require(background.bitmapImageRepForCachingDisplay(in: background.bounds))
                background.effectiveAppearance.performAsCurrentDrawingAppearance { background.cacheDisplay(in: background.bounds, to: rep) }
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "\(folder)/\(side)-\(Int(width))-rtl.png"))
                list.tableView.enumerateAvailableRowViews { rowView, _ in
                    (rowView.view(atColumn: 0) as? NSView)?.userInterfaceLayoutDirection = .leftToRight
                }
            }
        }
    }
}

/// The conversation's background, under the transcript in renders.
private final class RenderBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        dirtyRect.fill()
    }
}
