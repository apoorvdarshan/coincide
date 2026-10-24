import CoincideCore
import SwiftUI

struct ConversationHistoryBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    var body: some View {
        if let operation = store.conversationHistoryOperations(threadID: threadID).first(where: {
            $0.isWorking || $0.phase == .unconfirmed || $0.locksFiles ||
                $0.needsPromptRecall || store.canRecallConversationHistoryPrompt($0) ||
                store.hasPendingClaudeResumeSelection($0)
        }) {
            ConversationHistoryOperationView(store: store, operation: operation)
                .padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .coincideSurface()
        }
    }
}

struct ConversationHistoryOperationView: View {
    let store: WorkspaceStore
    let operation: ConversationHistoryOperation
    @State private var error: String?
    @State private var confirmingKeepFiles = false

    private var recalling: Bool { store.isRecallingConversationHistoryPrompt(operation.id) }
    private var claudeContext: Bool { ConversationHistoryPresentation.isClaudeContextSelection(operation.review) }
    private var incompleteFiles: ConversationHistoryFilesState? {
        guard operation.phase == .applied, let files = operation.files,
              [.failed, .unconfirmed].contains(files.phase), files.acknowledgedAt == nil else { return nil }
        return files
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if operation.isWorking || recalling { ProgressView().controlSize(.small) }
                Text(ConversationHistoryPresentation.status(operation)).font(.caption.weight(.medium))
                    .accessibilityIdentifier("conversation-history-operation-status")
            }
            providerState
            claudeResumeState
            if let message = operation.error { detail(message) }
            if let files = operation.files {
                if operation.isPending {
                    detail(claudeContext
                        ? String(localized: "Files will be restored only after the Claude resume point is durably saved. The original input returns after both steps finish; no message is sent.")
                        : String(localized: "Files will be restored only after the provider rewind is confirmed. The original input returns after both steps finish."))
                } else if files.isWorking {
                    detail(claudeContext
                        ? String(localized: "The Claude resume point is saved for your next message. Workspace actions remain paused while files are restored; you can keep editing your draft.")
                        : String(localized: "Conversation history is rewound. Workspace actions remain paused while files are restored; you can keep editing your draft."))
                } else if files.acknowledgedAt != nil {
                    detail(claudeContext
                        ? String(localized: "Current files were explicitly kept. The saved Claude resume point remains selected for your next message; its original input was not returned to the draft.")
                        : String(localized: "Current files were explicitly kept. The conversation rewind remains applied; its original input was not returned to the draft."))
                }
            }
            if let files = incompleteFiles {
                detail(claudeContext
                       ? files.phase == .unconfirmed
                       ? String(localized: "The Claude resume point is saved, but files or staging may be partially changed. Workspace actions stay paused. Inspect the evidence or explicitly keep current files; restoration will not be repeated.")
                       : String(localized: "The Claude resume point is saved, but file restoration did not complete. Workspace actions stay paused until you explicitly keep current files. The original input has not been returned.")
                       : files.phase == .unconfirmed
                       ? String(localized: "Conversation history is rewound, but files or staging may be partially changed. Workspace actions stay paused. Inspect the evidence or explicitly keep the current files; restoration will not be repeated.")
                       : String(localized: "Conversation history is rewound, but file restoration did not complete. Workspace actions stay paused until you explicitly keep the current files. The original input has not been returned."))
                ViewThatFits(in: .horizontal) {
                    HStack { fileActions(files) }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) { fileActions(files) }
                }
            }
            if operation.phase == .applied, operation.review.kind == .forkAfterRun,
               let target = operation.review.targetThreadID, let thread = store.thread(target) {
                Button("Open Fork") {
                    store.selectedProjectID = thread.projectID
                    store.showArchived = thread.isArchived
                    store.selectedThreadID = target
                }.controlSize(.small).accessibilityIdentifier("conversation-history-open-fork")
            }
            recallState
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
            // A parent identifier replaces child control identifiers in native AX.
            // Keep the status and action identifiers on their semantic leaves.
            .onChange(of: operation.updatedAt) { error = nil }
            .alert("Keep the current workspace files?", isPresented: $confirmingKeepFiles) {
                Button("Cancel", role: .cancel) { }.keyboardShortcut(.defaultAction)
                Button("Keep Current Files") { perform { try await store.acknowledgeConversationHistoryFiles(operation.id) } }
                    .accessibilityIdentifier("conversation-history-keep-files-confirm")
            } message: {
                Text(claudeContext
                     ? String(localized: "The saved Claude resume point remains selected for your next message. Current files and staging may contain a partial restoration. Continuing keeps those bytes, releases the workspace hold and leaves your latest draft unchanged; the original input will not be recalled.")
                     : String(localized: "The conversation rewind remains applied. Current files and staging may contain a partial restoration. Continuing keeps those bytes, releases the workspace hold and leaves your latest draft unchanged; the original input will not be recalled."))
            }
    }

    @ViewBuilder private var providerState: some View {
        if operation.phase == .unconfirmed {
            detail(operation.review.kind == .rewindBeforeRun
                   ? String(localized: "The local transcript was kept and provider work is paused. Inspect the provider state before continuing; the rewind will not be repeated.")
                   : String(localized: "The provider may have created a fork. This action was not repeated; the source conversation is unchanged."))
            if operation.files != nil { detail(String(localized: "File restoration has not started. The original input has not been returned to the draft.")) }
            if operation.review.claude != nil {
                detail(operation.review.kind == .forkAfterRun
                       ? String(localized: "Inspect checks only the exact reserved native fork and its source proof. It does not repeat publication, delete a transcript or send a message.")
                       : String(localized: "Inspect verifies the saved Claude context selection and its exact native source. It does not submit a message or replay the history action."))
                if let publication = operation.claudeForkPublication {
                    LabeledContent("Reserved fork", value: publication.target.sessionID)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("conversation-history-claude-native-candidate")
                }
            }
            if store.canInspectConversationHistory(operation) {
                Button(operation.review.claude != nil && operation.review.kind == .forkAfterRun ? "Inspect Reserved Fork" : "Inspect Provider State") {
                    perform { try await store.reconcileConversationHistory(operation.id) }
                }
                    .disabled(store.isInspectingConversationHistory(operation.id)).controlSize(.small)
                    .accessibilityIdentifier("conversation-history-reconcile")
            }
        }
    }
    @ViewBuilder private var claudeResumeState: some View {
        if store.hasPendingClaudeResumeSelection(operation) {
            if store.claudeResumeSelectionNeedsInspection(threadID: operation.review.sourceThreadID) {
                detail(String(localized: "Claude’s use of the selected context could not be confirmed. Inspect it before starting another turn. No input will be replayed."))
                Button("Inspect Claude Context") {
                    perform { try await store.inspectClaudeResumeSelection(threadID: operation.review.sourceThreadID) }
                }.disabled(store.isInspectingClaudeResumeSelection(threadID: operation.review.sourceThreadID))
                    .controlSize(.small).accessibilityIdentifier("conversation-history-inspect-claude-context")
            } else if store.isConsumingClaudeResumeSelection(operation) {
                detail(String(localized: "This Claude turn is using the saved context. Its selection remains recorded until the matching turn is confirmed."))
            } else {
                detail(String(localized: "Your next explicit message will use the saved Claude context. Existing native transcripts are retained; this selection did not send a message."))
            }
        }
    }
    @ViewBuilder private func fileActions(_ files: ConversationHistoryFilesState) -> some View {
        if files.phase == .unconfirmed {
            Button("Inspect Restoration Evidence") { perform { try await store.inspectConversationHistoryFiles(operation.id) } }
                .disabled(store.isInspectingConversationHistory(operation.id)).controlSize(.small)
                .accessibilityIdentifier("conversation-history-inspect-files")
        }
        Button("Keep Current Files…") { confirmingKeepFiles = true }
            .disabled(store.isInspectingConversationHistory(operation.id)).controlSize(.small)
            .accessibilityIdentifier("conversation-history-keep-files")
    }
    @ViewBuilder private var recallState: some View {
        if operation.needsPromptRecall {
            if recalling {
                detail(String(localized: "Returning the original input to your latest draft…"))
            } else {
                if let message = store.conversationHistoryRecallError(operation.id) { detail(message) }
                ViewThatFits(in: .horizontal) {
                    HStack { recallActions }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) { recallActions }
                }
            }
        } else if store.canRecallConversationHistoryPrompt(operation) {
            recallButton
        } else if operation.recalledAt != nil {
            detail(String(localized: "Original input recalled to the composer"))
        } else if operation.recallDismissedAt != nil {
            detail(String(localized: "Latest draft kept; original input was not recalled"))
        }
    }
    @ViewBuilder private var recallActions: some View {
        if store.canRecallConversationHistoryPrompt(operation) { recallButton }
        Button("Keep Current Draft") { perform { try await store.dismissConversationHistoryRecall(operation.id) } }
            .disabled(recalling).controlSize(.small).accessibilityIdentifier("conversation-history-keep-draft")
    }
    private var recallButton: some View {
        Button("Recall Prompt") { perform { try await store.recallConversationHistoryPrompt(operation.id) } }
            .disabled(recalling).controlSize(.small)
            .help("Append the original prompt and attachments to your latest draft.")
            .accessibilityIdentifier("conversation-history-recall")
    }
    private func detail(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do { try await action() }
            catch is CancellationError { }
            catch { self.error = ConversationHistoryPresentation.error(error) }
        }
    }
}
