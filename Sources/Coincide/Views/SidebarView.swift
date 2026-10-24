import CoincideCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    let onClone: () -> Void
    let onNewProject: () -> Void
    var onSettle: ((CodingThread) -> Void)? = nil
    var onImportAgentProjects: (() -> Void)? = nil
    @State private var renaming: SidebarRenameTarget?
    @State private var title = ""
    @State private var searchVisible = false
    @State private var expandedChatLists: Set<String> = []
    @State private var removing: ProjectRemovalRequest?
    @State private var removingGroup: ProjectGroupRemovalRequest?
    @State private var pendingGroupRemoval: ProjectGroupRemovalRequest?
    @Environment(ProjectActionsPresenter.self) private var projectActions: ProjectActionsPresenter?
    @State private var scratchRecoveryPresented = false
    private var selectedSidebarRow: Binding<SidebarThreadSelection?> {
        Binding(get: {
            guard let thread = store.selectedThread else { return nil }
            let group = store.projectGroup(containing: thread.projectID)
            let nested = group.map { group in
                store.isProjectGroupExpanded(group.key) && (expandedChatLists.contains(group.key) ||
                    store.visibleThreads.filter { group.memberProjectIDs.contains($0.projectID) }.prefix(3).contains { $0.id == thread.id })
            } ?? false
            return SidebarThreadSelection(id: thread.id, nested: nested)
        }, set: { if let value = $0 { store.selectThread(value.id) } })
    }
    var body: some View {
        List(selection: selectedSidebarRow) {
            Section {
                ForEach(store.orderedProjectGroups.filter { $0.representative.scratch == nil }) { group in
                    projectHeader(group)
                    if store.isProjectGroupExpanded(group.key) {
                        let chats = store.visibleThreads.filter { group.memberProjectIDs.contains($0.projectID) }
                        ForEach(expandedChatLists.contains(group.key) ? chats : Array(chats.prefix(3))) { thread in
                            threadRow(thread, group: group, nested: true).padding(.leading, 17)
                        }
                        if chats.count > 3 {
                            Button(expandedChatLists.contains(group.key) ? "Show less" : "Show all \(chats.count) chats") {
                                if !expandedChatLists.insert(group.key).inserted { expandedChatLists.remove(group.key) }
                            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.leading, 17)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button(action: onNewProject) { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("New project").accessibilityLabel("New project")
                }
            }
            Section("Recents") {
                ForEach(store.visibleThreads) { thread in
                    threadRow(thread, group: store.projectGroup(containing: thread.projectID))
                }
                if store.visibleThreads.isEmpty {
                    Text(store.search.isEmpty ? "No conversations yet" : "No matching conversations")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13))
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden).background(ChatChrome.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 18) {
                HStack(spacing: 16) {
                    Text("Coincide").font(.system(size: 16, weight: .medium))
                    Spacer()
                    Button { searchVisible.toggle(); if !searchVisible { store.search = "" } } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Search chats").accessibilityLabel("Search chats")
                    Button { store.sidebarVisible = false } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide sidebar").accessibilityLabel("Hide sidebar")
                }
                Button { store.newThread() } label: {
                    Label("New chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).font(.system(size: 13))
                if searchVisible || !store.search.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search chats", text: $store.search).textFieldStyle(.plain).accessibilityLabel("Search conversations")
                    }.font(.system(size: 12)).padding(8).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(.horizontal, 16).padding(.vertical, 14)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New Conversation Without a Project") { store.newScratchThread() }
                        .disabled(store.isCreatingScratchConversation)
                        .accessibilityIdentifier("scratch-new-conversation")
                    Button("Saved Scratch Allocations…") { scratchRecoveryPresented = true }
                    Divider()
                    Button("New Project…", action: onNewProject)
                    Button("Open Folder…") { store.addProject() }
                    Button("Clone Repository…", action: onClone)
                    if let onImportAgentProjects { Button("Import Agent Projects…", action: onImportAgentProjects) }
                } label: { Label("Add Project", systemImage: "folder.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Toggle(isOn: $store.showArchived) { Image(systemName: "archivebox") }.toggleStyle(.button).help("Show archived threads")
            }.buttonStyle(.borderless).padding(12)
        }
        .sheet(isPresented: $scratchRecoveryPresented) { ScratchWorkspaceRecoverySheet(store: store) }
        .onChange(of: store.selectedThreadID) { if let thread = store.selectedThread { store.selectedProjectID = thread.projectID } }
        .alert(renaming?.alertTitle ?? String(localized: "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title).accessibilityIdentifier("sidebar-rename-title")
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                switch renaming {
                case .project(let id): store.renameProject(id, title: title)
                case .group(let group): store.renameProjectGroup(group, title: title)
                case .thread(let id): store.rename(id, title: title)
                case nil: break
                }
                renaming = nil
            }.accessibilityIdentifier("sidebar-rename-save").disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(removing.map { String(localized: "Remove “\($0.name)” from Coincide?") } ?? String(localized: "Remove Project"),
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { request in
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove Project", role: .destructive) {
                removing = nil
                Task {
                    do { try await store.removeProject(request) }
                    catch is CancellationError { }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
        } message: { request in
            Text(removalExplanation(request))
        }
        .sheet(item: $removingGroup, onDismiss: finishGroupRemoval) { request in
            ProjectGroupRemovalSheet(request: request, cancel: { removingGroup = nil }, remove: {
                pendingGroupRemoval = request
                removingGroup = nil
            })
        }
    }

    private func finishGroupRemoval() {
        guard let request = pendingGroupRemoval else { return }
        pendingGroupRemoval = nil
        Task {
            do { try await store.removeProjectGroup(request) }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func threadRow(_ thread: CodingThread, group: ProjectGroup?, nested: Bool = false) -> some View {
        let project = store.snapshot.projects.first { $0.id == thread.projectID }
        return HStack(spacing: 8) {
            if thread.isPinned { Image(systemName: "pin").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title).lineLimit(1)
                if let clone = project?.clone, !clone.isReady {
                    Text(ProjectClonePresentation.title(clone)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if store.snapshot.isEffectivelySnoozed(threadID: thread.id, at: Date()), let until = thread.workspaceLifecycle?.snoozedUntil {
                    Text("Snoozed until \(until, format: .dateTime.month(.abbreviated).day().hour().minute())").font(.caption).foregroundStyle(.secondary)
                } else if thread.settlement?.phase == .resuming {
                    Text("Resuming…").font(.caption).foregroundStyle(.secondary)
                } else if thread.state != .idle {
                    Text(thread.state == .awaitingApproval ? "Needs your input" : thread.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                TerminalActivityBadge(store: store, threadID: thread.id)
                if (group?.members.count ?? 0) > 1, let project {
                    Text(project.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .overlay(alignment: .topTrailing) { ThreadJumpHintBadge(threadID: thread.id) }
        .tag(SidebarThreadSelection(id: thread.id, nested: nested))
        .accessibilityIdentifier((nested ? "project-thread-" : "thread-") + thread.id.uuidString)
        .contextMenu {
            Button(thread.isPinned ? "Unpin" : "Pin") { store.togglePin(thread.id) }
            Button("Rename…") { title = thread.title; renaming = .thread(thread.id) }
            Button(thread.isArchived ? "Unarchive" : "Archive") { store.toggleArchive(thread.id) }
                .disabled(store.isBusy(thread.id) || store.snapshot.isConversationHistoryLocked(threadID: thread.id) || store.isCheckpointRestoreLocked(threadID: thread.id) || store.isPullRequestCreationLocked(threadID: thread.id) || store.isPullRequestCheckoutLocked(threadID: thread.id))
            Button("Reveal Workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath) }
                .disabled(project?.clone.map { !$0.isReady } ?? false)
        }
    }

    private func projectHeader(_ group: ProjectGroup) -> some View {
        Button {
            store.setProjectGroupExpanded(group, expanded: !store.isProjectGroupExpanded(group.key))
            if let project = store.preferredProject(in: group) { store.selectedProjectID = project.id }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.isProjectGroupExpanded(group.key) ? "folder" : "folder.closed").foregroundStyle(.secondary)
                Text(group.displayName).lineLimit(1)
                Spacer(minLength: 0)
                if group.members.count > 1 { Text(group.members.count, format: .number).font(.caption2).foregroundStyle(.secondary) }
                Image(systemName: store.isProjectGroupExpanded(group.key) ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Chats in \(group.displayName)"))
        .accessibilityValue(store.isProjectGroupExpanded(group.key) ? Text("Expanded") : Text("Collapsed"))
        .contextMenu {
            if group.members.count > 1 {
                Menu("New Thread in Checkout") { newThreadCheckoutItems(group) }
                Menu("Checkouts") {
                    ForEach(group.members) { project in
                        Menu(project.path) { checkoutActions(project) }
                    }
                }
            } else if let project = group.members.first { checkoutActions(project) }
            if let projectActions { Divider(); Button("Project Settings…") { projectActions.showSettings(group.representative) } }
            if group.memberProjectIDs.count > 1 {
                Divider()
                Button("Rename Group…") { title = group.displayName; renaming = .group(group) }
                Button("Remove Group…", role: .destructive) { removingGroup = store.projectGroupRemovalRequest(group.key) }
            }
            if store.projectSortMode == .manual {
                Divider()
                if store.orderedProjectGroups.first?.id != group.id { Button("Move Up") { store.moveProjectGroup(group.key, by: -1) } }
                if store.orderedProjectGroups.last?.id != group.id { Button("Move Down") { store.moveProjectGroup(group.key, by: 1) } }
            }
        }
    }

    @ViewBuilder private func newThreadCheckoutItems(_ group: ProjectGroup) -> some View {
        ForEach(group.members) { project in Button(project.path) { store.newThread(projectID: project.id) } }
    }

    @ViewBuilder private func checkoutActions(_ project: WorkspaceProject) -> some View {
        Button("New Thread") { store.newThread(projectID: project.id) }
        Button("Reveal Checkout") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            .disabled(project.clone.map { !$0.isReady } ?? false)
        ExternalEditorMenu(store: store, workspacePath: project.path, title: "Open Checkout in…")
        Button("Rename Project…") { title = project.name; renaming = .project(project.id) }
        Menu("Group This Checkout") {
            Button("Use Default") { store.setProjectGroupingOverride(project.id, mode: nil) }
            ForEach(ProjectGroupingMode.allCases) { mode in Button(mode.title) { store.setProjectGroupingOverride(project.id, mode: mode) } }
        }
        Button("Refresh Repository Identity") { store.refreshRepositoryIdentity(project.id) }
            .disabled(project.clone.map { !$0.isReady } ?? false)
        Divider()
        Button("Remove Project…", role: .destructive) { removing = store.projectRemovalRequest(project.id) }
    }

    private func removalExplanation(_ request: ProjectRemovalRequest) -> String {
        var text = request.path + "\n\n" + String(localized: "This removes this checkout's active and archived conversations from the workspace and stops their agents, clone operation, and terminals. Other checkouts remain open.\n\nCoincide does not delete checkout, worktree, staging, or attachment files. Git may clean up unfinished files when an active clone is stopped. Conversation data remains in local recovery history; this is not secure erasure.")
        if !request.dirtyEditorIDs.isEmpty { text += "\n\n" + String(localized: "Unsaved file edits in this project will be discarded.") }
        return text
    }


}

private enum SidebarRenameTarget {
    case project(UUID), thread(UUID), group(ProjectGroup)
    var alertTitle: String {
        switch self {
        case .project: String(localized: "Rename Project")
        case .thread: String(localized: "Rename Thread")
        case .group: String(localized: "Rename Group")
        }
    }
}

private struct SidebarThreadSelection: Hashable {
    let id: UUID
    let nested: Bool
}
