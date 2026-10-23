import Foundation

/// Faithful attention/age decisions use observed native state, never inferred
/// provider history boundaries or synthesized pull-request associations.
public enum WorkspaceLifecyclePolicyDecision {
    public static func hasQueuedTurnStart(_ facts: ThreadWorkspaceLifecycleFacts, now: Date) -> Bool {
        guard let message = facts.latestUserMessageAt, !facts.failed,
              abs(now.timeIntervalSince(message)) <= 120 else { return false }
        guard facts.latestRunID != nil else { return true }
        return [facts.latestRunRequestedAt, facts.latestRunStartedAt, facts.latestRunCompletedAt].allSatisfy { $0.map { $0 < message } ?? true }
    }
    public static func raisedHandWhileSnoozed(_ facts: ThreadWorkspaceLifecycleFacts) -> Bool {
        if facts.pendingRequest { return true }
        guard facts.failed else { return false }
        guard let snoozedAt = facts.lifecycle?.snoozedAt else { return true }
        return facts.failedAt.map { $0 > snoozedAt } ?? false
    }
    public static func effectiveSnoozed(_ facts: ThreadWorkspaceLifecycleFacts, now: Date) -> Bool {
        guard let until = facts.lifecycle?.snoozedUntil, until > now else { return false }
        return !raisedHandWhileSnoozed(facts)
    }
    public static func wokeAt(_ facts: ThreadWorkspaceLifecycleFacts, now: Date) -> Date? {
        guard let until = facts.lifecycle?.snoozedUntil else { return facts.lifecycle?.lastSnoozeWakeAt }
        if raisedHandWhileSnoozed(facts) {
            if facts.failed, let failed = facts.failedAt, facts.lifecycle?.snoozedAt.map({ failed > $0 }) ?? true { return failed }
            return facts.updatedAt
        }
        return until <= now ? until : nil
    }
    public static func canSnooze(_ facts: ThreadWorkspaceLifecycleFacts, now: Date) -> Bool {
        !facts.archived && !facts.pendingRequest && !facts.authoredQueue && !hasQueuedTurnStart(facts, now: now)
    }
    public static func isAutoSettlementCandidate(_ facts: ThreadWorkspaceLifecycleFacts, now: Date) -> Bool {
        !facts.archived && !facts.pinned && facts.lifecycle?.settledOverride == nil && facts.lifecycle?.autoSettleDisabledAt == nil &&
            !facts.pendingRequest && !facts.busy && !facts.pendingBackgroundWork && !facts.authoredQueue && facts.canSettle &&
            !hasQueuedTurnStart(facts, now: now) && !effectiveSnoozed(facts, now: now)
    }
    public static func proposal(facts: ThreadWorkspaceLifecycleFacts, policy: WorkspaceLifecyclePolicy,
                                observations: [WorkspaceLifecyclePullRequestObservation] = [], now: Date) throws -> ThreadAutoSettlementProposal? {
        try policy.validate(); try facts.lifecycle?.validate()
        guard now.timeIntervalSince1970.isFinite, facts.createdAt.timeIntervalSince1970.isFinite,
              facts.updatedAt.timeIntervalSince1970.isFinite, policy.enabled,
              isAutoSettlementCandidate(facts, now: now) else { return nil }
        guard observations.count <= 100, facts.pullRequests.count <= 100,
              Set(facts.pullRequests.map(\.id)).count == facts.pullRequests.count,
              Set(observations.map { $0.link.id }).count == observations.count else { throw WorkspaceLifecycleError.invalidRequest }
        for observation in observations {
            guard facts.pullRequests.contains(observation.link), observation.link.linkedAt.timeIntervalSince1970.isFinite,
                  observation.observedAt.timeIntervalSince1970.isFinite,
                  abs(now.timeIntervalSince(observation.observedAt)) <= 120,
                  [observation.closedAt, observation.mergedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw WorkspaceLifecycleError.stale }
        }
        // Unknown or open linked work is authoritative even when the thread is
        // old. A terminal snapshot from before linking describes past work.
        guard observations.count == facts.pullRequests.count else { return nil }
        if observations.contains(where: { $0.state == .open || $0.newerOpenPullRequest }) { return nil }
        let waiting = observations.filter { observation in
            terminalAt(observation).map { $0 >= observation.link.linkedAt } ?? false
        }
        let activity = latest([facts.latestUserMessageAt, facts.latestRunRequestedAt, facts.latestRunStartedAt, facts.latestRunCompletedAt]) ?? facts.createdAt
        if let terminal = waiting.max(by: { (terminalAt($0) ?? .distantPast) < (terminalAt($1) ?? .distantPast) }),
           let terminalAt = terminalAt(terminal), terminalAt >= (latest([facts.createdAt, facts.latestUserAuthoredMessageAt]) ?? facts.createdAt),
           terminal.state == .closed || terminal.state == .merged && policy.onMerge {
            return try .init(facts: facts, policy: policy, settledAt: activity, evaluatedAt: now,
                reason: terminal.state == .closed ? .closedPullRequest : .mergedPullRequest, pullRequest: terminal, observations: observations)
        }
        if policy.keepPullRequests && !facts.pullRequests.isEmpty { return nil }
        guard let days = policy.afterDays else { return nil }
        let timerWake = facts.lifecycle?.snoozedUntil.flatMap { $0 <= now ? $0 : nil }
        let inactivity = latest([activity, facts.lifecycle?.lastSnoozeWakeAt, timerWake]) ?? activity
        guard inactivity < now.addingTimeInterval(-days * 86_400) else { return nil }
        return try .init(facts: facts, policy: policy, settledAt: inactivity, evaluatedAt: now, reason: .inactivity, pullRequest: nil, observations: observations)
    }
    public static func validate(_ proposal: ThreadAutoSettlementProposal, facts: ThreadWorkspaceLifecycleFacts,
                                policy: WorkspaceLifecyclePolicy, now: Date) throws {
        guard proposal.threadID == facts.id, proposal.projectID == facts.projectID,
              proposal.workspacePath.utf8.elementsEqual(facts.workspacePath.utf8), proposal.expectedUpdatedAt == facts.updatedAt,
              proposal.policy == policy, try ContextTransferProtocol.digest(facts) == proposal.expectedFingerprint,
              proposal.evaluatedAt <= now else { throw WorkspaceLifecycleError.stale }
        guard let current = try Self.proposal(facts: facts, policy: policy, observations: proposal.observations, now: now),
              current.reason == proposal.reason, current.settledAt == proposal.settledAt,
              current.pullRequest == proposal.pullRequest else { throw WorkspaceLifecycleError.stale }
    }
    private static func terminalAt(_ value: WorkspaceLifecyclePullRequestObservation) -> Date? { value.state == .merged ? value.mergedAt : value.closedAt }
    private static func latest(_ values: [Date?]) -> Date? { values.compactMap { $0 }.filter { $0.timeIntervalSince1970.isFinite }.max() }
}
