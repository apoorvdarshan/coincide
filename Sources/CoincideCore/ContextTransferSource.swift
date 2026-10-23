import Foundation

extension WorkspaceSnapshot {
    public func contextTransferSource(threadID: UUID, point: ContextTransferSourcePoint) throws -> ContextTransferResolvedPoint {
        guard let thread = threads.first(where: { $0.id == threadID }) else { throw ContextTransferError.invalidSource }
        let records = thread.activeHistoryRuns
        let run: ThreadRunRecord
        switch point {
        case .latestStable:
            guard let found = records.last(where: { $0.status == .completed && $0.checkpoints?.postRun?.phase == .ready && $0.checkpoints?.postRun?.receipt != nil }) else { throw ContextTransferError.invalidSource }
            run = found
        case .run(let id):
            guard let found = records.first(where: { $0.id == id }), found.status.isTerminal,
                  found.status != .unknown, found.messageAttributionVersion != nil else { throw ContextTransferError.invalidSource }
            run = found
        case .checkpoint(let id, let attemptID, let digest):
            guard let found = records.first(where: { $0.id == id }), found.status.isTerminal,
                  let after = found.checkpoints?.postRun, after.id == attemptID, after.phase == .ready,
                  after.receipt != nil, try ContextTransferProtocol.digest(after) == digest else { throw ContextTransferError.invalidSource }
            run = found
        }
        let ready = run.checkpoints?.postRun.flatMap { $0.phase == .ready && $0.receipt != nil ? $0 : nil }
        return .init(threadID: threadID, runID: run.id, checkpointAttemptID: ready?.id,
                     checkpointDigest: try ready.map { try ContextTransferProtocol.digest($0) })
    }
    func contextTransferFingerprint(_ thread: CodingThread, point: ContextTransferResolvedPoint) throws -> String {
        struct State: Encodable { let configuration: ProviderConfiguration; let runs: [ThreadRunRecord]; let messages: [ChatMessage]; let lineage: ContextTransferLineage? }
        guard let end = thread.activeHistoryRuns.firstIndex(where: { $0.id == point.runID }) else { throw ContextTransferError.invalidSource }
        let runs = Array(thread.activeHistoryRuns.prefix(end + 1)), ids = Set(runs.map(\.id))
        return try ContextTransferProtocol.digest(State(configuration: .init(thread: thread), runs: runs,
            messages: thread.messages.filter { $0.removedByHistoryOperationID == nil && $0.runReference.map { $0.threadID == thread.id && ids.contains($0.runID) } == true }, lineage: thread.contextTransferLineage))
    }
    func contextTransferMessages(thread: CodingThread, through point: ContextTransferResolvedPoint, ownRunsOnly: Bool) throws -> [ContextHandoffMessage] {
        let records = thread.activeHistoryRuns
        guard let index = records.firstIndex(where: { $0.id == point.runID }) else { throw ContextTransferError.invalidSource }
        let included = Set(records.prefix(index + 1).map(\.id))
        var result: [ContextHandoffMessage] = []
        if !ownRunsOnly, let lineage = thread.contextTransferLineage,
           let inherited = contextTransfer(lineage.transferID) { result = inherited.review.messages }
        for message in thread.messages where message.removedByHistoryOperationID == nil {
            guard let attribution = message.runReference, attribution.threadID == thread.id,
                  included.contains(attribution.runID) else { continue }
            guard message.role != .reasoning, let semantic = Self.publicContextMessage(message) else { continue }
            // Source archives carry text outcomes, never replay attachments,
            // commands, tool requests, or native reasoning as executable input.
            let itemID = try ContextTransferProtocol.digest([thread.id.uuidString, attribution.runID.uuidString, message.id])
            result.append(.init(id: "message:" + itemID, runID: attribution.runID,
                role: message.role.rawValue, kind: semantic.kind, text: semantic.text))
            for attachment in message.attachments ?? [] {
                result.append(.init(id: thread.id.uuidString + ":attachment:" + attachment.id.uuidString, runID: attribution.runID,
                    role: "system", kind: "attachmentMetadata", text: "Attachment \(attachment.name) (\(attachment.mimeType), \(attachment.byteCount) bytes, SHA-256 \(attachment.digest)). File bytes are not replayed by context transfer."))
            }
        }
        for run in records.prefix(index + 1) {
            if let delivery = run.contextDelivery, delivery.status == .delivered {
                let inheritedIDs = Set(thread.contextTransferLineage.flatMap { contextTransfer($0.transferID) }?.review.messages.map(\.id) ?? [])
                result.append(contentsOf: delivery.selection.messages.filter { !ownRunsOnly || !inheritedIDs.contains($0.id) })
            }
            let checkpoint = run.checkpoints?.postRun.map { " After-run checkpoint: \($0.phase.rawValue)." } ?? ""
            result.append(.init(id: "run-outcome:" + run.id.uuidString, runID: run.id, role: "system", kind: "runOutcome",
                text: "Run \(run.id.uuidString): \(run.status.rawValue); provider \(run.configuration.provider.name)." + checkpoint + (run.endReason.map { " Outcome: \($0.rawValue)." } ?? "")))
            if let context = run.contextDelivery {
                result.append(.init(id: "prior-context:" + context.id.uuidString, runID: run.id, role: "system", kind: "priorHandoff",
                    text: "Prior context delivery \(context.status.rawValue). " + context.selection.coverage))
            }
        }
        var unique = Set<Data>(); result = result.filter { unique.insert(Data($0.id.utf8)).inserted }
        guard !result.isEmpty, try ContextTransferProtocol.payload(result).count <= ContextTransferProtocol.maximumArchiveBytes else { throw ContextTransferError.limit }
        return result
    }
    private static func publicContextMessage(_ message: ChatMessage) -> (kind: String, text: String)? {
        guard let entity = message.providerEntity else { return (message.role == .tool ? "toolOutcome" : message.role.rawValue, message.text) }
        func content(_ value: JSONValue) -> String? {
            if value["type"].string == "text" { return value["text"].string }
            if value["type"].string == "resource" { return value["resource"]["text"].string }
            return nil
        }
        switch entity.key.type {
        case "user_message", "agent_message": return (entity.key.type, (entity.fields["content"].array ?? []).compactMap(content).joined(separator: "\n"))
        case "tool_call":
            let header = [entity.fields["title"].string ?? "Tool", entity.fields["status"].string].compactMap { $0 }.joined(separator: " · ")
            let publicContent = (entity.fields["content"].array ?? []).compactMap { item -> String? in
                if item["type"].string == "content" { return content(item["content"]) }
                if item["type"].string == "diff" { return item["patch"]["text"].string }
                return nil
            }
            return ("toolOutcome", ([header] + publicContent).joined(separator: "\n"))
        case "terminal":
            let output = entity.fields["output"]["data"].string ?? ""
            guard output.utf8.count <= ContextTransferProtocol.maximumArchiveBytes else { return nil }
            let bytes = Data(base64Encoded: output) ?? Data()
            return ("commandOutcome", [entity.fields["command"].string ?? "Command", String(decoding: bytes, as: UTF8.self)].joined(separator: "\n"))
        case "plan": return ("plan", (entity.fields["entries"].array ?? []).compactMap { $0["content"].string }.joined(separator: "\n"))
        case "compaction": return ("compaction", (entity.fields["summary"].array ?? []).compactMap(content).joined(separator: "\n"))
        default: return nil // Approval/session/configuration/private provider data is not context.
        }
    }
    func validateContextTransferReview(_ review: ContextTransferReview) throws {
        guard let source = threads.first(where: { $0.id == review.request.sourceThreadID }),
              !source.isArchived,
              workspaceReady(for: source), !isConversationHistoryLocked(threadID: source.id),
              ContextTransferProtocol.same(ProviderConfiguration(thread: source), review.request.expectedConfiguration),
              try contextTransferSource(threadID: source.id, point: review.sourcePoint.checkpointAttemptID.map { .checkpoint(runID: review.sourcePoint.runID, attemptID: $0, digest: review.sourcePoint.checkpointDigest ?? "") } ?? .run(review.sourcePoint.runID)) == review.sourcePoint,
              try contextTransferFingerprint(source, point: review.sourcePoint) == review.sourceFingerprint,
              !((contextTransfers ?? []).contains { $0.id == review.id }),
              review.targetConfiguration.nativeThreadID == review.targetProviderBinding?.configuration.nativeThreadID,
              review.targetConfiguration.claudeLaunchSelection == nil, review.targetConfiguration.piFreshSessionIntent == nil else { throw ContextTransferError.staleReview }
        try CodexReasoningValidation.configuration(review.targetConfiguration)
        try review.targetConfiguration.validateClaudeConfiguration()
        try ProviderHistoryValidation.path(review.targetConfiguration.workspacePath)
        switch review.request.intent {
        case .fork:
            guard !threads.contains(where: { $0.id == review.targetThreadID }), source.projectID == review.projectID else { throw ContextTransferError.staleReview }
        case .providerHandoff:
            guard !source.isBusy, source.queuedTurns.isEmpty, source.runtimeRequests.isEmpty,
                  !hasUnresolvedContextDelivery(threadID: source.id),
                  review.targetThreadID == source.id, review.targetConfiguration.workspacePath.utf8.elementsEqual(source.workspacePath.utf8) else { throw ContextTransferError.staleReview }
            let pending = pendingContextTransfers(threadID: source.id).map { ContextTransferPendingReference(id: $0.id, digest: $0.review.digest) }
            guard ContextTransferProtocol.same(pending, review.pendingSourceTransfers ?? []) else { throw ContextTransferError.staleReview }
            if let binding = review.targetProviderBinding {
                guard (source.contextProviderBindings ?? []).contains(where: { ContextTransferProtocol.same($0, binding) }),
                      Self.sameContextProvider(binding.configuration, review.targetConfiguration) else { throw ContextTransferError.staleReview }
            }
        case .mergeBack(let expected):
            guard let lineage = source.contextTransferLineage, lineage.parentThreadID == review.targetThreadID,
                  lineage.basePoint == review.basePoint,
                  let target = threads.first(where: { $0.id == review.targetThreadID && $0.projectID == review.projectID }),
                  !target.isArchived,
                  !hasUnresolvedContextDelivery(threadID: target.id),
                  workspaceReady(for: target), !isConversationHistoryLocked(threadID: target.id),
                  ContextTransferProtocol.same(ProviderConfiguration(thread: target), expected) else { throw ContextTransferError.staleReview }
        }
    }
    func contextTransfer(_ id: UUID) -> ContextTransfer? { contextTransfers?.first { $0.id == id } }
    public func pendingContextTransfers(threadID: UUID) -> [ContextTransfer] {
        (contextTransfers ?? []).filter { $0.targetThreadID == threadID && $0.status == .pending }
    }
    public func hasUnresolvedContextDelivery(threadID: UUID) -> Bool {
        (contextTransfers ?? []).contains { $0.targetThreadID == threadID && $0.status == .uncertain && $0.abandonedAt == nil }
    }
    func hasVerifiedContextClaudeFork(thread: CodingThread, inherited: ClaudeInheritedHead) throws -> Bool {
        guard let lineage = thread.contextTransferLineage,
              let transfer = contextTransfer(lineage.transferID), transfer.review.kind == .fork,
              transfer.review.strategy == .nativeFork, transfer.targetThreadID == thread.id,
              transfer.review.projectID == thread.projectID,
              transfer.review.sourcePoint == lineage.basePoint,
              transfer.sourceThreadID == lineage.parentThreadID,
              let review = transfer.review.nativeReview, review.kind == .forkAfterRun,
              review.id == transfer.id, review.targetThreadID == thread.id, review.claude != nil,
              review.sourceThreadID == transfer.sourceThreadID, review.runID == transfer.review.sourcePoint.runID,
              let delivery = transfer.delivery, delivery.runID == transfer.targetRunID,
              delivery.transferIDs == [transfer.id], let result = delivery.nativeResult,
              result.claude?.inheritedHead == inherited,
              result.claude?.publication == delivery.claudePublication,
              result.reference.nativeThreadID == thread.providerThreadID,
              let record = thread.runHistory?.first(where: { $0.id == delivery.runID }),
              record.contextTransferIDs == [transfer.id], record.contextDelivery?.nativeResult == result,
              record.configuration.claudeRuntimeConfiguration == transfer.review.targetConfiguration.claudeRuntimeConfiguration else { return false }
        try review.validateResult(result)
        return true
    }
    static func sameContextProvider(_ lhs: ProviderConfiguration, _ rhs: ProviderConfiguration) -> Bool {
        func identity(_ value: ProviderConfiguration) -> ProviderConfiguration {
            var value = value; value.nativeThreadID = nil; value.model = ""; value.reasoningEffort = nil; value.permission = .supervised
            value.claudeLaunchSelection = nil; value.piFreshSessionIntent = nil
            value.openCodeConfiguration = value.openCodeConfiguration?.selecting(model: nil)
            value.piConfiguration = value.piConfiguration?.selecting(model: nil, thinkingLevel: nil)
            value.museConfiguration = value.museConfiguration?.selecting(model: nil, reasoningEffort: nil)
            return value
        }
        return ContextTransferProtocol.same(identity(lhs), identity(rhs))
    }
    func contextProviderBinding(for thread: CodingThread, now: Date) throws -> ContextTransferProviderBinding? {
        let configuration = ProviderConfiguration(thread: thread)
        guard configuration.nativeThreadID != nil else { return nil }
        let runs = Set(thread.activeHistoryRuns.filter { $0.providerThreadID == configuration.nativeThreadID && Self.sameContextProvider($0.configuration, configuration) }.map(\.id))
        var known = Set<String>()
        for message in thread.messages where message.removedByHistoryOperationID == nil {
            guard let reference = message.runReference, reference.threadID == thread.id, runs.contains(reference.runID) else { continue }
            known.insert("message:" + (try ContextTransferProtocol.digest([thread.id.uuidString, reference.runID.uuidString, message.id])))
            for attachment in message.attachments ?? [] { known.insert(thread.id.uuidString + ":attachment:" + attachment.id.uuidString) }
        }
        for record in thread.activeHistoryRuns where runs.contains(record.id) {
            known.insert("run-outcome:" + record.id.uuidString)
            if let delivery = record.contextDelivery, delivery.status == .delivered {
                known.formUnion(delivery.selection.includedIDs)
                known.insert("prior-context:" + delivery.id.uuidString)
                for id in delivery.transferIDs {
                    if let transfer = contextTransfer(id), transfer.review.strategy == .nativeFork { known.formUnion(transfer.review.messages.map(\.id)) }
                }
            }
        }
        if let old = thread.contextProviderBindings?.first(where: { Self.sameContextProvider($0.configuration, configuration) && $0.configuration.nativeThreadID == configuration.nativeThreadID }) { known.formUnion(old.knownItemIDs) }
        return .init(configuration: configuration, knownItemIDs: known.sorted(), updatedAt: now)
    }
    func contextSelection(for delivery: ContextTransferDelivery, retrievalAvailable: Bool) throws -> ContextHandoffSelection {
        let eligible = Set((delivery.eligibleItemIDs ?? (delivery.selection.includedIDs + delivery.selection.omittedIDs)).map { Data($0.utf8) })
        var seen = Set<Data>(), nativeFork = false
        var messages = try delivery.transferIDs.flatMap { id -> [ContextHandoffMessage] in
            guard let transfer = contextTransfer(id), transfer.targetRunID == delivery.runID,
                  transfer.delivery?.id == delivery.id else { throw ContextTransferError.staleReview }
            nativeFork = nativeFork || transfer.review.strategy == .nativeFork
            return transfer.review.messages
        }.filter { eligible.contains(Data($0.id.utf8)) && seen.insert(Data($0.id.utf8)).inserted }
        guard seen == eligible else { throw ContextTransferError.staleReview }
        if let targetID = delivery.transferIDs.first.flatMap({ contextTransfer($0)?.targetThreadID }),
           let thread = threads.first(where: { $0.id == targetID }),
           let configuration = thread.activeRun?.id == delivery.runID ? thread.activeRun?.configuration : thread.runHistory?.first(where: { $0.id == delivery.runID })?.configuration,
           let nativeID = configuration.nativeThreadID {
            let known = Set((contextTransfers ?? []).filter {
                $0.targetThreadID == targetID && $0.delivery?.status == .delivered && $0.delivery?.nativeThreadID == nativeID &&
                Self.sameContextProvider($0.review.targetConfiguration, configuration)
            }.flatMap { transfer in transfer.review.strategy == .nativeFork ? transfer.review.messages.map(\.id) : (transfer.delivery?.selection.includedIDs ?? []) }.map { Data($0.utf8) })
            messages.removeAll { known.contains(Data($0.id.utf8)) }
        }
        let source = delivery.selection.source
        let coverage = ContextHandoffCoverage(transferID: source.transferID, sourceThreadID: source.sourceThreadID,
            sourceRunID: source.sourceRunID, sourceMessageID: source.sourceMessageID, strategy: source.strategy,
            retrievalAvailable: retrievalAvailable, additionalOmittedIDs: source.additionalOmittedIDs, additionalTransferIDs: source.additionalTransferIDs)
        let budget = try ContextHandoffBudget.available(userText: delivery.authoredText ?? "", attachments: delivery.authoredAttachments ?? [])
        return try ContextHandoffService.select(messages: nativeFork ? [] : messages, coverage: coverage,
            budget: nativeFork ? ContextHandoffBudget.defaultTokenCap : budget)
    }
    func validateContextTransfers() throws {
        let transfers = contextTransfers ?? []
        guard transfers.count <= ContextTransferProtocol.maximumStoredTransfers,
              Set(transfers.map(\.id)).count == transfers.count, Set(transfers.map(\.commandID)).count == transfers.count else { throw ContextTransferError.invalidSource }
        var archiveBytes = 0
        for transfer in transfers {
            let review = transfer.review
            guard transfer.id == review.id, review.digest.count == 64, review.sourceFingerprint.count == 64,
                  review.reviewedAt.timeIntervalSince1970.isFinite, transfer.updatedAt.timeIntervalSince1970.isFinite,
                  review.messages.count <= 100_000,
                  Set(review.messages.map { Data($0.id.utf8) }).count == review.messages.count,
                  try ContextTransferProtocol.payload(review.messages).count <= ContextTransferProtocol.maximumArchiveBytes,
                  review.messages.allSatisfy({ !$0.id.isEmpty && ["user", "assistant", "tool", "system"].contains($0.role) }) else { throw ContextTransferError.invalidSource }
            archiveBytes += try ContextTransferProtocol.payload(review).count
            guard archiveBytes <= ContextTransferProtocol.maximumStoredArchiveBytes else { throw ContextTransferError.limit }
            if let delivery = transfer.delivery {
                try ContextHandoffService.validate(delivery.selection)
                guard transfer.targetRunID == delivery.runID, delivery.transferIDs.contains(transfer.id),
                      delivery.transferIDs.count <= 32, Set(delivery.transferIDs).count == delivery.transferIDs.count,
                      delivery.selection.renderedText.utf8.count <= ContextHandoffBudget.maximumBytes,
                      delivery.selection.cost <= ContextHandoffBudget.maximumBytes else { throw ContextTransferError.invalidSource }
            }
        }
        for thread in threads {
            guard (thread.contextProviderBindings ?? []).count <= 32 else { throw ContextTransferError.limit }
            for binding in thread.contextProviderBindings ?? [] {
                guard binding.configuration.nativeThreadID != nil, binding.updatedAt.timeIntervalSince1970.isFinite,
                      binding.knownItemIDs.count <= 100_000, Set(binding.knownItemIDs).count == binding.knownItemIDs.count,
                      binding.knownItemIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }) else { throw ContextTransferError.invalidSource }
            }
            if let lineage = thread.contextTransferLineage {
                guard lineage.parentThreadID != thread.id, lineage.rootThreadID != thread.id,
                      let transfer = transfers.first(where: { $0.id == lineage.transferID }), transfer.targetThreadID == thread.id,
                      transfer.sourceThreadID == lineage.parentThreadID, transfer.review.sourcePoint == lineage.basePoint else { throw ContextTransferError.invalidSource }
            }
            for delivery in thread.queuedTurns.compactMap(\.contextDelivery) + [thread.activeRun?.contextDelivery].compactMap({ $0 }) {
                guard delivery.transferIDs.allSatisfy({ id in transfers.contains { $0.id == id && $0.targetThreadID == thread.id && $0.targetRunID == delivery.runID } }) else { throw ContextTransferError.invalidSource }
            }
        }
    }
}

extension CodingThread {
    mutating func applyContextConfiguration(_ configuration: ProviderConfiguration) {
        provider = configuration.provider; workspacePath = configuration.workspacePath; providerThreadID = configuration.nativeThreadID
        model = configuration.model; reasoningEffort = configuration.reasoningEffort; permission = configuration.permission
        acpAgent = configuration.acpAgent; openCodeConfiguration = configuration.openCodeConfiguration; piConfiguration = configuration.piConfiguration
        museConfiguration = configuration.museConfiguration; antigravityConfiguration = configuration.antigravityConfiguration
        codexRuntimeConfiguration = configuration.codexRuntimeConfiguration; claudeRuntimeConfiguration = configuration.claudeRuntimeConfiguration
        agentModeID = configuration.agentModeID; agentConfigValues = configuration.agentConfigValues; agentConfiguration = configuration.agentConfiguration
        claudeResumeSelection = nil; claudeResumeConsumerRunID = nil; claudeInheritedHead = nil
        piFreshSessionIntent = nil; piFreshConsumerRunID = nil
        runtimeID = nil; runtimeRequests = []; providerActivity = nil
    }
}
