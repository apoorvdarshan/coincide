import CoincideCore
import SwiftUI

struct ProjectCloneBanner: View {
    let project: WorkspaceProject
    let cancel: () -> Void
    let retry: () -> Void
    var retrying = false

    var body: some View {
        if let clone = project.clone, !clone.isReady {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if clone.phase == .queued || clone.phase == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: clone.phase == .failed ? "exclamationmark.triangle" : "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ProjectClonePresentation.title(clone)).font(.callout.weight(.medium))
                        Text("Messages wait until the repository is ready.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if clone.phase == .queued || clone.phase == .running {
                        Button(clone.cancelRequested ? "Cancelling…" : "Cancel", action: cancel)
                            .controlSize(.small).disabled(clone.cancelRequested)
                    } else if clone.canRetry {
                        Button(retrying ? "Retrying…" : "Retry", action: retry).controlSize(.small).disabled(retrying)
                    }
                }
                if clone.phase == .running, let percent = clone.progress.percent {
                    ProgressView(value: Double(min(100, max(0, percent))), total: 100)
                        .accessibilityLabel(ProjectClonePresentation.title(clone))
                }
                if clone.progress.stalled, clone.phase == .running {
                    Text("Waiting for the remote. You can keep working in other projects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = clone.error, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Repository clone")
        }
    }
}

enum ProjectClonePresentation {
    static func title(_ clone: ProjectCloneState) -> String {
        if clone.cancelRequested, clone.isRunning { return String(localized: "Cancelling clone…") }
        switch clone.phase {
        case .queued: return String(localized: "Preparing repository…")
        case .running:
            let label: String
            switch clone.progress.stage {
            case .connecting: label = String(localized: "Connecting…")
            case .counting: label = String(localized: "Counting objects…")
            case .receiving: label = String(localized: "Downloading repository…")
            case .resolving: label = String(localized: "Resolving objects…")
            case .checkout: label = String(localized: "Checking out files…")
            }
            if let percent = clone.progress.percent {
                return String(localized: "\(label) \(min(100, max(0, percent)))%")
            }
            return label
        case .completed: return String(localized: "Repository ready")
        case .failed: return String(localized: "Couldn’t clone repository")
        case .cancelled: return String(localized: "Clone cancelled")
        case .interrupted: return String(localized: "Clone interrupted")
        }
    }
}
