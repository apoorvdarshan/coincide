import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Opening a thread from the sidebar, as `MainWindowController.open` does through `ChatViewController.threadID`: the
/// latest messages show in the first frame after the switch, drawn edge to edge and at the bottom, with no scroll
/// from the reader and no wait. Heights that settle afterwards (pictures' shapes read in the background, rows measured
/// as they come into view) keep the view at the bottom. The chat runs in a transparent window far offscreen.
@MainActor @Suite(.serialized) struct ChatThreadSwitchTests {
    private let store = AppStore.shared
    private let folder = TemporaryDirectory("thread-switch")

    /// A PNG `width` by `height` pixels.
    private static func writePNG(to url: URL, width: Int, height: Int) throws {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// A long thread like the ones people keep open for days: hundreds of turns, work folded under "Worked for…",
    /// replies with tables and code, and screenshots shown inline in many of them.
    private func longThread(in project: Project, turns: Int, images: [String]) -> UUID {
        let id = store.createThread(in: project.id).id
        let paragraph = "The change keeps every row where the table lays it out, so nothing is left blank or drawn twice. "
        for turn in 0..<turns {
            store.append(TranscriptItem(kind: .user, text: "Question \(turn): what changed?"), to: id)
            store.append(TranscriptItem(kind: .reasoning, text: "Looking at turn \(turn).", status: .completed, provider: .claude), to: id)
            store.append(TranscriptItem(kind: .tool, text: "ok", title: "Run", category: .command, status: .completed, provider: .claude), to: id)
            var reply = "## Turn \(turn)\n\n" + String(repeating: paragraph, count: 1 + turn % 5) + "\n\n"
            if turn % 3 == 0 { reply += "```swift\nlet rows = builder.build()\nprint(rows.count)\n```\n\n" }
            if turn % 4 == 1 { reply += "| Row | Height |\n|---|---|\n| 1 | 40 |\n| 2 | 80 |\n\n" }
            if turn % 2 == 0 { reply += "![Screenshot \(turn)](\(images[turn % images.count]))\n\n" }
            reply += "Done."
            store.append(
                TranscriptItem(kind: .assistant, text: reply, status: .completed, provider: .claude, completedAt: Date()), to: id)
        }
        return id
    }

    private func transcriptTable(in view: NSView) -> TranscriptTableView? {
        if let table = view as? TranscriptTableView { return table }
        for subview in view.subviews {
            if let table = transcriptTable(in: subview) { return table }
        }
        return nil
    }

    /// The rows the reader sees, top to bottom.
    private func rowsOnScreen(_ list: TranscriptListController) -> [(index: Int, frame: NSRect)] {
        let visible = list.scrollView.contentView.documentVisibleRect
        var shown: [(index: Int, frame: NSRect)] = []
        list.tableView.enumerateAvailableRowViews { rowView, index in
            guard !rowView.isHidden, rowView.frame.intersects(visible) else { return }
            shown.append((index, rowView.frame))
        }
        return shown.sorted { $0.index < $1.index }
    }

    /// The latest messages are on screen at the bottom, drawn edge to edge by consecutive rows where the table lays
    /// them out, and the reader is following.
    private func expectLatestShown(_ list: TranscriptListController, _ comment: Comment) {
        let table = list.tableView
        let visible = list.scrollView.contentView.documentVisibleRect
        let shown = rowsOnScreen(list)
        #expect(!list.rows.isEmpty, "\(comment): no rows")
        #expect(!shown.isEmpty, "\(comment): nothing on screen at \(Int(visible.minY))…\(Int(visible.maxY)) of \(Int(table.frame.height))")
        #expect(list.isPinnedToBottom, "\(comment): not following")
        #expect(list.distanceFromBottom <= 1, "\(comment): \(Int(list.distanceFromBottom)) from the bottom")
        guard let first = shown.first, let last = shown.last else { return }
        #expect(last.index == list.rows.count - 1, "\(comment): the last row on screen is \(last.index) of \(list.rows.count)")
        let lastRect = table.rect(ofRow: list.rows.count - 1)
        #expect(abs(lastRect.maxY - table.frame.height) < 0.5, "\(comment): the table runs \(Int(table.frame.height - lastRect.maxY)) past its last row")
        if first.index > 0 { #expect(first.frame.minY <= visible.minY + 0.5, "\(comment): a gap above row \(first.index)") }
        #expect(last.frame.maxY >= min(visible.maxY, table.frame.height) - 0.5, "\(comment): a gap below row \(last.index)")
        for (above, below) in zip(shown, shown.dropFirst()) {
            #expect(below.index == above.index + 1, "\(comment): rows \(above.index + 1)…\(below.index - 1) missing")
            #expect(abs(below.frame.minY - above.frame.maxY) < 0.5, "\(comment): \(Int(below.frame.minY - above.frame.maxY)) between rows \(above.index) and \(below.index)")
        }
        for entry in shown {
            #expect(abs(entry.frame.minY - table.rect(ofRow: entry.index).minY) < 0.5, "\(comment): row \(entry.index) drawn away from its place")
        }
    }

    @Test func switchingBetweenLongThreadsShowsTheLatestMessagesInTheFirstFrame() async throws {
        var images: [String] = []
        for (index, size) in [(1600, 1000), (600, 1300), (1200, 800), (300, 300), (2400, 600)].enumerated() {
            let url = folder.url.appendingPathComponent("shot-\(index)-\(UUID().uuidString).png")
            try Self.writePNG(to: url, width: size.0, height: size.1)
            images.append(url.path)
        }
        let project = store.addProject(at: folder.url)
        defer { store.removeProject(project.id) }
        let first = longThread(in: project, turns: 260, images: images)
        let second = longThread(in: project, turns: 200, images: Array(images.reversed()))
        let chat = ChatViewController()
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = chat.view
        window.orderBack(nil)
        defer {
            chat.threadID = nil
            window.orderOut(nil)
        }
        func frame() {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        func settle(_ seconds: Double = 0.6, check: ((String) -> Void)? = nil) async {
            let end = Date().addingTimeInterval(seconds)
            var step = 0
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(25))
                frame()
                check?("step \(step)")
                step += 1
            }
        }
        frame()
        await settle()

        var timings: [String] = []
        for (name, id) in [("first", first), ("second", second), ("first again", first), ("second again", second)] {
            let start = CFAbsoluteTimeGetCurrent()
            chat.threadID = id
            frame()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            timings.append("\(name) \(Int(elapsed)) ms")
            let table = try #require(transcriptTable(in: chat.view))
            let list = try #require(table.delegate as? TranscriptListController)
            // The very first frame after the switch, before anything asynchronous ran.
            expectLatestShown(list, "\(name), first frame")
            // As pictures' shapes come in and rows on screen measure exactly, the reader stays at the latest.
            await settle { step in expectLatestShown(list, "\(name), settling \(step)") }
        }
        print("ChatThreadSwitchTests open to first content: \(timings.joined(separator: ", "))")

        // Scrolled up in one thread, the other still opens at its latest messages.
        let table = try #require(transcriptTable(in: chat.view))
        let list = try #require(table.delegate as? TranscriptListController)
        let clip = list.scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.minY - 3000))
        list.scrollView.reflectScrolledClipView(clip)
        list.scrollView.onReaderScroll?(true)
        await settle(0.2)
        #expect(!list.isPinnedToBottom)
        chat.threadID = first
        frame()
        expectLatestShown(list, "first, opened from a thread scrolled up")
        await settle { step in expectLatestShown(list, "first, from a thread scrolled up, settling \(step)") }
    }
}
