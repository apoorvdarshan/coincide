import Foundation

extension WorkspaceDecision {
    static func reduceContextTransfer(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> WorkspaceDecision {
        var result = WorkspaceDecision(snapshot: snapshot)
        switch command {
        case .client(.abandonContextTransfer(let threadID, let deliveryID, let ids)):
            guard let index = result.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  !result.snapshot.threads[index].isBusy, Set(ids).count == ids.count, !ids.isEmpty else { throw ContextTransferError.unavailable }
            let uncertain = (snapshot.contextTransfers ?? []).filter { $0.targetThreadID == threadID && $0.delivery?.id == deliveryID && $0.status == .uncertain && $0.abandonedAt == nil }
            guard Set(uncertain.map(\.id)) == Set(ids), let delivery = uncertain.first?.delivery,
                  Set(delivery.transferIDs) == Set(ids) else { throw ContextTransferError.staleReview }
            for i in result.snapshot.contextTransfers!.indices where ids.contains(result.snapshot.contextTransfers![i].id) { result.snapshot.contextTransfers![i].abandonedAt = now }
            let affectedProfiles = uncertain.map { $0.review.targetConfiguration }
            let retiredIDs = Set(uncertain.compactMap { $0.review.targetConfiguration.nativeThreadID } +
                [delivery.nativeThreadID, delivery.nativeResult?.reference.nativeThreadID, result.snapshot.threads[index].providerThreadID].compactMap { $0 })
            result.snapshot.threads[index].contextProviderBindings?.removeAll { binding in
                binding.configuration.nativeThreadID.map { retiredIDs.contains($0) } == true &&
                affectedProfiles.contains { WorkspaceSnapshot.sameContextProvider($0, binding.configuration) }
            }
            result.snapshot.threads[index].providerThreadID = nil
            result.snapshot.threads[index].claudeResumeSelection = nil; result.snapshot.threads[index].claudeResumeConsumerRunID = nil; result.snapshot.threads[index].claudeInheritedHead = nil
            result.snapshot.threads[index].queuedTurns.removeAll { $0.id == delivery.runID }
            result.snapshot.threads[index].queuePaused = true; result.closeRuntimes.insert(threadID)
        case .contextTransferAccepted(let review, let title, let scratchAllocation):
            try snapshot.validateContextTransferReview(review)
            guard (snapshot.contextTransfers ?? []).count < ContextTransferProtocol.maximumStoredTransfers else { throw ContextTransferError.limit }
            let used = try (snapshot.contextTransfers ?? []).reduce(0) { try $0 + ContextTransferProtocol.payload($1.review).count }
            guard try ContextTransferProtocol.payload(review).count <= ContextTransferProtocol.maximumStoredArchiveBytes - used else { throw ContextTransferError.limit }
            guard let source = snapshot.threads.first(where: { $0.id == review.request.sourceThreadID }),
                  let project = snapshot.projects.first(where: { $0.id == review.projectID }) else { throw ContextTransferError.staleReview }
            if result.snapshot.contextTransfers == nil { result.snapshot.contextTransfers = [] }
            for index in result.snapshot.contextTransfers!.indices {
                let old = result.snapshot.contextTransfers![index]
                if old.targetThreadID == review.targetThreadID && old.status == .pending && ((review.kind == .providerHandoff && review.pendingSourceTransfers?.contains(where: { $0.id == old.id && $0.digest == old.review.digest }) == true) || (review.kind != .providerHandoff && old.sourceThreadID == source.id && old.review.kind == review.kind)) {
                    result.snapshot.contextTransfers![index].status = .superseded
                    result.snapshot.contextTransfers![index].updatedAt = now
                }
            }
            if review.kind != .fork, scratchAllocation != nil { throw ScratchWorkspaceError() }
            switch review.request.intent {
            case .fork:
                var thread = CodingThread(project: project, model: review.targetConfiguration.model)
                thread.id = review.targetThreadID; thread.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? review.title
                guard thread.title.utf8.count <= 4_096, !thread.title.contains("\0") else { throw ContextTransferError.invalidSource }
                thread.applyContextConfiguration(review.targetConfiguration); thread.checkpointPolicy = source.checkpointPolicy
                if project.scratch != nil {
                    guard let allocation = scratchAllocation, allocation.receipt.commandID == id,
                          allocation.threadID == thread.id, allocation.project.scratch == project.scratch,
                          allocation.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8) else { throw ScratchWorkspaceError() }
                    thread.scratchWorkspace = allocation.receipt; thread.createdAt = allocation.receipt.createdAt
                } else if scratchAllocation != nil { throw ScratchWorkspaceError() }
                thread.contextTransferLineage = .init(parentThreadID: source.id,
                    rootThreadID: source.contextTransferLineage?.rootThreadID ?? source.id, transferID: review.id, basePoint: review.sourcePoint)
                result.snapshot.threads.insert(thread, at: 0)
            case .providerHandoff:
                guard let index = result.snapshot.threads.firstIndex(where: { $0.id == source.id }) else { throw ContextTransferError.staleReview }
                if let old = try snapshot.contextProviderBinding(for: source, now: now) {
                    var bindings = source.contextProviderBindings ?? []
                    bindings.removeAll { WorkspaceSnapshot.sameContextProvider($0.configuration, old.configuration) }
                    guard bindings.count < 32 else { throw ContextTransferError.limit }
                    bindings.append(old); result.snapshot.threads[index].contextProviderBindings = bindings
                }
                result.snapshot.threads[index].applyContextConfiguration(review.targetConfiguration)
                result.snapshot.threads[index].updatedAt = now; result.closeRuntimes.insert(source.id)
            case .mergeBack: break
            }
            result.snapshot.contextTransfers!.append(.init(id: review.id, commandID: id, review: review, status: .pending, updatedAt: now))
        case .contextTransferDispatching(let threadID, let runID, let deliveryID, let runtimeID):
            guard result.snapshot.threads.first(where: { $0.id == threadID })?.runtimeID == runtimeID,
                  result.snapshot.threads.first(where: { $0.id == threadID })?.activeRun?.stopRequested == false else { throw ContextTransferError.staleReview }
            try result.updateContextDelivery(threadID: threadID, runID: runID, deliveryID: deliveryID) { delivery in
                guard delivery.status == .reserved else { throw ContextTransferError.uncertain }
                delivery.status = .dispatching; delivery.runtimeID = runtimeID
            }
        case .contextTransferSelectionPrepared(let threadID, let runID, let deliveryID, let selection):
            guard let delivery = snapshot.threads.first(where: { $0.id == threadID })?.activeRun?.contextDelivery,
                  ContextTransferProtocol.same(try snapshot.contextSelection(for: delivery, retrievalAvailable: selection.source.retrievalAvailable), selection) else { throw ContextTransferError.staleReview }
            try result.updateContextDelivery(threadID: threadID, runID: runID, deliveryID: deliveryID) { saved in
                guard saved.status == .reserved else { throw ContextTransferError.uncertain }
                saved.selection = selection
            }
        case .contextTransferDeferred(let threadID, let runID, let deliveryID):
            guard let index = result.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  result.snapshot.threads[index].activeRun?.id == runID,
                  let delivery = result.snapshot.threads[index].activeRun?.contextDelivery,
                  delivery.id == deliveryID, delivery.status == .reserved else { throw ContextTransferError.staleReview }
            for i in result.snapshot.contextTransfers!.indices where delivery.transferIDs.contains(result.snapshot.contextTransfers![i].id) {
                guard result.snapshot.contextTransfers![i].delivery?.id == deliveryID,
                      result.snapshot.contextTransfers![i].delivery?.status == .reserved else { throw ContextTransferError.staleReview }
                result.snapshot.contextTransfers![i].status = .pending; result.snapshot.contextTransfers![i].targetRunID = nil; result.snapshot.contextTransfers![i].delivery = nil
            }
            result.snapshot.threads[index].activeRun?.contextTransferIDs = nil; result.snapshot.threads[index].activeRun?.contextDelivery = nil
            if let record = result.snapshot.threads[index].runHistory?.firstIndex(where: { $0.id == runID }) {
                result.snapshot.threads[index].runHistory?[record].contextTransferIDs = nil; result.snapshot.threads[index].runHistory?[record].contextDelivery = nil
            }
        case .contextTransferNativeReserved(let threadID, let runID, let deliveryID, let publication):
            guard result.snapshot.threads.first(where: { $0.id == threadID })?.activeRun?.stopRequested == false else { throw ContextTransferError.staleReview }
            try result.updateContextDelivery(threadID: threadID, runID: runID, deliveryID: deliveryID) { delivery in
                guard delivery.status == .dispatching, delivery.claudePublication == nil else { throw ContextTransferError.uncertain }
                delivery.claudePublication = publication
            }
        case .contextTransferNativeReady(let threadID, let runID, let deliveryID, let native):
            try result.updateContextDelivery(threadID: threadID, runID: runID, deliveryID: deliveryID) { delivery in
                guard delivery.status == .dispatching, delivery.nativeResult == nil else { throw ContextTransferError.uncertain }
                delivery.nativeResult = native; delivery.nativeThreadID = native.reference.nativeThreadID
            }
            guard let index = result.snapshot.threads.firstIndex(where: { $0.id == threadID }) else { throw ContextTransferError.staleReview }
            // A completed fork result remains evidence even if Stop won while
            // the native operation awaited I/O. It must not trigger input.
            guard result.snapshot.threads[index].activeRun?.id == runID,
                  result.snapshot.threads[index].activeRun?.stopRequested == false else { break }
            result.snapshot.threads[index].providerThreadID = native.reference.nativeThreadID
            result.snapshot.threads[index].activeRun?.configuration.nativeThreadID = native.reference.nativeThreadID
            if let record = result.snapshot.threads[index].runHistory?.firstIndex(where: { $0.id == runID }) {
                result.snapshot.threads[index].runHistory?[record].providerThreadID = native.reference.nativeThreadID
                result.snapshot.threads[index].runHistory?[record].configuration.nativeThreadID = native.reference.nativeThreadID
            }
            if let claude = native.claude {
                result.snapshot.threads[index].claudeResumeSelection = claude.selection
                result.snapshot.threads[index].claudeInheritedHead = claude.inheritedHead
            }
        case .contextTransferRuntimeRebound(let threadID, let runID, let deliveryID, let previous, let current):
            guard result.snapshot.threads.first(where: { $0.id == threadID })?.runtimeID == current else { throw ContextTransferError.staleReview }
            try result.updateContextDelivery(threadID: threadID, runID: runID, deliveryID: deliveryID) { delivery in
                guard delivery.status == .dispatching, delivery.nativeResult != nil, delivery.runtimeID == previous else { throw ContextTransferError.uncertain }
                delivery.runtimeID = current
            }
        case .contextTransferDelivered(let threadID, let runID, let deliveryID):
            let nativeID = result.snapshot.threads.first(where: { $0.id == threadID })?.providerThreadID
            try result.updateContextDelivery(threadID: threadID, runID: runID, deliveryID: deliveryID) { delivery in
                guard delivery.status == .dispatching else { throw ContextTransferError.uncertain }
                delivery.status = .delivered; delivery.nativeThreadID = nativeID ?? delivery.nativeThreadID
            }
        case .contextTransferUncertain(let threadID, let runID, let deliveryID):
            try result.updateContextDelivery(threadID: threadID, runID: runID, deliveryID: deliveryID) { delivery in
                guard delivery.status != .delivered else { return }
                delivery.status = .uncertain; delivery.error = ContextTransferError.uncertain.localizedDescription
            }
        default: throw ContextTransferError.invalidSource
        }
        return result
    }

    mutating func captureContextTransfers(for queued: inout QueuedTurn, thread: CodingThread, now: Date) throws {
        guard !(snapshot.contextTransfers ?? []).contains(where: { $0.targetThreadID == thread.id && $0.status == .uncertain && $0.abandonedAt == nil }) else { throw ContextTransferError.uncertain }
        let pending = snapshot.pendingContextTransfers(threadID: thread.id)
        guard !pending.isEmpty else { return }
        guard pending.count <= 32, pending.allSatisfy({ transfer in
            var expected = transfer.review.targetConfiguration, actual = queued.configuration
            expected.model = actual.model; expected.reasoningEffort = actual.reasoningEffort; expected.permission = actual.permission
            // Model controls may change after a copy/handoff is staged. Keep
            // profile, workspace and unrelated agent settings bound exactly.
            do {
                let key: String?
                switch actual.provider {
                case .claude:
                    _ = try ClaudeModelControl.options(in: actual)
                    key = ClaudeModelControl.configurationKey
                case .codex:
                    _ = try CodexServiceTier.selected(in: actual)
                    guard actual.agentModeID == nil || actual.agentModeID == "default" || actual.agentModeID == "plan" else { return false }
                    expected.agentModeID = actual.agentModeID
                    key = CodexServiceTier.configurationKey
                }
                if let key {
                    var settings = expected.agentConfiguration ?? [:]
                    settings[key] = actual.agentConfiguration?[key]
                    expected.agentConfiguration = settings.isEmpty ? nil : settings
                }
            } catch { return false }
            // A merge adds material to the parent's existing provider context.
            if transfer.review.kind == .mergeBack { expected.nativeThreadID = nil; actual.nativeThreadID = nil }
            if transfer.review.strategy != .nativeFork { expected.nativeThreadID = nil; actual.nativeThreadID = nil }
            return ContextTransferProtocol.same(expected, actual)
        }) else { throw ContextTransferError.staleReview }
        let native = pending.filter { $0.review.strategy == .nativeFork }
        guard native.count <= 1, native.isEmpty || pending.count == 1 else { throw ContextTransferError.unavailable }
        let ids = pending.map(\.id), deliveryID = UUID()
        var seen = Set<Data>()
        let consumed = Set((snapshot.contextTransfers ?? []).filter {
            $0.targetThreadID == thread.id && $0.status == .consumed && $0.delivery?.status == .delivered && queued.configuration.nativeThreadID != nil &&
            WorkspaceSnapshot.sameContextProvider($0.review.targetConfiguration, queued.configuration) &&
            ($0.delivery?.nativeThreadID ?? $0.review.targetConfiguration.nativeThreadID) == queued.configuration.nativeThreadID
        }.flatMap { transfer -> [Data] in
            // Only delivered/owned item identities are omitted. Budget omissions
            // remain eligible for a later explicit delta and scoped retrieval.
            let included = Set(transfer.delivery?.selection.includedIDs ?? [])
            return transfer.review.messages.filter { transfer.review.strategy == .nativeFork || included.contains($0.id) }.map { Data((($0.runID?.uuidString ?? "") + ":" + $0.id).utf8) }
        })
        let messages = pending.flatMap { $0.review.messages }.filter { message in
            let identity = Data(((message.runID?.uuidString ?? "") + ":" + message.id).utf8)
            return !consumed.contains(identity) && seen.insert(identity).inserted
        }
        let coverage = ContextHandoffCoverage(transferID: ids[0], sourceThreadID: pending[0].sourceThreadID,
            sourceRunID: pending[0].review.sourcePoint.runID, strategy: pending.count == 1 ? pending[0].review.strategy.rawValue : "combined_context",
            retrievalAvailable: false, additionalTransferIDs: Array(ids.dropFirst()))
        let budget = try ContextHandoffBudget.available(userText: queued.text, attachments: queued.attachments ?? [])
        let selection = try ContextHandoffService.select(messages: native.isEmpty ? messages : [], coverage: coverage, budget: native.isEmpty ? budget : ContextHandoffBudget.defaultTokenCap)
        var delivery = ContextTransferDelivery(id: deliveryID, runID: queued.id, transferIDs: ids, selection: selection, status: .reserved)
        delivery.authoredText = queued.text; delivery.authoredAttachments = queued.attachments
        delivery.eligibleItemIDs = messages.map(\.id)
        queued.contextTransferIDs = ids; queued.contextDelivery = delivery
        for index in (snapshot.contextTransfers ?? []).indices where ids.contains(snapshot.contextTransfers![index].id) {
            snapshot.contextTransfers![index].targetRunID = queued.id; snapshot.contextTransfers![index].delivery = delivery
            snapshot.contextTransfers![index].status = snapshot.contextTransfers![index].review.strategy == .nativeFork ? .resolvedNative : .resolvedPortable
            snapshot.contextTransfers![index].updatedAt = now
        }
    }

    private mutating func updateContextDelivery(threadID: UUID, runID: UUID, deliveryID: UUID,
                                                body: (inout ContextTransferDelivery) throws -> Void) throws {
        guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }),
              var delivery = (snapshot.threads[index].activeRun?.id == runID ? snapshot.threads[index].activeRun?.contextDelivery : snapshot.threads[index].runHistory?.first(where: { $0.id == runID })?.contextDelivery),
              delivery.id == deliveryID else { throw ContextTransferError.staleReview }
        try body(&delivery)
        if snapshot.threads[index].activeRun?.id == runID { snapshot.threads[index].activeRun?.contextDelivery = delivery }
        if let record = snapshot.threads[index].runHistory?.firstIndex(where: { $0.id == runID }) { snapshot.threads[index].runHistory?[record].contextDelivery = delivery }
        for i in (snapshot.contextTransfers ?? []).indices where delivery.transferIDs.contains(snapshot.contextTransfers![i].id) {
            guard snapshot.contextTransfers![i].targetThreadID == threadID, snapshot.contextTransfers![i].targetRunID == runID else { throw ContextTransferError.staleReview }
            snapshot.contextTransfers![i].delivery = delivery
            if delivery.status == .delivered { snapshot.contextTransfers![i].status = .consumed }
            if delivery.status == .uncertain { snapshot.contextTransfers![i].status = .uncertain; snapshot.contextTransfers![i].error = delivery.error }
        }
    }
    mutating func releaseContextReservation(_ queued: QueuedTurn?) throws {
        guard let delivery = queued?.contextDelivery else { return }
        guard delivery.status == .reserved else { throw ContextTransferError.uncertain }
        for index in (snapshot.contextTransfers ?? []).indices where delivery.transferIDs.contains(snapshot.contextTransfers![index].id) {
            guard snapshot.contextTransfers![index].targetRunID == delivery.runID,
                  snapshot.contextTransfers![index].delivery?.id == delivery.id,
                  snapshot.contextTransfers![index].delivery?.status == .reserved else { throw ContextTransferError.staleReview }
            snapshot.contextTransfers![index].status = .pending
            snapshot.contextTransfers![index].delivery = nil; snapshot.contextTransfers![index].targetRunID = nil
        }
    }
    mutating func restoreUndispatchedContext(in thread: inout CodingThread) {
        guard let run = thread.activeRun, let delivery = run.contextDelivery, delivery.status == .reserved,
              delivery.transferIDs.allSatisfy({ id in snapshot.contextTransfer(id)?.delivery?.id == delivery.id && snapshot.contextTransfer(id)?.delivery?.status == .reserved }) else { return }
        for index in snapshot.contextTransfers!.indices where delivery.transferIDs.contains(snapshot.contextTransfers![index].id) {
            snapshot.contextTransfers![index].status = .pending; snapshot.contextTransfers![index].targetRunID = nil; snapshot.contextTransfers![index].delivery = nil
        }
        thread.activeRun?.contextTransferIDs = nil; thread.activeRun?.contextDelivery = nil
        if let record = thread.runHistory?.firstIndex(where: { $0.id == run.id }) { thread.runHistory?[record].contextTransferIDs = nil; thread.runHistory?[record].contextDelivery = nil }
    }
    func validateContextTransferCommand(_ command: WorkspaceCommand) throws {
        guard case .editThread(let id, let edit) = command else { return }
        let pending = snapshot.pendingContextTransfers(threadID: id).isEmpty == false
        let uncertain = snapshot.hasUnresolvedContextDelivery(threadID: id)
        guard pending || uncertain else { return }
        switch edit {
        case .title, .draft, .pinned, .archived: return
        case .model, .permission, .codexModel, .codexReasoning, .codexDefaultModel, .codexServiceTier, .codexInteractionMode, .claudeModel, .claudeModelOptions, .resetProviderModelOptions, .checkpointPolicy:
            guard !uncertain else { throw ContextTransferError.uncertain }
        default: throw WorkspaceCommandError("This conversation has saved context. Keep its provider and workspace until delivery, or explicitly choose fresh context after an uncertain delivery.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
