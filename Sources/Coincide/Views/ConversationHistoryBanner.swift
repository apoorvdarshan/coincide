import CoincideCore
import SwiftUI

struct ConversationHistoryBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    var body: some View {
        if let operation = store.conversationHistoryOperations(threadID: threadID).first,
           operation.isWorking || operation.phase == .unconfirmed || operation.locksFiles ||
            operation.needsPromptRecall || store.canRecallConversationHistoryPrompt(operation) ||
            operation.error == ConversationHistoryOperation.openCodeV1NotAdoptedMessage {
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
    @State private var confirmingMaintenance = false
    @State private var confirmingKeepOriginal = false

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
            maintenanceState
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
        }
            // A parent identifier replaces child control identifiers in native AX.
            // Keep the status and action identifiers on their semantic leaves.
            .onChange(of: operation.updatedAt) { error = nil }
            .alert("Keep the current workspace files?", isPresented: $confirmingKeepFiles) {
                Button("Cancel", role: .cancel) { }.keyboardShortcut(.defaultAction)
                Button("Keep Current Files") { perform { try await store.acknowledgeConversationHistoryFiles(operation.id) } }
                    .accessibilityIdentifier("conversation-history-keep-files-confirm")
            } message: {
                Text("The conversation rewind remains applied. Current files and staging may contain a partial restoration. Continuing keeps those bytes, releases the workspace hold and leaves your latest draft unchanged; the original input will not be recalled.")
            }
            .alert("Clear the pending OpenCode revert?", isPresented: $confirmingMaintenance) {
                Button("Cancel", role: .cancel) { }.keyboardShortcut(.defaultAction)
                Button("Clear Pending Revert") { perform { try await store.clearConversationHistoryMaintenance(operation.id) } }
                    .accessibilityIdentifier("conversation-history-clear-confirm")
            } message: {
                Text("Coincide checks the exact staged boundary before clearing it and waits for OpenCode’s empty cleanup execution to finish. This does not repeat the rewind, restore files or send your draft. Conversation work stays paused until its history is verified.")
            }
            .alert("Keep the original conversation?", isPresented: $confirmingKeepOriginal) {
                Button("Cancel", role: .cancel) { }.keyboardShortcut(.defaultAction)
                Button("Keep Original Conversation") { perform { try await store.keepOpenCodeV1Original(operation.id) } }
                    .accessibilityIdentifier("conversation-history-keep-original-confirm")
            } message: {
                Text("Coincide verifies that the original native conversation is unchanged before releasing this hold. Your latest draft, settings and workspace files stay unchanged. A separate native conversation may remain; this does not repeat the history action or delete any native conversation.")
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
                    .disabled(store.isInspectingConversationHistory(operation.id) || operation.maintenance?.phase.isWorking == true).controlSize(.small)
                    .accessibilityIdentifier("conversation-history-reconcile")
                if operation.review.openCodeV2 != nil {
                    Button("Clear Pending Revert…") { confirmingMaintenance = true }
                        .disabled(!store.canClearConversationHistoryMaintenance(operation)).controlSize(.small)
                        .accessibilityIdentifier("conversation-history-clear")
                } else if operation.review.openCodeV1 != nil {
                    detail(String(localized: "OpenCode v1 rewinds through a separate native conversation. Inspect can adopt only the exact recorded candidate after its copy is verified. You can instead verify and keep the unchanged original; another native conversation may remain."))
                    if let candidate = operation.openCodeV1Candidate {
                        Text(candidate.reference.nativeThreadID).font(.caption.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("conversation-history-native-candidate")
                    }
                    Button("Keep Original Conversation…") { confirmingKeepOriginal = true }
                        .disabled(!store.canKeepOpenCodeV1Original(operation)).controlSize(.small)
                        .accessibilityIdentifier("conversation-history-keep-original")
                }
            }
        }
    }
    @ViewBuilder private var maintenanceState: some View {
        if let maintenance = operation.maintenance {
            if let message = maintenance.error { detail(message) }
            if maintenance.phase == .applied {
                detail(String(localized: "The pending revert was cleared without repeating the history action. Its exact cleanup execution is retained as evidence."))
            }
            if let prior = operation.previousMaintenanceAttempts, !prior.isEmpty {
                DisclosureGroup("Earlier cleanup attempts") {
                    ForEach(prior) { attempt in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attempt.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            if let message = attempt.error { Text(message).fixedSize(horizontal: false, vertical: true) }
                            else { Text("Cleanup completed") }
                        }.font(.caption).textSelection(.enabled)
                    }
                }.font(.caption)
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
