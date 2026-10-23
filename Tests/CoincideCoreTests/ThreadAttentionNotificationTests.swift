import Foundation
import Testing
@testable import CoincideCore

private func notificationThread() -> CodingThread {
    let project = WorkspaceProject(path: "/tmp/coincide-notification-policy")
    var thread = CodingThread(project: project)
    thread.title = "Generated notification thread"
    return thread
}

private func notificationSnapshot(_ thread: CodingThread) -> WorkspaceSnapshot {
    var result = WorkspaceSnapshot(); result.threads = [thread]; return result
}

private func notificationRun(_ thread: CodingThread, status: ThreadRunStatus, stop: Bool = false) -> ThreadRunRecord {
    var result = ThreadRunRecord(run: .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now), origin: .user)
    result.status = status; result.stopRequested = stop
    if status.isTerminal { result.endedAt = .now }
    return result
}

@Test func threadNotificationsDoNotReplayLoadedOrImportedHistoryAndDeduplicateTransitions() {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.runHistory = [notificationRun(thread, status: .completed)]
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    let next = notificationRun(thread, status: .running)
    thread.runHistory?.append(next)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runHistory?[1].status = .completed; thread.runHistory?[1].endedAt = .now
    let events = tracker.observe(notificationSnapshot(thread))
    #expect(events.count == 1 && events.first?.kind == .completed && events.first?.runID == next.id)
    #expect(events.first?.id == "coincide.thread." + thread.id.uuidString.lowercased())
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
}

@Test(arguments: [ThreadRunStatus.interrupted, .failed, .unknown, .completed])
func threadNotificationsRespectStopAndArchiveAndHistoryRemoval(status: ThreadRunStatus) {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runHistory = [notificationRun(thread, status: status, stop: true)]
    thread.state = status == .failed ? .failed : .idle
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.isArchived = true
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.isArchived = false
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    var new = notificationRun(thread, status: .completed)
    new.removedByHistoryOperationID = UUID()
    thread.runHistory?.append(new)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
}

@Test func threadNotificationsDistinguishApprovalQuestionsAndFailureWithoutTranscriptContent() {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runtimeRequests = [.init(request: .init(id: .number(1), method: "item/commandExecution/requestApproval", params: .object(["command": .string("private-command")])))]
    let approval = tracker.observe(notificationSnapshot(thread))
    #expect(approval.first?.kind == .approval && !approval.first!.threadTitle.contains("private-command"))
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runtimeRequests = [.init(request: .init(id: .number(2), method: "item/tool/requestUserInput", params: .object(["questions": .array([])])))]
    #expect(tracker.observe(notificationSnapshot(thread)).first?.kind == .input)
    thread.runtimeRequests = []; thread.state = .failed
    thread.runHistory?[0].status = .failed; thread.runHistory?[0].endedAt = .now
    #expect(tracker.observe(notificationSnapshot(thread)).first?.kind == .failed)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
}

@Test func threadNotificationsSeedBaselineAndSanitizeThreadNamesAndRepeatForNewRuns() {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.title = "Thread\n" + String(repeating: "工作", count: 100)
    #expect(tracker.observe(notificationSnapshot(thread), baseline: true).isEmpty)
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runHistory?[0].status = .completed; thread.runHistory?[0].endedAt = .now
    let first = tracker.observe(notificationSnapshot(thread))
    #expect(first.first?.threadTitle.contains("\n") == false && first.first!.threadTitle.unicodeScalars.count <= 160)
    let second = notificationRun(thread, status: .running)
    thread.runHistory?.append(second)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runHistory?[1].status = .completed; thread.runHistory?[1].endedAt = .now
    #expect(tracker.observe(notificationSnapshot(thread)).first?.runID != first.first?.runID)
    let third = notificationRun(thread, status: .completed)
    thread.runHistory?.append(third)
    #expect(tracker.observe(notificationSnapshot(thread), baseline: true).isEmpty)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(tracker.observe(WorkspaceSnapshot()).isEmpty)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
}

@Test func threadNotificationsIgnoreImportedTerminalRecordsAndHistoryRewinds() {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    let first = notificationRun(thread, status: .completed)
    thread.runHistory = [first]
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    let imported = notificationRun(thread, status: .completed)
    thread.runHistory?.append(imported)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runHistory?.removeLast()
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
}

@Test func threadNotificationsNeverReplayLoadedOrImportedFailureOnSubsequentUpdates() {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.runHistory = [notificationRun(thread, status: .failed)]; thread.state = .failed
    for _ in 0..<3 { #expect(tracker.observe(notificationSnapshot(thread)).isEmpty) }
    let imported = notificationRun(thread, status: .failed)
    thread.runHistory?.append(imported)
    for _ in 0..<3 { #expect(tracker.observe(notificationSnapshot(thread)).isEmpty) }
}

@Test func threadNotificationsRevalidateQueuedRequestsAcrossReplacementDismissalAndArchive() throws {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runtimeRequests = [.init(request: .init(id: .string("first"), method: "item/tool/requestUserInput", params: .object([:]))) ]
    let first = try #require(tracker.observe(notificationSnapshot(thread)).first)
    #expect(tracker.eventIsCurrent(first))
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(tracker.eventIsCurrent(first))

    thread.runtimeRequests[0].request.id = .string("replacement")
    let replacement = try #require(tracker.observe(notificationSnapshot(thread)).first)
    #expect(!tracker.eventIsCurrent(first) && tracker.eventIsCurrent(replacement))
    thread.runtimeRequests[0].responding = true
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(replacement))
    thread.runtimeRequests[0].responding = false
    let retried = try #require(tracker.observe(notificationSnapshot(thread)).first)
    #expect(tracker.eventIsCurrent(retried) && !tracker.eventIsCurrent(replacement))

    thread.isArchived = true
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(retried))
    thread.isArchived = false
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(retried), "Unarchiving cannot resurrect a delivery queued before archival.")
    thread.runtimeRequests = []
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(first) && !tracker.eventIsCurrent(retried))
}

@Test func threadNotificationsRevalidateCompletionAndFailureAcrossNewRunsHistoryRemovalAndDeletion() throws {
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    thread.runHistory?[0].status = .completed; thread.runHistory?[0].endedAt = .now
    let completed = try #require(tracker.observe(notificationSnapshot(thread)).first)
    #expect(tracker.eventIsCurrent(completed))
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty && tracker.eventIsCurrent(completed))
    thread.title = "Renamed after completion"
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(completed), "A queued alert cannot reveal a superseded thread name.")
    let next = notificationRun(thread, status: .running)
    thread.runHistory?.append(next)
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(completed))
    thread.state = .failed; thread.runHistory?[1].status = .failed; thread.runHistory?[1].endedAt = .now
    let failed = try #require(tracker.observe(notificationSnapshot(thread)).first)
    #expect(tracker.eventIsCurrent(failed))
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty && tracker.eventIsCurrent(failed))
    thread.runHistory?[1].removedByHistoryOperationID = UUID()
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(failed))
    #expect(tracker.observe(WorkspaceSnapshot()).isEmpty)
    #expect(!tracker.eventIsCurrent(completed) && !tracker.eventIsCurrent(failed))
    #expect(tracker.observe(notificationSnapshot(thread)).isEmpty)
    #expect(!tracker.eventIsCurrent(completed) && !tracker.eventIsCurrent(failed))
}
