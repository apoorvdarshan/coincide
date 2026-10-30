import AppKit
import Testing

@testable import Coincide

/// Double-clicking the window's top strip follows the system setting.
struct TitlebarDoubleClickTests {
    @Test func followsTheSystemSetting() {
        #expect(TitlebarDoubleClick.action(setting: nil, miniaturizes: false) == .zoom)
        #expect(TitlebarDoubleClick.action(setting: "Maximize", miniaturizes: false) == .zoom)
        #expect(TitlebarDoubleClick.action(setting: "Fill", miniaturizes: false) == .zoom)
        #expect(TitlebarDoubleClick.action(setting: "Minimize", miniaturizes: false) == .minimize)
        #expect(TitlebarDoubleClick.action(setting: "None", miniaturizes: true) == .none)
        #expect(TitlebarDoubleClick.action(setting: nil, miniaturizes: true) == .minimize)
    }

    @MainActor @Test func onlyTheTopStripOutsideControlsCounts() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        let content = try #require(window.contentView)
        let button = NSButton(frame: NSRect(x: 100, y: content.bounds.height - 20, width: 80, height: 18))
        content.addSubview(button)
        let top = window.contentLayoutRect.maxY
        #expect(TitlebarDoubleClick.handles(NSPoint(x: 300, y: top + 4), in: window))
        #expect(!TitlebarDoubleClick.handles(NSPoint(x: 300, y: top - 40), in: window))
        #expect(!TitlebarDoubleClick.handles(NSPoint(x: 120, y: content.bounds.height - 10), in: window))
    }
}
