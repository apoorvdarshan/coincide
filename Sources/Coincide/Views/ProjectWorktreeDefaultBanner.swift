import CoincideCore
import SwiftUI

/// When a project's resolved default is "New worktree", a new local conversation offers worktree
/// preparation before its first message. Nothing is created until the user chooses.
struct ProjectWorktreeDefaultBanner: View {
    let store: WorkspaceStore
    let thread: CodingThread
    let choose: () -> Void
    private struct Owner: Hashable {
        let id: UUID
        let birth: Date
        let projectID: UUID
        let path: Data
    }
    private struct LoadKey: Hashable { let owner: Owner; let revision: Int; let eligible: Bool }
    @MainActor private static var dismissed: Set<Owner> = []
    private var owner: Owner { .init(id: thread.id, birth: thread.createdAt, projectID: thread.projectID, path: Data(thread.workspacePath.utf8)) }
    private func isCurrent(_ captured: Owner) -> Bool {
        guard let current = store.thread(captured.id), store.selectedThreadID == captured.id else { return false }
        return current.createdAt == captured.birth && current.projectID == captured.projectID && Data(current.workspacePath.utf8) == captured.path
    }
    @State private var resolved: ProjectResolvedSetting<ProjectThreadEnvironmentMode>?
    @State private var hidden = false
    private var project: WorkspaceProject? { store.snapshot.projects.first { $0.id == thread.projectID } }
    private var eligible: Bool {
        guard let project, project.clone.map({ !$0.isReady }) != true else { return false }
        return thread.messages.isEmpty && thread.queuedTurns.isEmpty && thread.workspacePreparation == nil && thread.settlement == nil &&
            !thread.isBusy && URL(fileURLWithPath: thread.workspacePath).standardizedFileURL.path == URL(fileURLWithPath: project.path).standardizedFileURL.path
    }
    var body: some View {
        let offered = owner
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
                    Button("Use This Checkout") {
                        guard isCurrent(offered) else { return }
                        if Self.dismissed.count >= 1_024 { Self.dismissed.removeAll() }
                        Self.dismissed.insert(offered); hidden = true
                    }.controlSize(.small)
                    Button("Choose Worktree…") { if isCurrent(offered) { choose() } }
                        .controlSize(.small).accessibilityIdentifier("project-default-worktree")
                }
                .padding(12).coincideSurface()
                .accessibilityElement(children: .contain).accessibilityLabel("Worktree default")
            }
        }
        .task(id: LoadKey(owner: offered, revision: store.projectSettings.revision, eligible: eligible)) {
            resolved = nil; hidden = Self.dismissed.contains(offered)
            guard eligible, isCurrent(offered) else { return }
            let value = await store.projectDefaults(threadID: thread.id)?.threadEnvironmentMode
            guard !Task.isCancelled, isCurrent(offered) else { return }
            resolved = value
        }
    }
}
