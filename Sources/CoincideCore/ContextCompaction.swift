import Foundation

public enum ContextCompactionPhase: String, Codable, Sendable {
    case pending, running, completed, failed, unconfirmed
}

/// Latest explicit maintenance action. This is not a user turn and never
/// replaces Coincide's public transcript with the provider's private summary.
public struct ContextCompactionOperation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let threadID: UUID
    public let provider: ProviderKind
    public internal(set) var phase: ContextCompactionPhase
    public internal(set) var error: String?
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    let projectID: UUID
    let threadCreatedAt: Date
    let sourceIncarnation: UUID
    let runtimeID: UUID
    let configuration: ProviderConfiguration
    public var isWorking: Bool { phase == .pending || phase == .running }

    init(thread: CodingThread, incarnation: UUID, runtimeID: UUID, now: Date = .now) {
        id = UUID(); threadID = thread.id; projectID = thread.projectID
        threadCreatedAt = thread.createdAt; provider = thread.provider
        sourceIncarnation = incarnation; self.runtimeID = runtimeID
        configuration = .init(thread: thread); phase = .pending
        createdAt = now; updatedAt = now
    }
    func matches(_ thread: CodingThread) -> Bool {
        thread.id == threadID && thread.projectID == projectID && thread.createdAt == threadCreatedAt &&
            thread.runtimeID == runtimeID && ProviderConfiguration(thread: thread) == configuration
    }
    mutating func recover() {
        guard isWorking else { return }
        error = phase == .pending ? ProviderContextCompactionError(.notStarted).localizedDescription
            : ProviderContextCompactionError(.unconfirmed).localizedDescription
        phase = phase == .pending ? .failed : .unconfirmed; updatedAt = max(createdAt, .now)
    }
    private var validErrorForPhase: Bool {
        switch phase {
        case .pending, .running, .completed: return error == nil
        case .failed:
            return ProviderContextCompactionError.Kind.allCases.filter { $0 != .unconfirmed }
                .contains { ProviderContextCompactionError($0).localizedDescription == error }
        case .unconfirmed: return error == ProviderContextCompactionError(.unconfirmed).localizedDescription
        }
    }
    func validate(thread: CodingThread) throws {
        guard threadID == thread.id, projectID == thread.projectID, threadCreatedAt == thread.createdAt,
              configuration.provider == provider,
              configuration.nativeThreadID?.isEmpty == false,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt,
              validErrorForPhase,
              !isWorking || (matches(thread) && thread.contextCompactionID == id && thread.activeRun == nil && thread.queuedTurns.isEmpty) else {
            throw CoincideError("Invalid context compaction ownership.")
        }
    }
}

public struct ProviderContextCompactionReceipt: Sendable, Equatable {
    public let provider: ProviderKind
    public let nativeThreadID: String
    public init(provider: ProviderKind, nativeThreadID: String) {
        self.provider = provider; self.nativeThreadID = nativeThreadID
    }
}

public struct ProviderContextCompactionError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable { case unsupported, notIdle, notStarted, failed, unconfirmed }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unsupported: "This provider connection does not advertise supported manual compaction."
        case .notIdle: "Compact context requires the same idle, connected conversation. Send a reply to establish its connection first."
        case .notStarted: "Context compaction did not start. The visible conversation was kept."
        case .failed: "The provider did not complete context compaction. The visible conversation was kept."
        case .unconfirmed: "Context compaction may have started, but its completion could not be confirmed. It will not be retried automatically."
        }
    }
}

extension WorkspaceSnapshot {
    mutating func replaceContextCompaction(_ operation: ContextCompactionOperation) {
        guard let index = contextCompactionOperations?.firstIndex(where: { $0.id == operation.id }) else { return }
        contextCompactionOperations?[index] = operation
    }
    func validateContextCompactions() throws {
        let records = contextCompactionOperations ?? []
        guard Set(records.map(\.id)).count == records.count, Set(records.map(\.threadID)).count == records.count else {
            throw CoincideError("Duplicate context compaction ownership.")
        }
        for record in records {
            guard let thread = threads.first(where: { $0.id == record.threadID }) else { throw CoincideError("Missing context compaction owner.") }
            try record.validate(thread: thread)
        }
        for thread in threads {
            if let id = thread.contextCompactionID {
                guard records.contains(where: { $0.id == id && $0.threadID == thread.id && $0.isWorking }) else {
                    throw CoincideError("Missing context compaction operation.")
                }
            }
        }
    }
    mutating func recoverContextCompactions() {
        for index in (contextCompactionOperations ?? []).indices { contextCompactionOperations?[index].recover() }
        for index in threads.indices { threads[index].contextCompactionID = nil }
    }

    public func contextCompaction(threadID: UUID) -> ContextCompactionOperation? {
        contextCompactionOperations?.first { $0.threadID == threadID }
    }
    public func contextCompactionUnavailableReason(threadID: UUID) -> String? {
        guard let thread = threads.first(where: { $0.id == threadID }) else {
            return ProviderContextCompactionError(.unsupported).localizedDescription
        }
        if contextCompaction(threadID: threadID)?.isWorking == true { return "Wait for context compaction to finish." }
        guard !thread.isArchived, thread.activeRun == nil, !thread.isBusy, thread.queuedTurns.isEmpty,
              thread.runtimeRequests.isEmpty, thread.runtimeID != nil, thread.providerThreadID?.isEmpty == false else {
            return ProviderContextCompactionError(.notIdle).localizedDescription
        }
        guard pendingContextTransfers(threadID: threadID).isEmpty, !hasUnresolvedContextDelivery(threadID: threadID),
              thread.claudeResumeSelection == nil, thread.claudeResumeConsumerRunID == nil,
              !isOriginalImportedSession(configuration: .init(thread: thread), threadID: threadID) else {
            return "Send a reply to establish this Coincide conversation's independent context before compacting."
        }
        guard providerReady(for: thread), !isPromptSteeringHoldingQueue(threadID: threadID) else {
            return "Finish the pending conversation or workspace action before compacting context."
        }
        return nil
    }
}

extension WorkspaceDecision {
    mutating func acceptContextCompaction(_ operation: ContextCompactionOperation) throws {
        if let reason = snapshot.contextCompactionUnavailableReason(threadID: operation.threadID) { throw WorkspaceCommandError(reason) }
        guard let index = snapshot.threads.firstIndex(where: { $0.id == operation.threadID }),
              operation.matches(snapshot.threads[index]), operation.phase == .pending else {
            throw WorkspaceCommandError(ProviderContextCompactionError(.notIdle).localizedDescription)
        }
        snapshot.contextCompactionOperations = (snapshot.contextCompactionOperations ?? []).filter { $0.threadID != operation.threadID } + [operation]
        snapshot.threads[index].contextCompactionID = operation.id
        effects.append(.init(id: operation.id, request: .contextCompaction(threadID: operation.threadID, operationID: operation.id)))
    }
    mutating func dispatchContextCompaction(threadID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }),
              var operation = snapshot.contextCompaction(threadID: threadID), operation.id == operationID,
              operation.sourceIncarnation == incarnation, operation.phase == .pending,
              operation.matches(snapshot.threads[index]) else { throw WorkspaceCommandError(ProviderContextCompactionError(.notStarted).localizedDescription) }
        operation.phase = .running; operation.updatedAt = max(operation.createdAt, now); snapshot.replaceContextCompaction(operation)
    }
    mutating func finishContextCompaction(threadID: UUID, operationID: UUID, result: EffectResult, now: Date) {
        guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }),
              var operation = snapshot.contextCompaction(threadID: threadID), operation.id == operationID, operation.isWorking else { return }
        let wasDispatched = operation.phase == .running
        switch result {
        case .succeeded where wasDispatched && operation.matches(snapshot.threads[index]):
            operation.phase = .completed; operation.error = nil
        case .failed(let message):
            let known = ProviderContextCompactionError.Kind.allCases.first { ProviderContextCompactionError($0).localizedDescription == message }
            let kind = known ?? (wasDispatched ? .unconfirmed : .notStarted)
            operation.phase = kind == .unconfirmed ? .unconfirmed : .failed
            operation.error = ProviderContextCompactionError(kind).localizedDescription
        default:
            operation.phase = wasDispatched ? .unconfirmed : .failed
            operation.error = ProviderContextCompactionError(wasDispatched ? .unconfirmed : .notStarted).localizedDescription
        }
        operation.updatedAt = max(operation.createdAt, now); snapshot.replaceContextCompaction(operation)
        snapshot.threads[index].contextCompactionID = nil
        if operation.phase != .completed, snapshot.threads[index].runtimeID == operation.runtimeID {
            snapshot.threads[index].runtimeID = nil; closeRuntimes.insert(threadID)
        }
    }
    mutating func cancelContextCompaction(threadID: UUID, operationID: UUID, now: Date) throws {
        guard let operation = snapshot.contextCompaction(threadID: threadID), operation.id == operationID, operation.isWorking else {
            throw WorkspaceCommandError("This context compaction is no longer running.")
        }
        finishContextCompaction(threadID: threadID, operationID: operationID, result: .cancelled, now: now)
    }
    mutating func validateContextCompactionCommand(_ command: WorkspaceCommand) throws {
        guard let id = command.threadID, snapshot.contextCompaction(threadID: id)?.isWorking == true else { return }
        switch command {
        case .interrupt, .interruptFromAppMCP: return
        case .replaceComposerDraft, .discardComposerDraft, .editThread(_, .draft), .editThread(_, .title), .editThread(_, .pinned), .addAttachments, .removeAttachment: return
        default: throw WorkspaceCommandError("Wait for context compaction to finish before changing this conversation.")
        }
    }
}
