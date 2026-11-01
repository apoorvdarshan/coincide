import AppKit
import CoincideRemoteKit
import Testing

@testable import Coincide

@MainActor
struct NavigationRailTests {
    /// The rail's buttons paint their highlight across their frames, so the frames must be the laid-out squares with
    /// a gap between them; the push style's alignment insets once made neighbouring highlights touch.
    @Test func railButtonsAreSquaresWithGapsBetweenThem() throws {
        let rail = NavigationRailViewController()
        rail.view.frame = NSRect(x: 0, y: 0, width: NavigationRailViewController.width, height: 800)
        rail.view.layoutSubtreeIfNeeded()
        var buttons: [RailButton] = []
        func collect(_ view: NSView) {
            if let button = view as? RailButton { buttons.append(button) }
            view.subviews.forEach(collect)
        }
        collect(rail.view)
        #expect(buttons.count == 12)
        // Whatever opens on the right has its button on the right, in the toolbar (`InspectorPanelButtons`): the
        // schedules too, so the rail has no Scheduled clock.
        let labels = Set(buttons.compactMap { $0.accessibilityLabel() })
        #expect(labels.isDisjoint(with: ["Diff", "Pull Requests", "Browser Preview", "Scheduled", "Scheduled Tasks"]))
        #expect(!buttons.contains { $0.action == #selector(MainWindowController.toggleSchedulesPanel(_:)) })
        #expect(labels.contains("Terminal"))
        // Open In names the app it opens ("Open in Xcode"), or reads "Open In" when none is installed.
        #expect(labels.contains { $0.lowercased().hasPrefix("open in") })
        let frames = buttons.map { $0.convert($0.bounds, to: rail.view) }.sorted { $0.minY < $1.minY }
        for frame in frames {
            #expect(frame.width == RailButton.side)
            #expect(frame.height == RailButton.side)
        }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(lower.minY - upper.maxY >= 4, "\(upper) and \(lower) leave no gap")
        }
    }

    /// Star on GitHub, Join the Discord and Support Coincide on Ko-fi sit above the bottom group, named for their links
    /// in their tooltips and to VoiceOver, and send their clicks to the rail.
    @Test func communityButtonsNameTheirLinks() throws {
        let rail = NavigationRailViewController()
        _ = rail.view
        #expect(NavigationRailViewController.communityLinks == [.starOnGitHub, .joinDiscord, .supportOnKoFi])
        let buttons = rail.communityButtons
        #expect(buttons.map { $0.accessibilityLabel() } == ["Star on GitHub", "Join the Discord", "Support Coincide on Ko-fi"])
        #expect(buttons.map(\.toolTip) == [
            "Star on GitHub\nCoincide is open source under the MIT License", "Join the Discord\ndiscord.gg/DETrbhDVqw",
            "Support Coincide on Ko-fi\nBuy Apoorv a coffee",
        ])
        #expect(buttons.allSatisfy { $0.target === rail && $0.action != nil })
        #expect(buttons.map { $0.identifier?.rawValue } == ["community.starOnGitHub", "community.joinDiscord", "community.supportOnKoFi"])
        // Above Usage, Instructions, Agents and Settings, in one group with them.
        let group = try #require(buttons.first?.superview as? NSStackView)
        #expect(Array(group.arrangedSubviews.prefix(3)) == buttons as [NSView])
        #expect(group.arrangedSubviews.count == 7)
    }

    /// A window too short for every button lets the community buttons go, Ko-fi first and Discord last, before
    /// anything overlaps; a tall one shows them all.
    @Test func aShortRailLetsTheCommunityButtonsGo() throws {
        func shown(height: CGFloat) -> (community: [String], frames: [NSRect]) {
            let rail = NavigationRailViewController()
            rail.view.frame = NSRect(x: 0, y: 0, width: NavigationRailViewController.width, height: height)
            rail.view.layoutSubtreeIfNeeded()
            var buttons: [RailButton] = []
            func collect(_ view: NSView) {
                if let button = view as? RailButton, !button.isHiddenOrHasHiddenAncestor { buttons.append(button) }
                view.subviews.forEach(collect)
            }
            collect(rail.view)
            let community = rail.communityButtons.filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0.accessibilityLabel() }
            return (community, buttons.map { $0.convert($0.bounds, to: rail.view) }.sorted { $0.minY < $1.minY })
        }
        #expect(shown(height: 800).community == ["Star on GitHub", "Join the Discord", "Support Coincide on Ko-fi"])
        #expect(shown(height: 530).community == ["Star on GitHub", "Join the Discord"])
        #expect(shown(height: 500).community == ["Join the Discord"])
        #expect(shown(height: 450).community.isEmpty)
        for height in [800, 530, 500, 450] as [CGFloat] {
            let frames = shown(height: height).frames
            #expect(frames.count == 12 - (3 - shown(height: height).community.count))
            for (upper, lower) in zip(frames, frames.dropFirst()) {
                #expect(lower.minY - upper.maxY >= 4, "At \(height): \(upper) and \(lower) overlap")
            }
        }
    }
}

/// The diff, the pull requests and the browser preview share the inspector column; the toolbar's buttons switch it like
/// tabs.
@MainActor
@Suite(.serialized)
struct InspectorPanelTests {
    @Test func theInspectorSwitchesBetweenItsPanels() {
        let saved = UIState.shared.values
        defer { UIState.shared.update { $0 = saved } }
        UIState.shared.update {
            $0.isInspectorOpen = false
            $0.inspectorPanel = .diff
        }
        let split = MainSplitViewController()
        split.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        #expect(!split.isDiffOpen && !split.isPullRequestsOpen)

        split.togglePullRequestsPanel()
        #expect(split.isPullRequestsOpen && !split.isDiffOpen)
        #expect(split.inspector.selectedTabViewItemIndex == 1)
        #expect(UIState.shared.values.inspectorPanel == .pullRequests)

        // The diff takes the open column over rather than closing it.
        split.toggleDiffPanel()
        #expect(split.isDiffOpen && !split.isPullRequestsOpen)
        #expect(UIState.shared.values.inspectorPanel == .diff)

        split.togglePreviewPanel()
        #expect(split.isPreviewOpen && !split.isDiffOpen && !split.isPullRequestsOpen)
        #expect(UIState.shared.values.inspectorPanel == .preview)

        // Turn diffs always show the diff.
        split.togglePullRequestsPanel()
        split.showDiffPanel()
        #expect(split.isDiffOpen)
    }

    /// As with the terminal, closing the browser's last tab closes the browser, and only when it is the panel showing.
    @Test func closingTheBrowsersLastTabClosesTheBrowser() {
        let saved = UIState.shared.values
        defer { UIState.shared.update { $0 = saved } }
        UIState.shared.update {
            $0.isInspectorOpen = false
            $0.inspectorPanel = .diff
        }
        let split = MainSplitViewController()
        split.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        split.togglePreviewPanel()
        #expect(split.isPreviewOpen)
        split.preview.onLastTabClosed?()
        #expect(!split.isPreviewOpen && !split.isInspectorOpen)
        // Another panel showing is left alone.
        split.toggleDiffPanel()
        split.preview.onLastTabClosed?()
        #expect(split.isDiffOpen)
    }

    /// With the terminal on the right it is a fourth panel, switched to and from like the others; below the chat the
    /// inspector has no terminal panel.
    @Test func theTerminalIsAFourthPanelOnTheRight() {
        let saved = UIState.shared.values
        defer { UIState.shared.update { $0 = saved } }
        UIState.shared.update {
            $0.isInspectorOpen = false
            $0.inspectorPanel = .diff
            $0.isTerminalOpen = false
        }
        let below = MainSplitViewController(terminalPlacement: .bottom)
        below.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        #expect(below.inspector.panels == [.diff, .pullRequests, .preview, .schedules])
        #expect(!below.inspector.hasTerminal)

        let split = MainSplitViewController(terminalPlacement: .right)
        split.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        #expect(split.inspector.panels == [.diff, .pullRequests, .preview, .schedules, .terminal])
        #expect(!split.isTerminalOpen)

        split.toggleTerminalPanel()
        #expect(split.isTerminalOpen && split.isInspectorOpen && !split.content.isTerminalOpen)
        #expect(split.inspector.selectedTabViewItemIndex == 4)
        #expect(UIState.shared.values.inspectorPanel == .terminal)

        // Another panel takes the open column over, and the terminal's toggle takes it back.
        split.toggleDiffPanel()
        #expect(split.isDiffOpen && !split.isTerminalOpen)
        split.toggleTerminalPanel()
        #expect(split.isTerminalOpen && !split.isDiffOpen)
        split.toggleTerminalPanel()
        #expect(!split.isInspectorOpen)

        // Without the terminal, the inspector can't show it.
        split.inspector.detachTerminal()
        #expect(!split.inspector.hasTerminal)
        split.inspector.show(.terminal)
        #expect(split.inspector.panel == .diff)
    }

    @Test func theInspectorReopensOnThePanelLastShown() {
        let saved = UIState.shared.values
        defer { UIState.shared.update { $0 = saved } }
        UIState.shared.update { $0.inspectorPanel = .pullRequests }
        let inspector = InspectorViewController(diff: DiffViewController(), pullRequests: PullRequestsViewController())
        #expect(inspector.panel == .pullRequests)
        inspector.show(.diff)
        #expect(inspector.panel == .diff)
        #expect(UIState.shared.values.inspectorPanel == .diff)
    }
}
