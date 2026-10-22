import SwiftUI

struct ProjectGroupRemovalSheet: View {
    let request: ProjectGroupRemovalRequest
    let cancel: () -> Void
    let remove: () -> Void
    private var paths: [String] {
        request.projects.reduce(into: []) { paths, project in if !paths.contains(project.path) { paths.append(project.path) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove “\(request.name)” Group?").font(.title2)
            Text("This removes all active and archived conversations in these checkouts and stops their agents, clone operations, and terminals. Other projects remain open.")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(paths, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(12)
            }
            .frame(minHeight: 60, maxHeight: 160)
            .coincideSurface(cornerRadius: 8)
            .accessibilityIdentifier("group-removal-checkouts")
            Text("Coincide does not delete checkout, worktree, staging, or attachment files. Git may clean up unfinished files when an active clone is stopped. Conversation data remains in local recovery history; this is not secure erasure.")
                .font(.caption).foregroundStyle(.secondary)
            if !request.dirtyEditorIDs.isEmpty { Text("Unsaved file edits in these checkouts will be discarded.").font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Remove Group", role: .destructive, action: remove).accessibilityIdentifier("remove-project-group")
            }
        }.padding(24).frame(width: 520)
    }
}
