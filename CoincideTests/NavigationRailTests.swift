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
        #expect(buttons.count == 11)
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

/// The diff and the pull requests share the inspector column; the rail's buttons switch it like tabs.
@MainActor
@Suite(.serialized)
struct InspectorPanelTests {
    @Test func theRailSwitchesTheInspectorBetweenTheDiffAndThePullRequests() {
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
