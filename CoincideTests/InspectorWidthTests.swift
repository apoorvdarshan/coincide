import AppKit
import Testing

@testable import Coincide

/// The inspector's share of the space right of the thread list, as numbers.
struct InspectorWidthTests {
    @Test func theDefaultIsHalfOfTheSpace() {
        #expect(InspectorWidth.panelWidth(fraction: nil, available: 1000) == 500)
        #expect(InspectorWidth.panelWidth(fraction: nil, available: 1400) == 700)
        #expect(InspectorWidth.ratio(for: nil) == 1)
    }

    @Test func theShareKeepsBothMinimums() {
        // Too wide a share leaves the chat its minimum.
        #expect(InspectorWidth.panelWidth(fraction: 0.9, available: 1000) == 1000 - InspectorWidth.minimumChatWidth)
        // Too narrow a share keeps the panel's.
        #expect(InspectorWidth.panelWidth(fraction: 0.1, available: 1000) == InspectorWidth.minimumPanelWidth)
        // Short of space, the panel goes down to its minimum first; the window has to make up the rest.
        #expect(InspectorWidth.panelWidth(fraction: 0.5, available: 800) == 380)
        #expect(InspectorWidth.panelWidth(fraction: 0.5, available: 700) == InspectorWidth.minimumPanelWidth)
        #expect(InspectorWidth.shortfall(available: 700) == 40)
        #expect(InspectorWidth.shortfall(available: 1000) == 0)
    }

    @Test func aWidthBecomesAShareWithinTheMinimums() {
        #expect(InspectorWidth.fraction(panelWidth: 400, available: 1000) == 0.4)
        // Dragged past a minimum, the share is where the divider stopped.
        #expect(InspectorWidth.fraction(panelWidth: 950, available: 1000) == 0.58)
        #expect(InspectorWidth.fraction(panelWidth: 10, available: 1000) == 0.32)
        #expect(InspectorWidth.fraction(panelWidth: 400, available: 0) == nil)
    }

    @Test func aDamagedShareFallsBackOrIsClamped() {
        #expect(InspectorWidth.normalized(nil) == 0.5)
        #expect(InspectorWidth.normalized(.nan) == 0.5)
        #expect(InspectorWidth.normalized(.infinity) == 0.5)
        #expect(InspectorWidth.normalized(3) == InspectorWidth.fractionRange.upperBound)
        #expect(InspectorWidth.normalized(-1) == InspectorWidth.fractionRange.lowerBound)
        #expect(InspectorWidth.ratio(for: 0.75) == 3)
    }

    @Test func theShareFollowsTheSpace() {
        for available in [900.0, 1200, 1600, 2400] {
            let width = InspectorWidth.panelWidth(fraction: 0.4, available: available)
            #expect(abs(width - max(InspectorWidth.minimumPanelWidth, 0.4 * available)) < 0.001, "\(available)")
        }
    }

    @Test func theShareIsSavedAndAnOldWidthIsDropped() throws {
        let folder = TemporaryDirectory("ui")
        try Data(#"{"inspectorWidth": 480, "isInspectorOpen": true}"#.utf8).write(to: folder.url.appendingPathComponent("ui-state.json"))
        let state = UIState(directory: folder.url)
        #expect(state.values.inspectorFraction == nil)
        #expect(state.values.isInspectorOpen)
        state.update { $0.inspectorFraction = 0.37 }
        state.flush()
        #expect(UIState(directory: folder.url).values.inspectorFraction == 0.37)
    }
}

/// The main window's split view, offscreen: the inspector opens at its share, the divider drags and resets, and the
/// share holds as the window and the thread list change.
@MainActor @Suite(.serialized) struct InspectorLayoutTests {
    /// The window's layout with its own interface state, as a fresh launch would build it.
    @MainActor final class Harness {
        let folder: TemporaryDirectory
        let state: UIState
        let split: MainSplitViewController
        let root: MainRootViewController
        let window: NSWindow

        init(folder: TemporaryDirectory = TemporaryDirectory("split"), width: CGFloat = 1400, values: (inout UIState.Values) -> Void = { _ in }) {
            self.folder = folder
            state = UIState(directory: folder.url)
            state.update { state in
                state.listWidth = 288
                state.isSidebarCollapsed = false
                state.isInspectorOpen = false
                values(&state)
            }
            split = MainSplitViewController(state: state)
            root = MainRootViewController(split: split)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: -8000, width: width, height: 800), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = root
            resize(to: width)
            window.orderBack(nil)
        }

        func resize(to width: CGFloat) {
            window.setFrame(NSRect(x: -8000, y: -8000, width: width, height: 800), display: false)
            settle()
        }

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        /// Lets animations and the work they queue finish.
        func wait() async {
            try? await Task.sleep(for: .milliseconds(450))
            settle()
        }

        var sidebarWidth: CGFloat { split.sidebar.view.frame.width }
        var chatWidth: CGFloat { split.content.view.frame.width }
        var panelWidth: CGFloat { split.inspector.view.frame.width }
        var share: Double { Double(panelWidth / (chatWidth + panelWidth)) }

        /// Where the divider between the chat and the inspector is, in the split controller's view.
        var dividerX: CGFloat { split.content.view.convert(split.content.view.bounds, to: split.view).maxX }

        func close() {
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func theInspectorOpensAtHalfOfTheSpaceRightOfTheThreadList() async {
        let harness = Harness()
        defer { harness.close() }
        await harness.wait()
        let sidebar = harness.sidebarWidth
        #expect(sidebar == 288)
        let chatBefore = harness.chatWidth

        harness.split.toggleDiffPanel()
        await harness.wait()
        #expect(harness.split.isDiffOpen)
        #expect(harness.sidebarWidth == sidebar, "opening the panel must not move the thread list")
        #expect(abs(harness.chatWidth - harness.panelWidth) <= 1)
        #expect(abs(harness.chatWidth + harness.panelWidth + harness.split.splitView.dividerThickness - chatBefore) <= 1)
        #expect(!harness.split.dividerHandle.isHidden)

        // Every panel uses the same share.
        harness.split.togglePullRequestsPanel()
        await harness.wait()
        #expect(harness.split.isPullRequestsOpen && abs(harness.share - 0.5) < 0.01)
        harness.split.togglePullRequestsPanel()
        await harness.wait()
        #expect(!harness.split.isInspectorOpen)
        #expect(harness.split.dividerHandle.isHidden)
        #expect(harness.sidebarWidth == sidebar, "closing the panel must not move the thread list")
        #expect(abs(harness.chatWidth - chatBefore) <= 1)
    }

    @Test func draggingTheDividerChangesTheShareAndItSurvivesARelaunch() async {
        let harness = Harness(width: 1600)
        await harness.wait()
        harness.split.togglePreviewPanel()
        await harness.wait()
        let available = harness.chatWidth + harness.panelWidth
        // Drag the divider 150 points left: the panel takes them from the chat.
        let start = harness.dividerX
        harness.split.dragDivider(to: start - 150)
        harness.split.saveInspectorFraction()
        harness.settle()
        #expect(abs(harness.dividerX - (start - 150)) <= 1)
        #expect(abs(harness.chatWidth + harness.panelWidth - available) <= 1)
        let share = harness.share
        #expect(abs(share - Double((available / 2 + 150) / available)) < 0.01)
        #expect(abs((harness.state.values.inspectorFraction ?? 0) - share) < 0.01)
        harness.state.flush()
        let folder = harness.folder
        harness.close()

        // The next launch, in a wider window, opens at the same share.
        let relaunched = Harness(folder: folder, width: 1800) { $0.isInspectorOpen = true }
        defer { relaunched.close() }
        await relaunched.wait()
        #expect(relaunched.split.isInspectorOpen)
        #expect(abs(relaunched.share - share) < 0.01)
        #expect(relaunched.sidebarWidth == 288)
    }

    @Test func aDragStopsAtBothMinimums() async {
        let harness = Harness()
        defer { harness.close() }
        await harness.wait()
        harness.split.toggleDiffPanel()
        await harness.wait()
        harness.split.dragDivider(to: harness.dividerX - 2000)
        harness.settle()
        #expect(abs(harness.chatWidth - CGFloat(InspectorWidth.minimumChatWidth)) <= 1)
        harness.split.dragDivider(to: harness.dividerX + 4000)
        harness.settle()
        #expect(abs(harness.panelWidth - CGFloat(InspectorWidth.minimumPanelWidth)) <= 1)
        #expect(harness.sidebarWidth == 288)
    }

    @Test func doubleClickingTheDividerRestoresTheDefault() async {
        let harness = Harness { $0.inspectorFraction = 0.3; $0.isInspectorOpen = true }
        defer { harness.close() }
        await harness.wait()
        #expect(abs(harness.share - 0.3) < 0.01)
        harness.split.resetInspectorWidth()
        harness.settle()
        #expect(abs(harness.share - 0.5) < 0.01)
        #expect(harness.state.values.inspectorFraction == nil)
    }

    @Test func resizingTheWindowKeepsTheShareAndTheThreadListsWidth() async {
        let harness = Harness(width: 1600) { $0.inspectorFraction = 0.4; $0.isInspectorOpen = true }
        defer { harness.close() }
        await harness.wait()
        #expect(abs(harness.share - 0.4) < 0.01)
        for width in [2400, 1900, 1400] as [CGFloat] {
            harness.resize(to: width)
            let available = Double(harness.chatWidth + harness.panelWidth)
            #expect(harness.sidebarWidth == 288, "\(width)")
            #expect(abs(Double(harness.panelWidth) - InspectorWidth.panelWidth(fraction: 0.4, available: available)) <= 1, "\(width)")
        }
        harness.resize(to: 1600)
        #expect(abs(harness.share - 0.4) < 0.01)
    }

    @Test func aNarrowingWindowShrinksThePanelBeforeTheChat() async {
        let harness = Harness(width: 1600) { $0.inspectorFraction = 0.6; $0.isInspectorOpen = true }
        defer { harness.close() }
        await harness.wait()
        #expect(abs(harness.share - 0.6) < 0.01)
        for width in [1150, 1100] as [CGFloat] {
            harness.resize(to: width)
            let available = Double(harness.chatWidth + harness.panelWidth)
            #expect(abs(harness.chatWidth - CGFloat(InspectorWidth.minimumChatWidth)) <= 1, "\(width)")
            #expect(abs(Double(harness.panelWidth) - InspectorWidth.panelWidth(fraction: 0.6, available: available)) <= 1, "\(width)")
            #expect(harness.panelWidth >= CGFloat(InspectorWidth.minimumPanelWidth) - 0.5, "\(width)")
            #expect(harness.sidebarWidth == 288, "\(width)")
        }
        // Wider again, the saved share comes back.
        harness.resize(to: 1600)
        #expect(abs(harness.share - 0.6) < 0.01)
    }

    @Test func hidingTheThreadListKeepsTheShare() async {
        let harness = Harness { $0.inspectorFraction = 0.45; $0.isInspectorOpen = true }
        defer { harness.close() }
        await harness.wait()
        let before = harness.panelWidth
        harness.split.toggleSidebarPanel()
        await harness.wait()
        #expect(!harness.split.isSidebarOpen)
        #expect(abs(harness.share - 0.45) < 0.01)
        #expect(harness.panelWidth > before)
        harness.split.toggleSidebarPanel()
        await harness.wait()
        #expect(abs(harness.share - 0.45) < 0.01)
        #expect(abs(harness.panelWidth - before) <= 1)
    }

    @Test func openingInANarrowWindowWidensItRatherThanShrinkTheThreadList() async {
        let harness = Harness(width: 900)
        defer { harness.close() }
        await harness.wait()
        harness.split.toggleDiffPanel()
        await harness.wait()
        #expect(harness.sidebarWidth == 288)
        #expect(harness.chatWidth >= CGFloat(InspectorWidth.minimumChatWidth) - 0.5)
        #expect(harness.panelWidth >= CGFloat(InspectorWidth.minimumPanelWidth) - 0.5)
    }

    @Test func theHandleTakesClicksOnEitherSideOfTheDivider() async throws {
        let harness = Harness { $0.isInspectorOpen = true }
        defer { harness.close() }
        await harness.wait()
        let container = try #require(harness.split.view.superview)
        for offset in [-4, 0, 4] as [CGFloat] {
            let point = NSPoint(x: harness.dividerX + offset, y: harness.split.view.bounds.midY)
            // `hitTest` takes a point in the superview's coordinates.
            let hit = harness.split.view.hitTest(harness.split.view.convert(point, to: container))
            #expect(hit === harness.split.dividerHandle, "\(offset)")
        }
        #expect(harness.split.dividerHandle.toolTip?.isEmpty == false)
        #expect(harness.split.dividerHandle.accessibilityRole() == .splitter)
    }
}

/// The composer fills its column without pulling the chat wider, so the split view decides the chat's width.
@MainActor struct ComposerWidthTests {
    @Test func theComposerFillsUpToItsMaximumAndNeverWidensTheChat() {
        let composer = ComposerViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400))
        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        // As the main window's split view holds the chat's width.
        let width = view.widthAnchor.constraint(equalToConstant: 1200)
        width.priority = MainSplitViewController.contentHoldingPriority
        NSLayoutConstraint.activate([
            width, view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        #expect(composer.column.frame.width == Theme.contentMaxWidth)
        width.constant = 500
        container.layoutSubtreeIfNeeded()
        #expect(view.frame.width == 500)
        #expect(composer.column.frame.width == 500 - 2 * Theme.horizontalPadding)
    }
}
