import CoincideCore
import SwiftUI

struct PullRequestCheckoutBanner: View {
    let store: WorkspaceStore
    let thread: CodingThread
    var body: some View {
        if store.isPullRequestCheckoutLocked(threadID: thread.id) {
            Label("Pull request checkout is pending or unconfirmed. Open Changes → Pull Requests in the source checkout to inspect its state.", systemImage: "arrow.triangle.branch")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("conversation-pull-request-checkout-hold")
        }
        if let id = thread.pullRequestCheckoutOperationID,
           let operation = store.snapshot.pullRequestCheckout(id), let result = operation.result,
           !result.isOnPullRequestHead {
            VStack(alignment: .leading, spacing: 4) {
                Label("This conversation opened with preserved local commits or changes. Its checkout differed from the reviewed pull request head.", systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Opened branch: \(result.actualBranch) · Head: \(result.actualHeadCommit)")
                    .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Inspect Changes before continuing. This records the checkout result; it is not a live comparison with GitHub.")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("conversation-pull-request-checkout-off-head")
        }
    }
}
