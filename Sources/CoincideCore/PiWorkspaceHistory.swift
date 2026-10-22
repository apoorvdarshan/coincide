import Foundation

public enum PiFreshSessionInspection: Codable, Sendable, Equatable {
    /// Absence after draining the owned process does not prove that its input
    /// was never processed. Continuing requires an explicit acknowledgement.
    case unwritten
    case persisted(PiHistoryFileRevision)
    case unavailable
}

public struct PiFreshContextResolution: Codable, Sendable, Equatable {
    public let intentID: UUID
    public let consumerRunID: UUID
    public let resolvedAt: Date
    public let outcome: PiFreshSessionInspection
    public init(intentID: UUID, consumerRunID: UUID, resolvedAt: Date, outcome: PiFreshSessionInspection) {
        self.intentID = intentID; self.consumerRunID = consumerRunID; self.resolvedAt = resolvedAt; self.outcome = outcome
    }
    public func validate() throws {
        guard resolvedAt.timeIntervalSince1970.isFinite, outcome != .unavailable else { throw PiHistoryGraphError(.invalidWindow) }
        if case .persisted(let revision) = outcome { try revision.validate() }
    }
}

enum PiHistoryScope {
    static func sameFile(_ a: String, _ b: String) -> Bool {
        guard a.hasPrefix("/"), b.hasPrefix("/") else { return false }
        if a == b { return true }
        let lhs = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
        let rhs = URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
        if lhs == rhs { return true }
        guard let x = try? FileManager.default.attributesOfItem(atPath: lhs),
              let y = try? FileManager.default.attributesOfItem(atPath: rhs),
              let xd = x[.systemNumber] as? NSNumber, let yd = y[.systemNumber] as? NSNumber,
              let xi = x[.systemFileNumber] as? NSNumber, let yi = y[.systemFileNumber] as? NSNumber else { return false }
        return xd == yd && xi == yi
    }
}

extension WorkspaceSnapshot {
    func hasPiHistoryCapture(_ thread: CodingThread, nativeSessionFile: String) -> Bool {
        func matches(_ configuration: ProviderConfiguration, _ nativeID: String?) -> Bool {
            configuration.provider == .pi && (nativeID ?? configuration.nativeThreadID).map { PiHistoryScope.sameFile($0, nativeSessionFile) } == true
        }
        if matches(.init(thread: thread), thread.providerThreadID) { return true }
        if let run = thread.activeRun, matches(run.configuration, run.configuration.nativeThreadID ?? thread.runHistory?.first(where: { $0.id == run.id })?.providerThreadID) { return true }
        return thread.queuedTurns.contains { matches($0.configuration, $0.configuration.nativeThreadID) }
    }
    public func isPiHistoryScopeLocked(configuration: ProviderConfiguration, nativeThreadID: String?, excludingOperationID: UUID? = nil) -> Bool {
        guard configuration.provider == .pi, let path = nativeThreadID ?? configuration.nativeThreadID else { return false }
        return (conversationHistoryOperations ?? []).contains { operation in
            guard operation.id != excludingOperationID, operation.review.pi != nil else { return false }
            if operation.locksSource, PiHistoryScope.sameFile(path, operation.review.sourceReference.nativeThreadID) { return true }
            return (operation.piCandidates ?? []).contains { candidate in
                guard let candidatePath = candidate.nativeSessionFile, PiHistoryScope.sameFile(path, candidatePath) else { return false }
                // The adopted final file is available through its new local
                // owner. Intermediate and abandoned candidates remain reserved.
                return operation.phase != .applied || operation.locksSource || candidatePath != operation.result?.reference.nativeThreadID
            }
        }
    }
    public func piFreshSessionNeedsInspection(threadID: UUID) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }), thread.provider == .pi, !thread.isBusy,
              let intent = thread.piFreshSessionIntent, let consumer = thread.piFreshConsumerRunID,
              let run = thread.runHistory?.first(where: { $0.id == consumer }), run.status.isTerminal else { return false }
        return run.configuration.piFreshSessionIntent == intent && run.configuration.piConfiguration?.runtimeIdentity == intent.runtimeIdentity
    }
    public func verifiedPiHistoryPrefix(_ prefix: [ChatMessage], evidence: PiHistoryReviewEvidence, threadID: UUID, fork: Bool) throws -> [ChatMessage] {
        try evidence.validate()
        let owned = Set(evidence.inputs.flatMap(\.inputs).filter { $0.nativeUserEntryID != nil }.map(\.clientMessageID))
        let inherited = threads.first(where: { $0.id == threadID })?.forkedFromHistoryOperationID.flatMap(conversationHistoryOperation)
        for row in prefix {
            guard let id = row.promptSteeringID, let steering = promptSteering(id) else { continue }
            if steering.phase == .failed { continue }
            if row.runReference?.threadID != threadID, let inherited, inherited.phase == .applied, inherited.review.pi != nil,
               inherited.review.prefix.contains(where: { $0.id == row.id && $0.runReference == row.runReference }) { continue }
            guard (steering.phase == .delivered || steering.phase == .unconfirmed), owned.contains(row.id) else {
                throw WorkspaceCommandError("The retained steering input has no exact native Pi entry proof.")
            }
        }
        return fork ? prefix.filter { $0.promptSteeringID.flatMap(promptSteering)?.phase != .failed } : prefix
    }
    func validatePiFreshContexts() throws {
        for thread in threads {
            let resolutions = thread.piFreshContextResolutions ?? []
            guard resolutions.count <= 10_000, thread.piFreshContextResolutions?.isEmpty != true,
                  Set(resolutions.map(\.consumerRunID)).count == resolutions.count else { throw PiHistoryGraphError(.invalidWindow) }
            for resolution in resolutions {
                try resolution.validate()
                guard let run = thread.runHistory?.first(where: { $0.id == resolution.consumerRunID }),
                      run.status.isTerminal, run.configuration.piFreshSessionIntent?.id == resolution.intentID else { throw PiHistoryGraphError(.invalidWindow) }
                if case .persisted(let revision) = resolution.outcome {
                    guard revision.filePath == run.configuration.piFreshSessionIntent?.nativeSessionFile,
                          revision.sessionID == run.pi?.nativeSessionID else { throw PiHistoryGraphError(.invalidWindow) }
                }
            }
            guard let intent = thread.piFreshSessionIntent else {
                guard thread.piFreshConsumerRunID == nil else { throw PiHistoryGraphError(.invalidWindow) }
                continue
            }
            try intent.validate()
            guard thread.provider == .pi, thread.piConfiguration?.runtimeIdentity == intent.runtimeIdentity,
                  thread.providerThreadID == intent.nativeSessionFile,
                  let operation = conversationHistoryOperation(intent.operationID), operation.phase == .applied,
                  operation.review.sourceThreadID == thread.id || operation.review.targetThreadID == thread.id,
                  operation.result?.pi?.freshIntent == intent else { throw PiHistoryGraphError(.invalidWindow) }
            if let consumer = thread.piFreshConsumerRunID {
                guard let record = thread.runHistory?.first(where: { $0.id == consumer }),
                      record.configuration.piFreshSessionIntent == intent, !resolutions.contains(where: { $0.consumerRunID == consumer }) else { throw PiHistoryGraphError(.invalidWindow) }
            }
        }
    }
}

extension CodingThread {
    mutating func resolvePiFreshSession(intent: PiFreshSessionIntent, consumerRunID: UUID, inspection: PiFreshSessionInspection, now: Date) throws {
        guard !isBusy, piFreshSessionIntent == intent, piFreshConsumerRunID == consumerRunID,
              let record = runHistory?.first(where: { $0.id == consumerRunID }), record.status.isTerminal,
              record.configuration.piFreshSessionIntent == intent,
              !(piFreshContextResolutions ?? []).contains(where: { $0.consumerRunID == consumerRunID }) else {
            throw WorkspaceCommandError("The Pi empty-context attempt changed. Inspect its current state again.")
        }
        let resolution = PiFreshContextResolution(intentID: intent.id, consumerRunID: consumerRunID, resolvedAt: now, outcome: inspection)
        try resolution.validate()
        if case .persisted(let file) = inspection {
            guard let proof = record.pi, proof.runID == consumerRunID,
                  proof.preparation.openingInput.clientMessageID == record.userMessageID,
                  record.configuration.piConfiguration?.runtimeIdentity == intent.runtimeIdentity,
                  proof.preparation.freshIntentID == intent.id, proof.runtimeIdentity == intent.runtimeIdentity,
                  proof.nativeSessionFile == intent.nativeSessionFile, file.filePath == intent.nativeSessionFile,
                  file.sessionID == proof.nativeSessionID,
                  proof.persistedFileRevision == nil || proof.persistedFileRevision == file else { throw PiHistoryGraphError(.invalidWindow) }
            piFreshSessionIntent = nil
        }
        if piFreshContextResolutions == nil { piFreshContextResolutions = [] }
        piFreshContextResolutions?.append(resolution)
        piFreshConsumerRunID = nil; queuePaused = true; updatedAt = now
    }
    mutating func completeProvenPiFreshSession(now: Date) throws {
        guard let intent = piFreshSessionIntent, let consumer = piFreshConsumerRunID,
              let run = runHistory?.first(where: { $0.id == consumer }), run.status == .completed,
              run.configuration.piFreshSessionIntent == intent, let proof = run.pi,
              proof.runID == run.id, proof.preparation.openingInput.clientMessageID == run.userMessageID,
              run.configuration.piConfiguration?.runtimeIdentity == intent.runtimeIdentity,
              proof.preparation.freshIntentID == intent.id, proof.captureStatus == .proven, proof.terminalStatus == .completed,
              proof.nativeSessionFile == intent.nativeSessionFile, let revision = proof.persistedFileRevision else { return }
        try proof.validate()
        let resolution = PiFreshContextResolution(intentID: intent.id, consumerRunID: consumer, resolvedAt: now, outcome: .persisted(revision))
        try resolution.validate()
        if piFreshContextResolutions == nil { piFreshContextResolutions = [] }
        piFreshContextResolutions?.append(resolution); piFreshSessionIntent = nil; piFreshConsumerRunID = nil
    }
}

extension WorkspaceDecision {
    func validatePiFreshContextCommand(_ command: WorkspaceCommand) throws {
        guard case .editThread(let threadID, let edit) = command,
              snapshot.threads.first(where: { $0.id == threadID })?.piFreshSessionIntent != nil else { return }
        switch edit {
        case .provider, .workspacePath, .piProvider, .piRuntimeConfiguration, .piWorkspace, .claudeProvider, .claudeWorkspace,
             .claudeRuntimeConfiguration, .codexProvider, .codexRuntimeConfiguration, .antigravityConfiguration, .acpAgent:
            throw WorkspaceCommandError("Finish or inspect the pending Pi empty-context attempt before changing its runtime or workspace.")
        default: break
        }
    }
    @inline(never)
    static func reducePiHistory(_ command: EngineCommand, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        do { return try mutatePiHistory(command, snapshot: snapshot, now: now) }
        catch let error as WorkspaceCommandError { throw error }
        catch { throw WorkspaceCommandError("Pi could not verify this exact history owner or native proof. Inspect the current operation again.") }
    }
    @inline(never)
    private static func mutatePiHistory(_ command: EngineCommand, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        switch command {
        case .piFreshSessionResolved(let threadID, _, let intent, let consumer, let inspection):
            guard let index = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  !snapshot.isConversationHistoryLocked(threadID: threadID) else { throw WorkspaceCommandError("The Pi conversation is no longer available for inspection.") }
            try decision.snapshot.threads[index].resolvePiFreshSession(intent: intent, consumerRunID: consumer, inspection: inspection, now: now)
        case .conversationHistoryPiCandidateObserved(let operationID, let candidate, let incarnation):
            let index = try decision.piHistoryOperationIndex(operationID: operationID, incarnation: incarnation)
            var operation = decision.snapshot.conversationHistoryOperations![index]
            if operation.piCandidates?.last == candidate { return decision }
            try operation.review.pi!.validateCandidate(candidate, previous: operation.piCandidates ?? [])
            try decision.snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
            if let path = candidate.nativeSessionFile {
                guard !snapshot.threads.contains(where: { snapshot.hasPiHistoryCapture($0, nativeSessionFile: path) }),
                      !(snapshot.conversationHistoryOperations ?? []).contains(where: { prior in
                          prior.id != operationID && (prior.piCandidates ?? []).contains(where: { $0.nativeSessionFile.map { PiHistoryScope.sameFile($0, path) } == true })
                      }) else { throw WorkspaceCommandError("The Pi candidate is already owned by another conversation.") }
            }
            operation.piCandidates = (operation.piCandidates ?? []) + [candidate]; operation.updatedAt = now
            try operation.validate(); decision.snapshot.conversationHistoryOperations![index] = operation
        case .conversationHistoryPiControlsOpened(let operationID, let sessionID, let incarnation):
            let index = try decision.piHistoryOperationIndex(operationID: operationID, incarnation: incarnation)
            guard decision.snapshot.conversationHistoryOperations![index].piControls == nil else { throw WorkspaceCommandError("The Pi history action already owns another control worker.") }
            decision.snapshot.conversationHistoryOperations![index].piControls = .init(sessionID: sessionID)
        case .conversationHistoryPiControlEvent(let operationID, let sessionID, let event, let incarnation):
            guard let index = try? decision.piHistoryOperationIndex(operationID: operationID, incarnation: incarnation),
                  var controls = decision.snapshot.conversationHistoryOperations![index].piControls, controls.sessionID == sessionID else { return decision }
            switch event {
            case .sessionApproval(let request):
                _ = try PiExtensionRequest.presentation(request)
                if let old = controls.requests.first(where: { $0.id == request.id }) {
                    guard old.request == request else { throw WorkspaceCommandError("Pi reused a lifecycle request identity with different content.") }
                } else { controls.requests.append(.init(request: request, sessionScoped: true)) }
            case .sessionApprovalDismissed(let id): controls.requests.removeAll { $0.id == id }
            default: return decision
            }
            try controls.validate(); decision.snapshot.conversationHistoryOperations![index].piControls = controls
        case .conversationHistoryPiControlResponding(let operationID, let sessionID, let requestID, let response, let incarnation):
            let index = try decision.piHistoryOperationIndex(operationID: operationID, incarnation: incarnation)
            guard var controls = decision.snapshot.conversationHistoryOperations![index].piControls, controls.sessionID == sessionID,
                  let requestIndex = controls.requests.firstIndex(where: { $0.id == requestID }), !controls.requests[requestIndex].responding else {
                throw WorkspaceCommandError("This Pi lifecycle request belongs to an expired worker or was already answered.")
            }
            try validatePiHistoryResponse(response, request: controls.requests[requestIndex].request)
            controls.requests[requestIndex].responding = true
            decision.snapshot.conversationHistoryOperations![index].piControls = controls
        case .conversationHistoryPiControlsClosed(let operationID, let sessionID, let incarnation):
            guard let index = decision.snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
                  decision.snapshot.conversationHistoryOperations![index].review.sourceIncarnation == incarnation,
                  decision.snapshot.conversationHistoryOperations![index].piControls?.sessionID == sessionID else { return decision }
            decision.snapshot.conversationHistoryOperations![index].piControls = nil
        case .conversationHistoryPiCancelled(let operationID, let incarnation):
            guard let index = decision.snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
                  var operation = decision.snapshot.conversationHistoryOperations?[index], operation.review.pi != nil,
                  operation.review.sourceIncarnation == incarnation, operation.isPending else { return decision }
            operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? ConversationHistoryOperation.failureMessage : ConversationHistoryOperation.unconfirmedMessage
            operation.piControls = nil; operation.updatedAt = now
            decision.snapshot.conversationHistoryOperations![index] = operation
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }
    private func piHistoryOperationIndex(operationID: UUID, incarnation: UUID) throws -> Int {
        guard let index = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[index], operation.phase == .dispatching,
              operation.review.pi != nil, operation.review.sourceIncarnation == incarnation else {
            throw WorkspaceCommandError("The Pi history worker no longer owns this operation.")
        }
        return index
    }
    static func validatePiHistoryResponse(_ response: ProviderApprovalResponse, request: ApprovalRequest) throws {
        let input = try PiExtensionRequest.presentation(request)
        switch response {
        case .decision(let allow):
            guard !allow || input.method == .confirm else { throw WorkspaceCommandError("Answer the Pi request or cancel it.") }
        case .option(let option):
            guard input.method == .select, input.options.contains(option) else { throw WorkspaceCommandError("Choose one offered Pi option.") }
        case .answers(let answers):
            guard input.method == .input || input.method == .editor, Set(answers.keys) == ["value"], let value = answers["value"],
                  value.utf8.count <= 1_048_576, !value.contains("\0") else { throw WorkspaceCommandError("Provide a valid Pi input value.") }
        default: throw WorkspaceCommandError("This Pi lifecycle request does not accept that answer type.")
        }
    }
}
