import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Clicking a picture in the transcript opens it in Quick Look: an image attached to a message of the user's, and an
/// image an agent's reply shows. The clicks go through the window as a mouse does, down then up, so the table's own
/// tracking of a click (it selects the row) gets its say. The window is transparent and far offscreen.
@MainActor @Suite(.serialized) struct TranscriptClickTests {
    private let host = StubTranscriptHost()
    private let list = TranscriptListController()
    private let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)

    init() {
        list.host = host
        window.contentView = list.scrollView
        window.alphaValue = 0
        window.orderBack(nil)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    private static func writePNG(to url: URL, width: Int, height: Int) throws {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { subview in ((subview as? T).map { [$0] } ?? []) + descendants(of: subview, type) }
    }

    /// A click at the middle of `view`: the mouse goes down there and comes up there.
    private func click(_ view: NSView) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Queued first, as the mouse-up would be by the time the window handles the mouse-down: whoever tracks the
        // click (a control, the table selecting the row) takes it from the queue.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }

    @Test func clickingAnAttachedImageOrAShownImageOpensItInQuickLook() async throws {
        let folder = TemporaryDirectory("transcript-click")
        let attached = folder.url.appendingPathComponent("attached.png")
        let shown = folder.url.appendingPathComponent("shown.png")
        try Self.writePNG(to: attached, width: 800, height: 600)
        try Self.writePNG(to: shown, width: 1200, height: 700)
        let message = TranscriptItem(kind: .user, text: "Why does this look off?", attachments: [attached.path])
        let reply = TranscriptItem(kind: .assistant, text: "Here it is fixed:\n\n![Fixed](\(shown.path))", status: .completed, provider: .claude)
        host.items[message.id] = message
        host.items[reply.id] = reply
        let rows = [
            TranscriptRow(id: .item(message.id), kind: .user, revision: 0),
            TranscriptRow(id: .item(reply.id), kind: .assistant(meta: nil), revision: 0),
        ]
        list.update(rows, reload: true)
        list.restore(.anchor(rows[0].id, offset: 0))
        for _ in 0..<20 { await settle() }

        let thumbnail = try #require(descendants(of: list.tableView, TranscriptThumbnailView.self).first)
        click(thumbnail)
        #expect(host.previewed.map(\.paths) == [[attached.path]], "the attached image didn't open")

        let card = try #require(descendants(of: list.tableView, TranscriptMediaView.self).first { $0.media.kind == .image })
        let picture = try #require(descendants(of: card, NSImageView.self).first)
        click(picture)
        #expect(host.previewed.map(\.paths).last == [shown.path], "the shown image didn't open")
        #expect(host.previewed.count == 2)
    }
}
