import CryptoKit
import Foundation

extension WorkspaceDecision {
    static func reduceDelegatedTask(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var d = Self(snapshot: snapshot)
        switch command {
        case .delegatedTaskAccepted(let prepared):
            let request = prepared.request
            guard let parent = snapshot.threads.first(where: { $0.id == request.parentThreadID }),
                  let active = parent.activeRun, active.id == request.parentRunID, !active.stopRequested,
                  parent.runtimeID == prepared.parentRuntimeID, !parent.isArchived,
                  try TaskOrchestration.payload(ProviderConfiguration(thread: parent)) == TaskOrchestration.payload(request.expectedConfiguration),
                  AppMCPAdmission.permits(request.configuration.permission, ceiling: active.configuration.permission),
                  AppMCPAdmission.permits(request.configuration.permission, ceiling: parent.permission),
                  !snapshot.isConversationHistoryLocked(threadID: parent.id),
                  snapshot.providerReady(for: parent),
                  prepared.child.projectID == parent.projectID, prepared.child.providerThreadID == nil,
                  prepared.child.messages.isEmpty, prepared.child.queuedTurns.isEmpty,
                  prepared.child.delegatedTaskLineage?.taskID == TaskOrchestration.derivedID(id, "task"),
                  prepared.child.delegatedTaskLineage?.parentThreadID == parent.id else { throw DelegatedTaskError.staleParent }
            if let id = request.configurationSourceThreadID {
                guard let profile = snapshot.threads.first(where: { $0.id == id && !$0.isArchived }), let expected = request.expectedConfigurationSource,
                      try TaskOrchestration.payload(ProviderConfiguration(thread: profile)) == TaskOrchestration.payload(expected) else { throw DelegatedTaskError.staleParent }
            } else if request.expectedConfigurationSource != nil { throw DelegatedTaskError.invalidRequest }
            let tasks = snapshot.delegatedTasks ?? []
            guard tasks.count < TaskOrchestration.maximumTasks,
                  tasks.filter({ !$0.status.isTerminal }).count < TaskOrchestration.maximumActiveTasks else { throw DelegatedTaskError.limit }
            var ancestor = active.delegatedTaskID ?? parent.delegatedTaskLineage?.taskID, depth = 0, seen: Set<UUID> = []
            while let current = ancestor {
                guard seen.insert(current).inserted, let task = tasks.first(where: { $0.id == current }) else { throw DelegatedTaskError.invalidRequest }
                depth += 1; ancestor = task.parentTaskID
            }
            guard depth < TaskOrchestration.maximumDepth else { throw DelegatedTaskError.limit }
            let taskID = TaskOrchestration.derivedID(id, "task"), inputID = TaskOrchestration.derivedID(id, "input")
            var child = prepared.child
            child.createdAt = now; child.updatedAt = now
            var task = DelegatedTask(id: taskID, commandID: id, parentThreadID: parent.id, parentRunID: active.id,
                childThreadID: child.id, childRunID: inputID, parentTaskID: active.delegatedTaskID ?? parent.delegatedTaskLineage?.taskID,
                request: request, createdAt: now, updatedAt: now, status: .queued, workState: .working,
                wakePolicy: request.mode == .async ? .always : .settledOnly, completion: .init(), isolationProof: prepared.isolation)
            if d.snapshot.delegatedTasks == nil { d.snapshot.delegatedTasks = [] }
            d.snapshot.delegatedTasks!.append(task)
            if d.snapshot.delegatedTaskTransfers == nil { d.snapshot.delegatedTaskTransfers = [] }
            d.snapshot.delegatedTaskTransfers!.append(.init(id: TaskOrchestration.derivedID(taskID, "spawn"), taskID: taskID, kind: .subagentSpawn,
                sourceThreadID: parent.id, sourceRunID: active.id, sourceMessageID: nil, targetThreadID: child.id, targetRunID: inputID,
                sourceProviderInstanceID: try AppMCPAdmission.instanceID(configuration: active.configuration),
                targetProviderInstanceID: try AppMCPAdmission.instanceID(configuration: request.configuration), createdAt: now, consumedAt: now))
            try TaskOrchestration.requireCapacity(d.snapshot)
            d.snapshot.threads.insert(child, at: 0)
            if let worktree = prepared.worktree {
                guard let proof = prepared.isolation, worktree.selection == .createBranch(name: "coincide-task-" + taskID.uuidString.lowercased(), baseRef: proof.baseCommit),
                      worktree.sourcePath.utf8.elementsEqual(proof.projectPath.utf8), worktree.expectedSourceIdentity == proof.projectIdentity else { throw DelegatedTaskError.invalidRequest }
                try d.beginWorktreePreparation(threadID: child.id, request: worktree,
                    expectedSourcePath: child.workspacePath, previousAttemptID: nil, reviewSetup: true,
                    claudeRuntimeConfiguration: try child.claudeRuntimeConfiguration?.replacingWorkspace(worktree.destinationPath, physicalPath: ClaudeRuntimeValidation.physical(worktree.destinationPath, allowMissing: true)),
                    piRuntimeConfiguration: try child.piConfiguration?.runtime?.replacingWorkspace(worktree.destinationPath, physicalPath: PiRuntimeConfiguration.physical(worktree.destinationPath, allowMissing: true)), now: now)
                child = d.snapshot.threads.first { $0.id == child.id }!
            } else {
                guard prepared.isolation == nil, request.isolation == .shared,
                      child.workspacePath.utf8.elementsEqual(parent.workspacePath.utf8) else { throw DelegatedTaskError.invalidRequest }
            }
            let inner = try Self.make(.client(.submitFromAppMCP(threadID: child.id, text: request.prompt, queueEvenWhenIdle: false)),
                id: inputID, snapshot: d.snapshot, now: now, validatingLedger: false)
            d.snapshot = inner.snapshot; d.effects += inner.effects
            task = d.snapshot.delegatedTasks!.last!
            task.updatedAt = now; d.snapshot.delegatedTasks![d.snapshot.delegatedTasks!.count - 1] = task
        case .delegatedTaskObserved(let parentID, let taskID, let observedRun):
            guard let i = d.snapshot.delegatedTasks?.firstIndex(where: { $0.id == taskID && $0.parentThreadID == parentID }) else { throw DelegatedTaskError.notFound }
            if d.snapshot.delegatedTasks![i].result != nil {
                d.snapshot.delegatedTasks![i].completion.state = .acknowledged
                d.snapshot.delegatedTasks![i].completion.observedByRunID = observedRun
                d.snapshot.delegatedTasks![i].updatedAt = now
                d.withdrawDelegatedNotice(taskID, now: now)
            }
        case .delegatedTaskWakePolicy(let parent, let task):
            guard let i = d.snapshot.delegatedTasks?.firstIndex(where: { $0.id == task && $0.parentThreadID == parent }) else { throw DelegatedTaskError.notFound }
            d.snapshot.delegatedTasks![i].wakePolicy = .always
        case .delegatedTaskDrained(let owners):
            for owner in owners {
                guard let t = d.snapshot.threads.firstIndex(where: { $0.id == owner.threadID }),
                      d.snapshot.threads[t].activeRun?.id == owner.runID,
                      d.snapshot.threads[t].activeRun?.stopRequested == true else { continue }
                var child = d.snapshot.threads[t]
                d.restoreUndispatchedContext(in: &child)
                if let runID = child.activeRun?.id, child.runHistory?.first(where: { $0.id == runID })?.checkpoints?.providerReleased == false {
                    child.updateCheckpoint(runID: runID, stage: .baseline) { $0.phase = .interrupted; $0.error = ThreadRunCheckpointAttempt.interruptedMessage; $0.updatedAt = now }
                    if let r = child.runHistory?.firstIndex(where: { $0.id == runID }) { child.runHistory?[r].checkpoints?.pendingStart = nil }
                }
                child.finishRunRecord(status: .interrupted, reason: .forcedStop, now: now)
                child.activeRun = nil; child.state = .interrupted; d.snapshot.threads[t] = child
                if d.snapshot.threads[t].runtimeID == owner.runtimeID { d.snapshot.threads[t].runtimeID = nil; d.snapshot.threads[t].runtimeRequests = [] }
            }
        case .delegatedTaskCancel(let parentID, let taskID, _):
            guard let original = d.snapshot.delegatedTasks?.first(where: { $0.id == taskID && $0.parentThreadID == parentID }),
                  let parent = d.snapshot.threads.first(where: { $0.id == parentID }) else { throw DelegatedTaskError.notFound }
            let tree = d.snapshot.delegatedTaskTree(original.id)
            // All permission checks precede every mutation or process effect.
            for task in tree {
                guard let child = d.snapshot.threads.first(where: { $0.id == task.childThreadID }),
                      AppMCPAdmission.permits(child.permission, ceiling: parent.permission),
                      child.activeRun.map({ AppMCPAdmission.permits($0.configuration.permission, ceiling: parent.permission) }) ?? true,
                      child.queuedTurns.allSatisfy({ AppMCPAdmission.permits($0.configuration.permission, ceiling: parent.permission) }) else { throw DelegatedTaskError.permissionDenied }
            }
            for task in tree.reversed() {
                guard let t = d.snapshot.threads.firstIndex(where: { $0.id == task.childThreadID }),
                      let i = d.snapshot.delegatedTasks?.firstIndex(where: { $0.id == task.id }) else { continue }
                var child = d.snapshot.threads[t]
                let cancelsOwnedTask = task.id == original.id || task.childThreadID != original.childThreadID || child.activeRun?.delegatedTaskID == task.id || child.activeRun?.id == task.childRunID
                child.queuePaused = true
                child.queuedTurns.removeAll { queued in
                    if task.childThreadID == original.childThreadID { return queued.id == original.childRunID || queued.delegatedTaskID == original.id }
                    return queued.id == task.childRunID || queued.delegatedTaskID == task.id
                }
                d.stopDelegatedRun(in: &child, now: now)
                if child.workspacePreparation?.isRunning == true {
                    child.workspacePreparation?.cancelRequested = true
                    d.cancelWorktreeAttempt = child.workspacePreparation?.id
                }
                if var setup = child.workspacePreparation?.setup, setup.canSkip, setup.phase != .stopping {
                    setup.phase = .stopping; setup.pendingAction = .cancel; setup.updatedAt = now; child.workspacePreparation?.setup = setup
                }
                d.snapshot.threads[t] = child
                if cancelsOwnedTask {
                    d.snapshot.delegatedTasks![i].cancelRequestedAt = now
                    d.snapshot.delegatedTasks![i].completion.state = .disposed
                    if !d.snapshot.delegatedTasks![i].status.isTerminal { d.snapshot.delegatedTasks![i].status = .cancelled }
                    d.withdrawDelegatedNotice(task.id, now: now)
                }
            }
        case .delegatedTaskCompletionCoalesced(let cohortID, let expected, let additions):
            guard let c = d.snapshot.delegatedTaskCohorts?.firstIndex(where: { $0.id == cohortID }),
                  d.snapshot.delegatedTaskCohorts![c].state == .claimed,
                  d.snapshot.delegatedTaskCohorts![c].taskIDs == expected,
                  d.snapshot.delegatedTaskCohorts![c].steeringOperationID == nil,
                  let t = d.snapshot.threads.firstIndex(where: { $0.id == d.snapshot.delegatedTaskCohorts![c].threadID }),
                  let q = d.snapshot.threads[t].queuedTurns.firstIndex(where: { $0.id == d.snapshot.delegatedTaskCohorts![c].inputID }),
                  !additions.isEmpty, expected.count + additions.count <= TaskOrchestration.maximumCohortTasks, Set(expected + additions).count == expected.count + additions.count,
                  additions.allSatisfy({ id in d.snapshot.delegatedTasks?.contains(where: { $0.id == id && $0.parentThreadID == d.snapshot.threads[t].id && $0.result != nil && $0.completion.state == .pending }) == true }) else { throw DelegatedTaskError.staleParent }
            d.snapshot.delegatedTaskCohorts![c].taskIDs += additions; d.snapshot.delegatedTaskCohorts![c].updatedAt = now
            let cohort = d.snapshot.delegatedTaskCohorts![c]
            d.snapshot.threads[t].queuedTurns[q].text = TaskOrchestration.notice(cohort.taskIDs)
            d.snapshot.threads[t].queuedTurns[q].delegatedCompletion = .init(cohortID: cohort.id, parentRunID: cohort.parentRunID, generation: cohort.generation, taskIDs: cohort.taskIDs)
            for id in additions {
                let i = d.snapshot.delegatedTasks!.firstIndex { $0.id == id }!
                d.snapshot.delegatedTasks![i].completion.state = .claimed; d.snapshot.delegatedTasks![i].completion.cohortID = cohort.id
            }
        case .delegatedTaskCompletionPrepared(let cohort, let steering):
            guard let p = d.snapshot.threads.firstIndex(where: { $0.id == cohort.threadID }), !d.snapshot.threads[p].isArchived,
                  !d.snapshot.threads[p].queuePaused,
                  cohort.disposition == .open, cohort.state == .claimed,
                  !cohort.taskIDs.isEmpty, cohort.taskIDs.count <= TaskOrchestration.maximumCohortTasks, Set(cohort.taskIDs).count == cohort.taskIDs.count,
                  cohort.taskIDs.allSatisfy({ id in d.snapshot.delegatedTasks?.contains(where: { $0.id == id && $0.parentThreadID == cohort.threadID && $0.completion.state == .pending && $0.result != nil }) == true }),
                  !(d.snapshot.delegatedTaskCohorts ?? []).contains(where: { $0.id == cohort.id }) else { throw DelegatedTaskError.staleParent }
            if d.snapshot.delegatedTaskCohorts == nil { d.snapshot.delegatedTaskCohorts = [] }
            d.snapshot.delegatedTaskCohorts!.append(cohort)
            for id in cohort.taskIDs {
                let i = d.snapshot.delegatedTasks!.firstIndex { $0.id == id }!
                d.snapshot.delegatedTasks![i].completion.state = .claimed; d.snapshot.delegatedTasks![i].completion.cohortID = cohort.id
            }
            let reference = DelegatedTaskCompletionReference(cohortID: cohort.id, parentRunID: cohort.parentRunID, generation: cohort.generation, taskIDs: cohort.taskIDs)
            if let steering {
                guard steering.input.id == cohort.inputID, steering.input.delegatedCompletion == reference,
                      steering.preservesComposer == true, steering.threadID == cohort.threadID,
                      d.snapshot.threads[p].activeRun?.id == steering.runID,
                      d.snapshot.threads[p].activeRun?.stopRequested == false else { throw DelegatedTaskError.staleParent }
                try d.acceptPromptSteering(steering)
            } else {
                guard d.snapshot.pendingContextTransfers(threadID: cohort.threadID).isEmpty else { throw DelegatedTaskError.unavailable }
                var thread = d.snapshot.threads[p]
                thread.queuedTurns.append(.init(id: cohort.inputID, text: TaskOrchestration.notice(cohort.taskIDs), configuration: .init(thread: thread), createdAt: now,
                    checkpointPolicy: thread.effectiveCheckpointPolicy, preservesTitle: true,
                    delegatedTaskID: d.snapshot.delegatedTasks?.last(where: { $0.childThreadID == thread.id && $0.result == nil })?.id, delegatedCompletion: reference))
                d.startNext(in: &thread, now: now); d.snapshot.threads[p] = thread
            }
        default: throw DelegatedTaskError.invalidRequest
        }
        return d
    }

    private mutating func stopDelegatedRun(in child: inout CodingThread, now: Date) {
        guard var active = child.activeRun, !active.stopRequested else { return }
        active.stopRequested = true; child.activeRun = active; child.updateRunRecord()
        if child.runHistory?.first(where: { $0.id == active.id })?.checkpoints?.providerReleased == false {
            restoreUndispatchedContext(in: &child)
            child.updateCheckpoint(runID: active.id, stage: .baseline) { $0.phase = .interrupted; $0.error = ThreadRunCheckpointAttempt.interruptedMessage; $0.updatedAt = now }
            if let r = child.runHistory?.firstIndex(where: { $0.id == active.id }) { child.runHistory?[r].checkpoints?.pendingStart = nil }
            child.finishRunRecord(status: .interrupted, reason: .forcedStop, now: now)
            child.activeRun = nil; child.state = .interrupted
        } else { effects.append(.init(request: .providerInterrupt(threadID: child.id, runID: active.id))) }
    }

    private mutating func withdrawDelegatedNotice(_ taskID: UUID, now: Date) {
        for c in (snapshot.delegatedTaskCohorts ?? []).indices where snapshot.delegatedTaskCohorts![c].taskIDs.contains(taskID) {
            let cohort = snapshot.delegatedTaskCohorts![c]
            guard cohort.state == .claimed else { continue }
            let unobserved = cohort.taskIDs.filter { id in snapshot.delegatedTasks?.first(where: { $0.id == id })?.completion.state == .claimed }
            if let p = snapshot.threads.firstIndex(where: { $0.id == cohort.threadID }),
               let q = snapshot.threads[p].queuedTurns.firstIndex(where: { $0.id == cohort.inputID }) {
                if unobserved.isEmpty {
                    snapshot.threads[p].queuedTurns.remove(at: q)
                    snapshot.delegatedTaskCohorts![c].state = .acknowledged
                } else {
                    snapshot.delegatedTaskCohorts![c].taskIDs = unobserved
                    snapshot.threads[p].queuedTurns[q].text = TaskOrchestration.notice(unobserved)
                    snapshot.threads[p].queuedTurns[q].delegatedCompletion = .init(cohortID: cohort.id, parentRunID: cohort.parentRunID, generation: cohort.generation, taskIDs: unobserved)
                }
                snapshot.delegatedTaskCohorts![c].updatedAt = now
            }
        }
    }

    /// This runs in the same transaction as every child event. Publishing the
    /// original result waits for owned descendants, but never reopens it later.
    mutating func reconcileDelegatedTasks(now: Date, allowAutomaticSetup: Bool = true) throws {
        guard snapshot.delegatedTasks != nil else { return }
        // A stopped parent cannot be reawakened by late descendant completion.
        // Stop the app-owned tree without deleting its saved result or input.
        for i in snapshot.delegatedTasks!.indices {
            let task = snapshot.delegatedTasks![i]
            guard task.result == nil, task.cancelRequestedAt == nil,
                  let parent = snapshot.threads.first(where: { $0.id == task.parentThreadID }),
                  parent.activeRun.map({ $0.id == task.parentRunID && $0.stopRequested }) == true || parent.runHistory?.contains(where: { $0.id == task.parentRunID && $0.stopRequested }) == true else { continue }
            snapshot.delegatedTasks![i].cancelRequestedAt = now; snapshot.delegatedTasks![i].completion.state = .disposed
            if let t = snapshot.threads.firstIndex(where: { $0.id == task.childThreadID }) {
                snapshot.threads[t].queuePaused = true
                if snapshot.threads[t].workspacePreparation?.isRunning == true { snapshot.threads[t].workspacePreparation?.cancelRequested = true }
                if var setup = snapshot.threads[t].workspacePreparation?.setup, setup.canSkip, setup.phase != .stopping {
                    setup.phase = .stopping; setup.pendingAction = .cancel; setup.updatedAt = now; snapshot.threads[t].workspacePreparation?.setup = setup
                }
                var child = snapshot.threads[t]; stopDelegatedRun(in: &child, now: now); snapshot.threads[t] = child
            }
        }
        // Associate queued/active inputs before result publication. Explicit
        // later child input becomes a fresh task after the original is settled.
        for t in snapshot.threads.indices {
            guard let lineage = snapshot.threads[t].delegatedTaskLineage,
                  let original = snapshot.delegatedTasks!.first(where: { $0.id == lineage.taskID }) else { continue }
            for q in snapshot.threads[t].queuedTurns.indices where snapshot.threads[t].queuedTurns[q].delegatedTaskOwnershipRecorded != true {
                let queued = snapshot.threads[t].queuedTurns[q]
                let taskID: UUID?
                if let known = queued.delegatedTaskID { taskID = known }
                else { taskID = try taskForInput(queued.id, original: original, configuration: queued.configuration, text: queued.text, notification: queued.delegatedCompletion != nil, now: now) }
                snapshot.threads[t].queuedTurns[q].delegatedTaskID = taskID
                snapshot.threads[t].queuedTurns[q].delegatedTaskOwnershipRecorded = true
            }
            if let active = snapshot.threads[t].activeRun, active.delegatedTaskOwnershipRecorded != true {
                let text = snapshot.threads[t].messages.first { $0.runReference?.runID == active.id && $0.role == .user }?.text ?? ""
                let taskID: UUID?
                if let known = active.delegatedTaskID { taskID = known }
                else { taskID = try taskForInput(active.id, original: original, configuration: active.configuration, text: text, notification: active.delegatedCompletion != nil, now: now) }
                snapshot.threads[t].activeRun?.delegatedTaskID = taskID
                snapshot.threads[t].activeRun?.delegatedTaskOwnershipRecorded = true
                if let r = snapshot.threads[t].runHistory?.firstIndex(where: { $0.id == active.id }) {
                    snapshot.threads[t].runHistory?[r].delegatedTaskID = taskID
                    snapshot.threads[t].runHistory?[r].delegatedTaskOwnershipRecorded = true
                }
            }
        }

        for i in snapshot.delegatedTasks!.indices.reversed() {
            var task = snapshot.delegatedTasks![i]
            guard let child = snapshot.threads.first(where: { $0.id == task.childThreadID }) else {
                task.completion.state = .disposed
                if task.result == nil {
                    let text = "The delegated conversation was removed before its result was available."
                    task.status = .interrupted; task.workState = .resultAvailable; task.completedAt = now
                    task.result = .init(runID: task.childRunID, status: .interrupted, summary: text,
                        digest: TaskOrchestration.digest(Data(text.utf8)), contextTransferID: TaskOrchestration.derivedID(task.id, "result"), createdAt: now)
                    if snapshot.delegatedTaskTransfers == nil { snapshot.delegatedTaskTransfers = [] }
                    snapshot.delegatedTaskTransfers!.append(.init(id: task.result!.contextTransferID, taskID: task.id, kind: .subagentResult,
                        sourceThreadID: task.childThreadID, sourceRunID: task.childRunID, sourceMessageID: nil,
                        targetThreadID: task.parentThreadID, targetRunID: task.parentRunID,
                        sourceProviderInstanceID: try AppMCPAdmission.instanceID(configuration: task.request.configuration),
                        targetProviderInstanceID: try AppMCPAdmission.instanceID(configuration: task.request.expectedConfiguration), createdAt: now, consumedAt: now))
                }
                snapshot.delegatedTasks![i] = task; continue
            }
            let records = (child.runHistory ?? []).filter { $0.delegatedTaskID == task.id || $0.id == task.childRunID }
            let live = records.contains { !$0.status.isTerminal } || child.queuedTurns.contains { $0.delegatedTaskID == task.id }
            let descendants = snapshot.delegatedTasks!.filter { $0.parentTaskID == task.id }
            let childrenWorking = descendants.contains { ($0.result == nil || [.pending, .claimed, .uncertain].contains($0.completion.state)) && $0.cancelRequestedAt == nil }
            if task.result == nil {
                task.workState = live ? .working : childrenWorking ? .waitingForChildren : .resultAvailable
                if childrenWorking && !live { task.status = .waiting }
                if live {
                    task.status = child.runtimeRequests.contains(where: { !$0.responding }) ? .waiting : child.activeRun == nil ? .queued : .running
                } else if !childrenWorking, let last = records.last, last.status.isTerminal {
                    let status: DelegatedTaskStatus = task.cancelRequestedAt != nil ? .cancelled : last.status == .completed ? .completed : last.status == .failed ? .failed : .interrupted
                    let assistant = child.messages.last { $0.runReference?.runID == last.id && $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    let failure = last.status == .failed ? child.messages.last { $0.runReference?.runID == last.id && $0.role == .system && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } : nil
                    let whole = failure?.text ?? assistant?.text ?? (last.status == .completed ? "Child task completed without an assistant result." : "Child task ended with status \(last.status.rawValue).")
                    let bytes = Data(whole.utf8), clipped = bytes.count > TaskOrchestration.maximumResultBytes
                    var summary = TaskOrchestration.utf8Prefix(whole, maximumBytes: TaskOrchestration.maximumResultBytes)
                    if clipped { summary += "\n[Task result exceeds the bounded result size; inspect the child conversation for all output.]" }
                    let result = DelegatedTaskResult(runID: last.id, status: status, summary: summary,
                        digest: TaskOrchestration.digest(Data(summary.utf8)), contextTransferID: TaskOrchestration.derivedID(task.id, "result"), createdAt: now, truncated: clipped ? true : nil)
                    task.result = result; task.status = status; task.completedAt = now; task.updatedAt = now
                    try appendTaskResultTransfer(task, result: result, sourceMessageID: failure == nil ? assistant?.id : failure?.id, child: child, now: now)
                } else if !childrenWorking, child.activeRun == nil, child.workspacePreparation?.canRetry == true || (!live && task.cancelRequestedAt != nil) {
                    task.status = task.cancelRequestedAt == nil ? .failed : .cancelled; task.workState = .resultAvailable
                    let message = task.cancelRequestedAt != nil ? "The delegated task was cancelled." : child.workspacePreparation?.error ?? "The delegated workspace did not become ready."
                    task.result = .init(runID: task.childRunID, status: task.status, summary: message, digest: TaskOrchestration.digest(Data(message.utf8)), contextTransferID: TaskOrchestration.derivedID(task.id, "result"), createdAt: now)
                    task.completedAt = now
                    try appendTaskResultTransfer(task, result: task.result!, sourceMessageID: nil, child: child, now: now)
                }
            }
            snapshot.delegatedTasks![i] = task
        }
        for c in (snapshot.delegatedTaskCohorts ?? []).indices {
            var cohort = snapshot.delegatedTaskCohorts![c]
            guard cohort.state == .claimed, let thread = snapshot.threads.first(where: { $0.id == cohort.threadID }) else { continue }
            let phase = cohort.steeringOperationID.flatMap { snapshot.promptSteering($0)?.phase }
            let run = thread.runHistory?.first { $0.id == cohort.inputID }
            let delivered = phase == .delivered || run != nil
            let uncertain = phase == .unconfirmed
            if delivered || uncertain {
                cohort.state = delivered ? .delivered : .uncertain; cohort.updatedAt = now
                for id in cohort.taskIDs {
                    if let i = snapshot.delegatedTasks!.firstIndex(where: { $0.id == id }), snapshot.delegatedTasks![i].completion.state == .claimed {
                        snapshot.delegatedTasks![i].completion.state = cohort.state
                        snapshot.delegatedTasks![i].completion.observedByRunID = delivered ? (phase == .delivered ? snapshot.promptSteering(cohort.steeringOperationID!)?.runID : run?.id) : nil
                    }
                }
            } else if thread.queuePaused || thread.isArchived || !snapshot.threads.contains(where: { $0.id == cohort.threadID }) {
                cohort.state = .disposed; cohort.disposition = .stopped; cohort.updatedAt = now
                if let t = snapshot.threads.firstIndex(where: { $0.id == cohort.threadID }) {
                    snapshot.threads[t].queuedTurns.removeAll { $0.id == cohort.inputID && $0.delegatedCompletion?.cohortID == cohort.id }
                }
                for id in cohort.taskIDs { if let i = snapshot.delegatedTasks!.firstIndex(where: { $0.id == id }) { snapshot.delegatedTasks![i].completion.state = .disposed } }
            }
            snapshot.delegatedTaskCohorts![c] = cohort
        }
        guard allowAutomaticSetup else { return }
        // Setup is host-configured and was explicitly requested by worktree
        // delegation. Reuse its exact immutable native plan, never a client shell.
        for t in snapshot.threads.indices {
            guard snapshot.threads[t].delegatedTaskLineage != nil,
                  let setup = snapshot.threads[t].workspacePreparation?.setup, setup.canApprove,
                  let plan = setup.plan, snapshot.threads[t].workspacePreparation?.isReady == true,
                  snapshot.permitsScriptAction(owner: .setup(attemptID: snapshot.threads[t].workspacePreparation!.id), thread: snapshot.threads[t]) else { continue }
            try plan.validate(); var run = setup; run.phase = .starting; run.error = nil; run.updatedAt = now
            snapshot.threads[t].workspacePreparation?.setup = run
            effects.append(.init(request: .startProjectScript(threadID: snapshot.threads[t].id, attemptID: snapshot.threads[t].workspacePreparation!.id, plan: plan)))
        }
    }

    private mutating func appendTaskResultTransfer(_ task: DelegatedTask, result: DelegatedTaskResult, sourceMessageID: String?, child: CodingThread, now: Date) throws {
        if snapshot.delegatedTaskTransfers == nil { snapshot.delegatedTaskTransfers = [] }
        guard !snapshot.delegatedTaskTransfers!.contains(where: { $0.id == result.contextTransferID }) else { return }
        let boundedID = sourceMessageID.flatMap { (try? TaskOrchestration.payload($0).count).map { $0 <= 4_096 } == true ? $0 : nil }
        snapshot.delegatedTaskTransfers!.append(.init(id: result.contextTransferID, taskID: task.id, kind: .subagentResult,
            sourceThreadID: child.id, sourceRunID: result.runID, sourceMessageID: boundedID,
            targetThreadID: task.parentThreadID, targetRunID: task.parentRunID,
            sourceProviderInstanceID: try AppMCPAdmission.instanceID(configuration: task.request.configuration),
            targetProviderInstanceID: try AppMCPAdmission.instanceID(configuration: task.request.expectedConfiguration), createdAt: now, consumedAt: now,
            sourceMessageIDDigest: boundedID == nil ? sourceMessageID.map { TaskOrchestration.digest(Data($0.utf8)) } : nil))
    }

    private mutating func taskForInput(_ inputID: UUID, original: DelegatedTask, configuration: ProviderConfiguration, text: String, notification: Bool, now: Date) throws -> UUID? {
        if let task = snapshot.delegatedTasks!.first(where: { $0.childThreadID == original.childThreadID && $0.childRunID == inputID }) { return task.id }
        if notification { return snapshot.delegatedTasks!.last(where: { $0.childThreadID == original.childThreadID && $0.result == nil })?.id }
        // Before the original task settles, an independently authored queued
        // turn is not owned by that task. Record that decision once, even when
        // the queue later starts after the original result was published.
        guard original.result != nil else { return nil }
        guard snapshot.delegatedTasks!.count < TaskOrchestration.maximumTasks,
              let parent = snapshot.threads.first(where: { $0.id == original.parentThreadID }),
              let parentRun = parent.activeRun?.id ?? parent.runHistory?.last?.id else { throw DelegatedTaskError.unavailable }
        let id = TaskOrchestration.derivedID(inputID, "followup-task")
        if snapshot.delegatedTasks!.contains(where: { $0.id == id }) { return id }
        let request = DelegatedTaskRequest(parentThreadID: parent.id, parentRunID: parentRun, expectedConfiguration: .init(thread: parent), configuration: configuration, task: text)
        snapshot.delegatedTasks!.append(.init(id: id, commandID: inputID, parentThreadID: parent.id, parentRunID: parentRun,
            childThreadID: original.childThreadID, childRunID: inputID, parentTaskID: parent.activeRun?.delegatedTaskID ?? parent.runHistory?.last?.delegatedTaskID ?? original.parentTaskID, request: request,
            createdAt: now, updatedAt: now, status: .queued, workState: .working, wakePolicy: .always, completion: .init(), isFollowup: true))
        try TaskOrchestration.requireCapacity(snapshot)
        return id
    }
}

extension TaskOrchestration {
    static func payload<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(value) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        let data = Data(value.utf8); guard data.count > maximumBytes else { return value }
        var end = maximumBytes
        while end > 0, String(data: data.prefix(end), encoding: .utf8) == nil { end -= 1 }
        return String(data: data.prefix(end), encoding: .utf8) ?? ""
    }
    static func notice(_ ids: [UUID]) -> String { "Delegated task(s) \(ids.map { $0.uuidString.lowercased() }.joined(separator: ", ")) reached terminal state(s). Use task_status with taskId to read the result." }
}
