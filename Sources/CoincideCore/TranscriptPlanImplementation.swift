import Foundation

/// The original displayed source and composer/runtime ownership, captured before
/// any UI await. Heap storage keeps this compound admission off reducer stacks.
public struct TranscriptPlanImplementation: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let threadID: UUID
        let birth: Date
        let projectID: UUID
        let workspacePath: String
        let message: ChatMessage
        let configuration: ProviderConfiguration
        let draft: String
        let attachments: [ChatAttachment]
        let runtimeID: UUID?
        let preparationID: UUID?
        let legacyClaudeConfiguration: ClaudeRuntimeConfiguration?
        let piConfiguration: PiRuntimeConfiguration?
        init(thread: CodingThread, message: ChatMessage, legacyClaudeConfiguration: ClaudeRuntimeConfiguration?, piConfiguration: PiRuntimeConfiguration?) {
            threadID = thread.id; birth = thread.createdAt; projectID = thread.projectID; workspacePath = thread.workspacePath
            self.message = message; configuration = .init(thread: thread); draft = thread.draft; attachments = thread.draftAttachments
            runtimeID = thread.runtimeID; preparationID = thread.workspacePreparation?.id
            self.legacyClaudeConfiguration = legacyClaudeConfiguration; self.piConfiguration = piConfiguration
        }
    }
    private let storage: Storage
    public var threadID: UUID { storage.threadID }
    public var message: ChatMessage { storage.message }
    public var expectedConfiguration: ProviderConfiguration { storage.configuration }
    public init(thread: CodingThread, message: ChatMessage, legacyClaudeConfiguration: ClaudeRuntimeConfiguration? = nil,
                piConfiguration: PiRuntimeConfiguration? = nil) {
        storage = .init(thread: thread, message: message, legacyClaudeConfiguration: legacyClaudeConfiguration, piConfiguration: piConfiguration)
    }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { exact(lhs, rhs) }
    private static func exact<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let a = try? encoder.encode(lhs), let b = try? encoder.encode(rhs) else { return false }
        return a == b
    }

    /// Called again inside the same journal decision that submits the input.
    /// A retained view is never permission to replace the current composer.
    func command(in snapshot: WorkspaceSnapshot) throws -> WorkspaceCommand {
        let expected = storage
        guard let thread = snapshot.threads.first(where: { $0.id == expected.threadID }),
              thread.createdAt == expected.birth, thread.projectID == expected.projectID,
              thread.workspacePath.utf8.elementsEqual(expected.workspacePath.utf8),
              snapshot.projects.contains(where: { $0.id == expected.projectID }),
              !thread.isArchived, !thread.isBusy, thread.activeRun == nil, thread.queuedTurns.isEmpty,
              thread.settlement == nil, snapshot.providerReady(for: thread),
              thread.runtimeID == expected.runtimeID, thread.workspacePreparation?.id == expected.preparationID,
              thread.runtimeRequests.isEmpty, Self.exact(ProviderConfiguration(thread: thread), expected.configuration),
              thread.draft.utf8.elementsEqual(expected.draft.utf8), expected.draft.isEmpty,
              ComposerDraftSnapshot.sameAttachments(thread.draftAttachments, expected.attachments), expected.attachments.isEmpty else {
            throw WorkspaceCommandError("The plan, conversation, settings or composer changed. Review the current plan before implementing it.")
        }
        let sources = Array(thread.messages.lazy.filter {
            $0.removedByHistoryOperationID == nil && $0.id.utf8.elementsEqual(expected.message.id.utf8)
        }.prefix(2))
        guard sources.count == 1, let source = sources.first, Self.exact(source, expected.message), source.role == .tool else {
            throw WorkspaceCommandError("The original plan source changed or is ambiguous. Review its current transcript item before implementing it.")
        }
        guard thread.agentModeID?.lowercased() != "plan",
              thread.provider != .opencode || thread.openCodeConfiguration?.agentID.lowercased() != "plan" else {
            throw WorkspaceCommandError("Choose an implementation agent or mode before implementing this plan.")
        }
        let sourceRun = source.runReference.flatMap { reference in
            thread.activeHistoryRuns.first(where: { $0.id == reference.runID && $0.messageAttributionVersion == 1 })
        }
        guard source.providerEntity?.key.type == "plan" || sourceRun?.configuration.provider == .claude else {
            throw WorkspaceCommandError("This legacy item has no observed native plan provenance. Copy its text into a draft to review it first.")
        }
        let capturedProvider = sourceRun?.configuration.provider ?? thread.provider
        let card = TranscriptToolPresentation.card(for: source, context: .init(provider: capturedProvider, workspacePath: expected.workspacePath))
        guard card.kind == .plan, let plan = card.plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceCommandError("This transcript item no longer contains an implementable plan.")
        }
        let text = TranscriptPlanText.implementationPrompt(plan)
        guard text.utf16.count <= 120_000 else { throw WorkspaceCommandError("This plan is too large for a single input. Copy the plan into a bounded draft or attachment first.") }
        if thread.provider == .claude, thread.claudeRuntimeConfiguration == nil {
            guard let captured = expected.legacyClaudeConfiguration else { throw WorkspaceCommandError("Capture the original Claude runtime before implementing this plan.") }
            return .submitCapturedClaude(threadID: thread.id, text: text, configuration: captured)
        }
        if thread.provider == .pi, thread.piConfiguration?.runtime == nil {
            guard let captured = expected.piConfiguration else { throw WorkspaceCommandError("Capture the original Pi runtime before implementing this plan.") }
            return .submitCapturedPi(threadID: thread.id, text: text, configuration: captured)
        }
        return .submit(threadID: thread.id, text: text)
    }
}
