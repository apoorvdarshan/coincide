import AppKit
import CoincideKit
import Testing
import WebKit
@testable import Coincide

/// Tabs, headless: WebKit views live in the never-shown parking window, and the panel is tested in a borderless,
/// fully transparent window far off screen that is never ordered in or activated.
@MainActor @Suite(.serialized) struct BrowserTabsTests {
    static let opener = """
        <!doctype html><meta charset=utf-8><title>Opener</title>
        <a id=blank href="/child" target="_blank">child</a>
        <button id=pop onclick="window.open('/popup')">pop</button>
        """

    @Test func eachThreadHasItsOwnTabs() async throws {
        let harness = BrowserProfileTests.Harness()
        do {
            let first = harness.sessions.session(for: UUID()), second = harness.sessions.session(for: UUID())
            #expect(first.tabs.count == 1 && second.tabs.count == 1)
            let added = try #require(first.newTab(URL(string: "http://127.0.0.1:9/")))
            #expect(first.tabs.count == 2 && first.activeTab === added && second.tabs.count == 1)
            first.selectTab(offset: 1)
            #expect(first.activeTab === first.tabs[0])
            // Closing the last tab leaves an empty one: the browser never has none.
            let only = second.activeTab.id
            second.closeTab(only)
            #expect(second.tabs.count == 1 && second.activeTab.id != only && second.activeTab.url == nil)
            for _ in 0..<30 { first.newTab() }
            #expect(first.tabs.count == PreviewCommand.tabLimit)
            #expect(first.newTab() == nil)
        }
        await harness.tearDown()
    }

    @Test func agentsListOpenSelectAndCloseTabsOfTheirThreadOnly() async throws {
        let page = try await LoopbackPage.start(title: "Opener", html: Self.opener)
        defer { page.stop() }
        let harness = BrowserProfileTests.Harness()
        do {
            let id = UUID(), other = UUID()
            try await harness.sessions.enableAccess(for: id)
            try await harness.sessions.enableAccess(for: other)
            let client = BridgeClient(try #require(harness.sessions.bridge.access(for: id)))
            let otherClient = BridgeClient(try #require(harness.sessions.bridge.access(for: other)))
            _ = try await client.send(["action": "navigate", "url": .string(page.url.absoluteString)])
            let session = try #require(harness.sessions.existingSession(for: id))
            try await waitFor { session.webView.title == "Opener" && !session.webView.isLoading }

            let opened = try await client.send(["action": "new-tab", "url": .string(page.url.appendingPathComponent("second").absoluteString)])
            let secondID = try #require(opened["tab"]?.string)
            var tabs = try await client.send(["action": "tabs"])["tabs"]?.array ?? []
            #expect(tabs.count == 2 && tabs.last?["id"]?.string == secondID && tabs.last?["active"]?.bool == true)
            // Commands can name a background tab.
            let firstID = try #require(tabs.first?["id"]?.string)
            try await waitFor { session.tab(firstID)?.isLoading == false }
            let background = try await client.send(["action": "read", "tab": .string(firstID)])
            #expect(background["title"]?.string == "Opener" && background["tab"]?.string == firstID)
            #expect(session.activeTab.id == secondID)

            // The other thread can't reach these tabs.
            let foreign = try await otherClient.send(["action": "close-tab", "tab": .string(secondID)])
            #expect(foreign["error"] != nil)
            #expect(session.tabs.count == 2)

            _ = try await client.send(["action": "select-tab", "tab": .string(firstID)])
            #expect(session.activeTab.id == firstID)
            _ = try await client.send(["action": "close-tab", "tab": .string(secondID)])
            tabs = try await client.send(["action": "tabs"])["tabs"]?.array ?? []
            #expect(tabs.map { $0["id"]?.string } == [firstID])
            #expect(try await client.send(["action": "select-tab", "tab": "tab-99"])["error"] != nil)

            // target=_blank and window.open open new tabs in the same thread.
            _ = try await client.send(["action": "click", "selector": "#blank"])
            try await waitFor { session.tabs.count == 2 }
            #expect(session.activeTab.id != firstID)
            try await waitFor { session.activeTab.url?.path == "/child" }
            _ = try await client.send(["action": "click", "selector": "#pop", "tab": .string(firstID)])
            try await waitFor { session.tabs.count == 3 }
            try await waitFor { session.activeTab.url?.path == "/popup" }
            #expect(harness.sessions.existingSession(for: other)?.tabs.count == 1)
        }
        await harness.tearDown()
    }

    @Test func tabsAreRememberedAndBackgroundTabsUnload() async throws {
        let harness = BrowserProfileTests.Harness()
        let id = UUID()
        do {
            let session = harness.sessions.session(for: id)
            try session.navigate("http://127.0.0.1:9/a")
            session.newTab(URL(string: "http://127.0.0.1:9/b"))
            session.newTab(URL(string: "http://127.0.0.1:9/c"))
            session.select(session.tabs[1])
            let saved = try #require(UIState.shared.values.previewTabs[id.uuidString])
            #expect(saved.urls == ["http://127.0.0.1:9/a", "http://127.0.0.1:9/b", "http://127.0.0.1:9/c"])
            #expect(saved.selected == 1)

            harness.sessions.unloadTabsOverBudget(budget: 1)
            #expect(session.tabs.filter(\.isLoaded).map(\.id) == [session.activeTab.id])
            #expect(session.tabs[2].url?.path == "/c")
            session.select(session.tabs[2])
            #expect(session.tabs[2].isLoaded)
        }
        // A relaunch: a new set of sessions over the same remembered state.
        let relaunched = PreviewSessions(profile: harness.profile, bridge: PreviewBridge(directory: harness.folder.appendingPathComponent("bridge2")))
        let restored = relaunched.session(for: id)
        #expect(restored.tabs.map { $0.url?.path } == ["/a", "/b", "/c"])
        #expect(restored.activeTab === restored.tabs[2])
        #expect(restored.tabs.filter(\.isLoaded).count == 1)
        relaunched.stop()
        UIState.shared.update { $0.previewTabs.removeValue(forKey: id.uuidString) }
        await harness.tearDown()
    }

    @Test func panelShortcutsAndTabStrip() async throws {
        let harness = BrowserProfileTests.Harness()
        do {
            let id = UUID()
            let panel = PreviewViewController()
            panel.sessions = harness.sessions
            panel.threadID = id
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 500), styleMask: [.borderless],
                backing: .buffered, defer: true)
            window.alphaValue = 0
            window.contentViewController = panel
            defer { window.contentViewController = nil }
            let session = try #require(panel.session)
            // Visibility refresh is deferred until AppKit finishes attaching the hierarchy. Keyboard input arrives
            // after that attachment in the app; wait for the same state in this offscreen host.
            try await waitFor { session.webView.window === window }
            #expect(session.webView.window === window)
            #expect(panel.tabStrip.buttons.count == 1)
            func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            }
            // Focus elsewhere: ⌘T and ⌘W are left alone (⌘W stays Delete Thread).
            window.makeFirstResponder(nil)
            #expect(!panel.handleKey(key("t", .command, code: 17)))
            #expect(!panel.handleKey(key("w", .command, code: 13)))
            // Focus in the panel: they work on tabs.
            window.makeFirstResponder(session.webView)
            #expect(panel.handleKey(key("t", .command, code: 17)))
            #expect(session.tabs.count == 2 && panel.tabStrip.buttons.count == 2)
            window.makeFirstResponder(session.webView)
            #expect(panel.handleKey(key("[", [.command, .shift], code: 33)))
            #expect(session.activeTab === session.tabs[0])
            #expect(panel.handleKey(key("w", .command, code: 13)))
            #expect(session.tabs.count == 1 && panel.tabStrip.buttons.count == 1)
            // The strip's own buttons: select, close and new.
            panel.tabStrip.newButton.performClick(nil)
            #expect(session.tabs.count == 2)
            let firstButton = panel.tabStrip.buttons[0]
            #expect(firstButton.accessibilityPerformPress())
            #expect(session.activeTab === session.tabs[0])
            #expect(!firstButton.close.isHidden && panel.tabStrip.buttons[1].close.isHidden)
            firstButton.close.performClick(nil)
            #expect(session.tabs.count == 1)
            // Agent Control is a small header switch, on by default.
            #expect(harness.sessions.isAgentControlEnabled(id))
            panel.control.performClick(nil)
            #expect(!harness.sessions.isAgentControlEnabled(id))
            panel.control.performClick(nil)
            #expect(harness.sessions.isAgentControlEnabled(id))
            #expect(window.isVisible == false)
        }
        await harness.tearDown()
    }

    @Test func linksCanOpenInANewTab() {
        let url = URL(string: "https://example.test/")!
        #expect(LinkRouting.request(for: url, commandKey: true, optionKey: true, opensInDefaultBrowser: false)?.destination == .coincideBrowserNewTab)
        #expect(LinkRouting.request(for: url, commandKey: true, optionKey: true, opensInDefaultBrowser: true)?.destination == .coincideBrowserNewTab)
        #expect(LinkRouting.request(for: url, commandKey: false, optionKey: true, opensInDefaultBrowser: false)?.destination == .coincideBrowser)
        #expect(LinkRouting.menuTitle(.coincideBrowserNewTab) == String(localized: "Open in New Tab"))
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting")
    }
}
