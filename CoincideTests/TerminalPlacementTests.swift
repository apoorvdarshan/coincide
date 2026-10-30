import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Settings › General › Terminal: below the chat with its button in the rail (the default), or on the right as a panel
/// of the inspector with its button in the toolbar's top-right group. These share the window harness, and with it the
/// serialized suite, of `InspectorPanelButtonsTests`: they change the same shared settings and interface state. The
/// window is never ordered in.
extension InspectorPanelButtonsTests {
    private func railButtons(_ harness: Harness) -> [RailButton] {
        Self.allSubviews(of: harness.controller.rail.view, as: RailButton.self)
    }

    private func shownRailLabels(_ harness: Harness) -> [String] {
        railButtons(harness).filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }.compactMap { $0.accessibilityLabel() }
    }

    private static func allSubviews<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + allSubviews(of: $0, as: type) }
    }

    /// Waits for the thread's first shell to be up, so the tests can check that moving the terminal keeps it.
    private func runningSession(_ harness: Harness) async throws -> TerminalSession {
        let terminals = TerminalSessionManager.shared.terminals(for: harness.threadID)
        for _ in 0..<100 where terminals.activeSession?.state != .running {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(terminals.activeSession)
        try #require(session.state == .running, "the shell did not start")
        return session
    }

    @Test func theTerminalStartsBelowTheChatWithItsButtonInTheRail() async {
        let harness = Harness()
        defer { harness.close() }
        await harness.wait()
        #expect(harness.split.terminalPlacement == .bottom)
        #expect(shownRailLabels(harness).contains(String(localized: "Terminal")))
        #expect(!harness.buttons.showsTerminal)
        #expect(harness.buttons.shownButtons == [harness.buttons.diffButton, harness.buttons.pullRequestsButton, harness.buttons.previewButton])
        #expect(!harness.split.inspector.hasTerminal)

        harness.split.toggleTerminalPanel()
        await harness.wait()
        #expect(harness.split.content.isTerminalOpen && harness.split.isTerminalOpen)
        #expect(!harness.split.isInspectorOpen)
        #expect(harness.split.content.terminal.view.isDescendant(of: harness.split.content.view))
    }

    @Test func onTheRightTheTerminalIsAPanelOfTheInspectorWithItsButtonInTheGroup() async {
        let harness = Harness(terminal: .right)
        defer { harness.close() }
        await harness.wait()
        let buttons = harness.buttons
        let split = harness.split
        // The button left the rail, and Open In took its place.
        #expect(!shownRailLabels(harness).contains(String(localized: "Terminal")))
        let openIn = harness.controller.rail.openInButton
        #expect(railButtons(harness).contains { $0 === openIn && !$0.isHiddenOrHasHiddenAncestor && $0.window != nil })
        #expect(buttons.shownButtons.last === buttons.terminalButton)
        #expect(buttons.terminalButton.accessibilityLabel() == String(localized: "Terminal"))
        #expect(buttons.terminalButton.toolTip == KeyBindingsController.shared.toolTip(String(localized: "Terminal"), for: .toggleTerminal))
        #expect(buttons.terminalButton.action == #selector(MainWindowController.toggleTerminalPanel(_:)))
        #expect(split.inspector.hasTerminal)

        // The button opens the terminal in the column, lit like the other panels' buttons.
        buttons.terminalButton.performClick(nil)
        await harness.wait()
        #expect(split.isTerminalOpen && split.isInspectorOpen && split.inspector.panel == .terminal)
        #expect(!split.content.isTerminalOpen)
        #expect(split.content.terminal.view.isDescendant(of: split.inspector.view))
        #expect(buttons.openPanel == .terminal)
        #expect(buttons.terminalButton.isActive && buttons.terminalButton.isAccessibilitySelected())
        #expect(UIState.shared.values.inspectorPanel == .terminal)
        // Its header starts below the toolbar, as the other panels' do, so it is never under the group.
        let terminalView = split.content.terminal.view
        let headerTop = terminalView.convert(terminalView.safeAreaRect, to: nil).maxY
        #expect(headerTop <= harness.frame(of: buttons).minY + 1)

        // The column switches between it and the other panels like tabs.
        buttons.diffButton.performClick(nil)
        await harness.wait()
        #expect(split.isDiffOpen && !split.isTerminalOpen)
        #expect(!buttons.terminalButton.isActive && buttons.diffButton.isActive)
        harness.split.toggleTerminalPanel()
        await harness.wait()
        #expect(split.isTerminalOpen && !split.isDiffOpen)

        // The open panel's button closes the column; the menu, shortcut and palette toggle it the same way.
        buttons.terminalButton.performClick(nil)
        await harness.wait()
        #expect(!split.isInspectorOpen && !split.isTerminalOpen)
        #expect(buttons.openPanel == nil)
    }

    /// Switching moves the same terminal, with its running shell, and keeps it open or closed.
    @Test func switchingLiveMovesTheRunningTerminalWithoutRestartingIt() async throws {
        let harness = Harness()
        defer { harness.close() }
        await harness.wait()
        let split = harness.split
        let terminal = split.content.terminal
        split.toggleTerminalPanel()
        await harness.wait()
        let session = try await runningSession(harness)
        let process = try #require(session.terminalView.process)
        let sessionCount = TerminalSessionManager.shared.terminals(for: harness.threadID).sessions.count

        // To the right: the store's change reaches the window, as Settings › General's picker does.
        harness.store.updateSettings { $0.terminalPlacement = .right }
        await harness.wait()
        #expect(split.terminalPlacement == .right)
        #expect(split.isTerminalOpen && split.inspector.panel == .terminal)
        #expect(!split.content.isTerminalOpen)
        #expect(terminal.view.isDescendant(of: split.inspector.view))
        #expect(session.terminalView.isDescendant(of: terminal.view) && session.terminalView.window === harness.window)
        #expect(harness.buttons.showsTerminal && harness.buttons.terminalButton.isActive)
        #expect(!shownRailLabels(harness).contains(String(localized: "Terminal")))

        // And back: the drawer opens again with the same shell.
        harness.store.updateSettings { $0.terminalPlacement = .bottom }
        await harness.wait()
        #expect(split.terminalPlacement == .bottom)
        #expect(split.content.isTerminalOpen && split.isTerminalOpen)
        #expect(!split.isInspectorOpen)
        #expect(!split.inspector.hasTerminal)
        #expect(terminal.view.isDescendant(of: split.content.view))
        #expect(!harness.buttons.showsTerminal)
        #expect(shownRailLabels(harness).contains(String(localized: "Terminal")))

        // Nothing restarted: the same session and process, still running, and no new shells.
        let terminals = TerminalSessionManager.shared.terminals(for: harness.threadID)
        #expect(terminals.activeSession === session)
        #expect(session.terminalView.process === process)
        #expect(session.state == .running)
        #expect(terminals.sessions.count == sessionCount)
        #expect(split.content.terminal === terminal)
    }

    /// A closed terminal stays closed in its new place, and the inspector keeps the panel it shows.
    @Test func switchingKeepsAClosedTerminalClosedAndLeavesTheOtherPanelsAlone() async {
        let harness = Harness()
        defer { harness.close() }
        await harness.wait()
        let split = harness.split
        split.togglePreviewPanel()
        await harness.wait()

        harness.store.updateSettings { $0.terminalPlacement = .right }
        await harness.wait()
        #expect(!split.isTerminalOpen)
        #expect(split.isPreviewOpen)
        #expect(harness.buttons.openPanel == .preview)

        harness.store.updateSettings { $0.terminalPlacement = .bottom }
        await harness.wait()
        #expect(!split.isTerminalOpen && !split.content.isTerminalOpen)
        #expect(split.isPreviewOpen)

        // A terminal panel chosen but closed doesn't stay the inspector's choice once the terminal leaves it.
        harness.store.updateSettings { $0.terminalPlacement = .right }
        await harness.wait()
        split.toggleTerminalPanel()
        await harness.wait()
        split.toggleTerminalPanel()
        await harness.wait()
        #expect(!split.isInspectorOpen && split.inspector.panel == .terminal)
        harness.store.updateSettings { $0.terminalPlacement = .bottom }
        await harness.wait()
        #expect(split.inspector.panel == .diff)
        #expect(UIState.shared.values.inspectorPanel == .diff)
        #expect(!split.isTerminalOpen)
    }

    /// A window opened with the terminal on the right brings back the terminal panel its thread had open.
    @Test func aNewWindowRestoresTheTerminalPanelOnTheRight() async {
        let harness = Harness(terminal: .right, threadPanel: .terminal) {
            $0.isInspectorOpen = true
            $0.inspectorPanel = .terminal
        }
        defer { harness.close() }
        await harness.wait()
        #expect(harness.split.isTerminalOpen && harness.split.inspector.panel == .terminal)
        #expect(harness.buttons.openPanel == .terminal)
        #expect(!harness.split.content.isTerminalOpen)
    }

    /// A saved terminal panel means nothing with the terminal below the chat: the inspector shows the diff.
    @Test func aSavedTerminalPanelFallsBackToTheDiffWithTheTerminalBelow() async {
        let harness = Harness(terminal: .bottom, threadPanel: .terminal) {
            $0.isInspectorOpen = true
            $0.inspectorPanel = .terminal
        }
        defer { harness.close() }
        await harness.wait()
        #expect(harness.split.inspector.panel == .diff)
        #expect(!harness.split.isTerminalOpen)
    }

    /// With four buttons the pill still sits at the top-right corner and keeps its place as the column opens.
    @Test func theWiderGroupStaysAtTheTopRightCorner() async {
        let harness = Harness(terminal: .right)
        defer { harness.close() }
        await harness.wait()
        let buttons = harness.buttons
        let closed = harness.frame(of: buttons)
        #expect(closed.width == InspectorPanelButtons.buttonWidth * 4 + 2)
        #expect(harness.window.frame.width - closed.maxX < 24)
        #expect(harness.frame(of: harness.controller.projectScripts).maxX <= closed.minX)
        harness.split.toggleTerminalPanel()
        await harness.wait()
        let open = harness.frame(of: buttons)
        #expect(abs(open.maxX - closed.maxX) <= 1 && abs(open.midY - closed.midY) <= 1)
        // Switching back narrows it again, live.
        harness.store.updateSettings { $0.terminalPlacement = .bottom }
        await harness.wait()
        #expect(harness.frame(of: buttons).width == InspectorPanelButtons.buttonWidth * 3 + 2)
        #expect(harness.window.frame.width - harness.frame(of: buttons).maxX < 24)
    }
}

/// The rail without a window: the Terminal button can leave it, and Open In moves up into its place.
@MainActor struct NavigationRailTerminalTests {
    @Test func theTerminalButtonCanLeaveTheRail() throws {
        let rail = NavigationRailViewController()
        rail.view.frame = NSRect(x: 0, y: 0, width: NavigationRailViewController.width, height: 800)
        rail.view.layoutSubtreeIfNeeded()
        func shown() -> [RailButton] {
            var buttons: [RailButton] = []
            func collect(_ view: NSView) {
                if let button = view as? RailButton, !button.isHiddenOrHasHiddenAncestor, button.superview != nil {
                    buttons.append(button)
                }
                view.subviews.forEach(collect)
            }
            collect(rail.view)
            return buttons
        }
        #expect(rail.showsTerminalButton)
        let before = shown()
        let terminal = try #require(before.first { $0.accessibilityLabel() == "Terminal" })
        let terminalFrame = terminal.convert(terminal.bounds, to: rail.view)

        rail.showsTerminalButton = false
        rail.view.layoutSubtreeIfNeeded()
        let after = shown()
        #expect(after.count == before.count - 1)
        #expect(!after.contains { $0.accessibilityLabel() == "Terminal" })
        // Open In names its app ("Open in Xcode"), so it is found by identity rather than by label.
        let openIn = try #require(after.first { $0 === rail.openInButton })
        #expect(openIn.convert(openIn.bounds, to: rail.view) == terminalFrame)

        rail.showsTerminalButton = true
        rail.view.layoutSubtreeIfNeeded()
        #expect(shown().count == before.count)
    }
}

/// The setting itself: its default, how it is saved and read, Restore Defaults and settings search.
@MainActor struct TerminalPlacementSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func theTerminalStaysBelowByDefault() throws {
        #expect(AppSettings().terminalPlacement == .bottom)
        // Settings saved before the choice existed keep it below.
        #expect(try decode(#"{"fontSize": 15}"#).terminalPlacement == .bottom)
        #expect(TerminalPlacement.allCases == [.bottom, .right])
        #expect(TerminalPlacement.bottom.displayName == String(localized: "Bottom panel"))
        #expect(TerminalPlacement.right.displayName == String(localized: "Right panel"))
    }

    @Test func theChoiceIsSavedAndReadBack() throws {
        var settings = AppSettings()
        settings.terminalPlacement = .right
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["terminalPlacement"] as? String == "right")
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).terminalPlacement == .right)
    }

    @Test(arguments: [#""left""#, "1", "null", #"["right"]"#])
    func anUnreadableValueKeepsTheTerminalBelowAndTheOtherSettings(value: String) throws {
        let settings = try decode(#"{"terminalPlacement": \#(value), "fontSize": 15}"#)
        #expect(settings.terminalPlacement == .bottom)
        #expect(settings.fontSize == 15)
    }

    @Test func restoreDefaultsPutsTheTerminalBackBelow() {
        var settings = AppSettings()
        settings.terminalPlacement = .right
        GeneralSettingsView.restoreDefaults(in: &settings)
        #expect(settings.terminalPlacement == .bottom)
    }

    @Test func settingsSearchFindsIt() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["terminal", "Right panel", "bottom panel", "toolbar"] {
            #expect(entries.contains { $0.setting == .terminalPlacement && $0.matches(query) }, "\(query) doesn't find it")
        }
        let entry = try #require(entries.first { $0.setting == .terminalPlacement })
        #expect(entry.pane == .section(.general))
    }
}
