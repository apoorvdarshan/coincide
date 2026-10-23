import CoincideCore
import SwiftUI

/// The saved draft choice, rather than a live preference lookup. Closing a
/// window or restarting cannot silently turn a pending worktree into Local.
struct ProjectWorktreeDefaultBanner: View {
    let store: WorkspaceStore
    let thread: CodingThread
    let choose: () -> Void
    private func isCurrent(_ intent: DraftWorkspaceIntent) -> Bool {
        guard let current = store.thread(thread.id), store.selectedThreadID == thread.id else { return false }
        return current.createdAt == thread.createdAt && current.projectID == thread.projectID &&
            current.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8) && current.draftWorkspaceIntent == intent
    }
    var body: some View {
        if let intent = thread.draftWorkspaceIntent, thread.messages.isEmpty, thread.workspacePreparation == nil {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send prepares a new worktree").font(.callout.weight(.medium))
                    Text(intent.startFromOrigin
                        ? "From \(intent.baseBranch), using its configured remote when available. Your input waits for checkout and setup review."
                        : "From local \(intent.baseBranch). Your input waits for checkout and setup review.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Use This Checkout") {
                    guard isCurrent(intent) else { return }
                    store.useCurrentCheckout(threadID: thread.id, intentID: intent.id)
                }.controlSize(.small).accessibilityIdentifier("project-default-use-checkout")
                Button("Choose Worktree…") { if isCurrent(intent) { choose() } }
                    .controlSize(.small).accessibilityIdentifier("project-default-worktree")
            }.padding(12).coincideSurface()
                .accessibilityElement(children: .contain).accessibilityLabel("Worktree default")
        }
    }
}
