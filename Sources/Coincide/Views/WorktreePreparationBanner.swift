import CoincideCore
import SwiftUI

struct WorktreePreparationBanner: View {
    let preparation: ThreadWorkspacePreparation
    let cancel: () -> Void
    let retry: () -> Void
    var retrying = false
    var body: some View {
        if preparation.isReady, let warning = preparation.result?.submoduleWarning {
            Label {
                Text(warning).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.secondary).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("worktree-submodule-warning")
        } else if !preparation.isReady {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if preparation.isRunning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WorktreePreparationPresentation.title(preparation)).font(.callout.weight(.medium))
                        Text("Messages wait until this checkout is ready.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if preparation.isRunning {
                        Button(preparation.cancelRequested ? "Cancelling…" : "Cancel", action: cancel)
                            .controlSize(.small).disabled(retrying || preparation.cancelRequested)
                    } else if preparation.canRetry {
                        Button(retrying ? "Retrying…" : "Retry", action: retry).controlSize(.small).disabled(retrying)
                    }
                }
                Text(preparation.destinationPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                if let message = preparation.error, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                if preparation.canRetry {
                    Text("Existing files and branches are preserved. To change setup, remove queued messages and choose a worktree from the workspace menu.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityLabel("Worktree preparation")
        }
    }
}

enum WorktreePreparationPresentation {
    static func title(_ preparation: ThreadWorkspacePreparation) -> String {
        if preparation.cancelRequested, preparation.isRunning { return String(localized: "Cancelling worktree setup…") }
        return switch preparation.phase {
        case .queued: String(localized: "Preparing checkout…")
        case .resolving: String(localized: "Resolving local repository…")
        case .preparing: preparation.request.submodules == .none ? String(localized: "Preparing worktree…") : String(localized: "Preparing worktree and submodules…")
        case .completed: String(localized: "Checkout ready")
        case .failed: String(localized: "Couldn’t prepare checkout")
        case .cancelled: String(localized: "Worktree setup cancelled")
        case .interrupted: String(localized: "Worktree setup interrupted")
        }
    }
}
