import Foundation

extension WorkspaceDecision {
    mutating func finishCheckpoint(_ request: WorkspaceEffectRequest, result: EffectResult, now: Date) {
        guard let owner = request.checkpointOwner, let threadID = request.threadID,
              let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
        var thread = snapshot.threads[index]
        guard let old = thread.runCheckpoint(runID: owner.runID, stage: owner.stage), old.id == owner.attemptID, old.phase.isRunning,
              old.workspacePath == thread.workspacePath, !thread.isArchived else { return }
        thread.updateCheckpoint(runID: owner.runID, stage: owner.stage) { attempt in
            attempt.updatedAt = now
            switch result {
            case .checkpointResolved(let plan):
                guard plan.id == attempt.id, plan.workspacePath == attempt.workspacePath else { return }
                attempt.plan = plan; attempt.phase = .capturing
            case .checkpointCaptured(let receipt, let cleanupWarning):
                guard receipt.plan == attempt.plan else { return }
                attempt.receipt = receipt; attempt.phase = .ready; attempt.error = nil
                attempt.cleanupWarning = cleanupWarning ? ThreadRunCheckpointAttempt.cleanupWarningMessage : nil
            case .checkpointUnavailable:
                attempt.phase = .unavailable; attempt.unavailableReason = .notRepository; attempt.error = nil
            case .cancelled:
                attempt.phase = .interrupted; attempt.error = ThreadRunCheckpointAttempt.interruptedMessage
            case .failed:
                attempt.phase = .failed; attempt.error = ThreadRunCheckpointAttempt.failureMessage
            default: break
            }
        }
        guard let updated = thread.runCheckpoint(runID: owner.runID, stage: owner.stage) else { return }
        if case .checkpointResolved(let plan) = result, updated.plan == plan, updated.phase == .capturing {
            effects.append(.init(request: .captureRunCheckpoint(threadID: threadID, runID: owner.runID, stage: owner.stage, plan: plan)))
        } else if !updated.phase.isRunning {
            if owner.stage == .baseline {
                if updated.phase == .interrupted {
                    thread.finishRunRecord(status: .interrupted, reason: .forcedStop, now: now)
                    if let i = thread.runHistory?.firstIndex(where: { $0.id == owner.runID }) { thread.runHistory?[i].checkpoints?.pendingStart = nil }
                    thread.activeRun = nil; thread.state = .interrupted; thread.queuePaused = true
                } else { releaseCheckpointProviderStart(runID: owner.runID, in: &thread) }
            } else if updated.phase == .failed || updated.phase == .interrupted { thread.queuePaused = true }
            else { startNext(in: &thread, now: now) }
        }
        thread.updatedAt = now; snapshot.threads[index] = thread
    }
    mutating func releaseCheckpointProviderStart(runID: UUID, in thread: inout CodingThread) {
        guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
              let i = thread.runHistory?.firstIndex(where: { $0.id == runID }), var checkpoints = thread.runHistory?[i].checkpoints,
              !checkpoints.providerReleased, let pending = checkpoints.pendingStart else { return }
        checkpoints.pendingStart = nil; checkpoints.providerReleased = true; thread.runHistory?[i].checkpoints = checkpoints
        effects.append(.init(id: runID, request: .providerStart(threadID: thread.id, runID: runID, configuration: pending.configuration, prompt: pending.prompt, attachments: pending.attachments)))
    }
    mutating func requestPostRunCheckpoint(runID: UUID, in thread: inout CodingThread, now: Date) {
        guard let i = thread.runHistory?.firstIndex(where: { $0.id == runID }), let record = thread.runHistory?[i],
              record.status == .completed || record.status == .interrupted,
              var checkpoints = record.checkpoints, checkpoints.providerReleased, checkpoints.postRun == nil else { return }
        let attempt = ThreadRunCheckpointAttempt(workspacePath: record.configuration.workspacePath, now: now)
        checkpoints.postRun = attempt; thread.runHistory?[i].checkpoints = checkpoints
        effects.append(.init(request: .resolveRunCheckpoint(threadID: thread.id, runID: runID, stage: .postRun, attemptID: attempt.id)))
    }
    mutating func changePostRunCheckpoint(threadID: UUID, runID: UUID, expectedAttemptID: UUID, retry: Bool, now: Date) throws {
        guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }),
              !snapshot.threads[index].isArchived, !snapshot.threads[index].isBusy, snapshot.workspaceReady(for: snapshot.threads[index]),
              let held = snapshot.threads[index].heldPostRunCheckpoint, held.runID == runID, held.attempt.id == expectedAttemptID,
              !held.attempt.phase.isRunning else { throw WorkspaceCommandError("This checkpoint changed. Wait for capture to finish and review its current status.") }
        var thread = snapshot.threads[index]
        if retry {
            guard let i = thread.runHistory?.firstIndex(where: { $0.id == runID }), var checkpoints = thread.runHistory?[i].checkpoints,
                  let old = checkpoints.postRun else { return }
            checkpoints.previousPostRunAttempts.append(old)
            let next = ThreadRunCheckpointAttempt(workspacePath: old.workspacePath, now: now, isLaterObservation: true)
            checkpoints.postRun = next; thread.runHistory?[i].checkpoints = checkpoints
            effects.append(.init(request: .resolveRunCheckpoint(threadID: threadID, runID: runID, stage: .postRun, attemptID: next.id)))
        } else {
            thread.updateCheckpoint(runID: runID, stage: .postRun) { $0.phase = .skipped; $0.error = nil; $0.updatedAt = now }
        }
        // This explicit intent may release the queue. A later Stop can pause it again while
        // the retry drains/captures; completion never clears that newer pause.
        thread.queuePaused = false
        if !retry { startNext(in: &thread, now: now) }
        thread.updatedAt = now; snapshot.threads[index] = thread
    }
}
