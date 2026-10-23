import CoincideCore
import SwiftUI

struct RemoteWorktreeBanner: View {
    var store: RemoteWorktreeStore
    var body: some View {
        if let preparation = store.preparation {
            if preparation.isReady {
                if let warning = preparation.result?.submoduleWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).coincideSurface()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if preparation.isRunning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(preparation)).font(.callout.weight(.medium))
                            Text("Messages wait until this remote checkout is ready.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if preparation.isRunning {
                            Button(preparation.cancelRequested ? "Cancelling…" : "Cancel") { Task { await store.cancel() } }.disabled(!store.canCancel)
                        } else {
                            if preparation.plan != nil { Button("Inspect Result") { Task { await store.inspect() } }.disabled(!store.canInspect) }
                            if preparation.canRetry { Button("Retry") { Task { await store.retry() } }.disabled(!store.canRetry) }
                        }
                    }.controlSize(.small)
                    Text(preparation.destinationPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    if let error = preparation.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let message = store.eligibilityMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if preparation.canRetry {
                        Text("Inspect Result checks only this exact attempt. Retry preserves earlier folders and branches and uses the host's native recovery rules.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(12).coincideSurface().accessibilityIdentifier("remote-worktree-preparation")
            }
        }
    }
    private func title(_ preparation: ThreadWorkspacePreparation) -> String {
        if preparation.cancelRequested, preparation.isRunning { return "Cancelling remote worktree setup…" }
        return switch preparation.phase {
        case .queued: "Preparing remote checkout…"
        case .resolving: "Resolving repository on remote Mac…"
        case .preparing: preparation.request.submodules == .none ? "Preparing remote worktree…" : "Preparing remote worktree and submodules…"
        case .completed: "Remote checkout ready"
        case .failed: "Couldn’t prepare remote checkout"
        case .cancelled: "Remote worktree setup cancelled"
        case .interrupted: "Remote worktree setup interrupted"
        }
    }
}
