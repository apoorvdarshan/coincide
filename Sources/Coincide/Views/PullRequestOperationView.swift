import CoincideCore
import SwiftUI

struct PullRequestOperationView: View {
    let model: PullRequestStore
    var viewResult: () -> Void = { }
    @State private var confirmingAcknowledgement = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let operation = model.operation {
                PullRequestOperationContent(operation: operation, inspecting: model.isInspecting,
                    inspect: { perform { try await model.reconcileCreation() } },
                    acknowledge: { confirmingAcknowledgement = true }, viewResult: viewResult)
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let message = model.actionError { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.alert("Acknowledge the uncertain creation?", isPresented: $confirmingAcknowledgement) {
            Button("Cancel", role: .cancel) { }.keyboardShortcut(.defaultAction)
            Button("Acknowledge Outcome") { perform { try await model.acknowledgeCreation() } }
                .accessibilityIdentifier("pull-request-acknowledge-confirm")
        } message: {
            Text("The pull request may already exist. This releases the checkout hold without repeating creation. Inspect the exact branch on GitHub before explicitly creating another request; a missing lookup result does not prove creation never reached GitHub.")
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do { try await action() }
            catch is CancellationError { }
            catch { self.error = PullRequestPresentation.error(error) }
        }
    }
}

struct PullRequestOperationContent: View {
    let operation: PullRequestCreationOperation
    let inspecting: Bool
    let inspect: () -> Void
    let acknowledge: () -> Void
    let viewResult: () -> Void
    private var status: String {
        switch operation.phase {
        case .accepted, .dispatching: String(localized: "Creating pull request…")
        case .created: String(localized: "Pull request created")
        case .openedExisting: String(localized: "Existing pull request found")
        case .failed: String(localized: "Pull request creation could not complete")
        case .unconfirmed: operation.acknowledgedAt == nil ? String(localized: "Pull request creation unconfirmed") : String(localized: "Uncertain creation acknowledged")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if operation.isWorking || inspecting { ProgressView().controlSize(.small) }
                Text(status).font(.caption.weight(.medium)).accessibilityIdentifier("pull-request-creation-status")
            }
            Text(operation.review.context.repository.nameWithOwner + " · " + PullRequestPresentation.head(operation.review.context) + " → " + operation.review.baseBranch)
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pull-request-creation-scope")
            Text(operation.review.title).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let error = operation.error { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if operation.locksSource {
                Text("This checkout is held while creation is pending or unconfirmed. Your conversation drafts stay editable.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if operation.phase == .unconfirmed, operation.acknowledgedAt == nil {
                ViewThatFits(in: .horizontal) {
                    HStack { recoveryButtons }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 7) { recoveryButtons }
                }
            }
            if let result = result {
                ViewThatFits(in: .horizontal) {
                    HStack { resultButtons(result) }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 7) { resultButtons(result) }
                }
            }
        }.padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .coincideSurface(cornerRadius: 10)
    }
    private var result: GitHubPullRequestSummary? {
        switch operation.result {
        case .created(let detail), .openedExisting(let detail): detail.summary
        case nil: nil
        }
    }
    @ViewBuilder private var recoveryButtons: some View {
        Button("Inspect Creation State", action: inspect).disabled(inspecting).controlSize(.small)
            .accessibilityIdentifier("pull-request-inspect-creation")
        Button("Acknowledge Outcome…", action: acknowledge).disabled(inspecting).controlSize(.small)
            .accessibilityIdentifier("pull-request-acknowledge")
    }
    @ViewBuilder private func resultButtons(_ summary: GitHubPullRequestSummary) -> some View {
        Button("View Pull Request", action: viewResult).controlSize(.small).accessibilityIdentifier("pull-request-view-result")
        if let url = PullRequestPresentation.url(summary) { Link("Open on GitHub", destination: url).controlSize(.small) }
    }
}
