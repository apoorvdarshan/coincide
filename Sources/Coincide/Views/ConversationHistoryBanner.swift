import CoincideCore
import SwiftUI

struct ConversationHistoryBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    var body: some View {
        if let operation = store.conversationHistoryOperations(threadID: threadID).first,
           operation.isWorking || operation.phase == .unconfirmed || operation.locksFiles ||
            operation.needsPromptRecall || store.canRecallConversationHistoryPrompt(operation) {
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
            if let message = operation.error { detail(message) }
            if let files = operation.files {
                if operation.isPending {
                    detail(String(localized: "Files will be restored only after the provider rewind is confirmed. The original input returns after both steps finish."))
                } else if files.isWorking {
                    detail(String(localized: "Conversation history is rewound. Workspace actions remain paused while files are restored; you can keep editing your draft."))
                } else if files.acknowledgedAt != nil {
                    detail(String(localized: "Current files were explicitly kept. The conversation rewind remains applied; its original input was not returned to the draft."))
                }
            }
            if let files = incompleteFiles {
                detail(files.phase == .unconfirmed
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
        }.accessibilityIdentifier("conversation-history-operation-\(operation.id)")
            .onChange(of: operation.updatedAt) { error = nil }
            .alert("Keep the current workspace files?", isPresented: $confirmingKeepFiles) {
                Button("Cancel", role: .cancel) { }.keyboardShortcut(.defaultAction)
                Button("Keep Current Files") { perform { try await store.acknowledgeConversationHistoryFiles(operation.id) } }
                    .accessibilityIdentifier("conversation-history-keep-files-confirm")
            } message: {
                Text("The conversation rewind remains applied. Current files and staging may contain a partial restoration. Continuing keeps those bytes, releases the workspace hold and leaves your latest draft unchanged; the original input will not be recalled.")
            }
    }

    @ViewBuilder private var providerState: some View {
        if operation.phase == .unconfirmed {
            detail(operation.review.kind == .rewindBeforeRun
                   ? String(localized: "The local transcript was kept and provider work is paused. Inspect the provider state before continuing; the rewind will not be repeated.")
                   : String(localized: "The provider may have created a fork. This action was not repeated; the source conversation is unchanged."))
            if operation.files != nil { detail(String(localized: "File restoration has not started. The original input has not been returned to the draft.")) }
            if operation.review.kind == .rewindBeforeRun {
                Button("Inspect Provider State") { perform { try await store.reconcileConversationHistory(operation.id) } }
                    .disabled(store.isInspectingConversationHistory(operation.id)).controlSize(.small)
                    .accessibilityIdentifier("conversation-history-reconcile")
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
