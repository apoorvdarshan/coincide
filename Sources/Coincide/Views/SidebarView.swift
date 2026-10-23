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
    @State private var removing: ProjectRemovalRequest?
    @State private var removingGroup: ProjectGroupRemovalRequest?
    @State private var pendingGroupRemoval: ProjectGroupRemovalRequest?
    @State private var snoozing: ThreadSnoozePresentation?
    var body: some View {
        List(selection: $store.selectedThreadID) {
            ForEach(store.orderedProjectGroups) { group in
                Section {
                    ForEach(store.sidebarThreads(groupKey: group.key)) { thread in
                        threadRow(thread, group: group)
                    }
                    if store.isProjectGroupExpanded(group.key) {
                        if group.members.count > 1 {
                            Menu { newThreadCheckoutItems(group) } label: { Label("New Thread", systemImage: "plus") }
                                .menuStyle(.borderlessButton).foregroundStyle(.secondary)
                        } else if let project = group.members.first {
                            Button { store.newThread(projectID: project.id) } label: { Label("New Thread", systemImage: "plus") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                } header: { projectHeader(group) }
            }
            .onMove(perform: projectMoveAction)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 12) {
                HStack {
                    Button { store.newThread() } label: {
                        Label("New conversation", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Menu {
                        sortModeItem(.updatedAt)
                        sortModeItem(.createdAt)
                        sortModeItem(.manual)
                        Divider()
                        Section("Group Projects") {
                            ForEach(ProjectGroupingMode.allCases) { mode in
                                Button { store.setProjectGroupingMode(mode) } label: {
                                    if store.projectGroupingMode == mode { Label(mode.title, systemImage: "checkmark") }
                                    else { Text(mode.title) }
                                }
                            }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().help("Sort Projects")
                    .accessibilityLabel("Sort projects").accessibilityValue(store.projectSortMode.title)
                    .accessibilityIdentifier("project-sort-menu")
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search conversations", text: $store.search).textFieldStyle(.plain).accessibilityLabel("Search conversations")
                }.font(.system(size: 12)).padding(8).coincideSurface(cornerRadius: 8)
            }.padding(.horizontal, 16).padding(.vertical, 14)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New Project…", action: onNewProject)
                    Button("Open Folder…") { store.addProject() }
                    Button("Clone Repository…", action: onClone)
                    if let onImportAgentProjects { Button("Import Agent Projects…", action: onImportAgentProjects) }
                } label: { Label("Add Project", systemImage: "folder.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Toggle(isOn: $store.showArchived) { Image(systemName: "archivebox") }.toggleStyle(.button).help("Show archived threads")
            }.buttonStyle(.borderless).padding(12)
        }
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
        .sheet(item: $snoozing) { presentation in
            ThreadSnoozeSheet(presentation: presentation, snooze: { try await store.snoozeThread(presentation.id, until: $0) }, dismiss: { snoozing = nil })
        }
        .sheet(item: $removingGroup, onDismiss: finishGroupRemoval) { request in
            ProjectGroupRemovalSheet(request: request, cancel: { removingGroup = nil }, remove: {
                pendingGroupRemoval = request
                removingGroup = nil
            })
        }
    }

    private var projectMoveAction: ((IndexSet, Int) -> Void)? {
        guard store.projectSortMode == .manual else { return nil }
        return { offsets, destination in store.moveProjectGroups(fromOffsets: offsets, toOffset: destination) }
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

    private func threadRow(_ thread: CodingThread, group: ProjectGroup) -> some View {
        let project = store.snapshot.projects.first { $0.id == thread.projectID }
        return Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title).lineLimit(1)
                if let clone = project?.clone, !clone.isReady {
                    Text(ProjectClonePresentation.title(clone)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if store.snapshot.isEffectivelySnoozed(threadID: thread.id, at: Date()), let until = thread.workspaceLifecycle?.snoozedUntil {
                    Text("Snoozed until \(until, format: .dateTime.month(.abbreviated).day().hour().minute())").font(.caption).foregroundStyle(.secondary)
                } else if let settlement = thread.settlement {
                    Text(settlement.phase == .resuming ? "Resuming…" : "Settled").font(.caption).foregroundStyle(.secondary)
                } else if thread.state != .idle {
                    Text(thread.state == .awaitingApproval ? "Needs your input" : thread.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                TerminalActivityBadge(store: store, threadID: thread.id)
                if group.members.count > 1, let project {
                    Text(project.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: thread.isPinned ? "pin" : thread.isSettled ? "checkmark.circle" : thread.state == .running ? "circle.dotted" : "bubble.left")
        }
        .overlay(alignment: .topTrailing) { ThreadJumpHintBadge(threadID: thread.id) }
        .tag(thread.id)
        .accessibilityIdentifier("thread-\(thread.id.uuidString)")
        .contextMenu {
            Button(thread.isPinned ? "Unpin" : "Pin") { store.togglePin(thread.id) }
            Button("Rename…") { title = thread.title; renaming = .thread(thread.id) }
            if store.snapshot.isEffectivelySnoozed(threadID: thread.id, at: Date()) {
                Button("Wake Conversation") { store.wakeThread(thread.id) }
            }
            Button("Snooze…") { snoozing = .init(thread) }.disabled(!store.canSnooze(thread))
            Button(thread.workspaceLifecycle?.autoSettleDisabledAt == nil ? "Disable Automatic Settlement" : "Enable Automatic Settlement") {
                store.setAutoSettlement(thread.id, enabled: thread.workspaceLifecycle?.autoSettleDisabledAt != nil)
            }.disabled(thread.isArchived)
            if let settlement = thread.settlement {
                Button("Resume Conversation") { store.requestResume(thread.id, generationID: settlement.id) }
                    .disabled(settlement.phase == .resuming)
            } else if let onSettle {
                Button("Settle Conversation…") { onSettle(thread) }.disabled(!store.canSettle(thread))
            }
            Button(thread.isArchived ? "Unarchive" : "Archive") { store.toggleArchive(thread.id) }
                .disabled(store.isBusy(thread.id) || store.snapshot.isConversationHistoryLocked(threadID: thread.id) || store.isCheckpointRestoreLocked(threadID: thread.id) || store.isPullRequestCreationLocked(threadID: thread.id) || store.isPullRequestCheckoutLocked(threadID: thread.id))
            Button("Reveal Workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath) }
                .disabled(project?.clone.map { !$0.isReady } ?? false)
        }
    }

    private func projectHeader(_ group: ProjectGroup) -> some View {
        Button { store.setProjectGroupExpanded(group, expanded: !store.isProjectGroupExpanded(group.key)) } label: {
            HStack(spacing: 5) {
                Image(systemName: store.isProjectGroupExpanded(group.key) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Text(group.displayName).lineLimit(1)
                Spacer(minLength: 0)
                if group.members.count > 1 { Text(group.members.count, format: .number).font(.caption2).foregroundStyle(.secondary) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isProjectGroupExpanded(group.key) ? Text("Collapse \(group.displayName)") : Text("Expand \(group.displayName)"))
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

    private func sortModeItem(_ mode: ProjectSortMode) -> some View {
        Button { store.setProjectSortMode(mode) } label: {
            if store.projectSortMode == mode { Label(mode.title, systemImage: "checkmark") }
            else { Text(mode.title) }
        }
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
