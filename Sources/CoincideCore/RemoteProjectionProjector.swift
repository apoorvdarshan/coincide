import Foundation

struct RemoteProjectionSource {
    var projects: [RemoteProjectSummary] = []
    var threads: [RemoteThreadSummary] = []
    var detail: RemoteThreadDetail?
    var messages: [RemoteMessageSummary] = []
    var runs: [RemoteRunSummary] = []
    var operations: [RemoteOperationSummary] = []
    var contents: [UUID: Data] = [:]
    var references: [UUID: RemoteProjectionContentReference] = [:]
    var byteCount = 512
    var fingerprint = ""
}

enum RemoteProjectionProjector {
    static func build(_ update: WorkspaceUpdate, scope: RemoteProjectionScope,
                      reserve: @escaping (Int) throws -> Void) throws -> RemoteProjectionSource {
        guard update.error == nil else { throw RemoteProjectionFailure(.unavailable) }
        return try Builder(snapshot: update.snapshot, reserve: reserve).build(scope)
    }

    private final class Builder {
        let snapshot: WorkspaceSnapshot
        let reserve: (Int) throws -> Void
        var source = RemoteProjectionSource()
        var documents: [String: UUID] = [:]
        init(snapshot: WorkspaceSnapshot, reserve: @escaping (Int) throws -> Void) { self.snapshot = snapshot; self.reserve = reserve }
        func account(_ bytes: Int) throws { source.byteCount += bytes; try reserve(source.byteCount) }
        func row<T: Encodable>(_ value: T) throws -> T { try account(RemoteProjectionProtocol.payload(value).count); return value }
        func document(_ bytes: Data, kind: RemoteProjectionContentKind) throws -> RemoteProjectionContentReference {
            let digest = RemoteProjectionProtocol.digest(bytes), key = kind.rawValue + ":" + digest
            if let id = documents[key], let reference = source.references[id] { return reference }
            try account(bytes.count + 256)
            let reference = RemoteProjectionContentReference(id: UUID(), kind: kind, totalBytes: bytes.count, digest: digest)
            documents[key] = reference.id; source.contents[reference.id] = bytes; source.references[reference.id] = reference
            return reference
        }
        func json<T: Encodable>(_ value: T, kind: RemoteProjectionContentKind) throws -> RemoteProjectionContentReference {
            try document(RemoteProjectionProtocol.payload(value), kind: kind)
        }
        func text(_ value: String, kind: RemoteProjectionContentKind = .text) throws -> RemoteProjectionText {
            let bytes = Data(value.utf8)
            if bytes.count <= 1_024 { return .init(preview: value, complete: true) }
            var prefix = Data(bytes.prefix(1_024))
            while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
            return .init(preview: String(decoding: prefix, as: UTF8.self), complete: false, content: try document(bytes, kind: kind))
        }
        func availability(_ allowed: Bool, _ reason: String) -> RemoteProjectionAvailability { .init(allowed: allowed, reason: allowed ? nil : reason) }
        func samePath(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        func build(_ scope: RemoteProjectionScope) throws -> RemoteProjectionSource {
            let thread: CodingThread?
            switch scope {
            case .catalog: thread = nil
            case .thread(let id), .control(let id):
                guard let found = snapshot.threads.first(where: { $0.id == id }) else { throw RemoteProjectionFailure(.notFound) }
                thread = found
            }
            if case .catalog = scope {
                source.projects = try snapshot.projects.map(project)
                source.threads = try snapshot.threads.map { try summary($0) }
            } else if let thread {
                source.detail = try detail(thread)
                if case .thread = scope {
                    source.messages = try thread.messages.map(message)
                    source.runs = try (thread.runHistory ?? []).reversed().map { try run($0, thread: thread) }
                }
            }
            if case .catalog = scope { source.operations = [] }
            else { source.operations = try operations(thread: thread, control: { if case .control = scope { true } else { false } }()) }
            if case .control = scope {
                var latest = Set<RemoteOperationKind>()
                source.operations = source.operations.filter { value in
                    let held = value.actions.contains { $0.value.allowed && $0.key != RemoteOperationAction.openConversation.rawValue && $0.key != RemoteOperationAction.openPullRequest.rawValue }
                    return latest.insert(value.kind).inserted || held || ["accepted", "dispatching", "running", "preparing", "unconfirmed"].contains(value.phase)
                }
            }
            // Hash only proof-free projected material and content descriptors.
            struct Manifest: Encodable {
                let projects: [RemoteProjectSummary], threads: [RemoteThreadSummary]
                let detail: RemoteThreadDetail?
                let messages: [RemoteMessageSummary], runs: [RemoteRunSummary], operations: [RemoteOperationSummary]
                let contents: [RemoteProjectionContentReference]
            }
            let manifest = Manifest(projects: source.projects, threads: source.threads, detail: source.detail,
                messages: source.messages, runs: source.runs, operations: source.operations,
                contents: source.references.values.sorted { $0.id.uuidString < $1.id.uuidString })
            let encoded = try RemoteProjectionProtocol.payload(manifest)
            source.byteCount = 512 + encoded.count + source.contents.values.reduce(0) { $0 + $1.count }
            try reserve(source.byteCount)
            source.fingerprint = RemoteProjectionProtocol.digest(encoded)
            return source
        }
        func project(_ value: WorkspaceProject) throws -> RemoteProjectSummary {
            try row(.init(id: value.id, name: text(value.name), workspacePath: value.path, clonePhase: value.clone?.phase,
                cloneError: value.clone?.error.map { try text($0) }, createdAt: value.createdAt, updatedAt: value.updatedAt))
        }
        func summary(_ thread: CodingThread, counted: Bool = true) throws -> RemoteThreadSummary {
            let result = try RemoteThreadSummary(id: thread.id, projectID: thread.projectID, title: text(thread.title), workspacePath: thread.workspacePath,
                provider: thread.provider, providerName: thread.providerName, model: text(thread.model), permission: thread.permission,
                state: thread.state, isPinned: thread.isPinned, isArchived: thread.isArchived, createdAt: thread.createdAt, updatedAt: thread.updatedAt,
                messageCount: thread.messages.count, runCount: thread.runHistory?.count ?? 0, queueCount: thread.queuedTurns.count)
            return counted ? try row(result) : result
        }
        func preparation(_ value: ThreadWorkspacePreparation) throws -> RemoteWorktreePreparationSummary {
            .init(id: value.id, phase: value.phase, sourcePath: value.request.sourcePath, destinationPath: value.destinationPath,
                submodules: value.request.submodules, cancelRequested: value.cancelRequested, hasPlan: value.plan != nil,
                canCancel: value.isRunning && !value.cancelRequested, canRetry: value.canRetry, canInspect: value.canRetry && value.plan != nil,
                error: try value.error.map { try text($0) }, warnings: try value.result?.submoduleWarning.map { [try text($0)] } ?? [])
        }
        func detail(_ thread: CodingThread) throws -> RemoteThreadDetail {
            let ready = snapshot.workspaceReady(for: thread), history = snapshot.isConversationHistoryLocked(threadID: thread.id)
            let locked = history || snapshot.isCheckpointRestoreLocked(threadID: thread.id) || snapshot.isPullRequestCheckoutLocked(threadID: thread.id) || snapshot.isPullRequestCreationLocked(threadID: thread.id)
            let owners = snapshot.threads.filter { samePath($0.workspacePath, thread.workspacePath) }
            let busy = owners.contains { $0.isBusy || !$0.queuedTurns.isEmpty || !$0.runtimeRequests.isEmpty || $0.settlement != nil || $0.heldPostRunCheckpoint != nil }
            let preparing = snapshot.threads.contains { value in
                guard let worktree = value.workspacePreparation, worktree.isRunning else { return false }
                return samePath(worktree.request.sourcePath, thread.workspacePath) || samePath(worktree.destinationPath, thread.workspacePath)
            }
            let available = !thread.isArchived && !locked && thread.settlement == nil
            let canSubmit = available && (ready || thread.workspacePreparation?.isRunning == true)
            let canChoose = available && thread.messages.isEmpty && !thread.isBusy && thread.queuedTurns.isEmpty &&
                (thread.workspacePreparation == nil || thread.workspacePreparation?.isReady == true || thread.workspacePreparation?.canRetry == true)
            return try row(.init(summary: summary(thread, counted: false), configuration: json(ProviderConfiguration(thread: thread), kind: .configuration),
                draft: text(thread.draft, kind: .draft), draftAttachments: json(thread.draftAttachments, kind: .attachmentReferences),
                runtimeRequests: json(thread.runtimeRequests, kind: .runtimeRequests), requestCount: thread.runtimeRequests.count,
                queuePaused: thread.queuePaused, checkpointPolicy: thread.effectiveCheckpointPolicy,
                activeRun: thread.activeRun.map { .init(id: $0.id, runtimeID: thread.runtimeID, startedAt: $0.startedAt, stopRequested: $0.stopRequested) },
                runtimeID: thread.runtimeID, workspaceReady: ready, isBusy: thread.isBusy,
                submit: availability(canSubmit, "Finish or inspect the current workspace hold before submitting."),
                resumeQueue: availability(available && ready && thread.heldPostRunCheckpoint == nil, "Resolve the workspace or checkpoint hold before resuming queued work."),
                mutateFiles: availability(available && ready && !busy && !preparing, "Another conversation or operation owns this workspace."),
                openTerminal: availability(available && ready && !preparing, "This workspace is unavailable or held by an operation."),
                chooseWorktree: availability(canChoose, "Choose a worktree before the first message and with no running or queued work."),
                preparation: thread.workspacePreparation.map { try preparation($0) }, settlementID: thread.settlement?.id,
                checkpointBanner: banner(thread)))
        }
        func message(_ value: ChatMessage) throws -> RemoteMessageSummary {
            try row(.init(id: value.id, role: value.role, createdAt: value.createdAt, text: text(value.providerEntity?.text ?? value.text),
                attachments: value.attachments.map { try json($0, kind: .attachmentReferences) }, attachmentCount: value.attachments?.count ?? 0,
                runReference: value.runReference, removedByHistoryOperationID: value.removedByHistoryOperationID,
                submissionError: value.submissionError.map { try text($0) },
                title: value.providerEntity?.fields["title"].string.map { try text($0) }, status: value.providerEntity?.fields["status"].string.map { try text($0) }))
        }
        func attempt(_ value: ThreadRunCheckpointAttempt, stage: RunCheckpointStage, runID: UUID, thread: CodingThread) throws -> RemoteCheckpointAttemptSummary {
            let reason = snapshot.checkpointRestoreUnavailableReason(threadID: thread.id, runID: runID, stage: stage, expectedAttemptID: value.id)
            return .init(id: value.id, stage: stage, workspacePath: value.workspacePath, phase: value.phase, requestedAt: value.requestedAt,
                updatedAt: value.updatedAt, isLaterObservation: value.isLaterObservation, hasReceipt: value.receipt != nil,
                digest: RemoteProjectionProtocol.digest(try RemoteProjectionProtocol.payload(value)), restore: .init(allowed: reason == nil, reason: reason),
                error: try value.error.map { try text($0) }, cleanupWarning: try value.cleanupWarning.map { try text($0) })
        }
        func banner(_ thread: CodingThread) throws -> RemoteCheckpointBannerSummary? {
            if let held = thread.heldPostRunCheckpoint {
                return .init(runID: held.runID, stage: .postRun, attempt: try attempt(held.attempt, stage: .postRun, runID: held.runID, thread: thread),
                    title: held.attempt.phase.isRunning ? "Saving workspace snapshot…" : "Workspace snapshot needs attention",
                    detail: "Queued messages wait for this observation. Retry captures the current workspace including newer edits.",
                    providerReleased: true, canRetry: held.attempt.canRetryPostRun && !thread.isArchived,
                    canContinue: held.attempt.canContinuePostRun && !thread.isArchived)
            }
            guard let active = thread.activeRun, let checkpoints = thread.runHistory?.first(where: { $0.id == active.id })?.checkpoints else { return nil }
            let baseline = checkpoints.baseline, preparing = !checkpoints.providerReleased && baseline.phase.isRunning
            guard preparing || [.failed, .interrupted, .unavailable].contains(baseline.phase) else { return nil }
            return .init(runID: active.id, stage: .baseline, attempt: try attempt(baseline, stage: .baseline, runID: active.id, thread: thread),
                title: preparing ? "Preparing workspace snapshot…" : "Before-run snapshot unavailable",
                detail: preparing ? "Agent work begins after this observation attempt finishes." : "Agent work can continue; this run may lack a complete comparison.",
                providerReleased: checkpoints.providerReleased, canRetry: false, canContinue: false)
        }
        func run(_ record: ThreadRunRecord, thread: CodingThread) throws -> RemoteRunSummary {
            var attempts: [RemoteCheckpointAttemptSummary] = []
            var currentAttempts: [RemoteCheckpointAttemptSummary] = []
            if let checkpoints = record.checkpoints {
                let baseline = try attempt(checkpoints.baseline, stage: .baseline, runID: record.id, thread: thread)
                attempts.append(baseline); currentAttempts.append(baseline)
                for value in checkpoints.previousPostRunAttempts { attempts.append(try attempt(value, stage: .postRun, runID: record.id, thread: thread)) }
                if let post = checkpoints.postRun {
                    let current = try attempt(post, stage: .postRun, runID: record.id, thread: thread)
                    attempts.append(current); currentAttempts.append(current)
                }
            }
            let large = try RemoteProjectionProtocol.payload(attempts).count > 32_768
            let readyDiff = record.checkpoints.map { $0.baseline.phase == .ready && $0.baseline.receipt != nil && $0.postRun?.phase == .ready && $0.postRun?.receipt != nil } ?? false
            let currentDiff = record.checkpoints.map { checkpoints in
                guard let post = checkpoints.postRun, let before = checkpoints.baseline.receipt, let after = post.receipt else { return false }
                return samePath(checkpoints.baseline.workspacePath, thread.workspacePath) && samePath(post.workspacePath, thread.workspacePath) &&
                    samePath(before.plan.workspacePath, thread.workspacePath) && samePath(after.plan.workspacePath, thread.workspacePath)
            } ?? false
            let forkReason = snapshot.conversationHistoryUnavailableReason(threadID: thread.id, runID: record.id, kind: .forkAfterRun)
            let rewindReason = snapshot.conversationHistoryUnavailableReason(threadID: thread.id, runID: record.id, kind: .rewindBeforeRun)
            return try row(.init(id: record.id, origin: record.origin, status: record.status, startedAt: record.startedAt, endedAt: record.endedAt,
                userMessageID: record.userMessageID, stopRequested: record.stopRequested, endReason: record.endReason, turnCount: record.turnIDs.count,
                // An incomplete preview retains the exact current comparison
                // pair. The referenced document preserves every prior attempt.
                removedByHistoryOperationID: record.removedByHistoryOperationID, checkpointAttempts: large ? currentAttempts : attempts,
                checkpointAttemptCount: attempts.count, checkpointAttemptsComplete: !large,
                checkpointAttemptsContent: large ? json(attempts, kind: .checkpointAttempts) : nil,
                checkpointDiff: availability(readyDiff && currentDiff, readyDiff && !currentDiff ? "This comparison belongs to another workspace." : "This run has no exact complete before/after observation."),
                fork: .init(allowed: forkReason == nil, reason: forkReason), rewind: .init(allowed: rewindReason == nil, reason: rewindReason),
                provider: record.configuration.provider, providerName: record.configuration.provider.name, model: text(record.configuration.model),
                permission: record.configuration.permission, workspacePath: record.configuration.workspacePath,
                checkpointPolicy: record.checkpoints == nil ? nil : .automatic, configuration: json(record.configuration, kind: .configuration)))
        }
        func operation(id: UUID, kind: RemoteOperationKind, projectID: UUID, threadID: UUID? = nil, runID: UUID? = nil,
                       attemptID: UUID? = nil, targetThreadID: UUID? = nil, phase: String, updatedAt: Date, title: String,
                       error: String?, acknowledged: Bool = false, cancelRequested: Bool = false,
                       actions: [String: RemoteProjectionAvailability] = [:], details: [(String, String)] = [], warnings: [String] = [],
                       paths: [String] = [], pullRequest: GitHubPullRequestReference? = nil, url: String? = nil, readOnly: Bool? = nil) throws -> RemoteOperationSummary {
            try row(.init(id: id, kind: kind, projectID: projectID, threadID: threadID, runID: runID, attemptID: attemptID,
                targetThreadID: targetThreadID, phase: phase, updatedAt: updatedAt, title: text(title), error: error.map { try text($0) },
                acknowledged: acknowledged, cancelRequested: cancelRequested, actions: actions,
                fingerprint: RemoteProjectionProtocol.digest(Data("\(id)|\(phase)|\(updatedAt.timeIntervalSince1970)|\(acknowledged)|\(cancelRequested)".utf8)),
                details: details.map { .init(label: $0.0, value: try text($0.1)) }, warnings: warnings.map { try text($0) },
                workspacePaths: paths, pullRequest: pullRequest, url: url, readOnly: readOnly))
        }
        func operations(thread: CodingThread?, control: Bool) throws -> [RemoteOperationSummary] {
            var result: [RemoteOperationSummary] = []
            func owns(_ project: UUID, _ id: UUID?, _ path: String? = nil, target: UUID? = nil) -> Bool {
                guard let thread else { return true }
                return thread.projectID == project && (id == thread.id || target == thread.id || path.map { samePath($0, thread.workspacePath) } == true)
            }
            func action(_ name: RemoteOperationAction, _ allowed: Bool) -> (String, RemoteProjectionAvailability) {
                (name.rawValue, availability(allowed, "This action is unavailable in the saved operation state."))
            }
            func selected<T>(_ values: [T], held: (T) -> Bool) -> [T] {
                guard control else { return values }
                return values.enumerated().filter { $0.offset == values.count - 1 || held($0.element) }.map(\.element)
            }
            let creations = (snapshot.pullRequestCreations ?? []).filter { owns($0.projectID, nil, $0.registeredWorkspacePath) }
            for value in selected(creations, held: { $0.isWorking || ($0.phase == .unconfirmed && $0.acknowledgedAt == nil) }) {
                let detail: GitHubPullRequestDetail?
                switch value.result { case .created(let found), .openedExisting(let found): detail = found; case nil: detail = nil }
                result.append(try operation(id: value.id, kind: .pullRequestCreation, projectID: value.projectID, threadID: thread?.id,
                    phase: value.phase.rawValue, updatedAt: value.updatedAt, title: value.review.title, error: value.error, acknowledged: value.acknowledgedAt != nil,
                    actions: Dictionary(uniqueKeysWithValues: [action(.inspectCreation, value.phase == .unconfirmed && value.acknowledgedAt == nil), action(.acknowledgeCreation, value.phase == .unconfirmed && value.acknowledgedAt == nil), action(.openPullRequest, detail != nil)]),
                    details: [("Repository", value.review.context.repository.selector), ("Source", value.registeredWorkspacePath), ("Head branch", value.review.context.branch ?? ""), ("Head commit", value.review.context.headCommit ?? ""), ("Base branch", value.review.baseBranch), ("Base commit", value.review.baseCommit)],
                    paths: [value.registeredWorkspacePath] + value.scopePaths, pullRequest: detail?.summary.reference, url: detail?.summary.url))
            }
            let checkouts = (snapshot.pullRequestCheckouts ?? []).filter { owns($0.projectID, nil, $0.review.registeredWorkspacePath, target: $0.targetThreadID) }
            for value in selected(checkouts, held: { $0.isWorking || ($0.phase == .unconfirmed && $0.acknowledgedAt == nil) }) {
                result.append(try operation(id: value.id, kind: .pullRequestCheckout, projectID: value.projectID, threadID: thread?.id,
                    targetThreadID: value.targetThreadID, phase: value.phase.rawValue, updatedAt: value.updatedAt, title: value.review.title, error: value.error,
                    acknowledged: value.acknowledgedAt != nil, cancelRequested: value.cancelRequested,
                    actions: Dictionary(uniqueKeysWithValues: [action(.inspectCheckout, value.phase == .unconfirmed && value.acknowledgedAt == nil), action(.acknowledgeCheckout, value.phase == .unconfirmed && value.acknowledgedAt == nil), action(.cancelCheckout, value.isWorking && !value.cancelRequested), action(.openConversation, snapshot.threads.contains { $0.id == value.targetThreadID })]),
                    details: [("Repository", value.review.plan.pullRequest.reference.repository.selector), ("Source", value.review.registeredWorkspacePath), ("Destination", value.review.plan.destinationPath), ("Requested branch", value.review.plan.requestedBranch), ("Requested commit", value.review.plan.requestedHeadCommit), ("Actual branch", value.result?.branch ?? ""), ("Actual commit", value.result?.headCommit ?? "")],
                    warnings: value.result?.warnings ?? [], paths: [value.review.registeredWorkspacePath] + value.affectedWorkspacePaths + value.coordinationPaths,
                    pullRequest: value.review.plan.pullRequest.reference, url: value.review.plan.pullRequest.url, readOnly: value.review.plan.isReadOnly))
            }
            let restores = (snapshot.checkpointRestoreOperations ?? []).filter { owns($0.review.projectID, $0.review.threadID) }
            for value in selected(restores, held: { $0.locksSource }) {
                result.append(try operation(id: value.id, kind: .checkpointRestore, projectID: value.review.projectID, threadID: value.review.threadID,
                    runID: value.review.runID, attemptID: value.review.attemptID, phase: value.phase.rawValue, updatedAt: value.updatedAt,
                    title: "Restore \(value.review.stage.rawValue) checkpoint", error: value.error, acknowledged: value.acknowledgedAt != nil,
                    actions: Dictionary(uniqueKeysWithValues: [action(.inspectRestore, value.phase == .unconfirmed && value.acknowledgedAt == nil), action(.acknowledgeRestore, value.phase == .unconfirmed && value.acknowledgedAt == nil)]),
                    details: [("Affected paths", String(value.review.gitReview.affectedPaths.count))], paths: [value.review.workspacePath]))
            }
            let history = (snapshot.conversationHistoryOperations ?? []).filter { owns($0.review.projectID, $0.review.sourceThreadID, target: $0.review.targetThreadID) }
            for value in selected(history, held: { $0.locksSource || $0.isWorking }) {
                result.append(try operation(id: value.id, kind: .conversationHistory, projectID: value.review.projectID, threadID: value.review.sourceThreadID,
                    runID: value.review.runID, targetThreadID: value.review.targetThreadID, phase: value.phase.rawValue, updatedAt: value.updatedAt,
                    title: value.review.kind.rawValue, error: value.error,
                    details: [("Provider", value.review.sourceConfiguration.provider.name), ("Files", value.files?.phase.rawValue ?? "Kept")],
                    paths: [value.review.sourceConfiguration.workspacePath]))
            }
            let steering = (snapshot.promptSteerings ?? []).filter { owns($0.projectID, $0.threadID) }
            for value in selected(steering, held: { $0.holdsQueue }) {
                result.append(try operation(id: value.id, kind: .promptSteering, projectID: value.projectID, threadID: value.threadID,
                    runID: value.runID, phase: value.phase.rawValue, updatedAt: value.updatedAt, title: "Prompt steering", error: value.error,
                    acknowledged: value.acknowledgedAt != nil, paths: [value.configuration.workspacePath]))
            }
            for project in snapshot.projects where thread == nil || project.id == thread?.projectID {
                guard let clone = project.clone else { continue }
                result.append(try operation(id: clone.id, kind: .projectClone, projectID: project.id,
                    phase: clone.phase.rawValue, updatedAt: clone.updatedAt, title: "Project clone", error: clone.error,
                    cancelRequested: clone.cancelRequested,
                    details: [("Destination", clone.plan.destinationPath), ("Previous attempts", String(clone.previousPlans.count))],
                    paths: [clone.plan.destinationPath]))
            }
            for value in snapshot.threads where thread == nil || value.id == thread?.id {
                if let preparation = value.workspacePreparation {
                    result.append(try operation(id: preparation.id, kind: .worktreePreparation, projectID: value.projectID, threadID: value.id,
                        attemptID: preparation.id, phase: preparation.phase.rawValue, updatedAt: preparation.updatedAt, title: "Worktree preparation",
                        error: preparation.error, cancelRequested: preparation.cancelRequested,
                        actions: Dictionary(uniqueKeysWithValues: [action(.retryWorktree, preparation.canRetry), action(.inspectWorktree, preparation.canRetry && preparation.plan != nil), action(.cancelWorktree, preparation.isRunning && !preparation.cancelRequested)]),
                        paths: [preparation.request.sourcePath, preparation.destinationPath]))
                }
                if let settlement = value.settlement {
                    result.append(try operation(id: settlement.id, kind: .settlement, projectID: value.projectID, threadID: value.id,
                        phase: settlement.phase.rawValue, updatedAt: settlement.settledAt, title: "Conversation settled", error: nil, paths: [value.workspacePath]))
                }
            }
            return result.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        }
    }
}
