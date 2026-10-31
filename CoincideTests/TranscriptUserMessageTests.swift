import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Sets where the user's messages sit for the length of `body`, then puts back what was there. The tests that read
/// the setting through `Theme` change it only inside such a call, without suspending, so tests running alongside never
/// see it changed.
@MainActor
func withUserMessageSide<T>(_ side: UserMessageSide, _ body: () throws -> T) rethrows -> T {
    let saved = AppStore.shared.settings.userMessageSide
    AppStore.shared.updateSettings { $0.userMessageSide = side }
    defer { AppStore.shared.updateSettings { $0.userMessageSide = saved } }
    return try body()
}

/// The user's message card: on the right by default, hugging its content up to three quarters of the column, with its
/// actions under its outer edge; on the left, on the rail, as before the setting; mirrored right to left.
@MainActor @Suite struct TranscriptUserMessageLayoutTests {
    private let host = StubTranscriptHost()
    private let wide: CGFloat = 1000
    private let narrow: CGFloat = 380

    private func message(
        _ text: String, attachments: [String]? = nil, context: [MessageContext]? = nil, steered: Bool = false
    ) -> (TranscriptItem, TranscriptRow) {
        let item = TranscriptItem(kind: .user, text: text, attachments: attachments, context: context, steered: steered ? true : nil)
        host.items[item.id] = item
        return (item, TranscriptRow(id: .item(item.id), kind: .user, revision: 0))
    }

    private func layout(
        _ message: (TranscriptItem, TranscriptRow), width: CGFloat, side: UserMessageSide,
        direction: NSUserInterfaceLayoutDirection = .leftToRight
    ) -> TranscriptUserCell.Layout {
        TranscriptUserCell.layout(for: message.0, row: message.1, width: width, host: host, side: side, direction: direction)
    }

    private var longText: String {
        String(repeating: "A long message that wraps over several lines of the card to fill it. ", count: 8)
    }

    @Test func aShortMessageHugsItsTextAtTheColumnsRightEdge() {
        let column = TranscriptMetrics.column(width: wide)
        let layout = layout(message("Ship it"), width: wide, side: .right)
        #expect(layout.isOnRight)
        #expect(layout.bubble.maxX == column.x + column.width)
        #expect(layout.bubble.width < 120)
        // The text stays left-aligned inside the card.
        #expect(layout.text.minX == 12)
        #expect(layout.bubble.width >= layout.text.maxX + 12 - 1)
    }

    @Test func aLongMessageStopsAtThreeQuartersOfTheColumn() {
        let column = TranscriptMetrics.column(width: wide)
        let layout = layout(message(longText), width: wide, side: .right)
        // As wide as its longest wrapped line, which comes within a word of the limit.
        let limit = (column.width * 0.75).rounded(.down)
        #expect(TranscriptUserCell.maxBubbleWidth(column: column.width, side: .right) == limit)
        #expect(layout.bubble.width <= limit && layout.bubble.width > limit - 60)
        #expect(layout.bubble.maxX == column.x + column.width)
        #expect(layout.text.maxX <= layout.bubble.width - 12 + 0.5)
    }

    @Test func onTheLeftTheCardSitsOnTheRailAsBefore() {
        let column = TranscriptMetrics.column(width: wide)
        let short = layout(message("Ship it"), width: wide, side: .left)
        #expect(!short.isOnRight)
        #expect(short.bubble.minX == column.x)
        let long = layout(message(longText), width: wide, side: .left)
        let limit = (column.width * 0.8).rounded(.down)
        #expect(TranscriptUserCell.maxBubbleWidth(column: column.width, side: .left) == limit)
        #expect(long.bubble.width <= limit && long.bubble.width > limit - 60)
        #expect(long.bubble.minX == column.x)
    }

    @Test func aNarrowColumnLetsTheCardTakeItsWholeWidth() {
        let column = TranscriptMetrics.column(width: narrow)
        #expect(column.width < TranscriptUserCell.narrowColumnWidth)
        #expect(TranscriptUserCell.maxBubbleWidth(column: column.width, side: .right) == column.width)
        let layout = layout(message(longText), width: narrow, side: .right)
        #expect(layout.bubble.maxX == column.x + column.width)
        #expect(layout.bubble.width > column.width - 60)
        // A short one still hugs its text on the right.
        let short = self.layout(message("Ship it"), width: narrow, side: .right)
        #expect(short.bubble.maxX == column.x + column.width)
        #expect(short.bubble.width < column.width / 2)
    }

    @Test func anUnbrokenStringWrapsInsideTheCard() {
        let column = TranscriptMetrics.column(width: wide)
        let url = "https://example.com/" + String(repeating: "a1b2c3d4", count: 40) + "?query=" + String(repeating: "z", count: 60)
        let layout = layout(message(url), width: wide, side: .right)
        #expect(layout.bubble.width <= (column.width * 0.75).rounded(.down))
        #expect(layout.bubble.maxX == column.x + column.width)
        #expect(layout.text.maxX <= layout.bubble.width - 12 + 0.5)
        // It wrapped onto more lines rather than running out of the card.
        #expect(layout.text.height > Theme.lineHeight(of: Theme.bodyFont) * 3)
    }

    @Test func attachmentsAndContextStayInsideTheCard() {
        let quote = MessageContext(.quote(MessageContext.Quote(text: "The rail runs down the left", provider: .claude)))
        let file = MessageContext(.file(MessageContext.AttachedFile(path: "/tmp/Sources/App/TranscriptRows.swift")))
        let layout = layout(
            message("What about these?", attachments: ["/tmp/a.png", "/tmp/b.png", "/tmp/c.png"], context: [quote, file]),
            width: wide, side: .right)
        let column = TranscriptMetrics.column(width: wide)
        #expect(layout.bubble.maxX == column.x + column.width)
        for frame in layout.thumbnails + layout.pills + [layout.text] {
            #expect(frame.minX >= 12 - 0.5 && frame.maxX <= layout.bubble.width - 12 + 0.5, "\(frame) leaves the card")
        }
        #expect(layout.thumbnails[0].minX == 12)
    }

    /// Right to left, the card goes to the left (the transcript's trailing side there) and its contents run from
    /// its right edge; the Left choice puts it on the right.
    @Test func rightToLeftMirrorsTheCard() {
        let column = TranscriptMetrics.column(width: wide)
        let message = message(
            "مرحبا، هل يمكنك نقل رسائلي؟", attachments: ["/tmp/a.png", "/tmp/b.png"],
            context: [MessageContext(.quote(MessageContext.Quote(text: "quoted", provider: .codex)))])
        let ltr = layout(message, width: wide, side: .right)
        let rtl = layout(message, width: wide, side: .right, direction: .rightToLeft)
        #expect(!rtl.isOnRight && rtl.isRightToLeft)
        #expect(rtl.bubble.minX == column.x)
        #expect(rtl.bubble.size == ltr.bubble.size)
        #expect(rtl.height == ltr.height)
        // Each part mirrors within the card.
        for (left, right) in zip(ltr.thumbnails + ltr.pills + [ltr.text], rtl.thumbnails + rtl.pills + [rtl.text]) {
            #expect(abs(right.minX - (ltr.bubble.width - left.maxX)) < 0.5)
            #expect(right.minY == left.minY && right.size == left.size)
        }
        #expect(rtl.thumbnails[0].maxX == rtl.bubble.width - 12)
        let left = layout(message, width: wide, side: .left, direction: .rightToLeft)
        #expect(left.isOnRight)
        #expect(left.bubble.maxX == column.x + column.width)
    }

    @Test func theSettingsNamesFollowTheSideTheMessagesShowOn() {
        #expect(UserMessageSide.right.isOnRight(in: .leftToRight))
        #expect(!UserMessageSide.left.isOnRight(in: .leftToRight))
        #expect(!UserMessageSide.right.isOnRight(in: .rightToLeft))
        #expect(UserMessageSide.right.title(in: .leftToRight) == "Right")
        #expect(UserMessageSide.right.title(in: .rightToLeft) == "Left")
        #expect(UserMessageSide.left.title(in: .rightToLeft) == "Right")
    }

    @Test func rowsLineUpAtEitherEdgeInReadingOrder() {
        let widths: [CGFloat] = [22, 22, 40]
        let gaps: [CGFloat] = [0, 4]
        #expect(TranscriptUserCell.rowOrigins(widths: widths, gaps: gaps, edge: 100, alignsRight: false, rightToLeft: false) == [100, 122, 148])
        #expect(TranscriptUserCell.rowOrigins(widths: widths, gaps: gaps, edge: 188, alignsRight: true, rightToLeft: false) == [100, 122, 148])
        // Right to left, the first item is the rightmost.
        #expect(TranscriptUserCell.rowOrigins(widths: widths, gaps: gaps, edge: 100, alignsRight: false, rightToLeft: true) == [166, 144, 100])
        #expect(TranscriptUserCell.rowOrigins(widths: widths, gaps: gaps, edge: 188, alignsRight: true, rightToLeft: true) == [166, 144, 100])
    }

    @Test func theHeightDependsOnTheSideOnlyThroughTheCardsWidth() {
        for text in ["Ship it", longText] {
            let message = message(text)
            for width in [narrow, wide] {
                let right = layout(message, width: width, side: .right)
                let mirrored = layout(message, width: width, side: .right, direction: .rightToLeft)
                #expect(right.height == mirrored.height)
                let height = withUserMessageSide(.right) {
                    TranscriptUserCell.height(for: message.1, width: width, host: host)
                }
                #expect(height == right.height)
                let leftHeight = withUserMessageSide(.left) {
                    TranscriptUserCell.height(for: message.1, width: width, host: host)
                }
                #expect(leftHeight == layout(message, width: width, side: .left).height)
            }
        }
    }

    // MARK: The cell

    private func cell(
        for message: (TranscriptItem, TranscriptRow), width: CGFloat, direction: NSUserInterfaceLayoutDirection = .leftToRight
    ) -> TranscriptUserCell {
        let cell = TranscriptUserCell()
        cell.userInterfaceLayoutDirection = direction
        cell.configure(message.1, host: host)
        cell.frame = NSRect(x: 0, y: 0, width: width, height: TranscriptUserCell.height(for: message.1, width: width, host: host))
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private func frames(in cell: TranscriptUserCell) -> (bubble: NSRect, buttons: [NSRect], time: NSRect, steer: NSRect?) {
        let bubble = cell.subviews.first { $0 is TranscriptBubbleView }?.frame ?? .zero
        let buttons = cell.subviews.compactMap { $0 as? TranscriptIconButton }.map(\.frame)
        let labels = cell.subviews.compactMap { $0 as? NSTextField }
        let steerTitle = String(localized: "Steer")
        let time = labels.first { $0.stringValue != steerTitle }
        let steer = labels.first { $0.stringValue == steerTitle && !$0.isHidden }
        return (bubble, buttons, time?.frame ?? .zero, steer?.frame)
    }

    @Test func theActionsAndSteerMarkLineUpWithTheCardsOuterEdge() {
        let message = message("Keep the timestamps under the card", steered: true)
        withUserMessageSide(.right) {
            let cell = cell(for: message, width: wide)
            let parts = frames(in: cell)
            let column = TranscriptMetrics.column(width: wide)
            #expect(parts.bubble.maxX == column.x + column.width)
            // Edit, copy, then the time, ending at the card's right edge.
            #expect(parts.time.maxX == parts.bubble.maxX)
            #expect(parts.buttons.count == 2)
            #expect(parts.buttons.allSatisfy { $0.maxX <= parts.time.minX && $0.minY >= parts.bubble.maxY })
            // The "Steer" mark ends just inside the card's right edge.
            #expect(parts.steer.map { $0.maxX <= parts.bubble.maxX && $0.maxX >= parts.bubble.maxX - 4 } == true)
            #expect(!cell.showsRailNode)
        }
        withUserMessageSide(.left) {
            let cell = cell(for: message, width: wide)
            let parts = frames(in: cell)
            #expect(parts.bubble.minX == TranscriptMetrics.column(width: wide).x)
            #expect(parts.buttons.map(\.minX).min() == parts.bubble.minX - 3)
            #expect(parts.time.minX > (parts.buttons.map(\.maxX).max() ?? 0))
            #expect(cell.showsRailNode)
        }
        withUserMessageSide(.right) {
            // Right to left: the card on the left, the time first from the right, so leftmost under the card's edge.
            let cell = cell(for: message, width: wide, direction: .rightToLeft)
            let parts = frames(in: cell)
            #expect(parts.bubble.minX == TranscriptMetrics.column(width: wide).x)
            #expect(parts.time.minX == parts.bubble.minX)
            #expect(parts.buttons.allSatisfy { $0.minX >= parts.time.maxX })
            #expect(cell.showsRailNode)
        }
    }

    /// The row's first action is a pencil that does what the message's "Edit from Here…" menu item does, under the
    /// same rule: not while a turn runs.
    @Test func thePencilEditsFromTheMessageLikeTheMenuItem() throws {
        let message = message("Rename the setting")
        let buttons = withUserMessageSide(.right) { cell(for: message, width: wide).subviews.compactMap { $0 as? TranscriptIconButton } }
        #expect(buttons.map(\.symbolName) == ["pencil", "doc.on.doc"])
        let edit = try #require(buttons.first)
        #expect(edit.accessibilityLabel() == String(localized: "Edit from here"))
        #expect(edit.toolTip == String(localized: "Edit from here"))
        #expect(edit.isEnabled)
        edit.performClick(nil)
        #expect(host.rewound == [message.0.id])

        host.isRunning = true
        defer { host.isRunning = false }
        let running = withUserMessageSide(.right) { cell(for: message, width: wide).subviews.compactMap { $0 as? TranscriptIconButton } }
        let disabled = try #require(running.first)
        #expect(!disabled.isEnabled)
        disabled.performClick(nil)
        #expect(host.rewound == [message.0.id])
    }
}

/// Changing Settings › General › Your messages moves the open thread's messages at once. The main window is laid out
/// without ever being ordered in: it stays transparent and far offscreen, so nothing shows.
@MainActor @Suite(.serialized) struct UserMessageSideLiveSwitchTests {
    private static func subviews<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + subviews(of: $0, as: type) }
    }

    @Test func switchingTheSettingMovesTheOpenThreadsMessages() async throws {
        let saved = UIState.shared.values
        let folder = TemporaryDirectory("user-message-side")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let threadID = store.createThread(in: project.id).id
        store.append(TranscriptItem(kind: .user, text: "Put my messages on the right"), to: threadID)
        store.append(TranscriptItem(kind: .assistant, text: "Done: they sit across from my replies now.", provider: .claude), to: threadID)
        UIState.shared.update {
            $0.isInspectorOpen = false
            $0.isTerminalOpen = false
            $0.windowFrame = nil
        }
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.alphaValue = 0
        defer {
            #expect(!window.isVisible, "the test put the window on screen")
            window.close()
            store.removeProject(project.id)
            UIState.shared.update { $0 = saved }
        }
        try withUserMessageSide(.right) {
            controller.open(threadID)
            window.setFrame(NSRect(x: -20000, y: -20000, width: 1300, height: 800), display: false)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
        }
        try? await Task.sleep(for: .milliseconds(300))

        func cardFrame() throws -> (card: NSRect, cell: NSRect) {
            let root = try #require(window.contentView?.superview)
            root.layoutSubtreeIfNeeded()
            let cell = try #require(Self.subviews(of: root, as: TranscriptUserCell.self).first { !$0.isHiddenOrHasHiddenAncestor })
            cell.layoutSubtreeIfNeeded()
            let bubble = try #require(cell.subviews.first { $0 is TranscriptBubbleView })
            return (bubble.frame, cell.bounds)
        }
        try withUserMessageSide(.right) {
            let (card, cell) = try cardFrame()
            let column = TranscriptMetrics.column(width: cell.width)
            #expect(card.maxX == column.x + column.width)
        }
        // The switch applies right away, without reopening the thread.
        try withUserMessageSide(.left) {
            let (card, cell) = try cardFrame()
            #expect(card.minX == TranscriptMetrics.column(width: cell.width).x)
            #expect(card.maxX < TranscriptMetrics.column(width: cell.width).x + TranscriptMetrics.column(width: cell.width).width)
        }
        try withUserMessageSide(.right) {
            let (card, cell) = try cardFrame()
            let column = TranscriptMetrics.column(width: cell.width)
            #expect(card.maxX == column.x + column.width)
        }
    }
}
