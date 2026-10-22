import CoincideCore
import SwiftUI

struct PullRequestCheckoutOperationView: View {
    let model: PullRequestStore
    var operationID: UUID? = nil
    @State private var confirmingAcknowledgement = false
    @State private var confirmingOperationID: UUID?
    @State private var performingAction = false
    @State private var error: String?
    private var operation: PullRequestCheckoutOperation? {
        if let operationID { return model.checkoutOperations.first { $0.id == operationID } }
        return model.checkoutOperation
    }
    private var confirmation: PullRequestCheckoutOperation? {
        guard let confirmingOperationID else { return operation }
        return model.checkoutOperations.first { $0.id == confirmingOperationID }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let operation {
                PullRequestCheckoutOperationContent(operation: operation,
                    acting: performingAction || model.isInspecting,
                    stop: { perform { try await model.cancelCheckout(operationID: operation.id) } },
                    inspect: { perform { try await model.inspectCheckout(operationID: operation.id) } },
                    acknowledge: { confirmingOperationID = operation.id; confirmingAcknowledgement = true },
                    openConversation: { model.openCheckoutConversation(operationID: operation.id) })
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let message = model.actionError { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.accessibilityIdentifier("pull-request-checkout-operation-\(operationID?.uuidString ?? operation?.id.uuidString ?? "none")")
        .alert(confirmation?.review.plan.isReadOnly == true
                ? String(localized: "Close unconfirmed checkout inspection?") : String(localized: "Keep the current checkout files?"), isPresented: $confirmingAcknowledgement) {
            Button("Cancel", role: .cancel) { }.keyboardShortcut(.defaultAction)
            Button(confirmation?.review.plan.isReadOnly == true ? String(localized: "Keep Current Checkout") : String(localized: "Keep Current Files")) {
                guard let id = confirmingOperationID else { return }
                perform { try await model.acknowledgeCheckout(operationID: id) }
            }
                .accessibilityIdentifier("pull-request-checkout-acknowledge-confirm")
        } message: {
            if confirmation?.review.plan.isReadOnly == true {
                Text("No checkout changes were requested. This closes the inspection without creating a conversation or repeating the operation. Existing work continues.")
            } else {
                Text("Git may already have changed local branches, tracking or files. This releases the checkout hold without repeating the operation or creating a conversation. Inspect the current checkout before starting another action.")
            }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !performingAction else { return }
        error = nil; performingAction = true
        Task {
            defer { performingAction = false }
            do { try await action() }
            catch is CancellationError { }
            catch { self.error = PullRequestCheckoutPresentation.error(error) }
        }
    }
}

struct PullRequestCheckoutOperationContent: View {
    let operation: PullRequestCheckoutOperation
    let acting: Bool
    let stop: () -> Void
    let inspect: () -> Void
    let acknowledge: () -> Void
    let openConversation: () -> Void
    private var plan: GitHubPullRequestCheckoutPlan { operation.review.plan }
    private var status: String {
        switch operation.phase {
        case .accepted: String(localized: "Pull request checkout queued")
        case .dispatching: operation.cancelRequested ? String(localized: "Stopping pull request checkout…") : String(localized: "Preparing pull request checkout…")
        case .completed: String(localized: "Pull request conversation ready")
        case .failed: String(localized: "Pull request checkout did not complete")
        case .unconfirmed: operation.acknowledgedAt == nil ? String(localized: "Pull request checkout unconfirmed") : String(localized: "Current checkout kept")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if operation.isWorking || acting { ProgressView().controlSize(.small) }
                Text(status).font(.headline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pull-request-checkout-status")
            }
            Text("#\(plan.pullRequest.reference.number) · \(plan.pullRequest.reference.repository.nameWithOwner)")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text(plan.pullRequest.title).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            LabeledContent("Requested branch") { value(plan.requestedBranch) }
            LabeledContent("Requested head") { value(plan.requestedHeadCommit) }
            LabeledContent("Destination") { value(plan.destinationPath) }
            if plan.isReadOnly {
                Text("Read-only inspection leaves files, branches, tracking, submodules and setup unchanged. Existing provider, terminal and editor work can continue.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pull-request-checkout-read-only")
            }
            if operation.retainsProject {
                Text(plan.isReadOnly
                    ? "The inspection must be verified before its new conversation is created. It is never repeated automatically."
                    : plan.request.mode == .worktree
                        ? "The destination checkout is held until its outcome is verified or explicitly acknowledged. Work in the source checkout can continue; checkout is never repeated automatically."
                        : "This local checkout is held until its outcome is verified or explicitly acknowledged. Existing conversation drafts remain editable; checkout is never repeated automatically.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = operation.error {
                Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let result = operation.result {
                Divider()
                Text(resultDescription(result)).font(.callout).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Actual branch") { value(result.actualBranch) }
                LabeledContent("Actual head") { value(result.actualHeadCommit) }
                if !result.isOnPullRequestHead {
                    Label("The actual checkout differs from the reviewed pull request head. Local commits or changes were preserved; inspect the actual files before working.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pull-request-checkout-off-head")
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Text(LocalizedStringKey(warning)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("The new conversation starts empty. No prompt was sent.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Conversation", action: openConversation).disabled(acting)
                    .accessibilityIdentifier("pull-request-checkout-open-conversation")
            }
            if operation.isWorking {
                Text(plan.request.mode == .worktree
                     ? "You can close this sheet and continue working while checkout preparation finishes."
                     : "You can close this sheet while checkout preparation finishes. Changes to this local checkout stay held.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Stop Checkout", action: stop).disabled(acting || operation.cancelRequested)
                    .accessibilityIdentifier("pull-request-checkout-stop")
            } else if operation.phase == .unconfirmed, operation.acknowledgedAt == nil {
                ViewThatFits(in: .horizontal) {
                    HStack { recoveryButtons }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { recoveryButtons }
                }
            }
        }.font(.callout).padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("pull-request-checkout-operation")
    }
    @ViewBuilder private var recoveryButtons: some View {
        Button("Inspect Checkout State", action: inspect).disabled(acting)
            .accessibilityIdentifier("pull-request-checkout-inspect")
        Button("Keep Current Files…", action: acknowledge).disabled(acting)
            .accessibilityIdentifier("pull-request-checkout-acknowledge")
    }
    private func value(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func resultDescription(_ result: GitHubPullRequestCheckoutResult) -> String {
        if result.created { return String(localized: "A separate worktree was created.") }
        if result.reused, result.moved { return String(localized: "The existing worktree was updated and reused.") }
        if result.reused { return String(localized: "The existing worktree was reused with its local state preserved.") }
        return String(localized: "The local repository checkout is ready.")
    }
}
