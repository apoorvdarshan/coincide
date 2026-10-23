import CoincideCore
import SwiftUI

/// When a project's resolved default is "New worktree", a new local conversation offers worktree
/// preparation before its first message. Nothing is created until the user chooses.
struct ProjectWorktreeDefaultBanner: View {
    let store: WorkspaceStore
    let thread: CodingThread
    let choose: () -> Void
    @MainActor private static var dismissed: Set<UUID> = []
    @State private var resolved: ProjectResolvedSetting<ProjectThreadEnvironmentMode>?
    @State private var hidden = false
    private var project: WorkspaceProject? { store.snapshot.projects.first { $0.id == thread.projectID } }
    private var eligible: Bool {
        guard let project, project.clone.map({ !$0.isReady }) != true else { return false }
        return thread.messages.isEmpty && thread.queuedTurns.isEmpty && thread.workspacePreparation == nil && thread.settlement == nil &&
            !thread.isBusy && URL(fileURLWithPath: thread.workspacePath).standardizedFileURL.path == URL(fileURLWithPath: project.path).standardizedFileURL.path
    }
    var body: some View {
        Group {
            if eligible, !hidden, resolved?.value == .worktree {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This project starts new threads in a worktree").font(.callout.weight(.medium))
                        Text("Set by \(resolved?.source.title ?? ""). Choose a worktree before the first message, or keep this checkout.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Use This Checkout") { Self.dismissed.insert(thread.id); hidden = true }.controlSize(.small)
                    Button("Choose Worktree…", action: choose).controlSize(.small).accessibilityIdentifier("project-default-worktree")
                }
                .padding(12).coincideSurface()
                .accessibilityElement(children: .contain).accessibilityLabel("Worktree default")
            }
        }
        .task(id: "\(thread.id)\u{0}\(store.projectSettings.revision)") {
            hidden = Self.dismissed.contains(thread.id)
            guard eligible else { return }
            resolved = await store.projectDefaults(projectID: thread.projectID)?.threadEnvironmentMode
        }
    }
}
