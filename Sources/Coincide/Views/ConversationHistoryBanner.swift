import CoincideCore
import SwiftUI

struct ConversationHistoryBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    var body: some View {
        if let operation = store.conversationHistoryOperations(threadID: threadID).first,
           ConversationHistoryPresentation.isPending(operation) || operation.phase == .unconfirmed ||
            (operation.phase == .applied && operation.review.kind == .rewindBeforeRun && operation.recalledAt == nil) {
            ConversationHistoryOperationView(store: store, operation: operation)
                .padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ConversationHistoryOperationView: View {
    let store: WorkspaceStore
    let operation: ConversationHistoryOperation
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if ConversationHistoryPresentation.isPending(operation) { ProgressView().controlSize(.small) }
                Text(ConversationHistoryPresentation.status(operation)).font(.caption.weight(.medium))
                    .accessibilityIdentifier("conversation-history-operation-status")
            }
            if operation.phase == .unconfirmed {
                Text(operation.review.kind == .rewindBeforeRun
                     ? String(localized: "The local transcript was kept and provider work is paused. Inspect the provider state before continuing; the rewind will not be repeated.")
                     : String(localized: "The provider may have created a fork. This action was not repeated; the source conversation is unchanged."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if operation.review.kind == .rewindBeforeRun {
                    Button("Inspect Provider State") { perform { try await store.reconcileConversationHistory(operation.id) } }
                        .disabled(store.isInspectingConversationHistory(operation.id)).controlSize(.small)
                        .accessibilityIdentifier("conversation-history-reconcile")
                }
            }
            if let message = operation.error { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if operation.phase == .applied, operation.review.kind == .forkAfterRun,
               let target = operation.review.targetThreadID, let thread = store.thread(target) {
                Button("Open Fork") {
                    store.selectedProjectID = thread.projectID
                    store.showArchived = thread.isArchived
                    store.selectedThreadID = target
                }.controlSize(.small).accessibilityIdentifier("conversation-history-open-fork")
            }
            if store.canRecallConversationHistoryPrompt(operation) {
                Button("Recall Prompt") { perform { try await store.recallConversationHistoryPrompt(operation.id) } }
                    .disabled(store.isRecallingConversationHistoryPrompt(operation.id)).controlSize(.small)
                    .help("Append the original prompt and attachments to your latest draft.")
                    .accessibilityIdentifier("conversation-history-recall")
            } else if operation.recalledAt != nil {
                Text("Original input recalled to the composer").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.accessibilityIdentifier("conversation-history-operation-\(operation.id)")
            .onChange(of: operation.phase) { error = nil }
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
