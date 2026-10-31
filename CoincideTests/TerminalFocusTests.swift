import AppKit
import CoincideKit
import Metal
import Testing

@testable import Coincide

/// Keyboard focus in the terminal, with GPU rendering on and off: a click anywhere in it, opening the panel, switching
/// and closing tabs and switching threads give the terminal focus, so typing and its shortcuts (⌘T, ⌘W) reach it at
/// once. Windows are borderless, transparent, far offscreen and never ordered in. The tests share the serialized suite
/// of `InspectorPanelButtonsTests`, whose window harness some of them use: they all change the shared GPU rendering
/// setting.
@MainActor enum TerminalFocus {
    /// Reports itself key, as the window the user clicks in is, so AppKit treats clicks as it does there and the
    /// terminal's caret shows whether it has focus. It never becomes key or shows.
    final class KeyWindow: NSWindow {
        var isKey = true
        override var isKeyWindow: Bool { isKey }

        init(size: NSSize) {
            super.init(
                contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
                backing: .buffered, defer: false)
            alphaValue = 0
            isReleasedWhenClosed = false
        }
    }

    /// Stands in for the composer and other views that take focus on a click, without a text view's tracking loop.
    final class FocusTarget: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    static func withGPU<T>(_ on: Bool, _ body: () async throws -> T) async rethrows -> T {
        let saved = AppStore.shared.settings.terminalGPURendering
        AppStore.shared.updateSettings { $0.terminalGPURendering = on }
        defer { AppStore.shared.updateSettings { $0.terminalGPURendering = saved } }
        return try await body()
    }

    /// Checks the terminal draws the way the setting asks, so each case really covers its renderer.
    static func expectRenderer(_ terminal: ShellTerminalView, gpu: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let metal = gpu && MTLCreateSystemDefaultDevice() != nil
        #expect(terminal.isUsingMetalRenderer == metal, sourceLocation: sourceLocation)
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Presses the mouse at `point` in `view`'s coordinates, drags it through `path` and lets go, as `NSWindow` handles
    /// a press in the key window: the view under the pointer takes focus if it accepts it, then gets the press and
    /// everything after it. (`NSWindow.sendEvent` ignores mouse events in a window that isn't on screen.)
    static func press(_ view: NSView, at point: NSPoint, dragTo path: [NSPoint] = []) {
        let window = view.window!
        let content = window.contentView!
        let location = view.convert(point, to: nil)
        guard let hit = content.hitTest(content.superview?.convert(location, from: nil) ?? location) else {
            Issue.record("nothing under the pointer")
            return
        }
        if hit !== window.firstResponder, hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
        hit.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        for step in path { hit.mouseDragged(with: mouse(.leftMouseDragged, at: step, in: view)) }
        hit.mouseUp(with: mouse(.leftMouseUp, at: path.last ?? point, in: view))
    }

    /// A left click at `point` in `view`'s coordinates, its middle by default.
    static func click(_ view: NSView, at point: NSPoint? = nil) {
        press(view, at: point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    /// Types a key, as the window passes one the menu bar didn't take to its first responder.
    static func type(_ event: NSEvent, in window: NSWindow) {
        window.firstResponder?.keyDown(with: event)
    }

    /// A point inside a terminal's text, clear of the scroller at its right edge.
    static func textPoint(in terminal: ShellTerminalView) -> NSPoint {
        NSPoint(x: terminal.bounds.width * 0.3, y: terminal.bounds.midY)
    }

    static func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!
    }

    static func newTabKey(in window: NSWindow) -> NSEvent { key("t", keyCode: 17, flags: .command, in: window) }
    static func closeKey(in window: NSWindow) -> NSEvent { key("w", keyCode: 13, flags: .command, in: window) }

    static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + descendants(of: $0, as: type) }
    }

    static func bufferText(_ terminal: ShellTerminalView) -> String {
        String(decoding: terminal.getBufferAsData(), as: UTF8.self)
    }

    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// One pane, as a thread's terminal shows it, above a stand-in for the composer, which has focus to begin with.
    final class PaneFixture {
        let window = KeyWindow(size: NSSize(width: 720, height: 360))
        let terminal = ShellTerminalView(font: Theme.monoFont)
        let pane: TerminalPaneView
        let composer = FocusTarget()

        init() {
            pane = TerminalPaneView(terminalView: terminal)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
            composer.frame = NSRect(x: 0, y: 0, width: 720, height: 60)
            pane.frame = NSRect(x: 0, y: 60, width: 720, height: 300)
            root.addSubview(composer)
            root.addSubview(pane)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            window.makeFirstResponder(composer)
        }

        var textPoint: NSPoint { TerminalFocus.textPoint(in: terminal) }

        func close() {
            #expect(!window.isVisible, "a test put the window on screen")
            if terminal.process.running { terminal.terminate() }
            window.close()
        }
    }

    /// The terminal panel alone in a window, on a thread of its own, above a stand-in for the composer. As when the
    /// window opens with the panel showing, it starts a terminal and leaves focus with the composer. Shells start as in
    /// the app.
    final class PanelFixture {
        let folder = TemporaryDirectory("terminal-focus")
        let store = AppStore.shared
        let projectID: UUID
        let threadID: UUID
        let window = KeyWindow(size: NSSize(width: 900, height: 480))
        let controller = TerminalViewController()
        let composer = FocusTarget()

        init() {
            let project = store.addProject(at: folder.url)
            projectID = project.id
            threadID = store.createThread(in: project.id).id
            controller.threadID = threadID
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 480))
            composer.frame = NSRect(x: 0, y: 0, width: 900, height: 60)
            controller.view.frame = NSRect(x: 0, y: 60, width: 900, height: 420)
            root.addSubview(composer)
            root.addSubview(controller.view)
            window.contentView = root
            window.makeFirstResponder(composer)
        }

        var terminals: ThreadTerminals { TerminalSessionManager.shared.terminals(for: threadID) }
        var activeTerminal: ShellTerminalView? { terminals.activeSession?.terminalView }

        /// Lets the panel's queued visibility check and layout run.
        func settle() async {
            try? await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func tabItems() -> [TerminalTabItemView] {
            TerminalFocus.descendants(of: controller.view, as: TerminalTabItemView.self)
        }

        func close() {
            #expect(!window.isVisible, "a test put the window on screen")
            terminals.closeAll()
            window.close()
            store.removeProject(projectID)
        }
    }
}

// MARK: - One pane

/// Clicks, typing and shortcuts in one pane.
extension InspectorPanelButtonsTests {
    @Test(arguments: [true, false])
    func aClickInTheTerminalFocusesIt(gpu: Bool) async {
        await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PaneFixture()
            defer { fixture.close() }
            TerminalFocus.expectRenderer(fixture.terminal, gpu: gpu)
            #expect(fixture.window.firstResponder === fixture.composer)
            #expect(!fixture.terminal.hasFocus)
            // The view under the pointer is the terminal itself, not the Metal surface drawing it, which refuses focus.
            let point = fixture.terminal.convert(fixture.textPoint, to: fixture.pane)
            #expect(fixture.pane.hitTest(point) === fixture.terminal)

            TerminalFocus.click(fixture.terminal, at: fixture.textPoint)
            #expect(fixture.window.firstResponder === fixture.terminal)
            // The caret follows: SwiftTerm draws it solid while the terminal has focus in the key window.
            #expect(fixture.terminal.hasFocus)
        }
    }

    @Test(arguments: [true, false])
    func aClickInThePanesMarginFocusesTheTerminal(gpu: Bool) async {
        await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PaneFixture()
            defer { fixture.close() }
            // The pane keeps a few points between its edges and the text.
            #expect(fixture.terminal.frame.minX > 4)
            TerminalFocus.click(fixture.pane, at: NSPoint(x: 3, y: fixture.pane.bounds.midY))
            #expect(fixture.window.firstResponder === fixture.terminal)
        }
    }

    @Test(arguments: [true, false])
    func clickingElsewhereStillTakesFocusAway(gpu: Bool) async {
        await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PaneFixture()
            defer { fixture.close() }
            TerminalFocus.click(fixture.terminal, at: fixture.textPoint)
            #expect(fixture.window.firstResponder === fixture.terminal)
            TerminalFocus.click(fixture.composer)
            #expect(fixture.window.firstResponder === fixture.composer)
            #expect(!fixture.terminal.hasFocus)
        }
    }

    @Test(arguments: [true, false])
    func typingAfterAClickReachesTheShell(gpu: Bool) async {
        await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PaneFixture()
            defer { fixture.close() }
            let terminal = fixture.terminal
            terminal.startProcess(executable: "/bin/cat", args: [], environment: ["PATH=/usr/bin:/bin"])
            TerminalFocus.click(terminal, at: fixture.textPoint)
            for (character, code) in [("o", UInt16(31)), ("k", 40), ("\r", 36)] {
                TerminalFocus.type(TerminalFocus.key(character, keyCode: code, in: fixture.window), in: fixture.window)
            }
            // The terminal echoes "ok", and cat, having read the line, prints it back.
            let echoed = { TerminalFocus.bufferText(terminal).components(separatedBy: "ok").count > 2 }
            await TerminalFocus.waitUntil(echoed)
            #expect(echoed(), "the keys didn't reach the shell")
        }
    }

    @Test(arguments: [true, false])
    func draggingStillSelectsText(gpu: Bool) async {
        await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PaneFixture()
            defer { fixture.close() }
            let terminal = fixture.terminal
            terminal.feed(text: "coincide focus selection\r\n")
            await TerminalFocus.waitUntil { TerminalFocus.bufferText(terminal).contains("selection") }
            // The first row, from its start to past the text.
            let row = terminal.isFlipped ? 8 : terminal.bounds.height - 8
            let end = NSPoint(x: terminal.bounds.width * 0.5, y: row)
            TerminalFocus.press(terminal, at: NSPoint(x: 2, y: row), dragTo: [NSPoint(x: end.x / 2, y: row), end])
            #expect(fixture.window.firstResponder === terminal)
            #expect(terminal.selectedText?.hasPrefix("coincide focus") == true, "selected \(terminal.selectedText ?? "nothing")")
        }
    }

    @Test(arguments: [true, false])
    func theExitBannerLeavesClicksToTheTerminal(gpu: Bool) async throws {
        try await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PaneFixture()
            defer { fixture.close() }
            fixture.pane.showExitBanner(message: "Process exited with code 1.")
            fixture.pane.layoutSubtreeIfNeeded()
            let banner = try #require(TerminalFocus.descendants(of: fixture.pane, as: FlatSurfaceView.self).first)
            // Above the banner, and on the banner's own padding beside its message.
            TerminalFocus.click(fixture.terminal, at: fixture.textPoint)
            #expect(fixture.window.firstResponder === fixture.terminal)
            fixture.window.makeFirstResponder(fixture.composer)
            TerminalFocus.click(banner, at: NSPoint(x: 4, y: banner.bounds.midY))
            #expect(fixture.window.firstResponder === fixture.terminal)
        }
    }

    /// AppKit keeps the first responder while the window is in the background; the caret goes hollow and comes back.
    @Test(arguments: [true, false])
    func focusSurvivesTheAppGoingToTheBackground(gpu: Bool) async {
        await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PaneFixture()
            defer { fixture.close() }
            TerminalFocus.click(fixture.terminal, at: fixture.textPoint)
            fixture.window.isKey = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
            #expect(!fixture.terminal.hasFocus)
            fixture.window.isKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
            #expect(fixture.window.firstResponder === fixture.terminal)
            #expect(fixture.terminal.hasFocus)
        }
    }

    @Test func theTerminalsShortcutsAreRoutedWhileItIsFirstResponder() {
        let fixture = TerminalFocus.PaneFixture()
        defer { fixture.close() }
        var commands: [String] = []
        fixture.terminal.onCommand = { commands.append("\($0)") }
        let newTab = TerminalFocus.newTabKey(in: fixture.window)
        let close = TerminalFocus.closeKey(in: fixture.window)
        #expect(newTab.window === fixture.window)
        // With focus elsewhere the keys go on to the menu bar as usual.
        #expect(TerminalKeyRouter.route(newTab) === newTab)
        #expect(commands.isEmpty)

        TerminalFocus.click(fixture.terminal, at: fixture.textPoint)
        #expect(TerminalKeyRouter.route(newTab) == nil)
        #expect(TerminalKeyRouter.route(close) == nil)
        #expect(commands == ["newTab", "close"])
    }
}

// MARK: - The panel

/// What has focus in the panel after a click, a new tab from ⌘T, a tab change, a closed tab or terminal and a thread
/// switch.
extension InspectorPanelButtonsTests {
    /// The panel showing as the window opens leaves the composer focused; a click in its terminal moves focus there.
    @Test(arguments: [true, false])
    func aClickInAnExistingTerminalFocusesIt(gpu: Bool) async throws {
        try await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PanelFixture()
            defer { fixture.close() }
            await fixture.settle()
            let terminal = try #require(fixture.activeTerminal, "the shown panel started no terminal")
            TerminalFocus.expectRenderer(terminal, gpu: gpu)
            #expect(fixture.window.firstResponder === fixture.composer)

            TerminalFocus.click(terminal, at: TerminalFocus.textPoint(in: terminal))
            #expect(fixture.window.firstResponder === terminal)
            #expect(terminal.hasFocus)
            // ⌘T works at once, and the new tab has focus.
            #expect(TerminalKeyRouter.route(TerminalFocus.newTabKey(in: fixture.window)) == nil)
            #expect(fixture.terminals.tabs.count == 2)
            #expect(fixture.activeTerminal !== terminal)
            #expect(fixture.window.firstResponder === fixture.activeTerminal)
        }
    }

    @Test(arguments: [true, false])
    func showingThePanelFocusesItsTerminal(gpu: Bool) async throws {
        try await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PanelFixture()
            defer { fixture.close() }
            await fixture.settle()
            // Hidden, as the drawer leaves it while collapsed, then shown again.
            fixture.controller.view.isHidden = true
            await fixture.settle()
            #expect(fixture.window.firstResponder === fixture.composer)
            fixture.controller.view.isHidden = false
            await fixture.settle()
            let terminal = try #require(fixture.activeTerminal)
            TerminalFocus.expectRenderer(terminal, gpu: gpu)
            #expect(fixture.window.firstResponder === terminal)
            #expect(terminal.hasFocus)
        }
    }

    @Test(arguments: [true, false])
    func clickingATabFocusesItsTerminal(gpu: Bool) async throws {
        try await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PanelFixture()
            defer { fixture.close() }
            await fixture.settle()
            let first = try #require(fixture.activeTerminal)
            fixture.terminals.addTab()
            await fixture.settle()
            fixture.window.makeFirstResponder(fixture.composer)
            let items = fixture.tabItems()
            try #require(items.count == 2)
            // On the tab's padding, beside its icon.
            TerminalFocus.click(items[0], at: NSPoint(x: 3, y: items[0].bounds.midY))
            await fixture.settle()
            #expect(fixture.activeTerminal === first)
            #expect(fixture.window.firstResponder === first)
            TerminalFocus.expectRenderer(first, gpu: gpu)
            // ⌘⇧[ and ⌘⇧] switch tabs from the terminal, keeping focus in it.
            let next = TerminalFocus.key("]", keyCode: 30, flags: [.command, .shift], in: fixture.window)
            #expect(TerminalKeyRouter.route(next) == nil)
            #expect(fixture.activeTerminal !== first)
            #expect(fixture.window.firstResponder === fixture.activeTerminal)
        }
    }

    @Test(arguments: [true, false])
    func closingATabFocusesTheNextTerminal(gpu: Bool) async throws {
        try await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PanelFixture()
            defer { fixture.close() }
            await fixture.settle()
            let first = try #require(fixture.activeTerminal)
            fixture.terminals.addTab()
            await fixture.settle()
            let second = try #require(fixture.activeTerminal)
            TerminalFocus.click(second, at: TerminalFocus.textPoint(in: second))
            #expect(fixture.window.firstResponder === second)

            // ⌘W in the terminal closes it, and the tab left takes focus.
            #expect(TerminalKeyRouter.route(TerminalFocus.closeKey(in: fixture.window)) == nil)
            await fixture.settle()
            #expect(fixture.terminals.tabs.count == 1)
            #expect(fixture.window.firstResponder === first)

            // So does a tab's close button, from wherever focus was.
            fixture.terminals.addTab()
            await fixture.settle()
            fixture.window.makeFirstResponder(fixture.composer)
            let items = fixture.tabItems()
            try #require(items.count == 2)
            let closeButton = try #require(TerminalFocus.descendants(of: items[1], as: NSButton.self).first)
            closeButton.performClick(nil)
            await fixture.settle()
            #expect(fixture.terminals.tabs.count == 1)
            #expect(fixture.window.firstResponder === first)
        }
    }

    /// A shell that exits closes its terminal, and focus passes to the tab left.
    @Test func aShellThatExitsPassesFocusOn() async throws {
        let fixture = TerminalFocus.PanelFixture()
        defer { fixture.close() }
        await fixture.settle()
        let first = try #require(fixture.activeTerminal)
        let session = fixture.terminals.addTab()
        await fixture.settle()
        TerminalFocus.click(session.terminalView, at: TerminalFocus.textPoint(in: session.terminalView))
        #expect(fixture.window.firstResponder === session.terminalView)
        await TerminalFocus.waitUntil(timeout: .seconds(10)) { session.state == .running }
        try #require(session.state == .running, "the shell did not start")
        session.run("exit")
        await TerminalFocus.waitUntil(timeout: .seconds(10)) { fixture.terminals.tabs.count == 1 }
        await fixture.settle()
        #expect(fixture.terminals.tabs.count == 1)
        #expect(fixture.window.firstResponder === first)
    }

    @Test(arguments: [true, false])
    func aThreadSwitchFocusesTheShownThreadsTerminal(gpu: Bool) async throws {
        try await TerminalFocus.withGPU(gpu) {
            let fixture = TerminalFocus.PanelFixture()
            defer { fixture.close() }
            await fixture.settle()
            let other = fixture.store.createThread(in: fixture.projectID).id
            let otherTerminals = TerminalSessionManager.shared.terminals(for: other)
            let otherTerminal = otherTerminals.addTab().terminalView
            defer { otherTerminals.closeAll() }

            // Focus is on something that isn't text, as after a click in the sidebar.
            fixture.controller.threadID = other
            await fixture.settle()
            #expect(fixture.window.firstResponder === otherTerminal)
            TerminalFocus.expectRenderer(otherTerminal, gpu: gpu)

            // And back, from the terminal.
            fixture.controller.threadID = fixture.threadID
            await fixture.settle()
            #expect(fixture.window.firstResponder === fixture.activeTerminal)
        }
    }

    /// Someone typing elsewhere, or moving through the sidebar with the arrow keys, keeps their focus.
    @Test func aThreadSwitchLeavesTypingAndKeyboardNavigationAlone() {
        let text = NSTextView()
        let list = NSOutlineView()
        let click = NSEvent.EventType.leftMouseDown
        let takesFocus = TerminalViewController.takesFocusOnThreadSwitch
        #expect(takesFocus(true, false, list, click))
        #expect(takesFocus(true, false, nil, nil))
        #expect(takesFocus(true, true, nil, .keyDown))
        #expect(!takesFocus(true, false, text, click))
        #expect(!takesFocus(true, false, list, .keyDown))
        #expect(!takesFocus(false, false, list, click))
    }

    /// The context menu acts on the pane it opened over, which takes focus.
    @Test func theContextMenuFocusesItsPane() async throws {
        let fixture = TerminalFocus.PanelFixture()
        defer { fixture.close() }
        await fixture.settle()
        let terminal = try #require(fixture.activeTerminal)
        let menu = try #require(terminal.contextMenu?())
        #expect(menu.items.contains { $0.title == String(localized: "Copy") })
        #expect(fixture.window.firstResponder === terminal)
    }
}

// MARK: - The window

/// The real window: the terminal below the chat or on the right takes focus as it opens, from the toggle and from the
/// toolbar button, and a thread switch with the terminal open focuses the new thread's terminal.
extension InspectorPanelButtonsTests {
    private func activeTerminal(_ harness: Harness, _ threadID: UUID? = nil) -> ShellTerminalView? {
        TerminalSessionManager.shared.terminals(for: threadID ?? harness.threadID).activeSession?.terminalView
    }

    @Test(arguments: [TerminalPlacement.bottom, .right], [true, false])
    func openingTheTerminalFocusesIt(placement: TerminalPlacement, gpu: Bool) async throws {
        try await TerminalFocus.withGPU(gpu) {
            let harness = Harness(terminal: placement)
            defer { harness.close() }
            await harness.wait()
            #expect(!(harness.window.firstResponder is ShellTerminalView))
            harness.split.toggleTerminalPanel()
            await harness.wait()
            let terminal = try #require(activeTerminal(harness), "opening the panel started no terminal")
            TerminalFocus.expectRenderer(terminal, gpu: gpu)
            #expect(harness.window.firstResponder === terminal)
            // Its shortcuts work right away.
            #expect(TerminalKeyRouter.route(TerminalFocus.newTabKey(in: harness.window)) == nil)
            await harness.wait()
            #expect(TerminalSessionManager.shared.terminals(for: harness.threadID).tabs.count == 2)
            #expect(harness.window.firstResponder === activeTerminal(harness))

            // Closing the panel hands focus back to the composer; opening it again focuses the terminal.
            harness.split.toggleTerminalPanel()
            await harness.wait()
            #expect(!(harness.window.firstResponder is ShellTerminalView))
            harness.split.toggleTerminalPanel()
            await harness.wait()
            #expect(harness.window.firstResponder === activeTerminal(harness))
        }
    }

    @Test func theToolbarButtonOpensTheTerminalFocused() async throws {
        let harness = Harness(terminal: .right)
        defer { harness.close() }
        await harness.wait()
        harness.buttons.terminalButton.performClick(nil)
        await harness.wait()
        let terminal = try #require(activeTerminal(harness))
        #expect(harness.window.firstResponder === terminal)
    }

    @Test func aThreadSwitchWithTheTerminalOpenFocusesItsTerminal() async throws {
        let harness = Harness()
        defer { harness.close() }
        await harness.wait()
        harness.split.toggleTerminalPanel()
        await harness.wait()
        let other = harness.store.createThread(in: harness.projectID).id
        let otherTerminals = TerminalSessionManager.shared.terminals(for: other)
        let otherTerminal = otherTerminals.addTab().terminalView
        defer { otherTerminals.closeAll() }

        // From the terminal.
        harness.controller.open(other)
        await harness.wait()
        #expect(harness.window.firstResponder === otherTerminal)

        // From the sidebar, as a click on a thread leaves it.
        let list = try #require(TerminalFocus.descendants(of: harness.controller.sidebar.view, as: NSOutlineView.self).first)
        harness.window.makeFirstResponder(list)
        harness.controller.open(harness.threadID)
        await harness.wait()
        #expect(harness.window.firstResponder === activeTerminal(harness))
    }
}
