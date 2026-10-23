import CoincideCore
import SwiftUI

struct RemotePullRequestCheckoutPane: View {
    var model: RemotePullRequestWorkspace
    let reference: GitHubPullRequestReference
    @State private var mode = GitHubPullRequestCheckoutMode.worktree
    @State private var submodules = ProjectWorktreeSubmoduleMode.none
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Open Remote Pull Request in a Conversation").font(.title2)
                    Text("#\(reference.number) · \(reference.repository.nameWithOwner)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("A new empty conversation uses the reviewed checkout on the remote Mac. This action does not send a message.").foregroundStyle(.secondary)
                    if let review = model.checkoutReview {
                        let plan = review.plan
                        Text(PullRequestCheckoutPresentation.disposition(plan.disposition)).font(.headline)
                        if plan.isReadOnly { Label("Read-only inspection preserves existing files and work.", systemImage: "eye").foregroundStyle(.secondary) }
                        LabeledContent("Source") { value(plan.sourcePath) }
                        LabeledContent("Destination") { value(plan.destinationPath) }
                        LabeledContent("Requested branch") { value(plan.requestedBranch) }
                        LabeledContent("Requested head") { value(plan.requestedHeadCommit) }
                        if let branch = plan.proof.destinationBranch { LabeledContent("Existing branch") { value(branch) } }
                        if let head = plan.proof.destinationHeadCommit { LabeledContent("Existing head") { value(head) } }
                        LabeledContent("Conversation", value: review.title)
                        LabeledContent("Provider", value: RunHistoryPresentation.provider(review.targetConfiguration))
                        LabeledContent("Model", value: RunHistoryPresentation.model(review.targetConfiguration))
                        LabeledContent("Permissions") { Text(LocalizedStringKey(review.targetConfiguration.permission.title)) }
                        if plan.disposition == .reuseUnrelatedWorktree { Text("Existing local commits and edits are kept. The observed checkout may differ from the requested pull request head.").foregroundStyle(.secondary) }
                    } else {
                        Picker("Checkout on remote Mac", selection: $mode) {
                            Text("Separate worktree").tag(GitHubPullRequestCheckoutMode.worktree)
                            Text("Switch existing remote checkout").tag(GitHubPullRequestCheckoutMode.local)
                        }.pickerStyle(.radioGroup).disabled(model.isBusy)
                        if mode == .worktree {
                            Picker("Initialize remote submodules", selection: $submodules) {
                                Text("None").tag(ProjectWorktreeSubmoduleMode.none); Text("Top level").tag(ProjectWorktreeSubmoduleMode.topLevel); Text("Recursive").tag(ProjectWorktreeSubmoduleMode.recursive)
                            }.disabled(model.isBusy)
                        }
                        Text(mode == .local ? "Switching changes files used by other conversations in that remote checkout. Commit or stash tracked changes first." :
                            "Work in the source checkout can continue. A busy reused checkout is inspected without changing its files.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Git may fetch through the remote Mac's existing GitHub sign-in. Setup scripts are not run by this remote action.").font(.caption).foregroundStyle(.secondary)
                    if let error = model.actionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let message = model.unavailableMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                if model.checkout != nil { Button("Edit") { model.clearCheckout() }.disabled(model.isBusy) }
                Button(model.checkout == nil ? "Review Checkout…" : "Open New Conversation") {
                    Task {
                        if model.checkout == nil { await model.prepareCheckout(reference: reference, mode: mode, submodules: submodules) }
                        else { await model.beginCheckout() }
                    }
                }.disabled(model.checkout == nil ? !model.canCheckout(mode) : !model.canAcceptCheckout)
            }.padding(16)
        }.onChange(of: mode) { model.clearCheckout() }.onChange(of: submodules) { model.clearCheckout() }
    }
    private func value(_ text: String) -> some View { Text(text).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
}
