import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// A transcript host that knows one tool call and records what it was asked to show.
@MainActor
private final class RevealingTranscriptHost: TranscriptHost {
    let textCache = TranscriptTextCache()
    var threadID: UUID? { nil }
    var isThreadRunning: Bool { false }
    var toolCalls: [String: UUID] = [:]
    var revealed: [UUID] = []

    func item(_ id: UUID) -> TranscriptItem? { nil }
    func isExpanded(_ id: TranscriptRowID) -> Bool { false }
    func toggle(_ id: TranscriptRowID) {}
    func copyToPasteboard(_ text: String) {}
    func rewindTurn(_ itemID: UUID) {}
    func forkTurn(_ itemID: UUID) {}
    func canFork(_ itemID: UUID) -> Bool { false }
    func openThread(_ threadID: UUID) {}
    func showDiff(turnID: UUID, path: String?) {}
    func openLink(_ link: Any) -> Bool { false }
    func previewAttachments(_ paths: [String], selected: Int) {}
    func quote(_ text: String, from itemID: UUID) {}
    func openContext(_ context: MessageContext, from anchor: NSView) {}
    func changedFiles(for turnID: UUID) -> [ChangedFile] { [] }
    func modelLabel(for meta: AssistantMeta) -> String { "" }
    func modelName(for meta: AssistantMeta) -> String? { nil }
    func rail(for id: TranscriptRowID) -> TranscriptRail? { nil }
    func findHighlights(for itemID: UUID) -> TranscriptFindHighlights? { nil }
    func toolCallItem(_ toolCallID: String, provider: ProviderKind) -> UUID? { provider == .claude ? toolCalls[toolCallID] : nil }
    func reveal(_ itemID: UUID) { revealed.append(itemID) }
}

/// The live line between turns: a line per background task, with what it is, what it does and how long it has run.
@MainActor struct BackgroundWorkLineTests {
    private let host = RevealingTranscriptHost()

    private func cell(_ tasks: [BackgroundTask]) -> (TranscriptLiveCell, [TranscriptBackgroundTaskLine]) {
        let cell = TranscriptLiveCell(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
        let row = TranscriptRow(id: .live, kind: .live(.background(.claude, tasks: tasks)), revision: 0)
        cell.configure(row, host: host)
        cell.layoutSubtreeIfNeeded()
        let lines = cell.subviews.compactMap { $0 as? TranscriptBackgroundTaskLine }.filter { !$0.isHidden }
        return (cell, lines)
    }

    @Test func listsEachTaskWithItsKindProgressAndElapsedTime() {
        let started = Date().addingTimeInterval(-125)
        let agent = BackgroundTask(
            id: "a1", title: "Audit the port", kind: .agent, toolCallID: "toolu_1", startedAt: started, agentType: "general-purpose",
            progress: "Running the tests")
        let command = BackgroundTask(id: "b1", title: "npm run dev", kind: .command, toolCallID: "toolu_2", startedAt: started)
        let (_, lines) = cell([agent, command])
        #expect(lines.count == 2)
        #expect(
            TranscriptLiveCell.title(.background(.claude, tasks: [agent, command]))
                == "\(ProviderKind.claude.displayName) is running 2 tasks in the background")
        #expect(TranscriptLiveCell.title(.background(.claude, tasks: [agent])) == "\(ProviderKind.claude.displayName) is working in the background")
        #expect(TranscriptBackgroundTaskLine.detail(agent) == "Subagent · general-purpose · Running the tests")
        #expect(TranscriptBackgroundTaskLine.detail(command) == "Command")
        #expect(lines.first?.accessibilityLabel() == "Audit the port, Subagent · general-purpose · Running the tests, 2m 05s")
        #expect(lines.last?.accessibilityLabel() == "npm run dev, Command, 2m 05s")
        // A line each below the live line, which keeps its own height.
        let row = TranscriptRow(id: .live, kind: .live(.background(.claude, tasks: [agent, command])), revision: 0)
        let thinking = TranscriptRow(id: .live, kind: .live(.thinking), revision: 0)
        let width: CGFloat = 720
        #expect(
            TranscriptLiveCell.height(for: row, width: width, host: host)
                == TranscriptLiveCell.height(for: thinking, width: width, host: host) + 2 * TranscriptBackgroundTaskLine.height)
        #expect(lines.map(\.frame.minY) == [TranscriptMetrics.workRowHeight, TranscriptMetrics.workRowHeight + TranscriptBackgroundTaskLine.height])
    }

    @Test func clickingATaskShowsTheToolCallThatStartedIt() {
        let item = UUID()
        host.toolCalls["toolu_1"] = item
        let known = BackgroundTask(id: "a1", title: "Audit the port", kind: .agent, toolCallID: "toolu_1")
        let unknown = BackgroundTask(id: "b1", title: "npm run dev", kind: .command)
        let (_, lines) = cell([known, unknown])
        #expect(lines.map { $0.accessibilityRole() } == [.button, .staticText])
        #expect(lines[0].accessibilityPerformPress())
        #expect(host.revealed == [item])
        #expect(!lines[1].accessibilityPerformPress())
        #expect(host.revealed == [item])
    }

    /// A background command's title is often its whole script; it must stay on its own line, not draw over the next.
    @Test func multiLineTitlesStayOnOneLine() {
        let script = BackgroundTask(
            id: "c1", title: "python3 -c \"\np = 'Tests.swift'\ns = open(p).read()\n\"", kind: .command, toolCallID: "toolu_3")
        let agent = BackgroundTask(id: "a1", title: "Right-align user messages", kind: .agent)
        let (_, lines) = cell([script, agent])
        #expect(TranscriptBackgroundTaskLine.oneLine(script.title) == "python3 -c \" p = 'Tests.swift' s = open(p).read() \"")
        #expect(lines.first?.accessibilityLabel()?.contains("\n") == false)
        for line in lines {
            for field in line.subviews.compactMap({ $0 as? NSTextField }) where !field.isHidden {
                #expect(field.frame.minY >= 0 && field.frame.maxY <= line.bounds.height, "\(field.stringValue)")
            }
        }
        #expect(lines.map(\.frame.minY) == [TranscriptMetrics.workRowHeight, TranscriptMetrics.workRowHeight + TranscriptBackgroundTaskLine.height])
    }

    @Test func linesFollowTheTasksAsTheyFinish() {
        let host = self.host
        let cell = TranscriptLiveCell(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
        let tasks = (1...3).map { BackgroundTask(id: "t\($0)", title: "Task \($0)", kind: .other) }
        cell.configure(TranscriptRow(id: .live, kind: .live(.background(.claude, tasks: tasks)), revision: 0), host: host)
        cell.configure(TranscriptRow(id: .live, kind: .live(.background(.claude, tasks: [tasks[2]])), revision: 1), host: host)
        let shown = cell.subviews.compactMap { $0 as? TranscriptBackgroundTaskLine }.filter { !$0.isHidden }
        #expect(shown.map { $0.accessibilityLabel() } == ["Task 3, Task"])
        // A task without a start time shows no clock, and a turn hides them all.
        cell.configure(TranscriptRow(id: .live, kind: .live(.thinking), revision: 2), host: host)
        let lines = cell.subviews.compactMap { $0 as? TranscriptBackgroundTaskLine }
        #expect(lines.allSatisfy { $0.isHidden })
    }
}
