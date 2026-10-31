import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Hovering and selecting messages: a click selects a row without drawing anything over the conversation, the keyboard
/// shows its selection as a focus ring around the message, and the actions under a user's message fade in without
/// moving anything. The table sits in a transparent window far offscreen, so nothing shows.
@MainActor @Suite(.serialized) struct TranscriptHoverTests {
    private let host = StubTranscriptHost()
    private let list = TranscriptListController()
    private let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
    private let rows: [TranscriptRow]
    private let userRow: Int

    init() async throws {
        list.host = host
        window.contentView = list.scrollView
        window.alphaValue = 0
        window.orderBack(nil)
        let items = [
            TranscriptItem(kind: .assistant, text: "Here is the plan.", status: .completed, provider: .claude),
            TranscriptItem(kind: .user, text: "Make the hover quieter"),
            TranscriptItem(kind: .assistant, text: "Done.", status: .completed, provider: .claude),
        ]
        for item in items { host.items[item.id] = item }
        rows = TranscriptBuilder(items: items).build()
        userRow = try #require(rows.firstIndex { if case .user = $0.kind { true } else { false } })
        list.update(rows, reload: true)
        try? await Task.sleep(for: .milliseconds(60))
        window.layoutIfNeeded()
    }

    private var table: TranscriptTableView { list.tableView }

    private func userCell() throws -> TranscriptUserCell {
        try #require(table.view(atColumn: 0, row: userRow, makeIfNecessary: true) as? TranscriptUserCell)
    }

    private func rowView(_ row: Int) throws -> TranscriptRowView {
        let view = try #require(table.rowView(atRow: row, makeIfNecessary: true) as? TranscriptRowView)
        // Emphasized, as when the transcript has focus in the key window.
        view.isEmphasized = true
        return view
    }

    private func arrow(_ keyCode: UInt16, _ key: Int) -> NSEvent {
        let characters = String(UnicodeScalar(UInt32(key))!)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private var hoverEvent: NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    @Test func aClickSelectsTheRowWithoutDrawingOverTheConversation() throws {
        defer { window.close() }
        // What a click on a message's card does to the table.
        table.selectRowIndexes([userRow], byExtendingSelection: false)
        #expect(table.selectedRow == userRow)
        #expect(!table.showsSelection)
        #expect(try rowView(userRow).focusRing == nil)
        let cell = try userCell()
        #expect(!cell.isRowSelected)
        #expect(!cell.showsActions)
    }

    @Test func theKeyboardRingsTheMessagesCardNotTheWholeRow() throws {
        defer { window.close() }
        table.selectRowIndexes([userRow - 1], byExtendingSelection: false)
        table.keyDown(with: arrow(125, NSDownArrowFunctionKey))
        #expect(table.selectedRow == userRow)
        #expect(table.showsSelection)
        let cell = try userCell()
        #expect(cell.isRowSelected)
        #expect(cell.showsActions)
        let view = try rowView(userRow)
        let ring = try #require(view.focusRing)
        let card = view.convert(try #require(cell.selectionHighlight).rect, from: cell)
        // Along the card's edge, just inside it so its top never clips, and far narrower than the transcript column.
        let stroke = TranscriptRowView.ringWidth
        #expect(card.contains(ring.rect))
        #expect(abs(ring.rect.minX - card.minX - stroke / 2) < 0.5 && abs(card.maxX - ring.rect.maxX - stroke / 2) < 0.5)
        #expect(abs(ring.rect.minY - card.minY - stroke / 2) < 0.5 && abs(card.maxY - ring.rect.maxY - stroke / 2) < 0.5)
        #expect(ring.rect.width < TranscriptMetrics.column(width: view.bounds.width).width)
        #expect(ring.cornerRadius == 12 - stroke / 2)

        // A row without a card of its own is ringed around the transcript column.
        table.keyDown(with: arrow(125, NSDownArrowFunctionKey))
        let next = try rowView(userRow + 1)
        let column = TranscriptMetrics.column(width: next.bounds.width)
        let columnRing = try #require(next.focusRing)
        #expect(columnRing.rect.minX < column.x && columnRing.rect.maxX > column.x + column.width)
        #expect(try !userCell().isRowSelected)
    }

    @Test(.timeLimit(.minutes(1))) func aClickAfterTheKeyboardHidesTheSelectionAgain() throws {
        defer { window.close() }
        table.selectRowIndexes([userRow - 1], byExtendingSelection: false)
        table.keyDown(with: arrow(125, NSDownArrowFunctionKey))
        #expect(table.showsSelection)
        let point = table.convert(NSPoint(x: table.rect(ofRow: userRow).midX, y: table.rect(ofRow: userRow).midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // The table tracks the click until the button comes up; the release is already waiting.
        window.postEvent(mouse(.leftMouseUp), atStart: false)
        table.mouseDown(with: mouse(.leftMouseDown))
        #expect(!table.showsSelection)
        #expect(try rowView(table.selectedRow).focusRing == nil)
        #expect(try !userCell().isRowSelected)
    }

    @Test func hoverFadesTheActionsInWithoutMovingAnything() throws {
        defer { window.close() }
        let cell = try userCell()
        cell.layoutSubtreeIfNeeded()
        let actions = cell.subviews.filter { $0 is TranscriptIconButton || ($0 is NSTextField && $0.alphaValue == 0) }
        #expect(actions.count >= 3)
        #expect(actions.allSatisfy { $0.alphaValue == 0 })
        let frames = cell.subviews.map(\.frame)
        let height = TranscriptUserCell.height(for: rows[userRow], width: cell.bounds.width, host: host)
        cell.mouseEntered(with: hoverEvent)
        #expect(cell.showsActions)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.subviews.map(\.frame) == frames)
        #expect(TranscriptUserCell.height(for: rows[userRow], width: cell.bounds.width, host: host) == height)
        cell.mouseExited(with: hoverEvent)
        #expect(!cell.showsActions)
    }

    @Test func iconButtonsLightUpUnderThePointerOnlyWhenTheyWork() {
        defer { window.close() }
        let button = TranscriptIconButton(symbol: "doc.on.doc", label: "Copy", action: nil, target: nil)
        #expect(button.contentTintColor == .secondaryLabelColor)
        button.mouseEntered(with: hoverEvent)
        #expect(button.isHovered)
        #expect(button.contentTintColor == .labelColor)
        button.mouseExited(with: hoverEvent)
        #expect(!button.isHovered)
        #expect(button.contentTintColor == .secondaryLabelColor)

        button.mouseEntered(with: hoverEvent)
        button.isEnabled = false
        #expect(!button.isHovered)
        button.mouseEntered(with: hoverEvent)
        #expect(!button.isHovered)
        // The pencil's thin stroke draws a little larger to sit level with the copy symbol beside it.
        #expect(TranscriptIconButton.pointSize(for: "pencil") > TranscriptIconButton.pointSize(for: "doc.on.doc"))
    }
}
