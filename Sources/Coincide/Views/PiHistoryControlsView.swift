import CoincideCore
import SwiftUI

/// These requests belong to a history worker, not the source chat runtime.
struct PiHistoryControlsView: View {
    let store: WorkspaceStore
    let operation: ConversationHistoryOperation
    let controls: PiHistoryControlState
    let respond: (ApprovalRequest, ProviderApprovalResponse) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !controls.requests.isEmpty {
                Text("Pi is waiting for your input before this history action can finish. Answers apply only to this operation; your composer draft is not sent.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(controls.requests) { pending in
                    if let request = pending.request.piExtension {
                        PiExtensionApprovalView(request: request,
                            isResponding: pending.responding || !store.canRespondPiHistory(operationID: operation.id,
                                sessionID: controls.sessionID, requestID: pending.id),
                            onDecision: { respond(pending.request, .decision($0)) },
                            onAnswer: { respond(pending.request, .answers($0)) },
                            onOption: { respond(pending.request, .option($0)) })
                            .id(pending.id)
                    }
                }
            }
            Button(store.isCancellingPiHistory(operation.id) ? "Cancelling History Action…" : "Cancel History Action", action: cancel)
                .disabled(!store.canCancelPiHistory(operation)).controlSize(.small)
                .accessibilityIdentifier("conversation-history-pi-cancel")
        }
    }
}
