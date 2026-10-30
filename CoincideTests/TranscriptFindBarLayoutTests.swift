import AppKit
import Testing

@testable import Coincide

/// The find bar's field keeps the magnifying glass, the text (with its caret) and the clear button apart. Set
/// `COINCIDE_FIND_BAR_PNG_DIR` (`TEST_RUNNER_COINCIDE_FIND_BAR_PNG_DIR` through xcodebuild) to also write the bar as PNGs.
@MainActor struct TranscriptFindBarLayoutTests {
    private final class Harness {
        let window: NSWindow
        let bar = TranscriptFindBar()

        init() {
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: TranscriptFindBar.width + 20, height: 54),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.alphaValue = 0
            window.isReleasedWhenClosed = false
            bar.frame = NSRect(x: 10, y: 10, width: TranscriptFindBar.width, height: 34)
            window.contentView?.addSubview(bar)
            bar.layoutSubtreeIfNeeded()
        }
    }

    @Test func theTextStartsAfterTheMagnifyingGlassAndEndsBeforeTheClearButton() throws {
        let harness = Harness()
        let field = harness.bar.field
        let cell = try #require(field.cell as? TranscriptFindSearchFieldCell)
        let bounds = field.bounds
        #expect(bounds.width > 100)
        let glass = cell.searchButtonRect(forBounds: bounds)
        let clear = cell.cancelButtonRect(forBounds: bounds)
        let text = cell.searchTextRect(forBounds: bounds)
        let drawn = cell.drawingRect(forBounds: bounds)
        #expect(text.minX >= glass.maxX + 4)
        #expect(text.maxX <= clear.minX - 4)
        #expect(drawn.minX == text.minX && drawn.maxX == text.maxX)
        #expect(abs(drawn.midY - bounds.midY) <= 1)
    }

    @Test func theCaretSitsInTheTextColumnWhileTyping() throws {
        let harness = Harness()
        harness.bar.focus()
        let editor = try #require(harness.bar.field.currentEditor() as? NSTextView)
        let cell = try #require(harness.bar.field.cell as? TranscriptFindSearchFieldCell)
        let glass = cell.searchButtonRect(forBounds: harness.bar.field.bounds)
        let editorFrame = harness.bar.field.convert(editor.enclosingScrollView?.frame ?? editor.frame, from: editor.enclosingScrollView?.superview ?? editor.superview)
        #expect(editorFrame.minX >= glass.maxX + 4)
        try render(harness, "focused-empty")
        harness.bar.setQuery("passkey")
        try render(harness, "focused-query")
        harness.window.close()
    }

    @Test func rendersThePlaceholder() throws {
        try render(Harness(), "placeholder")
    }

    private func render(_ harness: Harness, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_FIND_BAR_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            harness.window.appearance = NSAppearance(named: appearance)
            let root = try #require(harness.window.contentView)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
            try #require(rep.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
