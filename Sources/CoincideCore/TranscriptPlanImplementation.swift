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
        let destination: TranscriptPlanDestination?
        let scratchSource: ScratchWorkspaceReceipt?
        let scratchAllocation: ScratchWorkspaceAllocation?
        init(thread: CodingThread, message: ChatMessage, legacyClaudeConfiguration: ClaudeRuntimeConfiguration?, destination: TranscriptPlanDestination?) {
            threadID = thread.id; birth = thread.createdAt; projectID = thread.projectID; workspacePath = thread.workspacePath
            self.message = message; configuration = .init(thread: thread); draft = thread.draft; attachments = thread.draftAttachments
            runtimeID = thread.runtimeID; preparationID = thread.workspacePreparation?.id
            self.legacyClaudeConfiguration = legacyClaudeConfiguration; self.destination = destination
            scratchSource = thread.scratchWorkspace; scratchAllocation = nil
        }
        init(copy: Storage, scratchAllocation: ScratchWorkspaceAllocation?) {
            threadID = copy.threadID; birth = copy.birth; projectID = copy.projectID; workspacePath = copy.workspacePath
            message = copy.message; configuration = copy.configuration; draft = copy.draft; attachments = copy.attachments
            runtimeID = copy.runtimeID; preparationID = copy.preparationID; legacyClaudeConfiguration = copy.legacyClaudeConfiguration
            destination = copy.destination; scratchSource = copy.scratchSource
            self.scratchAllocation = scratchAllocation
        }
    }
    private let storage: Storage
    public var threadID: UUID { storage.threadID }
    public var message: ChatMessage { storage.message }
    public var expectedConfiguration: ProviderConfiguration { storage.configuration }
    public var destination: TranscriptPlanDestination? { storage.destination }
    var scratchSource: ScratchWorkspaceReceipt? { storage.scratchSource }
    var scratchAllocation: ScratchWorkspaceAllocation? { storage.scratchAllocation }
    private init(storage: Storage) { self.storage = storage }
    func usingScratchAllocation(_ allocation: ScratchWorkspaceAllocation?) -> Self {
        .init(storage: .init(copy: storage, scratchAllocation: allocation))
    }
    func matchesOriginalCapture(_ other: Self) -> Bool {
        Self.exact(usingScratchAllocation(nil), other.usingScratchAllocation(nil))
    }
    public init(thread: CodingThread, message: ChatMessage, legacyClaudeConfiguration: ClaudeRuntimeConfiguration? = nil,
                destination: TranscriptPlanDestination? = nil) {
        storage = .init(thread: thread, message: message, legacyClaudeConfiguration: legacyClaudeConfiguration, destination: destination)
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
    func command(in snapshot: WorkspaceSnapshot, allowUnpreparedScratch: Bool = false) throws -> WorkspaceCommand {
        let expected = storage
        guard expected.destination != nil || expected.scratchAllocation == nil else { throw ScratchWorkspaceError() }
        guard let thread = snapshot.threads.first(where: { $0.id == expected.threadID }),
              thread.createdAt == expected.birth, thread.projectID == expected.projectID,
              thread.workspacePath.utf8.elementsEqual(expected.workspacePath.utf8),
              snapshot.projects.contains(where: { $0.id == expected.projectID }),
              !thread.isArchived, !thread.isBusy, thread.activeRun == nil, thread.queuedTurns.isEmpty,
              thread.settlement == nil, snapshot.providerReady(for: thread),
              thread.runtimeID == expected.runtimeID, thread.workspacePreparation?.id == expected.preparationID,
              thread.scratchWorkspace == expected.scratchSource,
              thread.runtimeRequests.isEmpty, Self.exact(ProviderConfiguration(thread: thread), expected.configuration),
              thread.draft.utf8.elementsEqual(expected.draft.utf8), (expected.destination != nil || expected.draft.isEmpty),
              ComposerDraftSnapshot.sameAttachments(thread.draftAttachments, expected.attachments), (expected.destination != nil || expected.attachments.isEmpty) else {
            throw WorkspaceCommandError("The plan, conversation, settings or composer changed. Review the current plan before implementing it.")
        }
        let sources = Array(thread.messages.lazy.filter {
            $0.removedByHistoryOperationID == nil && $0.id.utf8.elementsEqual(expected.message.id.utf8)
        }.prefix(2))
        guard sources.count == 1, let source = sources.first, Self.exact(source, expected.message), source.role == .tool else {
            throw WorkspaceCommandError("The original plan source changed or is ambiguous. Review its current transcript item before implementing it.")
        }
        if thread.provider == .codex {
            do { _ = try CodexInteractionMode.selected(in: expected.configuration) }
            catch { throw WorkspaceCommandError("Choose a supported Codex interaction mode before implementing this plan.") }
        }
        guard thread.provider == .codex || thread.agentModeID?.lowercased() != "plan" else {
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
        guard card.kind == .plan, card.status == .completed, let plan = card.plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceCommandError("This transcript item no longer contains an implementable plan.")
        }
        let text = TranscriptPlanText.implementationPrompt(plan)
        guard text.utf16.count <= 120_000 else { throw WorkspaceCommandError("This plan is too large for a single input. Copy the plan into a bounded draft or attachment first.") }
        let destinationID = expected.destination?.threadID ?? thread.id
        if let destination = expected.destination {
            guard destination.threadID != thread.id, !snapshot.threads.contains(where: { $0.id == destination.threadID }) else {
                throw WorkspaceCommandError("The implementation conversation identity is already in use.")
            }
            if let source = expected.scratchSource {
                if let allocation = expected.scratchAllocation {
                    guard allocation.threadID == destination.threadID, allocation.project.id == expected.projectID,
                          allocation.receipt.project == source.project, allocation.receipt.identity == source.identity,
                          allocation.receipt.sharedFrom == (source.sharedFrom ?? source.commandID),
                          allocation.workspacePath.utf8.elementsEqual(expected.workspacePath.utf8) else { throw ScratchWorkspaceError() }
                } else if !allowUnpreparedScratch {
                    throw ScratchWorkspaceError("Prepare a verified shared-folder grant before implementing this plan in a new scratch conversation.")
                }
            } else if expected.scratchAllocation != nil { throw ScratchWorkspaceError() }
            if thread.provider == .codex, !CodexModeSelection.isAvailable(for: thread) {
                throw WorkspaceCommandError("Refresh this Codex conversation before creating a Default-mode implementation conversation.")
            }
        }
        if thread.provider == .claude, thread.claudeRuntimeConfiguration == nil {
            guard let captured = expected.legacyClaudeConfiguration else { throw WorkspaceCommandError("Capture the original Claude runtime before implementing this plan.") }
            return .submitCapturedClaude(threadID: destinationID, text: text, configuration: captured)
        }
        return .submit(threadID: destinationID, text: text)
    }
    /// Only the source proven above authorizes a destination. Nothing from its
    /// native conversation, queued context, transcript or composer is copied.
    func destinationThread(in snapshot: WorkspaceSnapshot, now: Date) throws -> CodingThread? {
        guard let destination = storage.destination else { return nil }
        _ = try command(in: snapshot)
        guard let source = snapshot.threads.first(where: { $0.id == storage.threadID }),
              let project = snapshot.projects.first(where: { $0.id == source.projectID }) else {
            throw WorkspaceCommandError("The original plan conversation no longer exists.")
        }
        var configuration = storage.configuration
        configuration.nativeThreadID = nil; configuration.claudeLaunchSelection = nil
        if configuration.provider == .codex { configuration.agentModeID = CodexInteractionMode.default.rawValue }
        var thread = CodingThread(project: project, model: configuration.model)
        thread.id = destination.threadID; thread.createdAt = storage.scratchAllocation?.receipt.createdAt ?? now; thread.updatedAt = now
        thread.applyContextConfiguration(configuration)
        if source.scratchWorkspace != nil {
            guard let allocation = storage.scratchAllocation else { throw ScratchWorkspaceError() }
            thread.scratchWorkspace = allocation.receipt
        }
        thread.title = TranscriptPlanText.title(TranscriptToolPresentation.card(for: storage.message,
            context: .init(provider: source.provider, workspacePath: source.workspacePath)).plan ?? storage.message.text) ?? "Implement plan"
        // Titles are presentation only; input retains the entire original plan.
        thread.title = String(thread.title.replacingOccurrences(of: "\0", with: "").prefix(512))
        if thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { thread.title = "Implement plan" }
        thread.checkpointPolicy = source.checkpointPolicy
        thread.codexReasoningPreferences = source.codexReasoningPreferences
        thread.codexModelSelectionSource = source.codexModelSelectionSource
        thread.transcriptPlanSource = try .init(thread: source, message: storage.message)
        return thread
    }

}
