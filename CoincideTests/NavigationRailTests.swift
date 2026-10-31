import AppKit
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
        #expect(buttons.count == 10)
        // The panels that open on the right have their buttons on the right, in the toolbar (`InspectorPanelButtons`).
        let labels = Set(buttons.compactMap { $0.accessibilityLabel() })
        #expect(labels.isDisjoint(with: ["Diff", "Pull Requests", "Browser Preview"]))
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
