import Foundation

struct RemoteSteeringNativeRead: Sendable {
    private struct Payload: Sendable { let sequence: Int64; let thread: CodingThread; let project: WorkspaceProject; let incarnation: UUID; let availability: PromptSteeringAvailability; let operations: [PromptSteeringOperation] }
    private let storage: [Payload]
    var sequence: Int64 { storage[0].sequence }; var thread: CodingThread { storage[0].thread }; var project: WorkspaceProject { storage[0].project }
    var incarnation: UUID { storage[0].incarnation }; var availability: PromptSteeringAvailability { storage[0].availability }; var operations: [PromptSteeringOperation] { storage[0].operations }
    init(sequence: Int64, thread: CodingThread, project: WorkspaceProject, incarnation: UUID, availability: PromptSteeringAvailability, operations: [PromptSteeringOperation]) { storage = [.init(sequence: sequence, thread: thread, project: project, incarnation: incarnation, availability: availability, operations: operations)] }
}
extension RemoteEnvironmentAdmission {
    static func steeringCommands(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation, snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        guard case .promptSteering(let target, let action) = request.command, case .steering(let captured) = preparation,
              RemoteLifecycleProtocol.same(captured.target, target), RemoteLifecycleProtocol.same(captured.action, action) else { throw stale() }
        switch action {
        case .removeQueued(_, let id, let digest):
            guard let thread = snapshot.threads.first(where: { $0.id == target.threadID }),
                  let row = thread.queuedTurns.first(where: { $0.id == id }), try RemoteSteeringProtocol.digest(row) == digest else { throw stale() }
            return [.client(.removeQueued(threadID: target.threadID, queuedID: id))]
        case .moveQueued(_, let id, let beforeID, let revision):
            guard let order = captured.queueOrder, let thread = snapshot.threads.first(where: { $0.id == target.threadID }),
                  try RemoteSteeringProtocol.queueRevision(thread.queuedTurns) == revision else { throw stale() }
            return [.client(.moveQueued(threadID: target.threadID, queuedID: id, beforeID: beforeID, expectedOrder: order))]
        default: break
        }
        if let edit = captured.queuedEdit { return [.queuedInputReplaced(edit)] }
        if let operation = captured.operation {
            if case .steerComposer(_, let input) = action {
                guard let thread = snapshot.threads.first(where: { $0.id == target.threadID }),
                      RemoteComposerSubmission.textDigest(thread.draft) == input.expectedHostDraftDigest,
                      ComposerDraftSnapshot.sameAttachments(thread.draftAttachments, input.expectedDraftAttachments) else { throw stale() }
                let omitted = thread.draftAttachments.filter { !input.selectedDraftAttachmentIDs.contains($0.id) }
                return thread.draftAttachments.map { .client(.removeAttachment(threadID: thread.id, attachmentID: $0.id)) }
                    + ((operation.input.attachments ?? []).isEmpty ? [] : [.client(.addAttachments(threadID: thread.id, attachments: operation.input.attachments ?? []))])
                    + [.promptSteeringAccepted(operation)]
                    + (omitted.isEmpty ? [] : [.client(.addAttachments(threadID: thread.id, attachments: omitted))])
            }
            return [.promptSteeringAccepted(operation)]
        }
        if case .acknowledge(_, let id, let digest) = action {
            guard let operation = snapshot.promptSteering(id), operation.threadID == target.threadID, operation.isUnconfirmed,
                  try RemoteSteeringProtocol.digest(operation) == digest else { throw stale() }
            return [.client(.acknowledgePromptSteering(operationID: id))]
        }
        throw stale()
    }
}
extension WorkspaceDecision {
    @inline(never) static func reduceQueuedInputReplacement(_ edit: QueuedInputReplacement, commandID: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        try decision.prepareClientCommand(.replaceQueuedText(threadID: edit.threadID, queuedID: edit.queuedID, expectedText: "", text: edit.text), commandID: commandID, now: now)
        guard let thread = decision.snapshot.threads.firstIndex(where: { $0.id == edit.threadID }), !decision.snapshot.threads[thread].isArchived,
              let index = decision.snapshot.threads[thread].queuedTurns.firstIndex(where: { $0.id == edit.queuedID }) else { throw RemoteEnvironmentAdmission.stale() }
        guard edit.matches(decision.snapshot.threads[thread]) else { throw RemoteEnvironmentAdmission.stale() }
        let original = decision.snapshot.threads[thread].queuedTurns[index]
        guard original.existingMessageID == nil, original.contextDelivery == nil, try RemoteSteeringProtocol.digest(original) == edit.digest,
              edit.text.utf16.count <= 120_000, !edit.text.contains("\0"), !edit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !edit.attachments.isEmpty else { throw RemoteEnvironmentAdmission.stale() }
        do { try AttachmentLimits.validate(edit.attachments) }
        catch { throw WorkspaceCommandError("The queued attachment selection is invalid. Review the original input again.") }
        decision.snapshot.threads[thread].queuedTurns[index].text = edit.text
        decision.snapshot.threads[thread].queuedTurns[index].attachments = edit.attachments.isEmpty ? nil : edit.attachments
        decision.snapshot.threads[thread].updatedAt = now
        return decision
    }
}
