import CoincideCore
import SwiftUI

struct SettleConversationSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let close: () -> Void
    @State private var reviewScript = true
    @State private var submitting = false
    @State private var actionError: String?
    private var canSettle: Bool { store.thread(threadID).map(store.canSettle) == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settle Conversation?").font(.title2)
            Text("Keep this conversation for later. New messages resume it, and you can also choose Resume at any time.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Coincide stops this conversation’s managed setup jobs before checking its settle script. Your terminal tabs and checkout files stay in place.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Toggle("Review settle script", isOn: $reviewScript)
                .accessibilityIdentifier("settlement-review-script")
            Text("For a separate worktree with a declared settle script, review its exact command before running it. Turning this off skips the script. Settling never runs a command without review.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !canSettle {
                Text("Finish the current turn and queued messages, and complete checkout setup before settling.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(submitting)
                Spacer()
                Button(submitting ? "Settling…" : "Settle") {
                    guard canSettle, !submitting else { return }; submitting = true; actionError = nil
                    Task {
                        defer { submitting = false }
                        do { try await store.settleThread(threadID, reviewScript: reviewScript); close() }
                        catch is CancellationError { }
                        catch { actionError = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(submitting || !canSettle)
                    .accessibilityIdentifier("settlement-confirm")
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(submitting)
    }
}

struct ThreadSettlementBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    let settlement: ThreadSettlement
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if settlement.phase == .resuming { ProgressView().controlSize(.small) }
                else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(settlement.phase == .resuming ? "Resuming conversation…" : "Conversation settled")
                        .font(.callout.weight(.medium)).accessibilityIdentifier("settlement-status")
                    Text(settlement.phase == .resuming
                         ? "Messages wait until its managed jobs have stopped."
                         : "Send a message or choose Resume to continue. Files and Terminal remain available.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Resume") { store.requestResume(threadID, generationID: settlement.id) }
                    .controlSize(.small).disabled(settlement.phase == .resuming)
                    .accessibilityIdentifier("settlement-resume")
            }
            if settlement.phase == .settled, let script = settlement.script, script.phase != .skipped {
                WorkspaceSetupBanner(store: store, threadID: threadID, run: script, role: .settle)
            }
        }
        .padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain).accessibilityIdentifier("thread-settlement")
    }
}
