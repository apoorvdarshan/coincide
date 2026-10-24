import CoincideCore
import SwiftUI

struct ContextCompactionBanner: View {
    let operation: ContextCompactionOperation
    var isCancelling = false
    var cancel: () -> Void = {}
    @State private var dismissedID: UUID?

    static func title(for operation: ContextCompactionOperation) -> String {
        switch operation.phase {
        case .pending: "Requesting context compaction…"
        case .running: "Compacting context…"
        case .completed: "Context compacted"
        case .failed: "Context compaction failed"
        case .unconfirmed: "Context compaction was not confirmed"
        }
    }

    var body: some View {
        if dismissedID != operation.id {
            HStack(alignment: .top, spacing: 10) {
                if operation.isWorking { ProgressView().controlSize(.small) }
                else { Image(systemName: operation.phase == .completed ? "checkmark.circle" : "exclamationmark.circle") }
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(for: operation)).fontWeight(.medium)
                    if let error = operation.error { Text(error).foregroundStyle(.secondary) }
                    else if !operation.isWorking { Text("Your Coincide conversation and draft are unchanged.").foregroundStyle(.secondary) }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if operation.isWorking {
                    Button(isCancelling ? "Stopping…" : "Stop", action: cancel)
                        .disabled(isCancelling).accessibilityIdentifier("context-compaction-stop")
                } else {
                    Button { dismissedID = operation.id } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss context compaction status")
                }
            }
            .font(.system(size: 12)).padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("context-compaction-status")
        }
    }
}
