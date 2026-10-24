import Foundation

extension WorkspaceDecision {
    @inline(never)
    static func reduceScheduledTask(_ mutation: ScheduledTaskMutation, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot), ledger = snapshot.scheduler ?? .init()
        func index(_ taskID: UUID, _ revision: UUID) throws -> Int {
            guard let i = ledger.tasks.firstIndex(where: { $0.id == taskID }), ledger.tasks[i].revision == revision else { throw ScheduledTaskError.staleRevision }
            return i
        }
        switch mutation {
        case .listener(let port): ledger.webhookListenerPort = port
        case .mcp(let request):
            try request.source.validate(in: snapshot)
            let inner: ScheduledTaskMutation
            switch request.action {
            case .save(let taskID, let expected, let title, let prompt, let enabled, let schedule, let bound, _):
                if let taskID {
                    guard let i = ledger.tasks.firstIndex(where: { $0.id == taskID }), ledger.tasks[i].source.projectID == request.source.projectID else { throw ScheduledTaskError.staleRevision }
                    var task = ledger.tasks[i]
                    if let title { task.title = title }; if let prompt { task.prompt = prompt }; if let enabled { task.enabled = enabled }
                    if let schedule { task.schedule = schedule }; if let bound { task.destination = bound ? .existingThread : .freshThread; if bound { task.workspace = .sourceCheckout } }
                    task.revision = id; task.updatedAt = now; task.nextRunAt = task.enabled ? task.schedule.next(after: now) : nil
                    inner = .save(task, expectedRevision: expected)
                } else {
                    guard let title, let prompt, let schedule else { throw ScheduledTaskError.invalidDefinition }
                    var task = try ScheduledTaskDefinition(id: TaskOrchestration.derivedID(id, "definition"), title: title, prompt: prompt, enabled: enabled ?? true,
                        schedule: schedule, source: request.source, destination: bound == false ? .freshThread : .existingThread, now: now)
                    task.revision = id; inner = .save(task, expectedRevision: nil)
                }
            case .delete(let taskID, let revision, _):
                guard ledger.tasks.first(where: { $0.id == taskID })?.source.projectID == request.source.projectID else { throw ScheduledTaskError.sourceChanged }
                inner = .delete(id: taskID, revision: revision)
            case .run(let taskID, _):
                guard let task = ledger.tasks.first(where: { $0.id == taskID }), task.revision == request.expectedTaskRevision, task.source.projectID == request.source.projectID else { throw ScheduledTaskError.staleRevision }
                inner = .fire(.init(taskID: task.id, revision: task.revision, trigger: .manual, dueAt: now, observedAt: now,
                    managedRoot: request.managedRoot, prompt: nil, delivery: nil))
            case .acknowledge(let occurrenceID, _):
                guard let occurrence = ledger.occurrences.first(where: { $0.id == occurrenceID }), ledger.tasks.first(where: { $0.id == occurrence.taskID })?.source.projectID == request.source.projectID else { throw ScheduledTaskError.sourceChanged }
                inner = .acknowledge(id: occurrenceID, now: now)
            case .list, .read: throw ScheduledTaskError.unsupported
            }
            return try reduceScheduledTask(inner, id: id, snapshot: snapshot, now: now)
        case .enqueueWebhook(let pending):
            guard ledger.occurrences.filter({ $0.taskID == pending.taskID && $0.trigger == .webhook && pending.receivedAt.timeIntervalSince($0.observedAt) < 60 }).count < 60 else { throw ScheduledTaskError.capacity }
            let i = try index(pending.taskID, pending.revision)
            guard ledger.tasks[i].enabled, case .webhook = ledger.tasks[i].schedule,
                  pending.prompt.utf16.count <= 120_000, pending.prompt.utf8.count <= 512 * 1024,
                  !ledger.occurrences.contains(where: { $0.id == pending.id }),
                  ledger.webhookPending.filter({ $0.taskID == pending.taskID }).count < 20 else { throw ScheduledTaskError.capacity }
            let matching = ledger.webhookPending.firstIndex { $0.taskID == pending.taskID && $0.revision == pending.revision &&
                $0.delivery.coalesceDigest == pending.delivery.coalesceDigest && $0.fireAt > pending.receivedAt }
            let replayOwner = matching.map { ledger.webhookPending[$0].id } ?? pending.id
            try ledger.claimWebhookReplay(taskID: pending.taskID, digest: pending.delivery.replayDigest, occurrenceID: replayOwner, now: pending.receivedAt)
            if let matching {
                ledger.webhookPending[matching].prompt = pending.prompt; ledger.webhookPending[matching].delivery = pending.delivery
            } else { ledger.webhookPending.append(pending) }
            ledger.occurrences.append(.init(id: pending.id, taskID: pending.taskID, taskRevision: pending.revision, trigger: .webhook,
                dueAt: pending.fireAt, observedAt: pending.receivedAt, threadID: nil, phase: matching == nil ? .waiting : .coalesced,
                error: nil, acknowledgedAt: nil, delivery: pending.delivery))
        case .save(var task, let expected):
            try task.validate(); try task.source.validate(in: snapshot); task.error = nil
            if task.enabled, ledger.occurrences.contains(where: { $0.taskID == task.id && $0.phase == .uncertain && $0.acknowledgedAt == nil }) { throw ScheduledTaskError.uncertain }
            if let i = ledger.tasks.firstIndex(where: { $0.id == task.id }) {
                guard ledger.tasks[i].revision == expected else { throw ScheduledTaskError.staleRevision }
                task.createdAt = ledger.tasks[i].createdAt
                if task.schedule.isEquivalent(to: ledger.tasks[i].schedule), task.enabled == ledger.tasks[i].enabled { task.nextRunAt = ledger.tasks[i].nextRunAt }
                ledger.tasks[i] = task
            } else {
                guard expected == nil else { throw ScheduledTaskError.staleRevision }
                ledger.tasks.append(task)
            }
        case .enabled(let taskID, let revision, let enabled, let date):
            let i = try index(taskID, revision)
            if enabled {
                guard !ledger.occurrences.contains(where: { $0.taskID == taskID && $0.phase == .uncertain && $0.acknowledgedAt == nil }) else { throw ScheduledTaskError.uncertain }
                try ledger.tasks[i].source.validate(in: snapshot)
            }
            ledger.tasks[i].enabled = enabled; ledger.tasks[i].error = nil; ledger.tasks[i].updatedAt = date; ledger.tasks[i].revision = id
            ledger.tasks[i].nextRunAt = enabled ? ledger.tasks[i].schedule.next(after: date) : nil
        case .delete(let taskID, let revision):
            _ = try index(taskID, revision); ledger.tasks.removeAll { $0.id == taskID }; ledger.webhookPending.removeAll { $0.taskID == taskID }
        case .fire(let fire):
            let i = try index(fire.taskID, fire.revision), task = ledger.tasks[i]
            guard !ledger.occurrences.contains(where: { $0.id == id && $0.phase != .waiting }),
                  !ledger.occurrences.contains(where: { $0.taskID == task.id && $0.phase == .uncertain && $0.acknowledgedAt == nil }) else { throw ScheduledTaskError.uncertain }
            if fire.trigger != .manual { guard task.enabled else { throw ScheduledTaskError.staleRevision } }
            if fire.trigger == .scheduled {
                guard task.nextRunAt == fire.dueAt, fire.dueAt <= fire.observedAt, !task.schedule.isMissed(due: fire.dueAt, now: fire.observedAt) else { throw ScheduledTaskError.staleRevision }
            }
            if fire.trigger == .webhook {
                guard case .webhook = task.schedule, fire.delivery != nil else { throw ScheduledTaskError.invalidWebhook }
                guard ledger.occurrences.filter({ $0.taskID == task.id && $0.id != id && $0.trigger == .webhook && fire.observedAt.timeIntervalSince($0.observedAt) < 60 }).count < 60 else { throw ScheduledTaskError.capacity }
            }
            try task.source.validate(in: snapshot)
            if let delivery = fire.delivery { try ledger.claimWebhookReplay(taskID: task.id, digest: delivery.replayDigest, occurrenceID: id, now: fire.observedAt) }
            guard let project = snapshot.projects.first(where: { $0.id == task.source.projectID }) else { throw ScheduledTaskError.sourceChanged }
            let destinationThreadID: UUID
            if task.destination == .existingThread {
                destinationThreadID = task.source.threadID
            } else {
                var thread = CodingThread(project: project, model: task.source.configuration.model)
            thread.id = TaskOrchestration.derivedID(id, "scheduled-thread")
            thread.applyContextConfiguration(task.source.configuration)
            thread.providerThreadID = nil; thread.checkpointPolicy = task.source.checkpointPolicy; thread.title = task.title; thread.createdAt = fire.observedAt; thread.updatedAt = fire.observedAt
            var request: GitWorktreeRequest?
            switch task.workspace {
            case .sourceCheckout: break
            case .projectRoot: thread.workspacePath = project.path
            case .newWorktree(let base, let submodules):
                thread.workspacePath = project.path
                request = .init(id: TaskOrchestration.derivedID(id, "worktree"), sourcePath: project.path, destinationRoot: fire.managedRoot,
                    selection: .createBranch(name: "scheduled-" + id.uuidString.lowercased(), baseRef: base), submodules: submodules,
                    expectedSourceIdentity: .init(device: task.source.projectDirectory.device, inode: task.source.projectDirectory.inode))
            }
            do {
                if let runtime = thread.claudeRuntimeConfiguration { thread.claudeRuntimeConfiguration = try runtime.replacingWorkspace(thread.workspacePath) }
            } catch is CoincideError { throw ScheduledTaskError.sourceChanged }
            let created = try Self.make(.client(.createThread(thread)), id: id, snapshot: decision.snapshot, now: now, validatingLedger: false)
            decision = created
            if let request {
                let preparation: Self
                do {
                    preparation = try Self.reduceWorktreePreparation(.beginWorktreePreparation(threadID: thread.id, request: request,
                        expectedSourcePath: thread.workspacePath, previousAttemptID: nil, incarnation: id, reviewSetup: true,
                        claudeRuntimeConfiguration: try thread.claudeRuntimeConfiguration?.replacingWorkspace(request.destinationPath, physicalPath: ClaudeRuntimeValidation.physical(request.destinationPath, allowMissing: true))),
                        snapshot: decision.snapshot, now: now)
                } catch is CoincideError { throw ScheduledTaskError.sourceChanged }
                decision.snapshot = preparation.snapshot; decision.effects += preparation.effects
            }
                destinationThreadID = thread.id
            }
            let prompt = fire.prompt ?? task.prompt
            let submitted = try Self.make(.client(.submitFromAppMCP(threadID: destinationThreadID, text: prompt, queueEvenWhenIdle: false)), id: id,
                snapshot: decision.snapshot, now: now, validatingLedger: false)
            decision.snapshot = submitted.snapshot; decision.effects += submitted.effects
            let originalDelivery = ledger.occurrences.first(where: { $0.id == id && $0.phase == .waiting })?.delivery ?? fire.delivery
            ledger.occurrences.removeAll { $0.id == id && $0.phase == .waiting }; ledger.webhookPending.removeAll { $0.id == id }
            ledger.occurrences.append(.init(id: id, taskID: task.id, taskRevision: task.revision, trigger: fire.trigger, dueAt: fire.dueAt,
                observedAt: fire.observedAt, threadID: destinationThreadID, phase: .accepted, error: nil, acknowledgedAt: nil, delivery: originalDelivery, selectedDeliveryDigest: fire.delivery?.bodyDigest))
            ledger.tasks[i].error = nil; ledger.tasks[i].nextRunAt = task.enabled ? task.schedule.next(after: fire.observedAt) : nil
        case .missed(let taskID, let revision, let due, let date):
            let i = try index(taskID, revision)
            guard ledger.tasks[i].nextRunAt == due else { throw ScheduledTaskError.staleRevision }
            ledger.occurrences.append(.init(id: id, taskID: taskID, taskRevision: revision, trigger: .scheduled, dueAt: due, observedAt: date,
                threadID: nil, phase: .missed, error: "The fixed time was missed by more than ten minutes. No backlog was started.", acknowledgedAt: nil, delivery: nil))
            ledger.tasks[i].nextRunAt = ledger.tasks[i].schedule.next(after: date)
        case .failure(let taskID, let revision, let occurrenceID, let trigger, let due, let date):
            let i = try index(taskID, revision)
            guard !ledger.occurrences.contains(where: { $0.id == occurrenceID && $0.phase != .waiting }) else { break }
            ledger.webhookPending.removeAll { $0.id == occurrenceID }; ledger.occurrences.removeAll { $0.id == occurrenceID && $0.phase == .waiting }
            ledger.tasks[i].enabled = false; ledger.tasks[i].nextRunAt = nil
            ledger.tasks[i].error = "Input admission was refused. Check the saved source and storage capacity before enabling this task again."
            if ledger.occurrences.count >= 1000 { break }
            ledger.occurrences.append(.init(id: occurrenceID, taskID: taskID, taskRevision: revision, trigger: trigger, dueAt: due,
                observedAt: date, threadID: nil, phase: .failed, error: ledger.tasks[i].error, acknowledgedAt: nil, delivery: nil))
        case .observe(let occurrenceID, _):
            guard let i = ledger.occurrences.firstIndex(where: { $0.id == occurrenceID }), ledger.occurrences[i].phase == .accepted else { break }
            let occurrence = ledger.occurrences[i]
            guard let thread = snapshot.threads.first(where: { $0.id == occurrence.threadID }) else {
                ledger.occurrences[i].phase = .uncertain; ledger.occurrences[i].error = ScheduledTaskError.uncertain.localizedDescription; break
            }
            if thread.activeRun?.id != occurrenceID, !thread.queuedTurns.contains(where: { $0.id == occurrenceID }),
               thread.runHistory?.contains(where: { $0.id == occurrenceID }) != true {
                ledger.occurrences[i].phase = .failed; ledger.occurrences[i].error = "The original queued input was removed. It will not be resent."; break
            }
            if let record = thread.runHistory?.first(where: { $0.id == occurrenceID }), let ended = record.endedAt {
                _ = ended
                ledger.occurrences[i].phase = record.status == .completed ? .succeeded : record.status == .unknown ? .uncertain : .failed
                if record.status != .completed { ledger.occurrences[i].error = "Inspect the original scheduled run. Its input will not be sent again." }
            }
        case .acknowledge(let occurrenceID, let date):
            guard let i = ledger.occurrences.firstIndex(where: { $0.id == occurrenceID }), ledger.occurrences[i].phase != .accepted, ledger.occurrences[i].phase != .waiting else { throw ScheduledTaskError.unavailable }
            ledger.occurrences[i].acknowledgedAt = date
        case .pruneResolvedHistory:
            ledger.occurrences.removeAll { $0.phase == .succeeded || ($0.phase != .accepted && $0.phase != .waiting && $0.acknowledgedAt != nil) }
        }
        for i in ledger.occurrences.indices where ledger.occurrences[i].phase == .waiting {
            let occurrence = ledger.occurrences[i]
            if !ledger.tasks.contains(where: { $0.id == occurrence.taskID && $0.revision == occurrence.taskRevision && $0.enabled }) {
                ledger.occurrences[i].phase = .failed; ledger.occurrences[i].error = "The task changed before webhook input admission."
                ledger.webhookPending.removeAll { $0.id == occurrence.id }
            }
        }
        try ledger.validate(); decision.snapshot.scheduler = ledger
        return decision
    }
}

private extension ScheduledTaskLedger {
    mutating func claimWebhookReplay(taskID: UUID, digest: String?, occurrenceID: UUID, now: Date) throws {
        webhookReplay.removeAll { $0.expiresAt <= now }
        guard let digest else { return }
        if let existing = webhookReplay.first(where: { $0.taskID == taskID && $0.digest == digest }) {
            guard existing.occurrenceID == occurrenceID else { throw ScheduledTaskError.duplicateWebhook }; return
        }
        guard webhookReplay.count < 10_000 else { throw ScheduledTaskError.capacity }
        webhookReplay.append(.init(taskID: taskID, digest: digest, occurrenceID: occurrenceID, expiresAt: now.addingTimeInterval(7 * 24 * 3600)))
    }
}
