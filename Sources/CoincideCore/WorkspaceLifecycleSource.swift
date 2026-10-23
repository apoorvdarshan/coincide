import Foundation

extension CodingThread {
    /// Cheap presentation/notification gate: completion never ends a snooze;
    /// a pending question or a failure after the latest snooze does.
    public func isEffectivelySnoozed(at now: Date) -> Bool {
        guard let until = workspaceLifecycle?.snoozedUntil, until > now, runtimeRequests.isEmpty else { return false }
        if state == .failed {
            let failedAt = runHistory?.last(where: { $0.status == .failed })?.endedAt ?? updatedAt
            if workspaceLifecycle?.snoozedAt.map({ failedAt > $0 }) ?? true { return false }
        }
        return true
    }
}

extension WorkspaceSnapshot {
    public func isEffectivelySnoozed(threadID: UUID, at now: Date) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }), thread.isEffectivelySnoozed(at: now) else { return false }
        return !(delegatedTasks ?? []).contains { task in
            task.parentThreadID == threadID && threads.contains { $0.id == task.childThreadID && !$0.runtimeRequests.isEmpty }
        }
    }
    public func workspaceLifecyclePullRequestLinks(threadID: UUID) -> [WorkspaceLifecyclePullRequestLink] {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return [] }
        var links: [WorkspaceLifecyclePullRequestLink] = []
        if let id = thread.pullRequestCheckoutOperationID,
           let operation = pullRequestCheckouts?.first(where: { $0.id == id && $0.phase == .completed && $0.targetThreadID == threadID && $0.projectID == thread.projectID }),
           operation.result?.destinationPath.utf8.elementsEqual(thread.workspacePath.utf8) == true,
           operation.result?.isOnPullRequestHead == true, thread.createdAt <= operation.updatedAt {
            links.append(.init(id: operation.id, reference: operation.review.plan.pullRequest.reference, linkedAt: operation.review.reviewedAt))
        }
        for operation in pullRequestCreations ?? [] {
            guard operation.sourceThreadID == threadID, operation.projectID == thread.projectID,
                  thread.createdAt <= operation.review.reviewedAt,
                  operation.registeredWorkspacePath.utf8.elementsEqual(thread.workspacePath.utf8),
                  operation.phase == .created || operation.phase == .openedExisting, let result = operation.result else { continue }
            let detail: GitHubPullRequestDetail
            switch result { case .created(let value), .openedExisting(let value): detail = value }
            links.append(.init(id: operation.id, reference: detail.summary.reference, linkedAt: operation.review.reviewedAt))
        }
        // This native model records exact checkout/create provenance rather
        // than a separately editable multi-PR link roster. Keep the latest
        // association; an old completed PR must not pin a reused thread forever.
        guard let latest = links.map(\.linkedAt).max() else { return [] }
        // Equal timestamps cannot establish which review is current, including
        // a repeated review of one PR. Keep that ambiguity for the host gate.
        return links.filter { $0.linkedAt == latest }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    @inline(never)
    public func workspaceLifecycleFacts(threadID: UUID) throws -> ThreadWorkspaceLifecycleFacts? {
        guard let thread = threads.first(where: { $0.id == threadID }), projects.contains(where: { $0.id == thread.projectID }) else { return nil }
        let runs = thread.runHistory ?? [], latest = runs.last
        let userMessages = thread.visibleMessages.filter { $0.role == .user }
        let authored = userMessages.filter { message in
            guard let reference = message.runReference, let run = runs.first(where: { $0.id == reference.runID }) else { return true }
            return run.origin != .agent && run.delegatedCompletion == nil
        }
        let tasks = (delegatedTasks ?? []).filter { $0.parentThreadID == thread.id }
        let children = tasks.compactMap { task in threads.first { $0.id == task.childThreadID } }
        let childRequests = children.contains { !$0.runtimeRequests.isEmpty }
        let delegatedWork = tasks.contains { !$0.status.isTerminal || $0.result == nil } || children.contains { $0.isBusy || !$0.queuedTurns.isEmpty }
        let nativeBackground = thread.visibleMessages.contains { message in
            guard let entity = message.providerEntity, ["subagent", "background_task", "monitor"].contains(entity.key.type) else { return false }
            return ["running", "waiting", "in_progress", "pending", "queued"].contains(entity.fields["status"].string ?? "")
        }
        let failedAt = thread.state == .failed ? (runs.last(where: { $0.status == .failed })?.endedAt ?? thread.updatedAt) : nil
        struct Content: Encodable { let title: String; let draft: ComposerDraftSnapshot }
        let contentDigest = try ContextTransferProtocol.digest(Content(title: thread.title, draft: .init(threadID: thread.id,
            projectID: thread.projectID, workspacePath: thread.workspacePath, text: thread.draft, attachments: thread.draftAttachments)))
        return try .init(id: thread.id, projectID: thread.projectID, workspacePath: thread.workspacePath,
            configurationDigest: ContextTransferProtocol.digest(ProviderConfiguration(thread: thread)), createdAt: thread.createdAt, updatedAt: thread.updatedAt,
            latestUserMessageAt: userMessages.map(\.createdAt).max(), latestUserAuthoredMessageAt: authored.map(\.createdAt).max(),
            latestRunRequestedAt: thread.queuedTurns.map(\.createdAt).max(), latestRunStartedAt: runs.map(\.startedAt).max() ?? thread.activeRun?.startedAt,
            latestRunCompletedAt: runs.compactMap(\.endedAt).max(), latestRunID: thread.activeRun?.id ?? latest?.id,
            failed: thread.state == .failed, failedAt: failedAt, busy: thread.isBusy,
            archived: thread.isArchived, pinned: thread.isPinned, pendingRequest: !thread.runtimeRequests.isEmpty || childRequests,
            pendingBackgroundWork: delegatedWork || nativeBackground, authoredQueue: thread.queuedTurns.contains { $0.delegatedCompletion == nil },
            canSettle: canSettle(threadID: thread.id), lifecycle: thread.workspaceLifecycle,
            pullRequests: workspaceLifecyclePullRequestLinks(threadID: threadID), contentDigest: contentDigest)
    }

    func validateWorkspaceLifecycle() throws {
        try (workspaceLifecyclePolicy ?? .init()).validate()
        for thread in threads { try thread.workspaceLifecycle?.validate() }
    }
}

extension WorkspaceDecision {
    @inline(never)
    mutating func applyWorkspaceLifecycle(_ action: WorkspaceLifecycleAction, commandID: UUID, now: Date, policy: WorkspaceLifecyclePolicy) throws {
        guard let index = snapshot.threads.firstIndex(where: { $0.id == action.threadID }), !snapshot.threads[index].isArchived,
              let facts = try snapshot.workspaceLifecycleFacts(threadID: action.threadID) else { throw WorkspaceLifecycleError.unavailable }
        var lifecycle = snapshot.threads[index].workspaceLifecycle ?? .init()
        switch action {
        case .snooze(_, let until):
            guard until.timeIntervalSince1970.isFinite, until > now else { throw WorkspaceLifecycleError.invalidRequest }
            guard WorkspaceLifecyclePolicyDecision.canSnooze(facts, now: now) else { throw WorkspaceLifecycleError.busy }
            lifecycle.snoozedUntil = until; lifecycle.snoozedAt = now
            snapshot.threads[index].updatedAt = now
        case .wake:
            if lifecycle.snoozedUntil != nil { lifecycle.lastSnoozeWakeAt = now; snapshot.threads[index].updatedAt = now }
            lifecycle.snoozedUntil = nil; lifecycle.snoozedAt = nil
        case .wakeExpired(let wake):
            guard wake.expectedUntil.timeIntervalSince1970.isFinite, wake.expectedSnoozedAt.timeIntervalSince1970.isFinite,
                  lifecycle.snoozedUntil == wake.expectedUntil, lifecycle.snoozedAt == wake.expectedSnoozedAt,
                  wake.expectedUntil <= now else { throw WorkspaceLifecycleError.stale }
            lifecycle.lastSnoozeWakeAt = wake.expectedUntil
            lifecycle.snoozedUntil = nil; lifecycle.snoozedAt = nil; snapshot.threads[index].updatedAt = now
        case .setAutoSettle(_, let enabled):
            if enabled != (lifecycle.autoSettleDisabledAt == nil) { snapshot.threads[index].updatedAt = now }
            lifecycle.autoSettleDisabledAt = enabled ? nil : lifecycle.autoSettleDisabledAt ?? now
        case .automaticallySettle(let proposal):
            try WorkspaceLifecyclePolicyDecision.validate(proposal, facts: facts, policy: policy, now: now)
            guard snapshot.canSettle(threadID: action.threadID) else { throw WorkspaceLifecycleError.busy }
            lifecycle.settledOverride = .settled; lifecycle.unsettledAt = nil
            lifecycle.snoozedUntil = nil; lifecycle.snoozedAt = nil
            snapshot.threads[index].settlement = .init(id: commandID, settledAt: proposal.settledAt)
            snapshot.threads[index].queuePaused = true; snapshot.threads[index].isPinned = false
            snapshot.threads[index].runtimeID = nil; snapshot.threads[index].runtimeRequests = []; snapshot.threads[index].providerActivity = nil
            snapshot.threads[index].updatedAt = now; closeRuntimes.insert(action.threadID)
        }
        try lifecycle.validate(); snapshot.threads[index].workspaceLifecycle = lifecycle
    }

    /// Central command integration calls this only after an action's native
    /// guards succeed. Attention changes never bypass a settlement's drain gate.
    mutating func reconcileWorkspaceLifecycle(previous: WorkspaceSnapshot, command: WorkspaceCommand, now: Date) {
        guard let id = command.threadID, let index = snapshot.threads.firstIndex(where: { $0.id == id }) else { return }
        var value = snapshot.threads[index].workspaceLifecycle ?? .init()
        switch command {
        case .settleThread:
            guard snapshot.threads[index].settlement != nil else { return }
            value.settledOverride = .settled; value.unsettledAt = nil; value.snoozedUntil = nil; value.snoozedAt = nil
            snapshot.threads[index].isPinned = false
        case .resumeThread:
            guard snapshot.threads[index].settlement?.phase == .resuming else { return }
            if value.settledOverride != .active { value.unsettledAt = now }
            value.settledOverride = .active
        case .editThread(_, .pinned(true)):
            if value.snoozedUntil != nil { value.lastSnoozeWakeAt = now }
            value.snoozedUntil = nil; value.snoozedAt = nil
        case .submit, .submitFromAppMCP, .submitCapturedClaude, .submitCapturedPi:
            value.snoozedUntil = nil; value.snoozedAt = nil
        default: return
        }
        if snapshot.threads[index].workspaceLifecycle == nil, value == ThreadWorkspaceLifecycle() { return }
        snapshot.threads[index].workspaceLifecycle = value
    }
}
