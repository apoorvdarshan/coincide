import AppKit
import Testing

@testable import Coincide

/// Each thread keeps its own inspector: open or closed, and on which panel.
@MainActor struct InspectorFollowTests {
    private let all: [UIState.InspectorPanel] = [.diff, .pullRequests, .preview, .terminal]

    private func change(_ isOpen: Bool, _ panel: UIState.InspectorPanel, saved: UIState.InspectorPanel?) -> InspectorFollow.Change {
        InspectorFollow.change(isOpen: isOpen, panel: panel, saved: saved, available: all)
    }

    @Test func aThreadGetsThePanelItLastShowed() {
        // Closed: the thread's panel opens.
        #expect(change(false, .diff, saved: .preview) == .show(.preview))
        #expect(change(false, .preview, saved: .preview) == .show(.preview))
        #expect(change(false, .diff, saved: .terminal) == .show(.terminal))
        // Open on another panel: the column switches to the thread's.
        #expect(change(true, .diff, saved: .pullRequests) == .show(.pullRequests))
        #expect(change(true, .preview, saved: .diff) == .show(.diff))
        // Already on it: nothing to do.
        #expect(change(true, .pullRequests, saved: .pullRequests) == .none)
    }

    @Test func aThreadThatNeverOpenedOneHasItClosed() {
        for panel in all {
            #expect(change(true, panel, saved: nil) == .close)
            #expect(change(false, panel, saved: nil) == .none)
        }
    }

    @Test func aTerminalThatMovedBelowTheChatLeavesTheColumnClosed() {
        let withoutTerminal: [UIState.InspectorPanel] = [.diff, .pullRequests, .preview]
        #expect(InspectorFollow.change(isOpen: true, panel: .diff, saved: .terminal, available: withoutTerminal) == .close)
        #expect(InspectorFollow.change(isOpen: false, panel: .diff, saved: .terminal, available: withoutTerminal) == .none)
    }

    @Test func anEarlierVersionsOpenPanelStaysWithItsThread() throws {
        let thread = UUID()
        let folder = TemporaryDirectory("ui")
        let file = folder.url.appendingPathComponent("ui-state.json")
        func load(_ json: String) throws -> [String: UIState.InspectorPanel] {
            try Data(json.utf8).write(to: file)
            return UIState(directory: folder.url).values.threadPanels
        }
        let id = thread.uuidString
        #expect(try load(#"{"isInspectorOpen": true, "inspectorPanel": "preview", "selectedThreadID": "\#(id)"}"#) == [id: .preview])
        #expect(try load(#"{"isInspectorOpen": true, "inspectorPanel": "diff", "selectedThreadID": "\#(id)"}"#) == [id: .diff])
        // Closed, or a file that already keeps panels per thread, is taken as it is.
        #expect(try load(#"{"isInspectorOpen": false, "inspectorPanel": "preview", "selectedThreadID": "\#(id)"}"#).isEmpty)
        #expect(try load(#"{"isInspectorOpen": true, "selectedThreadID": "\#(id)", "threadPanels": {}}"#).isEmpty)
        let saved = UIState(directory: folder.url)
        saved.update { $0.threadPanels = [id: .pullRequests] }
        saved.flush()
        #expect(UIState(directory: folder.url).values.threadPanels == [id: .pullRequests])
    }
}

/// The window's split view, offscreen (`InspectorLayoutTests.Harness`), switching threads.
@MainActor @Suite(.serialized) struct InspectorFollowLayoutTests {
    typealias Harness = InspectorLayoutTests.Harness

    /// The inspector reads and writes its panel in the shared state; each test puts it back.
    private func withSharedPanel(_ panel: UIState.InspectorPanel, _ body: () -> Void) {
        let saved = UIState.shared.values
        defer { UIState.shared.update { $0 = saved } }
        UIState.shared.update { $0.inspectorPanel = panel }
        body()
    }

    @Test func aBrowserOpenedInOneThreadDoesntOpenInOthers() {
        withSharedPanel(.diff) {
            let harness = Harness(width: 1600) { $0.inspectorFraction = 0.4 }
            defer { harness.close() }
            let split = harness.split
            let first = UUID(), second = UUID()
            split.setThreadID(first)
            split.togglePreviewPanel()
            harness.settle()
            #expect(split.isPreviewOpen && abs(harness.share - 0.4) < 0.01)
            #expect(harness.state.values.threadPanels == [first.uuidString: .preview])

            // A thread that never opened its browser doesn't get an empty one.
            split.setThreadID(second)
            harness.settle()
            #expect(!split.isInspectorOpen)
            #expect(harness.state.values.threadPanels == [first.uuidString: .preview])

            // Back in the first thread, its browser is there again, as wide as it was.
            split.setThreadID(first)
            harness.settle()
            #expect(split.isPreviewOpen && abs(harness.share - 0.4) < 0.01)
            #expect(harness.sidebarWidth == 288)

            // Closed there, it stays closed.
            split.togglePreviewPanel()
            #expect(harness.state.values.threadPanels.isEmpty)
            split.setThreadID(second)
            split.setThreadID(first)
            #expect(!split.isInspectorOpen)
        }
    }

    @Test func everyPanelBelongsToItsThread() {
        withSharedPanel(.diff) {
            let harness = Harness(width: 1600) { $0.inspectorFraction = 0.35 }
            defer { harness.close() }
            let split = harness.split
            let diffThread = UUID(), pullsThread = UUID(), browserThread = UUID(), closedThread = UUID()
            split.setThreadID(diffThread)
            split.toggleDiffPanel()
            split.setThreadID(pullsThread)
            #expect(!split.isInspectorOpen, "a thread with no panel starts closed")
            split.togglePullRequestsPanel()
            split.setThreadID(browserThread)
            split.togglePreviewPanel()

            for _ in 0..<2 {
                split.setThreadID(diffThread)
                harness.settle()
                #expect(split.isDiffOpen && abs(harness.share - 0.35) < 0.01)
                split.setThreadID(pullsThread)
                #expect(split.isPullRequestsOpen)
                split.setThreadID(closedThread)
                #expect(!split.isInspectorOpen)
                split.setThreadID(browserThread)
                harness.settle()
                #expect(split.isPreviewOpen && abs(harness.share - 0.35) < 0.01)
            }

            // Switching a thread's column to another panel is remembered for that thread alone.
            split.setThreadID(diffThread)
            split.togglePullRequestsPanel()
            split.setThreadID(browserThread)
            #expect(split.isPreviewOpen)
            split.setThreadID(diffThread)
            #expect(split.isPullRequestsOpen)
            #expect(harness.state.values.threadPanels[diffThread.uuidString] == .pullRequests)
        }
    }

    @Test func anAgentsBrowserOutOfSightDoesntOpenThePanel() {
        withSharedPanel(.diff) {
            let harness = Harness()
            defer { harness.close() }
            let thread = UUID()
            // The agent drives the thread's browser headless; the panel never showed.
            _ = PreviewSessions.shared.session(for: thread)
            harness.split.setThreadID(thread)
            harness.settle()
            #expect(!harness.split.isInspectorOpen)
            #expect(harness.state.values.threadPanels.isEmpty)
        }
    }

    /// At launch the selected thread decides, before the window's first layout, and its panel opens at the saved
    /// share.
    @Test func aLaunchRestoresTheSelectedThreadsPanel() {
        let thread = UUID()
        withSharedPanel(.preview) {
            let other = Harness(width: 1600, threadID: UUID()) {
                $0.isInspectorOpen = true
                $0.inspectorPanel = .preview
                $0.threadPanels = [thread.uuidString: .preview]
            }
            defer { other.close() }
            #expect(!other.split.isInspectorOpen)
        }
        withSharedPanel(.diff) {
            let harness = Harness(width: 1600, threadID: thread) {
                $0.inspectorFraction = 0.4
                $0.threadPanels = [thread.uuidString: .pullRequests]
            }
            defer { harness.close() }
            harness.settle()
            #expect(harness.split.isPullRequestsOpen)
            #expect(abs(harness.share - 0.4) < 0.01)
        }
    }
}
