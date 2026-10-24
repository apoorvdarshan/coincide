import Foundation

extension WorkspaceSnapshot {
    public func delegatedTaskTree(_ taskID: UUID) -> [DelegatedTask] {
        guard let original = delegatedTasks?.first(where: { $0.id == taskID }) else { return [] }
        var values = (delegatedTasks ?? []).filter { $0.childThreadID == original.childThreadID }
        var seen = Set(values.map(\.id)), index = 0
        while index < values.count {
            for task in delegatedTasks ?? [] where task.parentTaskID == values[index].id {
                if seen.insert(task.id).inserted { values.append(task) }
            }
            index += 1
        }
        return values
    }
    func validateDelegatedTasks() throws {
        let tasks = delegatedTasks ?? [], cohorts = delegatedTaskCohorts ?? [], transfers = delegatedTaskTransfers ?? []
        guard tasks.count <= TaskOrchestration.maximumTasks,
              Set(tasks.map(\.id)).count == tasks.count,
              Set(tasks.map(\.commandID)).count == tasks.count,
              Set(cohorts.map(\.id)).count == cohorts.count, Set(transfers.map(\.id)).count == transfers.count,
              try TaskOrchestration.payload(tasks).count + TaskOrchestration.payload(cohorts).count + TaskOrchestration.payload(transfers).count <= TaskOrchestration.maximumLedgerBytes else { throw DelegatedTaskError.limit }
        for task in tasks {
            try task.isolationProof?.validate()
            guard task.isFollowup == true || (task.request.isolation == .worktree) == (task.isolationProof != nil),
                   task.id != task.childThreadID, task.childRunID != task.parentRunID,
                  task.request.parentThreadID == task.parentThreadID,
                  task.request.parentRunID == task.parentRunID,
                  task.isFollowup == true || !task.request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.request.task.utf16.count <= 120_000, !task.request.task.contains("\0"),
                  task.request.title.map({ $0.utf16.count <= 512 && !$0.contains("\0") }) ?? true,
                  task.isFollowup == true || (task.request.configuration.nativeThreadID == nil && task.request.configuration.claudeLaunchSelection == nil),
                  task.result == nil || (task.status.isTerminal && task.workState == .resultAvailable && task.completedAt != nil),
                  task.parentTaskID == nil || tasks.contains(where: { $0.id == task.parentTaskID && $0.childThreadID == task.parentThreadID }) else { throw DelegatedTaskError.invalidRequest }
            if task.isFollowup != true {
                guard transfers.contains(where: { $0.taskID == task.id && $0.kind == .subagentSpawn && $0.id == TaskOrchestration.derivedID(task.id, "spawn") }) else { throw DelegatedTaskError.invalidRequest }
            }
            if let child = threads.first(where: { $0.id == task.childThreadID }) {
                guard let lineage = child.delegatedTaskLineage,
                      lineage.parentThreadID == task.parentThreadID,
                      tasks.contains(where: { $0.id == lineage.taskID && $0.childThreadID == child.id }) else { throw DelegatedTaskError.invalidRequest }
            }
            if let result = task.result {
                guard result.status == task.status, result.digest == TaskOrchestration.digest(Data(result.summary.utf8)),
                      result.contextTransferID == TaskOrchestration.derivedID(task.id, "result"),
                      transfers.contains(where: { $0.id == result.contextTransferID && $0.kind == .subagentResult && $0.taskID == task.id && $0.sourceThreadID == task.childThreadID && $0.sourceRunID == result.runID && $0.targetThreadID == task.parentThreadID && $0.targetRunID == task.parentRunID }),
                      result.summary.utf8.count <= TaskOrchestration.maximumResultBytes + 256 else { throw DelegatedTaskError.invalidRequest }
            }
            var ancestor = task.parentTaskID, seen: Set<UUID> = [task.id], depth = 0
            while let id = ancestor {
                guard seen.insert(id).inserted, let parent = tasks.first(where: { $0.id == id }) else { throw DelegatedTaskError.invalidRequest }
                depth += 1; guard depth <= TaskOrchestration.maximumDepth else { throw DelegatedTaskError.limit }; ancestor = parent.parentTaskID
            }
        }
        for transfer in transfers {
            guard let task = tasks.first(where: { $0.id == transfer.taskID }),
                  transfer.sourceMessageID.map({ (try? TaskOrchestration.payload($0).count).map { $0 <= 4_096 } ?? false }) ?? true,
                  transfer.sourceMessageIDDigest == nil || (transfer.sourceMessageID == nil && transfer.sourceMessageIDDigest?.utf8.count == 64),
                  transfer.kind == .subagentResult || (transfer.id == TaskOrchestration.derivedID(task.id, "spawn") && transfer.sourceThreadID == task.parentThreadID && transfer.targetThreadID == task.childThreadID && transfer.sourceRunID == task.parentRunID && transfer.targetRunID == task.childRunID) else { throw DelegatedTaskError.invalidRequest }
        }
        for cohort in cohorts {
            guard !cohort.taskIDs.isEmpty, cohort.taskIDs.count <= TaskOrchestration.maximumCohortTasks, Set(cohort.taskIDs).count == cohort.taskIDs.count,
                  cohort.taskIDs.allSatisfy({ id in tasks.contains(where: { $0.id == id && $0.parentThreadID == cohort.threadID }) }),
                  cohort.generation > 0, cohort.id != cohort.inputID else { throw DelegatedTaskError.invalidRequest }
        }
        for thread in threads {
            if let lineage = thread.delegatedTaskLineage {
                guard tasks.contains(where: { $0.id == lineage.taskID && $0.childThreadID == thread.id && $0.parentThreadID == lineage.parentThreadID && $0.parentRunID == lineage.parentRunID }) else { throw DelegatedTaskError.invalidRequest }
            }
            for run in thread.runHistory ?? [] {
                if let id = run.delegatedTaskID { guard tasks.contains(where: { $0.id == id && $0.childThreadID == thread.id }) else { throw DelegatedTaskError.invalidRequest } }
            }
            for queued in thread.queuedTurns {
                if let id = queued.delegatedTaskID { guard tasks.contains(where: { $0.id == id && $0.childThreadID == thread.id }) else { throw DelegatedTaskError.invalidRequest } }
                if let reference = queued.delegatedCompletion { try validate(reference, threadID: thread.id, cohorts: cohorts) }
            }
            if let reference = thread.activeRun?.delegatedCompletion { try validate(reference, threadID: thread.id, cohorts: cohorts) }
        }
    }
    private func validate(_ reference: DelegatedTaskCompletionReference, threadID: UUID, cohorts: [DelegatedTaskCohort]) throws {
        guard cohorts.contains(where: { $0.id == reference.cohortID && $0.threadID == threadID && $0.parentRunID == reference.parentRunID && $0.generation == reference.generation && $0.taskIDs == reference.taskIDs }) else { throw DelegatedTaskError.invalidRequest }
    }
    mutating func recoverDelegatedTaskResults() {
        var decision = WorkspaceDecision(snapshot: self)
        do {
            try decision.reconcileDelegatedTasks(now: Date(), allowAutomaticSetup: false)
            self = decision.snapshot
        } catch {
            // Recovery never upgrades malformed ownership. Leave its evidence
            // intact for the normal strict journal validator to reject.
        }
    }
    mutating func recoverDelegatedTasks() {
        for i in (delegatedTasks ?? []).indices {
            // A blocking MCP wait died with its owning provider process. Never
            // replay its call; a future explicit continuation can read results.
            if delegatedTasks![i].wakePolicy == .settledOnly { delegatedTasks![i].wakePolicy = .always }
        }
        for i in (delegatedTaskCohorts ?? []).indices where delegatedTaskCohorts![i].state == .claimed {
            delegatedTaskCohorts![i].state = .uncertain
            for id in delegatedTaskCohorts![i].taskIDs {
                if let t = delegatedTasks?.firstIndex(where: { $0.id == id && $0.completion.state == .claimed }) {
                    delegatedTasks![t].completion.state = .uncertain
                }
            }
        }
    }
}

extension TaskOrchestration {
    /// JSON can encode one ASCII control byte as six bytes. Reserve completion
    /// storage before a provider starts; an oversized output can never turn a
    /// previously accepted task into a failed database transaction.
    static var maximumEncodedResultReservation: Int { maximumResultBytes * 6 + 16_384 }
    private struct Ledger: Encodable {
        let tasks: [DelegatedTask]
        let cohorts: [DelegatedTaskCohort]
        let transfers: [DelegatedTaskResultTransfer]
    }
    static func ledgerBytes(_ snapshot: WorkspaceSnapshot) throws -> Int {
        try payload(Ledger(tasks: snapshot.delegatedTasks ?? [], cohorts: snapshot.delegatedTaskCohorts ?? [], transfers: snapshot.delegatedTaskTransfers ?? [])).count
    }
    static func requireCapacity(_ snapshot: WorkspaceSnapshot) throws {
        let bytes = try ledgerBytes(snapshot)
        let pending = (snapshot.delegatedTasks ?? []).filter { $0.result == nil }.count
        guard bytes <= maximumLedgerBytes,
              pending <= (maximumLedgerBytes - bytes) / maximumEncodedResultReservation else { throw DelegatedTaskError.limit }
    }
}
