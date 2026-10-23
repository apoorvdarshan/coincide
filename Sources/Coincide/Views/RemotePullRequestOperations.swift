import CoincideCore
import SwiftUI

private enum RemotePullRequestAcknowledgement: Identifiable {
    case creation(UUID), checkout(UUID)
    var id: UUID { switch self { case .creation(let id), .checkout(let id): id } }
}

struct RemotePullRequestOperations: View {
    var model: RemotePullRequestWorkspace
    var viewResult: () -> Void = { }
    @State private var confirming: RemotePullRequestAcknowledgement?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let operation = model.operation {
                PullRequestOperationContent(operation: operation, inspecting: model.isActing,
                    inspect: { Task { await model.recoverCreation(id: operation.id) } },
                    acknowledge: { confirming = .creation(operation.id) }, viewResult: viewResult)
            }
            ForEach(model.checkoutOperations.reversed()) { operation in
                PullRequestCheckoutOperationContent(operation: operation, acting: model.isActing,
                    stop: { Task { await model.cancelCheckout(operation.id) } },
                    inspect: { Task { await model.recoverCheckout(operation.id) } },
                    acknowledge: { confirming = .checkout(operation.id) },
                    openConversation: { model.openConversation(operation.id) })
            }
            if let error = model.actionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.disabled(!model.connected || !model.writesAllowed)
        .confirmationDialog("Acknowledge the unconfirmed remote outcome?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let captured = confirming {
                Button("Keep Current Outcome") {
                    confirming = nil
                    Task {
                        switch captured {
                        case .creation(let id): await model.recoverCreation(id: id, acknowledge: true)
                        case .checkout(let id): await model.recoverCheckout(id, acknowledge: true)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("The remote operation may already have changed GitHub or checkout files. This releases its hold without repeating creation or checkout. Inspect the current state before starting a new operation.")
        }
    }
}

struct RemotePullRequestBanner: View {
    var store: RemotePullRequestStore
    var body: some View {
        if let model = store.current, model.operation?.locksSource == true || model.checkoutOperations.contains(where: \.retainsProject) {
            ScrollView { RemotePullRequestOperations(model: model).padding(12) }.frame(maxHeight: 200)
        }
    }
}
