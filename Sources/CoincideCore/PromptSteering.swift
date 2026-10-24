import Foundation

public struct PromptSteeringAvailability: Sendable, Equatable {
    public let canSteer: Bool
    public let runID: UUID?
    public let configuration: ProviderConfiguration?
    public let interruptsTools: Bool
    public let unavailableReason: String?
    public let target: ProviderSteeringTarget?
    public init(canSteer: Bool = false, runID: UUID? = nil, configuration: ProviderConfiguration? = nil,
                interruptsTools: Bool = false, unavailableReason: String? = nil, target: ProviderSteeringTarget? = nil) {
        self.canSteer = canSteer; self.runID = runID; self.configuration = configuration
        self.interruptsTools = interruptsTools; self.unavailableReason = unavailableReason
        self.target = target
    }
}

public enum PromptSteeringPhase: String, Codable, Sendable { case accepted, dispatching, delivered, queued, failed, unconfirmed }

/// Input acceptance and native delivery are separate durable facts. The input's
/// reserved ID becomes a run ID only when a proven-unsent input starts normally.
public struct PromptSteeringOperation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let effectID: UUID
    public let threadID: UUID
    public let projectID: UUID
    public let sourceIncarnation: UUID
    public let runtimeID: UUID
    public let runID: UUID
    public let nativeThreadID: String
    public let nativeTurnID: String?
    public let adapterRunID: UUID?
    public var target: ProviderSteeringTarget? {
        switch (nativeTurnID, adapterRunID) {
        case (.some(let id), .none): .nativeTurn(id)
        case (.none, .some(let id)): .adapterRun(id)
        default: nil
        }
    }
    public let input: QueuedTurn
    public let messageID: String
    public let queuedID: UUID?
    public let configuration: ProviderConfiguration
    /// Independent app-tool input does not consume the user's composer.
    /// nil retains the exact legacy encoding and composer ownership behavior.
    public var preservesComposer: Bool?
    public let createdAt: Date
    public var updatedAt: Date
    public var phase: PromptSteeringPhase
    public var receipt: ProviderSteeringReceipt?
    public var error: String?
    public var acknowledgedAt: Date?
    public var fallbackAllowed: Bool
    public var fallbackRunID: UUID { input.id }
    public var isWorking: Bool { phase == .accepted || phase == .dispatching }
    public var isUnconfirmed: Bool { phase == .unconfirmed }
    public var holdsQueue: Bool { isWorking || (isUnconfirmed && acknowledgedAt == nil) }
    public static let failureMessage = "The steering input was not delivered. It was retained and was not automatically resent."
    public static let unconfirmedMessage = "Steering delivery could not be confirmed. This input may already have reached the provider and was not repeated."
    public init(id: UUID = UUID(), effectID: UUID = UUID(), threadID: UUID, projectID: UUID,
                sourceIncarnation: UUID, runtimeID: UUID, runID: UUID, nativeThreadID: String, nativeTurnID: String,
                input: QueuedTurn, messageID: String, queuedID: UUID? = nil, configuration: ProviderConfiguration,
                createdAt: Date = Date(), phase: PromptSteeringPhase = .accepted, preservesComposer: Bool = false) {
        self.init(id: id, effectID: effectID, threadID: threadID, projectID: projectID, sourceIncarnation: sourceIncarnation,
            runtimeID: runtimeID, runID: runID, nativeThreadID: nativeThreadID, target: .nativeTurn(nativeTurnID),
            input: input, messageID: messageID, queuedID: queuedID, configuration: configuration, createdAt: createdAt, phase: phase, preservesComposer: preservesComposer)
    }
    public init(id: UUID = UUID(), effectID: UUID = UUID(), threadID: UUID, projectID: UUID,
                sourceIncarnation: UUID, runtimeID: UUID, runID: UUID, nativeThreadID: String, target: ProviderSteeringTarget,
                input: QueuedTurn, messageID: String, queuedID: UUID? = nil, configuration: ProviderConfiguration,
                createdAt: Date = Date(), phase: PromptSteeringPhase = .accepted, preservesComposer: Bool = false) {
        self.id = id; self.effectID = effectID; self.threadID = threadID; self.projectID = projectID
        self.sourceIncarnation = sourceIncarnation; self.runtimeID = runtimeID; self.runID = runID
        self.nativeThreadID = nativeThreadID; self.input = input
        switch target {
        case .nativeTurn(let id): nativeTurnID = id; adapterRunID = nil
        case .adapterRun(let id): nativeTurnID = nil; adapterRunID = id
        }
        self.messageID = messageID; self.queuedID = queuedID; self.configuration = configuration
        self.preservesComposer = preservesComposer ? true : nil
        self.createdAt = createdAt; updatedAt = createdAt; self.phase = phase; fallbackAllowed = true
    }
    public func validate() throws {
        guard let target else { throw ProviderSteeringError(.invalidRequest) }
        try target.validate(); try ProviderSteeringValidation.id(nativeThreadID)
        // Only removed adapter providers steered runs without a native turn.
        if case .adapterRun = target { throw ProviderSteeringError(.invalidRequest) }
        try ProviderSteeringValidation.id(messageID); try ProviderHistoryValidation.path(configuration.workspacePath)
        try AttachmentLimits.validate(input.attachments ?? [])
        guard preservesComposer != true || (queuedID == nil && input.attachments?.isEmpty != false) else { throw ProviderSteeringError(.invalidRequest) }
        var inputConfiguration = input.configuration; inputConfiguration.nativeThreadID = configuration.nativeThreadID
        inputConfiguration.claudeLaunchSelection = configuration.claudeLaunchSelection
        guard inputConfiguration == configuration, Set([id, effectID, threadID, projectID, runID, input.id]).count == 6,
              queuedID == nil || queuedID == input.id, input.existingMessageID == nil,
              input.text.utf16.count <= 120_000, !input.text.isEmpty || input.attachments?.isEmpty == false,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite, input.createdAt.timeIntervalSince1970.isFinite,
              acknowledgedAt.map({ isUnconfirmed && $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw CoincideError("The steering input has invalid ownership or captured input.")
        }
        switch phase {
        case .accepted, .dispatching, .queued: guard receipt == nil, error == nil, acknowledgedAt == nil else { throw CoincideError("A pending steering input contains delivery evidence.") }
        case .delivered:
            guard let receipt, error == nil, acknowledgedAt == nil, receipt.target == target else { throw CoincideError("The steering receipt does not match its target.") }
            try receipt.validate()
        case .failed: guard receipt == nil, error == Self.failureMessage, acknowledgedAt == nil else { throw CoincideError("A failed steering input lost its delivery explanation.") }
        case .unconfirmed: guard receipt == nil, error == Self.unconfirmedMessage else { throw CoincideError("An uncertain steering input lost its warning.") }
        }
    }
    public func matchesActiveRun(_ run: ActiveRun) -> Bool {
        run.id == runID && run.configuration == configuration && target?.matches(run: run) == true
    }
}

/// Validation needs ownership and authored content, not another captured runtime
/// configuration. Keep these small projections across the validation phases.
private struct PromptSteeringAudit {
    let id: UUID
    let effectID: UUID
    let threadID: UUID
    let projectID: UUID
    let runID: UUID
    let inputID: UUID
    let messageID: String
    let phase: PromptSteeringPhase
    let text: String
    let attachments: [ChatAttachment]?
    let holdsQueue: Bool

    @inline(never)
    init(_ operation: borrowing PromptSteeringOperation) {
        id = operation.id; effectID = operation.effectID; threadID = operation.threadID
        projectID = operation.projectID; runID = operation.runID; inputID = operation.input.id
        messageID = operation.messageID; phase = operation.phase
        text = operation.input.text; attachments = operation.input.attachments
        holdsQueue = operation.holdsQueue
    }
}

extension WorkspaceSnapshot {
    public func promptSteering(_ id: UUID) -> PromptSteeringOperation? { promptSteerings?.first { $0.id == id } }
    public func isPromptSteeringHoldingQueue(threadID: UUID) -> Bool {
        (promptSteerings ?? []).contains { $0.threadID == threadID && $0.holdsQueue }
    }
    var promptSteeringReservedIDs: Set<UUID> { Set((promptSteerings ?? []).flatMap { [$0.id, $0.effectID, $0.input.id] }) }
    func promptSteeringTargetReason(threadID: UUID, queuedID: UUID? = nil, target: ProviderSteeringTarget? = nil) -> String? {
        guard let thread = threads.first(where: { $0.id == threadID }), !thread.isArchived,
              let run = thread.activeRun, !run.stopRequested,
              run.nativeTurnID.map({ !$0.isEmpty }) == true,
              thread.runtimeID != nil, thread.providerThreadID != nil,
              thread.provider == run.configuration.provider, workspaceReady(for: thread),
              thread.runtimeRequests.isEmpty, thread.settlement == nil,
              !isConversationHistoryLocked(threadID: threadID), !isCheckpointRestoreLocked(threadID: threadID),
              !isPullRequestCreationLocked(threadID: threadID), !isPullRequestCheckoutLocked(threadID: threadID) else {
            return "Wait for an active provider turn with no pending approval or question before steering."
        }
        if let target, !target.matches(run: run) { return "The provider turn changed before steering was accepted." }
        guard !isPromptSteeringHoldingQueue(threadID: threadID) else { return "Finish or acknowledge the previous steering delivery before steering again." }
        if let queuedID {
            guard let queued = thread.queuedTurns.first(where: { $0.id == queuedID }) else { return "The selected queued input is no longer available." }
            guard queued.existingMessageID == nil else { return "This steering input is already reserved as a follow-up. Resume its queue instead." }
            var configuration = queued.configuration; configuration.nativeThreadID = run.configuration.nativeThreadID
            configuration.claudeLaunchSelection = run.configuration.claudeLaunchSelection
            guard configuration == run.configuration else { return "This queued input has different captured settings. Keep it queued or explicitly restart with those settings." }
        }
        return nil
    }
    // Keep captured configurations, whole threads and checkpoint payloads out of
    // the same validation frame. These boundaries also apply in debug builds.
    @inline(never)
    func validatePromptSteerings() throws {
        let operations = promptSteerings ?? []
        let audits = operations.map { PromptSteeringAudit($0) }
        let ids = audits.flatMap { [$0.id, $0.effectID, $0.inputID] }
        guard Set(ids).count == ids.count else { throw CoincideError("Steering inputs must reserve distinct operation, effect and input identities.") }
        let external = promptSteeringExternalIdentities(audits: audits)
        guard Set(ids).isDisjoint(with: external) else { throw CoincideError("A steering identity belongs to another workspace action.") }
        for index in operations.indices {
            try validatePromptSteeringOperation(operations[index], audit: audits[index])
        }
        for index in threads.indices {
            try validatePromptSteeringThreadAudit(threads[index], audits: audits)
        }
    }

    @inline(never)
    private func promptSteeringExternalIdentities(audits: [PromptSteeringAudit]) -> Set<UUID> {
        var external = Set(projects.map(\.id) + threads.map(\.id) +
            (pullRequestCreations ?? []).flatMap { [$0.id, $0.effectID] } +
            (pullRequestCheckouts ?? []).flatMap { [$0.id, $0.effectID, $0.targetThreadID, $0.review.plan.id] } +
            (checkpointRestoreOperations ?? []).map(\.id) +
            (conversationHistoryOperations ?? []).flatMap { [$0.id] + ($0.review.targetThreadID.map { [$0] } ?? []) + ($0.review.files.map { [$0.id] } ?? []) })
        for project in projects { if let clone = project.clone { external.formUnion((clone.previousPlans + [clone.plan]).map(\.id)) } }
        for index in threads.indices {
            appendPromptSteeringThreadIdentities(threads[index], audits: audits, to: &external)
        }
        return external
    }

    @inline(never)
    private func appendPromptSteeringThreadIdentities(_ thread: borrowing CodingThread, audits: [PromptSteeringAudit], to external: inout Set<UUID>) {
        let threadID = thread.id
        external.formUnion((thread.runHistory ?? []).map(\.id).filter { runID in !audits.contains { $0.threadID == threadID && $0.phase == .queued && $0.inputID == runID } })
        external.formUnion(thread.queuedTurns.filter { queued in !audits.contains { $0.threadID == threadID && $0.phase == .queued && $0.inputID == queued.id } }.map(\.id))
        if let preparation = thread.workspacePreparation { external.formUnion([preparation.id] + preparation.previousAttempts.map { $0.request.id }) }
        if let settlement = thread.settlement { external.insert(settlement.id) }
        for (_, script) in thread.projectScripts { external.formUnion(script.previousPlans.map(\.id) + [script.id]) }
        let runs = thread.runHistory ?? []
        for index in runs.indices {
            appendPromptSteeringCheckpointIdentities(runs[index], to: &external)
        }
    }

    @inline(never)
    private func appendPromptSteeringCheckpointIdentities(_ run: borrowing ThreadRunRecord, to external: inout Set<UUID>) {
        if let checkpoints = run.checkpoints {
            external.formUnion(([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).map(\.id))
        }
    }

    @inline(never)
    private func validatePromptSteeringOperation(_ operation: borrowing PromptSteeringOperation, audit: PromptSteeringAudit) throws {
        try operation.validate()
        guard let index = threads.firstIndex(where: { $0.id == audit.threadID }) else { return }
        try validatePromptSteeringTranscript(threads[index], audit: audit)
        for index in threads.indices {
            try validatePromptSteeringTurnIdentities(threads[index], audit: audit)
        }
    }

    @inline(never)
    private func validatePromptSteeringTranscript(_ thread: borrowing CodingThread, audit: PromptSteeringAudit) throws {
        let threadID = thread.id
        guard thread.projectID == audit.projectID,
              let row = thread.messages.first(where: { $0.id == audit.messageID }), row.role == .user,
              row.promptSteeringID == audit.id, row.text == audit.text,
              row.attachments == audit.attachments,
              row.runReference == .init(threadID: threadID, runID: audit.phase == .queued ? audit.inputID : audit.runID) ||
                (audit.phase == .queued && row.runReference == .init(threadID: threadID, runID: audit.runID)),
              thread.runHistory?.contains(where: { $0.id == audit.runID }) == true else {
            throw CoincideError("The steering input lost its original transcript or run ownership.")
        }
    }

    @inline(never)
    private func validatePromptSteeringTurnIdentities(_ thread: borrowing CodingThread, audit: PromptSteeringAudit) throws {
        let threadID = thread.id
        guard !thread.queuedTurns.contains(where: { ($0.id == audit.id || $0.id == audit.effectID) || ($0.id == audit.inputID && (threadID != audit.threadID || audit.phase != .queued || $0.existingMessageID != audit.messageID)) }),
              !(thread.runHistory ?? []).contains(where: { $0.id == audit.id || $0.id == audit.effectID || ($0.id == audit.inputID && (threadID != audit.threadID || audit.phase != .queued)) }) else {
            throw CoincideError("A steering input identity was reused by another turn.")
        }
    }

    @inline(never)
    private func validatePromptSteeringThreadAudit(_ thread: borrowing CodingThread, audits: [PromptSteeringAudit]) throws {
        let threadID = thread.id
        guard audits.filter({ $0.threadID == threadID && $0.holdsQueue }).count <= 1 else { throw CoincideError("Only one steering delivery can own a conversation at a time.") }
        for row in thread.messages where row.promptSteeringID != nil {
            guard let audit = audits.first(where: { $0.id == row.promptSteeringID }), audit.messageID == row.id,
                  audit.text == row.text, audit.attachments == row.attachments else { throw CoincideError("A transcript steering row has no captured delivery audit.") }
        }
        for queued in thread.queuedTurns where queued.existingMessageID != nil {
            guard audits.contains(where: { $0.threadID == threadID && $0.phase == .queued && $0.inputID == queued.id && $0.messageID == queued.existingMessageID }) else { throw CoincideError("The queued follow-up has no retained steering acceptance.") }
        }
    }
    /// A submitted frame is not a native acknowledgement of its input content.
    func hasUnverifiedSteering(in prefix: [ChatMessage]) -> Bool {
        prefix.contains { row in
            guard let id = row.promptSteeringID, let operation = promptSteering(id) else { return false }
            return operation.isWorking || operation.isUnconfirmed || (operation.phase == .queued && row.runReference?.runID == operation.runID) || (operation.phase == .delivered && operation.receipt?.delivery != .acknowledged)
        }
    }
    func verifiedForkPrefix(_ prefix: [ChatMessage]) throws -> [ChatMessage] {
        guard !hasUnverifiedSteering(in: prefix) else { throw WorkspaceCommandError("This transcript includes steering whose native delivery is unconfirmed. Rewind before its run or retain the current conversation.") }
        return prefix.filter { row in row.promptSteeringID.flatMap(promptSteering)?.phase != .failed }
    }
}

extension WorkspaceDecision {
    func validatePromptSteeringCommand(_ command: WorkspaceCommand, commandID: UUID) throws {
        let reserved = snapshot.promptSteeringReservedIDs
        guard !reserved.contains(commandID) else { throw WorkspaceCommandError("This input identity is reserved by a steering delivery.") }
        let identities: [UUID]
        switch command {
        case .createThread(let thread): identities = [thread.id] + (thread.runHistory ?? []).map(\.id) + thread.queuedTurns.map(\.id)
        case .addProject(let project): identities = [project.id]
        case .addProjectWithThread(let project, let thread), .startProjectClone(let project, let thread): identities = [project.id, thread.id] + (project.clone.map { [$0.id] } ?? [])
        case .retryProjectClone(_, let plan): identities = [plan.id]
        default: identities = []
        }
        guard reserved.isDisjoint(with: identities) else { throw WorkspaceCommandError("This workspace identity is reserved by a steering delivery.") }
    }
    mutating func acceptPromptSteering(_ operation: PromptSteeringOperation) throws {
        try operation.validate()
        guard snapshot.promptSteering(operation.id) == nil,
              snapshot.promptSteeringTargetReason(threadID: operation.threadID, queuedID: operation.queuedID, target: operation.target) == nil,
              let index = snapshot.threads.firstIndex(where: { $0.id == operation.threadID }) else { throw WorkspaceCommandError("The provider turn or queued input changed before steering was accepted.") }
        var thread = snapshot.threads[index]
        guard let run = thread.activeRun, thread.projectID == operation.projectID, thread.runtimeID == operation.runtimeID,
              operation.matchesActiveRun(run), thread.providerThreadID == operation.nativeThreadID,
              run.configuration == operation.configuration, !thread.messages.contains(where: { $0.id == operation.messageID }),
              !snapshot.promptSteeringReservedIDs.contains(operation.id), !snapshot.promptSteeringReservedIDs.contains(operation.effectID),
              !snapshot.promptSteeringReservedIDs.contains(operation.input.id) else { throw WorkspaceCommandError("The exact provider turn is no longer available for this steering input.") }
        if let queuedID = operation.queuedID {
            guard let queued = thread.queuedTurns.firstIndex(where: { $0.id == queuedID }), thread.queuedTurns[queued] == operation.input else { throw WorkspaceCommandError("The captured queued input changed. Choose it again.") }
            thread.queuedTurns.remove(at: queued)
        } else if operation.preservesComposer != true {
            guard thread.draftAttachments == (operation.input.attachments ?? []) else { throw WorkspaceCommandError("The draft attachments changed before steering was accepted.") }
            if thread.draft.trimmingCharacters(in: .whitespacesAndNewlines) == operation.input.text { thread.draft = "" }
            thread.draftAttachments = []
        }
        var message = ChatMessage(id: operation.messageID, role: .user, text: operation.input.text, attachments: operation.input.attachments)
        message.createdAt = operation.input.createdAt; message.runReference = .init(threadID: thread.id, runID: run.id); message.promptSteeringID = operation.id
        if run.configuration.provider == .claude, run.configuration.claudeRuntimeConfiguration != nil {
            try thread.registerClaudeSteeringInput(runID: run.id, messageID: operation.messageID)
        }
        thread.messages.append(message); thread.updatedAt = operation.createdAt; snapshot.threads[index] = thread
        if snapshot.promptSteerings == nil { snapshot.promptSteerings = [] }; snapshot.promptSteerings!.append(operation)
        try snapshot.validatePromptSteerings()
        effects.append(.init(id: operation.effectID, request: .promptSteering(threadID: thread.id, operationID: operation.id)))
    }
    mutating func dispatchPromptSteering(operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let index = snapshot.promptSteerings?.firstIndex(where: { $0.id == operationID }), let operation = snapshot.promptSteerings?[index],
              operation.phase == .accepted, operation.sourceIncarnation == incarnation,
              let thread = snapshot.threads.first(where: { $0.id == operation.threadID }), !thread.isArchived,
              thread.runtimeRequests.isEmpty, thread.settlement == nil, snapshot.workspaceReady(for: thread),
              !snapshot.isConversationHistoryLocked(threadID: thread.id), !snapshot.isCheckpointRestoreLocked(threadID: thread.id),
              !snapshot.isPullRequestCreationLocked(threadID: thread.id), !snapshot.isPullRequestCheckoutLocked(threadID: thread.id),
              thread.activeRun.map(operation.matchesActiveRun) == true,
              thread.activeRun?.stopRequested == false, thread.runtimeID == operation.runtimeID,
              thread.providerThreadID == operation.nativeThreadID, operation.fallbackAllowed else { throw WorkspaceCommandError("The steering target ended or was stopped before dispatch.") }
        snapshot.promptSteerings?[index].phase = .dispatching; snapshot.promptSteerings?[index].updatedAt = now
    }
    mutating func finishPromptSteering(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) throws {
        guard case .promptSteering(let threadID, let operationID) = request,
              let index = snapshot.promptSteerings?.firstIndex(where: { $0.id == operationID }), var operation = snapshot.promptSteerings?[index],
              operation.threadID == threadID, operation.sourceIncarnation == incarnation, operation.isWorking else { return }
        switch result {
        case .promptSteeringDelivered(let receipt):
            try receipt.validate(); guard operation.phase == .dispatching, let target = operation.target, receipt.target == target else { throw CoincideError("The steering acknowledgement belongs to another target.") }
            operation.phase = .delivered; operation.receipt = receipt; operation.error = nil
        case .promptSteeringUnsentCompleted:
            if operation.fallbackAllowed, let thread = snapshot.threads.first(where: { $0.id == threadID }), !thread.isArchived,
               !thread.queuePaused, thread.activeRun == nil,
               thread.runHistory?.contains(where: { $0.id == operation.runID && $0.status == .completed && !$0.stopRequested }) == true {
                operation.phase = .queued; operation.error = nil
                if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                    var queued = operation.input; queued.existingMessageID = operation.messageID
                    snapshot.threads[threadIndex].queuedTurns.insert(queued, at: 0)
                }
            } else { operation.phase = .failed; operation.error = PromptSteeringOperation.failureMessage }
        case .failed: operation.phase = .failed; operation.error = PromptSteeringOperation.failureMessage
        case .promptSteeringUnconfirmed, .cancelled, .stopped:
            operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? PromptSteeringOperation.failureMessage : PromptSteeringOperation.unconfirmedMessage
        default: return
        }
        operation.updatedAt = now; snapshot.promptSteerings?[index] = operation
        if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
            if operation.isUnconfirmed { snapshot.threads[threadIndex].queuePaused = true }
            if let row = snapshot.threads[threadIndex].messages.firstIndex(where: { $0.id == operation.messageID }) {
                snapshot.threads[threadIndex].messages[row].submissionError = operation.error
            }
            var thread = snapshot.threads[threadIndex]; startNext(in: &thread, now: now); snapshot.threads[threadIndex] = thread
        }
    }
    mutating func acknowledgePromptSteering(operationID: UUID, now: Date) throws {
        guard let index = snapshot.promptSteerings?.firstIndex(where: { $0.id == operationID }), let operation = snapshot.promptSteerings?[index], operation.isUnconfirmed else { throw WorkspaceCommandError("Only unconfirmed steering needs acknowledgement.") }
        if operation.acknowledgedAt == nil { snapshot.promptSteerings?[index].acknowledgedAt = now; snapshot.promptSteerings?[index].updatedAt = now }
        if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == operation.threadID }) {
            var thread = snapshot.threads[threadIndex]; startNext(in: &thread, now: now); snapshot.threads[threadIndex] = thread
        }
    }
    mutating func preventDelayedPromptSteering(_ command: WorkspaceCommand, now: Date) {
        let threadIDs: Set<UUID>
        switch command {
        case .interrupt(let id), .interruptFromAppMCP(let id, _, _), .editThread(let id, .archived(true)): threadIDs = [id]
        case .removeProject(let project, _): threadIDs = Set(snapshot.threads.filter { $0.projectID == project }.map(\.id))
        case .removeProjectGroup(_, let projects, _): threadIDs = Set(snapshot.threads.filter { thread in projects.contains { $0.id == thread.projectID } }.map(\.id))
        case .removeQueued(let threadID, let queuedID), .editQueued(let threadID, let queuedID):
            guard let queued = snapshot.threads.first(where: { $0.id == threadID })?.queuedTurns.first(where: { $0.id == queuedID }),
                  let messageID = queued.existingMessageID,
                  let index = snapshot.promptSteerings?.firstIndex(where: { $0.threadID == threadID && $0.phase == .queued && $0.messageID == messageID }) else { return }
            snapshot.promptSteerings?[index].phase = .failed; snapshot.promptSteerings?[index].error = PromptSteeringOperation.failureMessage
            snapshot.promptSteerings?[index].updatedAt = now; snapshot.promptSteerings?[index].fallbackAllowed = false
            if let t = snapshot.threads.firstIndex(where: { $0.id == threadID }), let m = snapshot.threads[t].messages.firstIndex(where: { $0.id == messageID }) { snapshot.threads[t].messages[m].submissionError = PromptSteeringOperation.failureMessage }
            return
        default: return
        }
        let removing: Bool
        switch command { case .removeProject, .removeProjectGroup: removing = true; default: removing = false }
        for index in (snapshot.promptSteerings ?? []).indices where threadIDs.contains(snapshot.promptSteerings![index].threadID) {
            guard snapshot.promptSteerings?[index].isWorking == true else { continue }
            snapshot.promptSteerings?[index].fallbackAllowed = false
            if snapshot.promptSteerings?[index].phase == .accepted || removing {
                let unknown = snapshot.promptSteerings?[index].phase == .dispatching
                snapshot.promptSteerings?[index].phase = unknown ? .unconfirmed : .failed
                snapshot.promptSteerings?[index].error = unknown ? PromptSteeringOperation.unconfirmedMessage : PromptSteeringOperation.failureMessage
                snapshot.promptSteerings?[index].updatedAt = now
                let operation = snapshot.promptSteerings![index]
                if let t = snapshot.threads.firstIndex(where: { $0.id == operation.threadID }),
                   let m = snapshot.threads[t].messages.firstIndex(where: { $0.id == operation.messageID }) { snapshot.threads[t].messages[m].submissionError = operation.error }
            }
        }
    }
}
