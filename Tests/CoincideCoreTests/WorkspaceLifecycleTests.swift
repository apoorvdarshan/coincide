import Foundation
import Testing
@testable import CoincideCore

private func lifecycleSnapshot(now: Date) -> WorkspaceSnapshot {
    let project = WorkspaceProject(path: "/private/coincide-lifecycle-fixture")
    var thread = CodingThread(project: project)
    thread.createdAt = now.addingTimeInterval(-10 * 86_400); thread.updatedAt = now.addingTimeInterval(-5 * 86_400)
    var message = ChatMessage(role: .user, text: "Preserve this original question")
    message.createdAt = thread.updatedAt; thread.messages = [message]; thread.draft = "Keep this unsent draft"
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; return snapshot
}

@Test func workspaceLifecycleSnoozeIsAttentionOnlyAndRejectsAuthoredQueuesQuestionsAndPastTimes() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000), snapshot = lifecycleSnapshot(now: now), id = snapshot.threads[0].id
    let until = now.addingTimeInterval(3_600)
    let pinnedLegacy = try WorkspaceDecision.make(.client(.editThread(id, .pinned(true))), id: UUID(), snapshot: snapshot, now: now)
    #expect(pinnedLegacy.snapshot.threads[0].workspaceLifecycle == nil)
    let snoozed = try WorkspaceDecision.make(.client(.workspaceLifecycle(.snooze(threadID: id, until: until))), id: UUID(), snapshot: snapshot, now: now)
    #expect(snoozed.snapshot.threads[0].isEffectivelySnoozed(at: now))
    #expect(snoozed.snapshot.threads[0].draft == snapshot.threads[0].draft && snoozed.snapshot.threads[0].messages == snapshot.threads[0].messages)
    #expect(snoozed.effects.isEmpty && snoozed.closeRuntimes.isEmpty && snoozed.snapshot.threads[0].settlement == nil)
    let pinnedSnooze = try WorkspaceDecision.make(.client(.editThread(id, .pinned(true))), id: UUID(), snapshot: snoozed.snapshot, now: now.addingTimeInterval(1))
    #expect(pinnedSnooze.snapshot.threads[0].workspaceLifecycle?.lastSnoozeWakeAt == now.addingTimeInterval(1))
    #expect(pinnedSnooze.snapshot.threads[0].workspaceLifecycle?.snoozedUntil == nil)
    for change in ["authored-queue", "request", "past"] {
        var changed = snapshot
        if change == "authored-queue" { changed.threads[0].queuedTurns = [.init(id: UUID(), text: "Never remove this", configuration: .init(thread: changed.threads[0]), createdAt: now)] }
        if change == "request" { changed.threads[0].runtimeRequests = [.init(request: .init(id: .number(1), method: "item/tool/requestUserInput", params: .object([:])), responding: false)] }
        #expect(throws: WorkspaceLifecycleError.self) {
            _ = try WorkspaceDecision.make(.client(.workspaceLifecycle(.snooze(threadID: id, until: change == "past" ? now : until))), id: UUID(), snapshot: changed, now: now)
        }
    }
    var running = snapshot
    running.threads[0].activeRun = .init(id: UUID(), configuration: .init(thread: running.threads[0]), startedAt: now)
    running.threads[0].state = .running
    let hiddenRunning = try WorkspaceDecision.make(.client(.workspaceLifecycle(.snooze(threadID: id, until: until))), id: UUID(), snapshot: running, now: now)
    #expect(hiddenRunning.snapshot.threads[0].activeRun?.id == running.threads[0].activeRun?.id && hiddenRunning.effects.isEmpty)
}

@Test func workspaceLifecycleFreshFailuresAndQuestionsWakeButCompletionAndOlderFailuresDoNot() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000); var snapshot = lifecycleSnapshot(now: now)
    snapshot.threads[0].workspaceLifecycle = .init(snoozedUntil: now.addingTimeInterval(3_600), snoozedAt: now)
    #expect(snapshot.threads[0].isEffectivelySnoozed(at: now.addingTimeInterval(1)))
    var run = ThreadRunRecord(run: .init(id: UUID(), configuration: .init(thread: snapshot.threads[0]), startedAt: now.addingTimeInterval(-10)), origin: .user)
    run.status = .completed; run.endedAt = now.addingTimeInterval(1); snapshot.threads[0].runHistory = [run]
    #expect(snapshot.threads[0].isEffectivelySnoozed(at: now.addingTimeInterval(2)))
    snapshot.threads[0].state = .failed; run.status = .failed; run.endedAt = now.addingTimeInterval(-1); snapshot.threads[0].runHistory = [run]
    snapshot.threads[0].updatedAt = now.addingTimeInterval(100)
    #expect(snapshot.threads[0].isEffectivelySnoozed(at: now.addingTimeInterval(2)))
    snapshot.threads[0].runHistory?[0].endedAt = now.addingTimeInterval(1)
    #expect(!snapshot.threads[0].isEffectivelySnoozed(at: now.addingTimeInterval(2)))
    snapshot.threads[0].state = .idle
    snapshot.threads[0].runtimeRequests = [.init(request: .init(id: .number(1), method: "item/tool/requestUserInput", params: .object([:])), responding: false)]
    #expect(!snapshot.threads[0].isEffectivelySnoozed(at: now.addingTimeInterval(2)))
}

@Test func workspaceLifecycleExpiredTimerPinsBothSnoozeStampsAndPersistsOriginalDeadlineAfterOfflineTime() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000); var snapshot = lifecycleSnapshot(now: now)
    let id = snapshot.threads[0].id, until = now.addingTimeInterval(-7 * 86_400), at = until.addingTimeInterval(-3_600)
    snapshot.threads[0].workspaceLifecycle = .init(snoozedUntil: until, snoozedAt: at)
    let wake = WorkspaceLifecycleExpiredSnooze(threadID: id, expectedUntil: until, expectedSnoozedAt: at)
    let result = try WorkspaceDecision.make(.client(.workspaceLifecycle(.wakeExpired(wake))), id: wake.id, snapshot: snapshot, now: now)
    #expect(result.snapshot.threads[0].workspaceLifecycle?.lastSnoozeWakeAt == until)
    #expect(result.snapshot.threads[0].workspaceLifecycle?.snoozedUntil == nil && result.effects.isEmpty && result.snapshot.threads[0].activeRun == nil)
    snapshot.threads[0].workspaceLifecycle = .init(snoozedUntil: until, snoozedAt: at.addingTimeInterval(1))
    #expect(throws: WorkspaceLifecycleError.stale) { _ = try WorkspaceDecision.make(.client(.workspaceLifecycle(.wakeExpired(wake))), id: wake.id, snapshot: snapshot, now: now) }
}

@Test(arguments: ["pinned", "active-override", "disabled", "busy", "request", "background", "snoozed", "recent-wake", "eligible"])
func workspaceLifecycleAutomaticAgeSettlementPreservesExplicitActivityAndPendingWork(condition: String) throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000), old = now.addingTimeInterval(-5 * 86_400)
    let lifecycle: ThreadWorkspaceLifecycle?
    switch condition {
    case "active-override": lifecycle = .init(settledOverride: .active)
    case "disabled": lifecycle = .init(autoSettleDisabledAt: old)
    case "snoozed": lifecycle = .init(snoozedUntil: now.addingTimeInterval(3_600), snoozedAt: old)
    case "recent-wake": lifecycle = .init(lastSnoozeWakeAt: now.addingTimeInterval(-86_400))
    default: lifecycle = nil
    }
    let facts = ThreadWorkspaceLifecycleFacts(id: UUID(), projectID: UUID(), workspacePath: "/private/captured", configurationDigest: String(repeating: "a", count: 64), createdAt: old, updatedAt: old,
        busy: condition == "busy", pinned: condition == "pinned", pendingRequest: condition == "request", pendingBackgroundWork: condition == "background", lifecycle: lifecycle)
    let proposal = try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(), now: now)
    #expect((proposal != nil) == (condition == "eligible"))
    if let proposal { #expect(proposal.settledAt == old && proposal.reason == .inactivity) }
}

@Test func workspaceLifecycleLinkedPullRequestsRequireFreshCompleteTerminalEvidenceAndDoNotGuessFromUpdatedAt() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000), old = now.addingTimeInterval(-5 * 86_400)
    let repo = try GitHubRepository(owner: "acme", name: "actual"), ref = try GitHubPullRequestReference(repository: repo, number: 1)
    let link = WorkspaceLifecyclePullRequestLink(id: UUID(), reference: ref, linkedAt: old)
    let facts = ThreadWorkspaceLifecycleFacts(id: UUID(), projectID: UUID(), workspacePath: "/private/captured", configurationDigest: String(repeating: "a", count: 64), createdAt: old, updatedAt: old,
        latestUserAuthoredMessageAt: old, pullRequests: [link])
    let merged = WorkspaceLifecyclePullRequestObservation(link: link, state: .merged, mergedAt: now.addingTimeInterval(-60), observedAt: now)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(afterDays: nil), observations: [merged], now: now)?.reason == .mergedPullRequest)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(), now: now) == nil)
    let missingDate = WorkspaceLifecyclePullRequestObservation(link: link, state: .merged, observedAt: now)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(afterDays: nil), observations: [missingDate], now: now) == nil)
    let newerOpen = WorkspaceLifecyclePullRequestObservation(link: link, state: .merged, mergedAt: now.addingTimeInterval(-60), observedAt: now, newerOpenPullRequest: true)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(), observations: [newerOpen], now: now) == nil)
    let closed = WorkspaceLifecyclePullRequestObservation(link: link, state: .closed, closedAt: now.addingTimeInterval(-60), observedAt: now)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(onMerge: false), observations: [closed], now: now)?.reason == .closedPullRequest)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(afterDays: nil, onMerge: false), observations: [merged], now: now) == nil)
    let terminalBeforeLink = WorkspaceLifecyclePullRequestObservation(link: link, state: .closed, closedAt: old.addingTimeInterval(-1), observedAt: now)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(keepPullRequests: true), observations: [terminalBeforeLink], now: now) == nil)
    let second = WorkspaceLifecyclePullRequestLink(id: UUID(), reference: try .init(repository: repo, number: 2), linkedAt: old)
    let multiple = ThreadWorkspaceLifecycleFacts(id: facts.id, projectID: facts.projectID, workspacePath: facts.workspacePath, configurationDigest: facts.configurationDigest,
        createdAt: old, updatedAt: old, pullRequests: [link, second])
    let open = WorkspaceLifecyclePullRequestObservation(link: second, state: .open, observedAt: now)
    #expect(try WorkspaceLifecyclePolicyDecision.proposal(facts: multiple, policy: .init(), observations: [merged, open], now: now) == nil)
}

@Test func workspaceLifecycleAutomaticProposalRefusesLaterDraftEvenWhenThreadUpdatedAtDidNotChange() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000), initial = lifecycleSnapshot(now: now)
    let facts = try #require(try initial.workspaceLifecycleFacts(threadID: initial.threads[0].id))
    let proposal = try #require(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(), now: now))
    var changed = initial; changed.threads[0].draft = "User typed after the sweep"
    var decision = WorkspaceDecision(snapshot: changed)
    #expect(throws: WorkspaceLifecycleError.stale) { try decision.applyWorkspaceLifecycle(.automaticallySettle(proposal), commandID: proposal.id, now: now, policy: .init()) }
    #expect(decision.snapshot == changed && decision.effects.isEmpty)
}
