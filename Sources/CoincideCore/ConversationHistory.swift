import CryptoKit
import Foundation

public enum ConversationHistoryKind: String, Codable, Sendable { case forkAfterRun, rewindBeforeRun }
public enum ConversationHistoryPhase: String, Codable, Sendable { case accepted, dispatching, applied, failed, unconfirmed }
public enum ConversationHistoryReconciliation: Codable, Sendable, Equatable {
    case applied(ProviderConversationSnapshot)
    case unchanged
}

/// A reviewed local/provider history boundary. Creating this value never performs
/// provider work; the engine persists it before the corresponding outbox effect.
public struct ConversationHistoryReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ConversationHistoryKind
    public let reviewedAt: Date
    public let sourceThreadID: UUID
    public let projectID: UUID
    public let runID: UUID
    public let sourceIncarnation: UUID
    public let sourceConfiguration: ProviderConfiguration
    public let targetConfiguration: ProviderConfiguration
    public let sourceReference: ProviderConversationReference
    public let reviewedHeadTurnID: String
    public let boundary: ProviderHistoryBoundary
    public let expectedResultHeadTurnID: String?
    public let prefix: [ChatMessage]
    public let removedRunIDs: [UUID]
    public let removedMessageIDs: [String]
    public let sourceFingerprint: String
    public let targetThreadID: UUID?
    public let suggestedTitle: String
    public init(id: UUID = UUID(), kind: ConversationHistoryKind, reviewedAt: Date = Date(), sourceThreadID: UUID,
                projectID: UUID, runID: UUID, sourceIncarnation: UUID, sourceConfiguration: ProviderConfiguration,
                targetConfiguration: ProviderConfiguration, sourceReference: ProviderConversationReference,
                reviewedHeadTurnID: String, boundary: ProviderHistoryBoundary, expectedResultHeadTurnID: String?,
                prefix: [ChatMessage], removedRunIDs: [UUID], removedMessageIDs: [String], sourceFingerprint: String,
                targetThreadID: UUID?, suggestedTitle: String) throws {
        self.id = id; self.kind = kind; self.reviewedAt = reviewedAt; self.sourceThreadID = sourceThreadID
        self.projectID = projectID; self.runID = runID; self.sourceIncarnation = sourceIncarnation
        self.sourceConfiguration = sourceConfiguration; self.targetConfiguration = targetConfiguration
        self.sourceReference = sourceReference; self.reviewedHeadTurnID = reviewedHeadTurnID; self.boundary = boundary
        self.expectedResultHeadTurnID = expectedResultHeadTurnID; self.prefix = prefix; self.removedRunIDs = removedRunIDs
        self.removedMessageIDs = removedMessageIDs; self.sourceFingerprint = sourceFingerprint
        self.targetThreadID = targetThreadID; self.suggestedTitle = suggestedTitle
        try validate()
    }
    public func validate() throws {
        try sourceReference.validate(); try boundary.validate(); try ProviderHistoryValidation.id(reviewedHeadTurnID)
        if let expectedResultHeadTurnID { try ProviderHistoryValidation.id(expectedResultHeadTurnID) }
        try ProviderHistoryValidation.path(sourceConfiguration.workspacePath); try ProviderHistoryValidation.path(targetConfiguration.workspacePath)
        guard reviewedAt.timeIntervalSince1970.isFinite, sourceReference.provider == .codex,
              sourceConfiguration.provider == sourceReference.provider, targetConfiguration.provider == sourceReference.provider,
              sourceConfiguration.nativeThreadID == sourceReference.nativeThreadID,
              sourceConfiguration.workspacePath == targetConfiguration.workspacePath,
              sourceFingerprint.utf8.count == 64, sourceFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Set(prefix.map(\.id)).count == prefix.count, prefix.allSatisfy({ $0.removedByHistoryOperationID == nil }),
              Set(removedRunIDs).count == removedRunIDs.count, Set(removedMessageIDs).count == removedMessageIDs.count,
              !suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, suggestedTitle.utf8.count <= 4_096,
              !suggestedTitle.contains("\0"), try JSONEncoder().encode(prefix).count <= 4_194_304 else {
            throw CoincideError("This conversation history review is invalid or exceeds its bounded transcript limit.")
        }
        switch (kind, boundary) {
        case (.forkAfterRun, .throughTurn(let turn)):
            guard targetThreadID != nil, targetThreadID != sourceThreadID, targetThreadID != id,
                  removedRunIDs.isEmpty, removedMessageIDs.isEmpty, expectedResultHeadTurnID == turn else { throw CoincideError("The fork review has inconsistent ownership or turn boundaries.") }
        case (.rewindBeforeRun, .beforeTurn):
            guard targetThreadID == nil, removedRunIDs.contains(runID), !removedMessageIDs.isEmpty else { throw CoincideError("The rewind review has no exact retained transcript suffix.") }
        default: throw CoincideError("The conversation history action does not match its reviewed boundary.")
        }
    }
}

public struct ConversationHistoryOperation: Codable, Sendable, Equatable, Identifiable {
    public let review: ConversationHistoryReview
    public var phase: ConversationHistoryPhase
    public var updatedAt: Date
    public var targetTitle: String?
    public var result: ProviderConversationSnapshot?
    public var error: String?
    public var recalledAt: Date?
    public var id: UUID { review.id }
    public init(review: ConversationHistoryReview, phase: ConversationHistoryPhase = .accepted, updatedAt: Date? = nil,
                targetTitle: String? = nil, result: ProviderConversationSnapshot? = nil, error: String? = nil, recalledAt: Date? = nil) {
        self.review = review; self.phase = phase; self.updatedAt = updatedAt ?? review.reviewedAt
        self.targetTitle = targetTitle; self.result = result; self.error = error; self.recalledAt = recalledAt
    }
    public static let failureMessage = "The conversation history action was not completed. No provider work was replayed."
    public static let unconfirmedMessage = "The provider history outcome could not be confirmed. Inspect it before continuing; the action was not repeated."
    public static let unchangedMessage = "Provider history is unchanged. Review again before retrying."
    public var isPending: Bool { phase == .accepted || phase == .dispatching }
    public var locksSource: Bool { isPending || (phase == .unconfirmed && review.kind == .rewindBeforeRun) }
    public func validate() throws {
        try review.validate()
        guard updatedAt.timeIntervalSince1970.isFinite,
              error == nil || [Self.failureMessage, Self.unconfirmedMessage, Self.unchangedMessage].contains(error!),
              (phase == .applied) == (result != nil), recalledAt == nil || (phase == .applied && review.kind == .rewindBeforeRun && recalledAt!.timeIntervalSince1970.isFinite),
              targetTitle.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4_096 && !$0.contains("\0") }) ?? true else { throw CoincideError("The conversation history operation has inconsistent state.") }
        if let result {
            try result.validate()
            let referenceMatches = review.kind == .forkAfterRun ? result.reference != review.sourceReference : result.reference == review.sourceReference
            guard referenceMatches, result.reference.provider == review.sourceReference.provider, result.historyMode == .paginated,
                  result.workspacePath == review.targetConfiguration.workspacePath, result.headTurnID == review.expectedResultHeadTurnID else {
                throw CoincideError("The conversation history result does not match its reviewed provider boundary.")
            }
        }
    }
}

extension CodingThread {
    public var visibleMessages: [ChatMessage] { messages.filter { $0.removedByHistoryOperationID == nil } }
    public var activeHistoryRuns: [ThreadRunRecord] { (runHistory ?? []).filter { $0.removedByHistoryOperationID == nil } }
}

extension WorkspaceSnapshot {
    public func conversationHistoryOperation(_ id: UUID) -> ConversationHistoryOperation? { conversationHistoryOperations?.first { $0.id == id } }
    public func isConversationHistoryLocked(threadID: UUID) -> Bool {
        (conversationHistoryOperations ?? []).contains { $0.review.sourceThreadID == threadID && $0.locksSource }
    }
    public func canReviewConversationHistory(threadID: UUID, excludingOperationID: UUID? = nil) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }), !thread.isArchived, !thread.isBusy,
              thread.queuedTurns.isEmpty, thread.runtimeRequests.isEmpty, thread.heldPostRunCheckpoint == nil,
              thread.settlement == nil, workspaceReady(for: thread), !isCheckpointRestoreLocked(threadID: threadID),
              !(conversationHistoryOperations ?? []).contains(where: { $0.id != excludingOperationID && $0.review.sourceThreadID == threadID && $0.locksSource }) else { return false }
        return thread.workspacePreparation?.setup.map { [.succeeded, .skipped].contains($0.phase) } ?? true
    }
    public func historySourceFingerprint(threadID: UUID) throws -> String {
        guard let thread = threads.first(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
        struct Source: Encodable {
            let id: UUID, projectID: UUID
            let configuration: ProviderConfiguration
            let messages: [ChatMessage]
            let records: [ThreadRunRecord]
            let checkpointPolicy: RunCheckpointPolicy?
            let activeRun: ActiveRun?
            let queuedTurns: [QueuedTurn]
            let runtimeRequests: [RuntimeRequest]
            let preparation: ThreadWorkspacePreparation?
            let settlement: ThreadSettlement?
            let archived: Bool, queuePaused: Bool
        }
        let records = thread.activeHistoryRuns.map { value in var value = value; value.checkpoints = nil; return value }
        let source = Source(id: thread.id, projectID: thread.projectID, configuration: .init(thread: thread), messages: thread.visibleMessages,
            records: records, checkpointPolicy: thread.checkpointPolicy, activeRun: thread.activeRun,
            queuedTurns: thread.queuedTurns, runtimeRequests: thread.runtimeRequests,
            preparation: thread.workspacePreparation, settlement: thread.settlement, archived: thread.isArchived, queuePaused: thread.queuePaused)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
    }
    public func conversationHistoryUnavailableReason(threadID: UUID, runID: UUID, kind: ConversationHistoryKind) -> String? {
        guard canReviewConversationHistory(threadID: threadID), let thread = threads.first(where: { $0.id == threadID }) else {
            return "Finish current work, queued messages, questions and workspace preparation before changing conversation history."
        }
        guard let run = thread.activeHistoryRuns.first(where: { $0.id == runID }), run.status.isTerminal,
              run.messageAttributionVersion == 1, run.configuration.provider == .codex, thread.provider == .codex,
              run.configuration.workspacePath == thread.workspacePath, !run.turnIDs.isEmpty,
              run.providerThreadID == thread.providerThreadID, run.providerThreadID != nil else { return "This run has no verified boundary in the current Codex conversation and checkout." }
        if kind == .forkAfterRun, run.status != .completed { return "Native forks require a completed run with a verified provider turn." }
        do { _ = try thread.transcriptPrefix(runID: runID, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun) }
        catch { return "This run has no verified local transcript boundary." }
        return nil
    }

    func validateConversationHistorySource(_ review: ConversationHistoryReview, excludingOperationID: UUID? = nil) throws {
        try review.validate()
        guard canReviewConversationHistory(threadID: review.sourceThreadID, excludingOperationID: excludingOperationID),
              let thread = threads.first(where: { $0.id == review.sourceThreadID && $0.projectID == review.projectID }),
              ProviderConfiguration(thread: thread) == review.sourceConfiguration,
              try historySourceFingerprint(threadID: thread.id) == review.sourceFingerprint,
              let run = thread.activeHistoryRuns.first(where: { $0.id == review.runID }), run.status.isTerminal,
              run.messageAttributionVersion == 1, run.configuration == review.targetConfiguration,
              run.configuration.workspacePath == thread.workspacePath,
              run.configuration.provider == .codex, thread.provider == .codex,
              run.providerThreadID == review.sourceReference.nativeThreadID, thread.providerThreadID == review.sourceReference.nativeThreadID,
              !run.turnIDs.isEmpty else { throw WorkspaceCommandError("This conversation or its reviewed history changed. Review the current run again.") }
        let prefix = try thread.transcriptPrefix(runID: run.id, boundary: review.kind == .forkAfterRun ? .afterRun : .beforeRun)
        guard prefix == review.prefix else { throw WorkspaceCommandError("The reviewed transcript prefix changed. Review it again.") }
        switch review.kind {
        case .forkAfterRun:
            guard run.status == .completed, review.boundary == .throughTurn(run.turnIDs.last!), review.expectedResultHeadTurnID == run.turnIDs.last else { throw WorkspaceCommandError("The fork no longer matches the completed provider run.") }
        case .rewindBeforeRun:
            guard review.boundary == .beforeTurn(run.turnIDs.first!), let start = thread.activeHistoryRuns.firstIndex(where: { $0.id == run.id }) else { throw WorkspaceCommandError("The rewind no longer matches the selected provider run.") }
            let removedRuns = thread.activeHistoryRuns.dropFirst(start).map(\.id)
            let prefixIDs = Set(prefix.map(\.id))
            let removedMessages = thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id)
            guard review.removedRunIDs == removedRuns, review.removedMessageIDs == removedMessages else { throw WorkspaceCommandError("The conversation suffix changed. Review the rewind again.") }
        }
    }

    func validateConversationHistory() throws {
        let operations = conversationHistoryOperations ?? []
        guard Set(operations.map(\.id)).count == operations.count,
              Set(operations.compactMap { $0.review.targetThreadID }).count == operations.filter({ $0.review.targetThreadID != nil }).count else { throw CoincideError("Conversation history actions must have unique operation and target identities.") }
        for operation in operations {
            try operation.validate()
            if operation.locksSource {
                guard threads.contains(where: { $0.id == operation.review.sourceThreadID && $0.projectID == operation.review.projectID }) else { throw CoincideError("A pending history action lost its source conversation.") }
            }
            if let targetID = operation.review.targetThreadID, let target = threads.first(where: { $0.id == targetID }) {
                guard operation.phase == .applied, target.forkedFromHistoryOperationID == operation.id else { throw CoincideError("A fork target is already owned by another conversation.") }
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) })
        for thread in threads {
            if let fork = thread.forkedFromHistoryOperationID {
                guard let operation = byID[fork], operation.phase == .applied, operation.review.kind == .forkAfterRun,
                      operation.review.targetThreadID == thread.id, operation.review.projectID == thread.projectID,
                      operation.review.prefix.allSatisfy({ original in thread.messages.contains(where: { $0.id == original.id && $0.runReference == original.runReference }) }) else { throw CoincideError("The forked conversation has no matching applied lineage.") }
            }
            for run in thread.runHistory ?? [] {
                guard let marker = run.removedByHistoryOperationID else { continue }
                guard let operation = byID[marker], operation.phase == .applied, operation.review.kind == .rewindBeforeRun,
                      operation.review.sourceThreadID == thread.id, operation.review.removedRunIDs.contains(run.id) else { throw CoincideError("A removed run has no matching applied rewind.") }
            }
            for message in thread.messages {
                if let marker = message.removedByHistoryOperationID {
                    guard let operation = byID[marker], operation.phase == .applied, operation.review.kind == .rewindBeforeRun,
                          operation.review.sourceThreadID == thread.id, operation.review.removedMessageIDs.contains(message.id) else { throw CoincideError("A removed message has no matching applied rewind.") }
                }
                if let reference = message.runReference, reference.threadID != thread.id {
                    guard let fork = thread.forkedFromHistoryOperationID, let operation = byID[fork], operation.phase == .applied,
                          operation.review.kind == .forkAfterRun, operation.review.targetThreadID == thread.id,
                          operation.review.prefix.contains(where: { $0.id == message.id && $0.runReference == reference }) else { throw CoincideError("An inherited message has no matching applied fork provenance.") }
                }
            }
        }
        // Resolved audit survives removal. Existing sources must retain every marked
        // row; subsequent rewinds never physically delete or reassign old markers.
        for operation in operations where operation.phase == .applied && operation.review.kind == .rewindBeforeRun {
            guard let source = threads.first(where: { $0.id == operation.review.sourceThreadID }) else { continue }
            guard operation.review.removedRunIDs.allSatisfy({ id in source.runHistory?.contains(where: { $0.id == id && $0.removedByHistoryOperationID == operation.id }) == true }),
                  operation.review.removedMessageIDs.allSatisfy({ id in source.messages.contains(where: { $0.id == id && $0.removedByHistoryOperationID == operation.id }) }) else { throw CoincideError("The rewind audit lost retained transcript or run evidence.") }
        }
    }
}

extension WorkspaceDecision {
    func validateConversationHistoryLocks(_ command: WorkspaceCommand) throws {
        let created: CodingThread?
        switch command {
        case .createThread(let thread), .addProjectWithThread(_, let thread), .startProjectClone(_, let thread): created = thread
        default: created = nil
        }
        if let created, (snapshot.conversationHistoryOperations ?? []).contains(where: { $0.id == created.id || $0.review.targetThreadID == created.id }) {
            throw WorkspaceCommandError("This conversation identity is reserved by a history action. Create a fresh conversation instead.")
        }
        let locked = Set(snapshot.threads.filter { snapshot.isConversationHistoryLocked(threadID: $0.id) }.map(\.id))
        guard !locked.isEmpty else { return }
        let targets: Set<UUID>
        switch command {
        case .editThread(let id, let edit):
            switch edit { case .draft, .pinned, .title: return; default: targets = [id] }
        case .removeProject(let projectID, _): targets = Set(snapshot.threads.filter { $0.projectID == projectID }.map(\.id))
        case .removeProjectGroup(_, let projects, _): targets = Set(snapshot.threads.filter { thread in projects.contains { $0.id == thread.projectID } }.map(\.id))
        case .submit(let id, _), .interrupt(let id), .respond(let id, _, _), .resumeQueue(let id),
             .removeQueued(let id, _), .editQueued(let id, _), .settleThread(let id, _, _), .resumeThread(let id, _),
             .cancelWorktreePreparation(let id), .approveProjectScript(let id, _, _), .stopProjectScript(let id, _),
             .skipProjectScript(let id, _), .retryProjectScript(let id, _), .retryPostRunCheckpoint(let id, _, _),
             .continueAfterPostRunCheckpoint(let id, _, _): targets = [id]
        case .removeACPAgent(let agentID): targets = Set(snapshot.threads.filter { $0.acpAgent?.id == agentID }.map(\.id))
        default: return
        }
        guard locked.isDisjoint(with: targets) else { throw WorkspaceCommandError("Finish or inspect the pending conversation history action before changing this conversation.") }
    }

    mutating func acceptConversationHistory(_ review: ConversationHistoryReview, title: String?, now: Date) throws {
        guard snapshot.conversationHistoryOperation(review.id) == nil,
              !snapshot.threads.contains(where: { $0.id == review.id }),
              review.targetThreadID.map({ target in !snapshot.threads.contains { $0.id == target } && !(snapshot.conversationHistoryOperations ?? []).contains { $0.review.targetThreadID == target || $0.id == target } }) ?? true else {
            throw WorkspaceCommandError("This conversation history action or target identity is already in use. Review again.")
        }
        try snapshot.validateConversationHistorySource(review)
        let operation = ConversationHistoryOperation(review: review, updatedAt: now, targetTitle: title)
        do { try operation.validate() } catch { throw WorkspaceCommandError("Choose a valid conversation title and reviewed history boundary.") }
        if snapshot.conversationHistoryOperations == nil { snapshot.conversationHistoryOperations = [] }
        snapshot.conversationHistoryOperations!.append(operation)
        effects.append(.init(id: review.id, request: .conversationHistory(threadID: review.sourceThreadID, operationID: review.id)))
    }

    mutating func dispatchConversationHistory(threadID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[i], operation.phase == .accepted,
              operation.review.sourceThreadID == threadID, operation.review.sourceIncarnation == incarnation else { return }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        snapshot.conversationHistoryOperations?[i].phase = .dispatching
        snapshot.conversationHistoryOperations?[i].updatedAt = now
    }

    mutating func finishConversationHistory(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) {
        guard case .conversationHistory(let threadID, let operationID) = request,
              let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], operation.isPending,
              operation.review.sourceThreadID == threadID, operation.review.sourceIncarnation == incarnation else { return }
        switch result {
        case .conversationHistoryConfirmed(let result):
            guard operation.phase == .dispatching else { return }
            do {
                try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
                operation.phase = .applied; operation.result = result; operation.error = nil; operation.updatedAt = now
                try operation.validate()
                try applyConversationHistory(operation, now: now)
            } catch {
                operation.phase = .unconfirmed; operation.result = nil; operation.error = ConversationHistoryOperation.unconfirmedMessage; operation.updatedAt = now
            }
        case .failed:
            operation.phase = .failed; operation.error = ConversationHistoryOperation.failureMessage; operation.updatedAt = now
        case .cancelled, .stopped, .conversationHistoryUnconfirmed:
            operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? ConversationHistoryOperation.failureMessage : ConversationHistoryOperation.unconfirmedMessage
            operation.updatedAt = now
        default: return
        }
        snapshot.conversationHistoryOperations?[i] = operation
    }

    mutating func reconcileConversationHistory(operationID: UUID, result: ConversationHistoryReconciliation, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], operation.phase == .unconfirmed,
              operation.review.kind == .rewindBeforeRun else { throw WorkspaceCommandError("Only the current unconfirmed rewind can be inspected.") }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        switch result {
        case .applied(let result):
            operation.phase = .applied; operation.result = result; operation.error = nil; operation.updatedAt = now
            try operation.validate(); try applyConversationHistory(operation, now: now)
        case .unchanged:
            operation.phase = .failed; operation.error = ConversationHistoryOperation.unchangedMessage; operation.updatedAt = now
        }
        snapshot.conversationHistoryOperations?[i] = operation
    }

    private mutating func applyConversationHistory(_ operation: ConversationHistoryOperation, now: Date) throws {
        let review = operation.review
        guard let sourceIndex = snapshot.threads.firstIndex(where: { $0.id == review.sourceThreadID }), let result = operation.result else { throw WorkspaceCommandError("The history action lost its source conversation.") }
        switch review.kind {
        case .forkAfterRun:
            guard let targetID = review.targetThreadID, !snapshot.threads.contains(where: { $0.id == targetID }),
                  let project = snapshot.projects.first(where: { $0.id == review.projectID }) else { throw WorkspaceCommandError("The fork target is no longer available.") }
            let configuration = review.targetConfiguration
            var target = CodingThread(project: project, model: configuration.model)
            target.id = targetID; target.title = operation.targetTitle ?? review.suggestedTitle
            target.workspacePath = configuration.workspacePath; target.provider = configuration.provider
            target.permission = configuration.permission; target.acpAgent = configuration.acpAgent
            target.agentModeID = configuration.agentModeID; target.agentConfigValues = configuration.agentConfigValues
            target.agentConfiguration = configuration.agentConfiguration; target.providerThreadID = result.reference.nativeThreadID
            target.messages = review.prefix; target.forkedFromHistoryOperationID = operation.id
            target.checkpointPolicy = snapshot.threads[sourceIndex].checkpointPolicy
            target.createdAt = now; target.updatedAt = now
            snapshot.threads.append(target)
        case .rewindBeforeRun:
            var source = snapshot.threads[sourceIndex]
            let removedMessages = Set(review.removedMessageIDs), removedRuns = Set(review.removedRunIDs)
            for i in source.messages.indices where removedMessages.contains(source.messages[i].id) { source.messages[i].removedByHistoryOperationID = operation.id }
            for i in (source.runHistory ?? []).indices where removedRuns.contains(source.runHistory![i].id) { source.runHistory?[i].removedByHistoryOperationID = operation.id }
            source.providerThreadID = result.reference.nativeThreadID; source.activeRun = nil; source.runtimeID = nil
            source.runtimeRequests = []; source.providerActivity = nil; source.providerMetadata = nil
            source.state = .idle; source.updatedAt = now
            snapshot.threads[sourceIndex] = source; closeRuntimes.insert(source.id)
        }
    }

    mutating func recallConversationHistoryPrompt(operationID: UUID, now: Date) throws {
        guard let operationIndex = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[operationIndex], operation.phase == .applied,
              operation.review.kind == .rewindBeforeRun else { throw WorkspaceCommandError("Recall requires an applied conversation rewind.") }
        guard operation.recalledAt == nil else { return }
        guard !snapshot.isConversationHistoryLocked(threadID: operation.review.sourceThreadID),
              let sourceIndex = snapshot.threads.firstIndex(where: { $0.id == operation.review.sourceThreadID }),
              let record = snapshot.threads[sourceIndex].runHistory?.first(where: { $0.id == operation.review.runID }), record.origin == .user,
              let message = snapshot.threads[sourceIndex].messages.first(where: { $0.id == record.userMessageID && $0.role == .user && $0.runReference == .init(threadID: operation.review.sourceThreadID, runID: record.id) }) else { throw WorkspaceCommandError("The original prompt is unavailable or another history action is pending.") }
        var source = snapshot.threads[sourceIndex], attachments = snapshot.threads[sourceIndex].draftAttachments
        var ids = Set(attachments.map(\.id))
        for attachment in message.attachments ?? [] where ids.insert(attachment.id).inserted { attachments.append(attachment) }
        do { try AttachmentLimits.validate(attachments) } catch { throw WorkspaceCommandError("The recalled attachments exceed the draft limit. Remove some attachments and try again.") }
        if !message.text.isEmpty { source.draft = source.draft.isEmpty ? message.text : source.draft + "\n\n" + message.text }
        source.draftAttachments = attachments; source.updatedAt = now
        snapshot.threads[sourceIndex] = source; snapshot.conversationHistoryOperations?[operationIndex].recalledAt = now
        snapshot.conversationHistoryOperations?[operationIndex].updatedAt = now
    }
}
