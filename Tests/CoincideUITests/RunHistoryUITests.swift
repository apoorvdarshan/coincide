import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private func runHistoryFixture() -> CodingThread {
    let project = WorkspaceProject(path: "/tmp/coincide-history-source")
    var thread = CodingThread(project: project, model: "captured-model")
    thread.title = "Synthetic run history"
    thread.messages = [.init(id: "history-user", role: .user, text: "Keep the exact original prompt")]
    thread.permission = .supervised
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let first = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: start, stopRequested: false,
                          nativeTurnID: "adapter-created-turn")
    var completed = ThreadRunRecord(run: first, origin: .user, userMessageID: "history-user")
    completed.status = .completed; completed.endedAt = start.addingTimeInterval(4); completed.endReason = .providerCompleted
    completed.providerThreadID = "synthetic-provider-session"; completed.providerStopReason = "end_turn"
    thread.provider = .claude
    thread.model = "captured-agent-model"; thread.workspacePath = "/tmp/coincide-history-other-checkout"
    let second = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: start.addingTimeInterval(6),
                           stopRequested: true, nativeTurnID: nil)
    var waiting = ThreadRunRecord(run: second, origin: .agent); waiting.status = .awaitingApproval
    thread.runHistory = [completed, waiting]
    thread.model = "current-settings-must-not-replace-captured-settings"
    thread.permission = .fullAccess; thread.workspacePath = "/tmp/current-workspace"
    thread.draft = "An unsent draft stays unchanged"
    return thread
}

@Test func runHistoryUsesCapturedSettingsAndHonestPromptOriginsWithoutChangingTranscript() throws {
    let thread = runHistoryFixture(), before = thread
    let records = RunHistoryPresentation.records(in: thread)
    #expect(records.map(\.id) == Array(try #require(thread.runHistory).map(\.id).reversed()))
    let completed = try #require(records.last), waiting = try #require(records.first)
    #expect(RunHistoryPresentation.prompt(completed, in: thread) == "Keep the exact original prompt")
    #expect(RunHistoryPresentation.model(completed.configuration) == "captured-model")
    #expect(completed.configuration.permission == .supervised)
    #expect(completed.configuration.workspacePath == "/tmp/coincide-history-source")
    #expect(RunHistoryPresentation.provider(waiting.configuration) == "Claude")
    #expect(RunHistoryPresentation.prompt(waiting, in: thread) == "Agent-initiated run")
    #expect(waiting.stopRequested && waiting.status == .awaitingApproval)
    var legacy = waiting; legacy.origin = .legacy; legacy.userMessageID = "history-user"
    #expect(RunHistoryPresentation.prompt(legacy, in: thread).contains("not recorded"))
    var missing = completed; missing.userMessageID = "missing-user-message"
    #expect(RunHistoryPresentation.prompt(missing, in: thread) == "User message unavailable")
    var defaultModel = waiting.configuration; defaultModel.model = ""
    #expect(RunHistoryPresentation.model(defaultModel) == "Default model")
    #expect(RunHistoryPresentation.status(.unknown) == "Outcome unknown")
    #expect(thread == before)
}

@Test func runHistoryDoesNotInventRecordsForEarlierMessagesOrEmptyConversations() {
    var thread = runHistoryFixture(); thread.runHistory = nil
    #expect(RunHistoryPresentation.records(in: thread).isEmpty)
    #expect(RunHistoryPresentation.emptyDescription(thread) == "Earlier messages do not include recorded run details.")
    var mixed = runHistoryFixture()
    #expect(!RunHistoryPresentation.hasUnrecordedMessages(in: mixed))
    mixed.messages.insert(.init(id: "earlier-user", role: .user, text: "Earlier unrecorded message"), at: 0)
    #expect(RunHistoryPresentation.hasUnrecordedMessages(in: mixed))
    #expect(RunHistoryPresentation.records(in: mixed).count == 2)
    thread.messages = []; thread.runHistory = []
    #expect(RunHistoryPresentation.records(in: thread).isEmpty)
    #expect(RunHistoryPresentation.emptyDescription(thread).contains("after a message starts"))
}

@MainActor @Test func nativeRunHistoryFitsSmallSheetsAndBothAppearancesWithoutEditingConversation() async throws {
    _ = NSApplication.shared
    let fixture = runHistoryFixture(), before = fixture
    var legacy = fixture; legacy.runHistory = nil
    var mixed = fixture
    mixed.messages.insert(.init(id: "earlier-user", role: .user, text: "Earlier unrecorded message"), at: 0)
    let contents: [(String, CodingThread?)] = [("recorded", fixture), ("mixed", mixed), ("legacy", legacy), ("removed", nil)]
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 560] {
            for (name, thread) in contents {
                let view = RunHistoryContent(thread: thread).environment(\.colorScheme, scheme)
                let hosting = NSHostingController(rootView: view)
                let size = hosting.sizeThatFits(in: CGSize(width: width, height: 560))
                #expect(size.width <= width + 1 && size.height <= 600)
                try await captureRunHistory(view, name: name, width: width, height: max(320, size.height), scheme: scheme)
            }
        }
    }
    #expect(fixture == before)
}

@MainActor private func captureRunHistory<Content: View>(_ content: Content, name: String, width: CGFloat,
                                                       height: CGFloat, scheme: ColorScheme) async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_HISTORY"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let view = content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: height)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; hosting.appearance = appearance
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let color = scheme == .light ? "light" : "dark"
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-\(name)-\(Int(width))-\(color).png")
    try data.write(to: path)
    print("Run history preview: \(path.path)")
}
