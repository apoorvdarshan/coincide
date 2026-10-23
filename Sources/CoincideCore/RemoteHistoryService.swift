import Foundation

actor RemoteHistoryService {
    private let environmentID: UUID
    private let hostID = UUID()
    private let engine: WorkspaceEngine
    private let workspace: RemoteWorkspaceService
    private var leases: [UUID: RemoteHistoryLease] = [:]
    private var order: [UUID] = []
    private var cleanup: [UUID: Task<Void, Never>] = [:]
    private var closing = false
    private var operations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closeTask: Task<Void, Never>?
    init(environmentID: UUID, engine: WorkspaceEngine, workspace: RemoteWorkspaceService) {
        self.environmentID = environmentID; self.engine = engine; self.workspace = workspace
    }
    private func begin() throws { guard !closing else { throw RemoteHistoryFailure(.unavailable) }; operations += 1 }
    private func finish() {
        operations -= 1
        if operations == 0 { let owned = waiters; waiters = []; for waiter in owned { waiter.resume() } }
    }
    private func validate(_ target: RemoteWorkspaceTarget, locked: Bool, requireRoot: Bool) async throws {
        guard !closing, target.environmentID == environmentID else { throw RemoteHistoryFailure(.invalidTarget) }
        try await workspace.validateHistoryTarget(target, allowLocked: locked, requireRoot: requireRoot)
        guard !closing else { throw RemoteHistoryFailure(.unavailable) }
    }
    private func binding(_ target: RemoteWorkspaceTarget, objectID: UUID, digest: String) -> RemoteHistoryBinding {
        .init(environmentID: environmentID, hostID: hostID, leaseID: UUID(), threadID: target.threadID, objectID: objectID, digest: digest)
    }
    private func remove(_ id: UUID) {
        guard let lease = leases.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if let reviewID = lease.reviewID {
            let token = UUID(), engine = engine, request = RemoteHistoryDiscardRequest(target: lease.target, reviewID: reviewID, digest: lease.binding.digest)
            cleanup[token] = Task {
                _ = await engine.discardRemoteHistoryReview(request)
                self.cleanup.removeValue(forKey: token)
            }
        }
        if let claim = lease.maintenanceClaim {
            let token = UUID(), engine = engine, target = lease.target
            cleanup[token] = Task {
                await engine.discardRemoteHistoryMaintenance(target: target, claim: claim)
                self.cleanup.removeValue(forKey: token)
            }
        }
    }
    private func publish(_ lease: RemoteHistoryLease) throws {
        guard !closing, lease.bytes <= RemoteHistoryProtocol.maximumCacheBytes else { throw RemoteHistoryFailure(.limitExceeded) }
        while leases.count >= RemoteHistoryProtocol.maximumLeases || leases.values.reduce(lease.bytes, { $0 + $1.bytes }) > RemoteHistoryProtocol.maximumCacheBytes {
            guard let oldest = order.first else { throw RemoteHistoryFailure(.limitExceeded) }; remove(oldest)
        }
        leases[lease.binding.leaseID] = lease; order.append(lease.binding.leaseID)
    }
    private func lease(_ binding: RemoteHistoryBinding, target: RemoteWorkspaceTarget) throws -> RemoteHistoryLease {
        guard binding.environmentID == environmentID, binding.hostID == hostID,
              let lease = leases[binding.leaseID], lease.binding == binding,
              try RemoteHistoryProtocol.payload(lease.target) == RemoteHistoryProtocol.payload(target) else { throw RemoteHistoryFailure(.staleReview) }
        order.removeAll { $0 == binding.leaseID }; order.append(binding.leaseID)
        lease.maximumBytes = RemoteHistoryProtocol.maximumCacheBytes - leases.values.filter { $0 !== lease }.reduce(0) { $0 + $1.bytes }
        return lease
    }
    func review(_ request: RemoteHistoryReviewRequest) async throws -> RemoteHistoryReview {
        try begin(); defer { finish() }
        var prepared: RemoteHistoryPreparedReview?
        do {
            try await validate(request.target, locked: false, requireRoot: true)
            // Evicting an unused display also disposes its exact native review;
            // accepted review evidence is protected by the Engine fence.
            if leases.count >= RemoteHistoryProtocol.maximumLeases, let oldest = order.first { remove(oldest) }
            for task in Array(cleanup.values) { await task.value }
            let value = try await engine.reviewRemoteHistory(request); prepared = value
            try await validate(request.target, locked: false, requireRoot: true)
            var restoreAvailability = try await engine.remoteHistoryFileRestoreAvailability(value.native)
            if restoreAvailability.allowed, value.native.files == nil {
                let current = try await engine.captureRemoteHistory(request.target)
                if case .available(let target) = try current.snapshot.conversationHistoryFileTarget(for: value.native) {
                    do { try await workspace.admitHistoryScope(.init(mutatingPaths: [target.receipt.plan.repositoryPath, target.receipt.plan.commonDirectoryPath], coordinationPaths: [target.receipt.plan.commonDirectoryPath])) }
                    catch { restoreAvailability = .init(allowed: false, reason: "Another operation owns the saved checkpoint's workspace.") }
                }
            }
            let scope = Self.scope(value.native)
            try await workspace.admitHistoryScope(scope)
            guard !closing else { throw RemoteHistoryFailure(.unavailable) }
            let lease = try RemoteHistoryLease(target: request.target, binding: binding(request.target, objectID: value.native.id, digest: value.digest),
                proofBytes: RemoteHistoryProtocol.payload(value).count)
            lease.reviewID = value.native.id
            lease.messages = try value.native.prefix.map { try lease.message($0) }
            lease.paths = value.native.files?.gitReview.affectedPaths ?? []
            try lease.account(RemoteHistoryProtocol.payload(lease.paths).count)
            let files = try value.native.files.map { files in
                RemoteHistoryFileReview(id: files.id, checkpointRunID: files.target.checkpointRunID, attemptID: files.target.attemptID,
                    stage: files.target.stage, affectedPathCount: files.gitReview.affectedPaths.count,
                    patch: try lease.text(files.gitReview.previewPatch), patchTruncated: files.gitReview.previewTruncated)
            }
            let summary = try RemoteHistoryReviewSummary(kind: value.native.kind, runID: value.native.runID, reviewedAt: value.native.reviewedAt,
                provider: value.native.sourceConfiguration.provider, workspacePath: value.native.sourceConfiguration.workspacePath,
                sourceConfiguration: lease.json(value.native.sourceConfiguration, kind: .configuration), targetConfiguration: lease.json(value.native.targetConfiguration, kind: .configuration),
                retainedMessageCount: value.native.prefix.count, removedMessageCount: value.native.removedMessageIDs.count, removedRunCount: value.native.removedRunIDs.count,
                targetThreadID: value.native.targetThreadID, suggestedTitle: lease.text(value.native.suggestedTitle), files: files,
                recallPromptOnSuccess: value.native.recallPromptOnSuccess == true,
                restoreFiles: restoreAvailability,
                mutatingPaths: scope.mutatingPaths, coordinationPaths: scope.coordinationPaths,
                details: [.init(label: "Boundary", value: lease.text(Self.boundary(value.native))),
                          .init(label: "Native source", value: lease.text(value.native.sourceReference.nativeThreadID))])
            let result = RemoteHistoryReview(target: request.target, id: value.native.id, digest: value.digest, binding: lease.binding, value: summary)
            try lease.account(RemoteHistoryProtocol.payload(result).count)
            guard try RemoteHistoryProtocol.payload(result).count <= RemoteHistoryProtocol.maximumResultBytes else { throw RemoteHistoryFailure(.limitExceeded) }
            try publish(lease); return result
        } catch {
            if let value = prepared { _ = await engine.discardRemoteHistoryReview(.init(target: value.target, reviewID: value.native.id, digest: value.digest)) }
            throw Self.safe(error)
        }
    }
    func read(_ request: RemoteHistoryReadRequest) async throws -> RemoteHistoryReadResult {
        try begin(); defer { finish() }
        var unusedMaintenance: RemoteHistoryMaintenanceReview?
        do {
            guard request.target.environmentID == environmentID else { throw RemoteHistoryFailure(.invalidTarget) }
            let result: RemoteHistoryReadResult
            switch request.query {
            case .prefix(let binding, let newest, let cursor):
                let value = try lease(binding, target: request.target)
                result = try value.page(query: "prefix|\(newest)", cursor: cursor, rows: value.messages, reverse: newest, wrap: RemoteHistoryValue.messages)
            case .paths(let binding, let cursor):
                let value = try lease(binding, target: request.target)
                result = try value.page(query: "paths", cursor: cursor, rows: value.paths, wrap: RemoteHistoryValue.paths)
            case .content(let binding, let reference, let offset, let cursor):
                let value = try lease(binding, target: request.target), key = "content|\(reference.id)"
                guard value.references[reference.id] == reference, let bytes = value.contents[reference.id] else { throw RemoteHistoryFailure(.invalidRequest) }
                let expected = try value.offset(cursor, query: key)
                guard offset == expected, offset >= 0, offset <= bytes.count else { throw RemoteHistoryFailure(.staleCursor) }
                let data = Data(bytes.dropFirst(offset).prefix(RemoteHistoryProtocol.maximumContentChunkBytes)), end = offset + data.count
                let next = end == bytes.count ? nil : try value.cursor(query: key, offset: end)
                result = .init(target: request.target, value: .content(.init(binding: binding, reference: reference, offset: offset, data: data, nextCursor: next, complete: next == nil)))
            case .release(let binding):
                guard binding.environmentID == environmentID, binding.hostID == hostID else { throw RemoteHistoryFailure(.staleReview) }
                if leases[binding.leaseID] == nil { result = .init(target: request.target, value: .released(false)) }
                else {
                    _ = try lease(binding, target: request.target); remove(binding.leaseID)
                    for task in Array(cleanup.values) { await task.value }
                    result = .init(target: request.target, value: .released(true))
                }
            case .controls:
                try await validate(request.target, locked: true, requireRoot: false)
                let update = try await engine.captureRemoteHistory(request.target), thread = try Self.thread(update.snapshot, target: request.target)
                result = .init(target: request.target, value: .controls(.init(claudeSelectionID: thread.claudeResumeSelection?.id,
                    claudeConsumerRunID: thread.claudeResumeConsumerRunID, piIntentID: thread.piFreshSessionIntent?.id,
                    piConsumerRunID: thread.piFreshConsumerRunID,
                    canInspectClaudeResume: update.snapshot.claudeResumeSelectionNeedsInspection(threadID: thread.id),
                    canInspectPiFresh: update.snapshot.piFreshSessionNeedsInspection(threadID: thread.id))))
            case .operation(let id), .recall(let id), .maintenance(let id):
                let maintenance: Bool; if case .maintenance = request.query { maintenance = true } else { maintenance = false }
                try await validate(request.target, locked: true, requireRoot: maintenance)
                if maintenance { unusedMaintenance = try await engine.reviewRemoteHistoryMaintenance(target: request.target, operationID: id) }
                let update = try await engine.captureRemoteHistory(request.target), thread = try Self.thread(update.snapshot, target: request.target)
                guard let operation = update.snapshot.conversationHistoryOperation(id), operation.review.sourceThreadID == thread.id,
                      operation.review.projectID == thread.projectID else { throw RemoteHistoryFailure(.invalidTarget) }
                let value = try RemoteHistoryLease(target: request.target, binding: binding(request.target, objectID: id, digest: RemoteHistoryProtocol.digest(operation)),
                    proofBytes: unusedMaintenance.map { try RemoteHistoryProtocol.payload($0).count } ?? 0)
                if let claim = unusedMaintenance { value.maintenanceClaim = .init(id: claim.id, digest: claim.digest) }
                if case .recall = request.query {
                    guard operation.review.kind == .rewindBeforeRun, let run = thread.runHistory?.first(where: { $0.id == operation.review.runID }), run.origin == .user,
                          let message = thread.messages.first(where: { $0.id == run.userMessageID && $0.role == .user && $0.runReference == .init(threadID: thread.id, runID: run.id) }) else { throw RemoteHistoryFailure(.invalidTarget) }
                    result = try .init(target: request.target, value: .recall(.init(binding: value.binding, operationID: id, runID: run.id, messageID: message.id,
                        text: value.text(message.text), attachments: value.json(message.attachments ?? [], kind: .attachmentReferences))))
                } else {
                    result = .init(target: request.target, value: .operation(try Self.operation(operation, snapshot: update.snapshot, lease: value)))
                }
                guard !closing else { throw RemoteHistoryFailure(.unavailable) }; try publish(value); unusedMaintenance = nil
            case .piFresh(let intent, let consumer):
                try await validate(request.target, locked: true, requireRoot: true)
                let update = try await engine.captureRemoteHistory(request.target), thread = try Self.thread(update.snapshot, target: request.target)
                guard thread.piFreshSessionIntent?.id == intent, thread.piFreshConsumerRunID == consumer else { throw RemoteHistoryFailure(.invalidTarget) }
                let observed = try await engine.inspectPiFreshSession(threadID: thread.id)
                try await validate(request.target, locked: true, requireRoot: true)
                let current = try Self.thread((try await engine.captureRemoteHistory(request.target)).snapshot, target: request.target)
                guard current.piFreshSessionIntent?.id == intent, current.piFreshConsumerRunID == consumer else { throw RemoteHistoryFailure(.invalidTarget) }
                let state: RemoteHistoryPiFreshInspection.State
                switch observed { case .unwritten: state = .unwritten; case .persisted: state = .persisted; case .unavailable: state = .unavailable }
                result = .init(target: request.target, value: .piFresh(.init(intentID: intent, consumerRunID: consumer, state: state)))
            }
            guard !closing, try RemoteHistoryProtocol.payload(result).count <= RemoteHistoryProtocol.maximumResultBytes else { throw RemoteHistoryFailure(.limitExceeded) }
            return result
        } catch {
            if let claim = unusedMaintenance { await engine.discardRemoteHistoryMaintenance(target: claim.target, claim: .init(id: claim.id, digest: claim.digest)) }
            throw Self.safe(error)
        }
    }
    func discard(_ request: RemoteHistoryDiscardRequest) async throws -> RemoteHistoryDiscardResult {
        try begin(); defer { finish() }
        guard request.target.environmentID == environmentID else { throw RemoteHistoryFailure(.invalidTarget) }
        let discarded = await engine.discardRemoteHistoryReview(request)
        if discarded { for lease in leases.values.filter({ $0.reviewID == request.reviewID }) { remove(lease.binding.leaseID) } }
        return .init(request: request, discarded: discarded)
    }
    func prepare(_ command: RemoteEnvironmentCommand) async throws -> RemoteEnvironmentPreparation {
        try begin(); defer { finish() }
        guard case .history(let target, let action) = command else { throw RemoteHistoryFailure(.invalidRequest) }
        let locked: Bool; if case .begin = action { locked = false } else { locked = true }
        do {
            try await validate(target, locked: locked, requireRoot: action.requiresBoundRoot)
            let value = try await engine.prepareRemoteHistory(command)
            try await validate(target, locked: locked, requireRoot: action.requiresBoundRoot)
            return value
        } catch { throw Self.safe(error) }
    }
    func close() async {
        if let task = closeTask { await task.value; return }
        closing = true
        let task = Task {
            await self.engine.closeRemoteHistory()
            if self.operations > 0 { await withCheckedContinuation { self.waiters.append($0) } }
            for task in Array(self.cleanup.values) { await task.value }
            self.leases = [:]; self.order = []
        }
        closeTask = task; await task.value
    }
    private static func thread(_ snapshot: WorkspaceSnapshot, target: RemoteWorkspaceTarget) throws -> CodingThread {
        guard let value = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }) else { throw RemoteHistoryFailure(.invalidTarget) }
        return value
    }
    private static func scope(_ review: ConversationHistoryReview) -> RemoteHistoryScope {
        guard let files = review.files else { return .init(mutatingPaths: [], coordinationPaths: []) }
        return .init(mutatingPaths: [files.gitReview.currentPlan.repositoryPath, files.gitReview.currentPlan.commonDirectoryPath], coordinationPaths: [files.gitReview.currentPlan.commonDirectoryPath])
    }
    private static func boundary(_ review: ConversationHistoryReview) -> String {
        if let claude = review.claude {
            switch claude.boundary { case .freshSession: return "Empty Claude context for the next explicit input; original native transcript retained."
            case .throughMessage: return review.kind == .forkAfterRun ? "Verified Claude transcript copy through the selected message." : "Saved Claude resume point; original native transcript retained." }
        }
        if let pi = review.pi, case .freshSession = pi.boundary { return "Empty Pi context for the next explicit input; original native session retained." }
        return review.kind == .forkAfterRun ? "Through the end of the selected completed run." : "Before the selected run's opening input."
    }
    private static func operation(_ value: ConversationHistoryOperation, snapshot: WorkspaceSnapshot, lease: RemoteHistoryLease) throws -> RemoteHistoryOperationView {
        let inspect = snapshot.canInspectConversationHistory(operationID: value.id)
        let filePending = value.phase == .applied && value.files.map { [.failed, .unconfirmed].contains($0.phase) && $0.acknowledgedAt == nil } == true
        let canRecall = value.phase == .applied && value.review.kind == .rewindBeforeRun && value.allExternalWorkSucceeded && value.recalledAt == nil && value.recallDismissedAt == nil
        func availability(_ allowed: Bool) -> RemoteProjectionAvailability { .init(allowed: allowed, reason: allowed ? nil : "This action is unavailable in the saved history state.") }
        let actions: [String: RemoteProjectionAvailability] = [
            "inspectProvider": availability(inspect), "inspectFiles": availability(filePending && value.files?.phase == .unconfirmed),
            "acknowledgeFiles": availability(filePending), "recallPrompt": availability(canRecall), "dismissRecall": availability(value.needsPromptRecall),
            "keepOriginal": availability(value.phase == .unconfirmed && (value.review.openCodeV1 != nil || value.review.pi != nil)),
            "inspectMaintenance": availability(value.phase == .unconfirmed && value.review.openCodeV2 != nil && value.maintenance?.phase.isWorking != true),
            "clearMaintenance": availability(value.phase == .unconfirmed && value.review.openCodeV2 != nil && value.maintenance?.phase.isWorking != true && value.maintenance?.phase != .applied),
            "cancelPi": availability(value.review.pi != nil && value.isPending), "respondPi": availability(value.piControls?.requests.contains(where: { !$0.responding }) == true),
            "openConversation": availability(value.phase == .applied && value.review.targetThreadID != nil)]
        let summary = try RemoteOperationSummary(id: value.id, kind: .conversationHistory, projectID: value.review.projectID, threadID: value.review.sourceThreadID,
            runID: value.review.runID, targetThreadID: value.review.targetThreadID, phase: value.phase.rawValue, updatedAt: value.updatedAt,
            title: lease.text(value.review.kind.rawValue), error: value.error.map { try lease.text($0) }, acknowledged: value.files?.acknowledgedAt != nil,
            cancelRequested: false,
            actions: actions, fingerprint: lease.binding.digest, details: [.init(label: "Provider", value: lease.text(value.review.sourceConfiguration.provider.name)),
                .init(label: "Files", value: lease.text(value.files?.phase.rawValue ?? "Kept"))], workspacePaths: [value.review.sourceConfiguration.workspacePath])
        return try .init(binding: lease.binding, operation: summary, kind: value.review.kind, provider: value.review.sourceConfiguration.provider,
            filesPhase: value.files?.phase, filesAcknowledged: value.files?.acknowledgedAt != nil, needsPromptRecall: value.needsPromptRecall,
            recalled: value.recalledAt != nil, recallDismissed: value.recallDismissedAt != nil, piSessionID: value.piControls?.sessionID,
            piRequests: value.piControls.map { try lease.json($0.requests, kind: .runtimeRequests) }, maintenanceClaim: lease.maintenanceClaim)
    }
    private static func safe(_ error: Error) -> RemoteHistoryFailure {
        if let value = error as? RemoteHistoryFailure { return value }
        if let value = error as? RemoteWorkspaceFailure {
            switch value.kind { case .busy: return .init(.busy); case .limitExceeded: return .init(.limitExceeded); case .unavailable, .interrupted: return .init(.unavailable); default: return .init(.invalidTarget) }
        }
        if let value = error as? ProviderHistoryError {
            switch value.kind { case .historyChanged: return .init(.staleReview); case .notIdle: return .init(.busy); case .limitExceeded: return .init(.limitExceeded); default: return .init(.operationFailed) }
        }
        return .init(error is CancellationError ? .unavailable : .operationFailed)
    }
}
