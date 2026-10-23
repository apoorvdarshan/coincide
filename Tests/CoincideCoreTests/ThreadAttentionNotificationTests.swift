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

@Test func threadNotificationsConsumeSnoozedSuccessWithoutReplayingWhenSnoozeExpires() {
    let start = Date(timeIntervalSince1970: 1_700_000_000), expires = start.addingTimeInterval(600)
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.workspaceLifecycle = .init(snoozedUntil: expires, snoozedAt: start)
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread), now: start).isEmpty)
    thread.runHistory?[0].status = .completed
    thread.runHistory?[0].endedAt = start.addingTimeInterval(60)
    #expect(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(60)).isEmpty)
    #expect(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(120)).isEmpty)
    #expect(tracker.observe(notificationSnapshot(thread), now: expires).isEmpty)
    thread.workspaceLifecycle?.snoozedUntil = nil; thread.workspaceLifecycle?.snoozedAt = nil
    #expect(tracker.observe(notificationSnapshot(thread), now: expires.addingTimeInterval(1)).isEmpty)

    // Consumption applies only to the old completion. A later observed run
    // still produces its own notification after the snooze has expired.
    let next = notificationRun(thread, status: .running)
    thread.runHistory?.append(next)
    #expect(tracker.observe(notificationSnapshot(thread), now: expires.addingTimeInterval(2)).isEmpty)
    thread.runHistory?[1].status = .completed
    thread.runHistory?[1].endedAt = expires.addingTimeInterval(3)
    let events = tracker.observe(notificationSnapshot(thread), now: expires.addingTimeInterval(3))
    #expect(events.count == 1 && events.first?.kind == .completed && events.first?.runID == next.id)
}

@Test func threadNotificationsFreshFailureWakesSnoozedThreadAndRestampingConsumesTheOldFailure() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000), failedAt = start.addingTimeInterval(60)
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.workspaceLifecycle = .init(snoozedUntil: start.addingTimeInterval(600), snoozedAt: start)
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread), now: start).isEmpty)
    thread.state = .failed; thread.runHistory?[0].status = .failed; thread.runHistory?[0].endedAt = failedAt
    let failure = try #require(tracker.observe(notificationSnapshot(thread), now: failedAt).first)
    #expect(failure.kind == .failed && tracker.eventIsCurrent(failure))
    #expect(!notificationSnapshot(thread).isEffectivelySnoozed(threadID: thread.id, at: failedAt))

    // A subsequent explicit snooze hides the already observed error, and also
    // invalidates a delivery still queued behind native notification permission.
    let restampedAt = failedAt.addingTimeInterval(1), expires = restampedAt.addingTimeInterval(600)
    thread.workspaceLifecycle = .init(snoozedUntil: expires, snoozedAt: restampedAt)
    #expect(tracker.observe(notificationSnapshot(thread), now: restampedAt).isEmpty)
    #expect(!tracker.eventIsCurrent(failure))
    #expect(tracker.observe(notificationSnapshot(thread), now: expires).isEmpty)
    #expect(!tracker.eventIsCurrent(failure))
}

@Test(arguments: [false, true])
func threadNotificationsFreshQuestionOrApprovalWakesSnoozeAndDismissalCancelsQueuedNotice(question: Bool) throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.workspaceLifecycle = .init(snoozedUntil: start.addingTimeInterval(600), snoozedAt: start)
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread), now: start).isEmpty)
    let method = question ? "item/tool/requestUserInput" : "item/commandExecution/requestApproval"
    thread.runtimeRequests = [.init(request: .init(id: .string("new-snoozed-request"), method: method,
        params: .object(["private": .string("must-not-enter-alert")])))]
    let events = tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(30))
    let event = try #require(events.first)
    #expect(events.count == 1 && event.kind == (question ? .input : .approval))
    #expect(!event.threadTitle.contains("must-not-enter-alert") && tracker.eventIsCurrent(event))
    #expect(!notificationSnapshot(thread).isEffectivelySnoozed(threadID: thread.id, at: start.addingTimeInterval(30)))
    #expect(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(31)).isEmpty)
    thread.runtimeRequests = []
    #expect(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(32)).isEmpty)
    #expect(!tracker.eventIsCurrent(event))
    #expect(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(600)).isEmpty)
}

@Test func threadNotificationsRestampingSnoozeInvalidatesQueuedSuccessWithoutExpiryReplay() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var tracker = ThreadAttentionNotificationTracker(), thread = notificationThread()
    thread.runHistory = [notificationRun(thread, status: .running)]
    #expect(tracker.observe(notificationSnapshot(thread), now: start).isEmpty)
    thread.runHistory?[0].status = .completed; thread.runHistory?[0].endedAt = start.addingTimeInterval(1)
    let queued = try #require(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(1)).first)
    #expect(tracker.eventIsCurrent(queued))
    let expires = start.addingTimeInterval(600)
    thread.workspaceLifecycle = .init(snoozedUntil: expires, snoozedAt: start.addingTimeInterval(2))
    #expect(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(2)).isEmpty)
    #expect(!tracker.eventIsCurrent(queued))
    thread.workspaceLifecycle = .init(snoozedUntil: expires.addingTimeInterval(600), snoozedAt: start.addingTimeInterval(3))
    #expect(tracker.observe(notificationSnapshot(thread), now: start.addingTimeInterval(3)).isEmpty)
    #expect(tracker.observe(notificationSnapshot(thread), now: expires.addingTimeInterval(600)).isEmpty)
    #expect(!tracker.eventIsCurrent(queued))
}
