import CoincideCore
import SwiftUI

struct PromptSteeringBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    @State private var acknowledging: Set<UUID> = []
    private var operations: [PromptSteeringOperation] {
        (store.snapshot.promptSteerings ?? []).filter { $0.threadID == threadID && ($0.isWorking || ($0.isUnconfirmed && $0.acknowledgedAt == nil)) }
    }
    var body: some View {
        ForEach(operations) { operation in
            PromptSteeringStatusContent(working: operation.isWorking, acting: acknowledging.contains(operation.id),
                message: operation.error,
                acknowledge: {
                    guard acknowledging.insert(operation.id).inserted else { return }
                    Task {
                        await store.acknowledgePromptSteering(operation.id)
                        acknowledging.remove(operation.id)
                    }
                })
        }
    }
}

struct PromptSteeringStatusContent: View {
    let working: Bool
    let acting: Bool
    let message: String?
    let acknowledge: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if working || acting { ProgressView().controlSize(.small) }
                Text(working ? "Sending to the running turn…" : "Steering delivery unconfirmed")
                    .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("prompt-steering-status")
            }
            if working {
                Text("The current turn continues. Queued messages wait until this input's delivery is known.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(message ?? String(localized: "The provider may have received this input. It stays in the conversation and will not be sent again automatically."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Continuing releases the delivery hold without confirming delivery or repeating this input. Choose Resume Queue when you are ready to send queued messages.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Continue Without Repeating", action: acknowledge).font(.caption).disabled(acting)
                    .accessibilityIdentifier("prompt-steering-continue")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
