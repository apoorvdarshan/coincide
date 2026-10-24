import CoincideCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    let onNewProject: () -> Void
    var onImportAgentProjects: (() -> Void)? = nil

    @State private var renaming: SidebarRenameTarget?
    @State private var title = ""
    @State private var searchVisible = false
    @State private var expandedChatLists: Set<UUID> = []
    @State private var removing: ProjectRemovalRequest?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionTitle("Projects")
                    let projects = store.orderedProjects.filter { $0.scratch == nil }
                    ForEach(projects) { project in
                        projectRow(project)
                        if store.isProjectExpanded(project.id) {
                            projectChats(project)
                        }
                    }
                    if projects.isEmpty {
                        emptyState("No projects yet", detail: "Add a folder to keep related chats together.")
                    }
                    HStack {
                        sectionTitle(store.showArchived ? "Archived chats" : "Recents")
                        Spacer(minLength: 4)
                        Button {
                            store.showArchived.toggle()
                        } label: {
                            Image(systemName: "archivebox")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(SidebarIconButtonStyle(size: 26))
                        .help(store.showArchived ? "Show recent chats" : "Show archived chats")
                        .accessibilityLabel(store.showArchived ? "Show recent chats" : "Show archived chats")
                    }
                    .padding(.top, 14)
                    ForEach(store.visibleThreads.map { SidebarChatEntry(thread: $0, projectID: nil) }) { entry in
                        threadRow(entry.thread)
                    }
                    if store.visibleThreads.isEmpty {
                        if !store.search.isEmpty {
                            emptyState("No matching conversations", detail: "Try another chat title or message.")
                        } else if store.showArchived {
                            emptyState("No archived chats", detail: "Conversations you archive appear here.")
                        } else {
                            emptyState("No conversations yet", detail: "Start a new chat above.")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            bottomMenu
        }
        .background(ChatChrome.sidebar)
        .onChange(of: store.selectedThreadID) {
            if let thread = store.selectedThread { store.selectedProjectID = thread.projectID }
        }
        .alert(renaming?.alertTitle ?? String(localized: "Rename"),
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title).accessibilityIdentifier("sidebar-rename-title")
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                switch renaming {
                case .project(let id): store.renameProject(id, title: title)
                case .thread(let id): store.rename(id, title: title)
                case nil: break
                }
                renaming = nil
            }
            .accessibilityIdentifier("sidebar-rename-save")
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 3) {
                Text("Coincide").font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                Button {
                    searchVisible.toggle()
                    if searchVisible { searchFocused = true }
                    else { store.search = ""; searchFocused = false }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help("Search chats").accessibilityLabel("Search chats")
                Button { store.sidebarVisible = false } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help("Hide sidebar").accessibilityLabel("Hide sidebar")
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            Button { store.newThread() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.pencil").font(.system(size: 15)).frame(width: 16)
                    Text("New chat").font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowStyle())
            .padding(.horizontal, -8)
            if searchVisible || !store.search.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search chats", text: $store.search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("Search conversations")
                    if !store.search.isEmpty {
                        Button {
                            store.search = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(SidebarIconButtonStyle(size: 22))
                        .help("Clear search").accessibilityLabel("Clear search")
                    }
                }
                .font(.system(size: 13))
                .padding(.leading, 10).padding(.trailing, 5)
                .frame(height: 34)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, -8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var bottomMenu: some View {
        HStack {
            Menu {
                Button("New Project…", action: onNewProject)
                Button("Open Folder…") { store.addProject() }
                if let onImportAgentProjects {
                    Button("Import Agent Projects…", action: onImportAgentProjects)
                }
            } label: {
                Label("Add project", systemImage: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .modifier(SidebarControlHover())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(ChatChrome.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(ChatChrome.separator).frame(height: 1) }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26, alignment: .leading)
    }

    private func emptyState(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12))
            Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 8)
    }

    private func projectRow(_ project: WorkspaceProject) -> some View {
        let expanded = store.isProjectExpanded(project.id)
        return Button {
            store.setProjectExpanded(project.id, expanded: !expanded)
            store.selectedProjectID = project.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 16)
                Text(project.name).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .help(project.name + "\n" + project.path)
        .accessibilityLabel(Text("Chats in \(project.name)"))
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
        .contextMenu {
            Button("New chat") { store.newThread(projectID: project.id) }
            Button("Rename…") { title = project.name; renaming = .project(project.id) }
            Button("Remove Project…", role: .destructive) { removing = store.projectRemovalRequest(project.id) }
        }
    }

    @ViewBuilder private func projectChats(_ project: WorkspaceProject) -> some View {
        let chats = store.visibleThreads.filter { $0.projectID == project.id }
        let shown = expandedChatLists.contains(project.id) ? chats : Array(chats.prefix(3))
        ForEach(shown.map { SidebarChatEntry(thread: $0, projectID: project.id) }) { entry in
            threadRow(entry.thread, nested: true)
        }
        if chats.count > 3 {
            Button(expandedChatLists.contains(project.id) ? "Show less" : "Show all \(chats.count) chats") {
                if !expandedChatLists.insert(project.id).inserted { expandedChatLists.remove(project.id) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .buttonStyle(SidebarRowStyle(height: 28))
            .padding(.leading, 22)
        }
    }

    private func threadRow(_ thread: CodingThread, nested: Bool = false) -> some View {
        let nestedChats = store.visibleThreads.filter { $0.projectID == thread.projectID }
        let shownInProject = store.isProjectExpanded(thread.projectID) &&
            (expandedChatLists.contains(thread.projectID) || nestedChats.prefix(3).contains { $0.id == thread.id })
        let selected = store.selectedThreadID == thread.id && (nested || !shownInProject)
        return Button { store.selectThread(thread.id) } label: {
            HStack(spacing: 6) {
                if thread.isPinned {
                    Image(systemName: "pin").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(thread.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let status = status(thread) {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .padding(.leading, nested ? 22 : 0)
        .help(thread.title)
        .accessibilityIdentifier((nested ? "project-thread-" : "thread-") + thread.id.uuidString)
        .accessibilityValue(selected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(thread.isPinned ? "Unpin" : "Pin") { store.togglePin(thread.id) }
            Button("Rename…") { title = thread.title; renaming = .thread(thread.id) }
            Button(thread.isArchived ? "Unarchive" : "Archive") { store.toggleArchive(thread.id) }
                .disabled(store.isBusy(thread.id) || store.snapshot.isConversationHistoryLocked(threadID: thread.id)
                          || store.isCheckpointRestoreLocked(threadID: thread.id) || store.isPullRequestCreationLocked(threadID: thread.id)
                          || store.isPullRequestCheckoutLocked(threadID: thread.id))
        }
    }

    private func status(_ thread: CodingThread) -> LocalizedStringKey? {
        switch thread.state {
        case .idle: nil
        case .running: "Working"
        case .awaitingApproval: "Needs input"
        case .failed: "Failed"
        case .interrupted: "Stopped"
        }
    }

    private func removalExplanation(_ request: ProjectRemovalRequest) -> String {
        var text = request.path + "\n\n" + String(localized: "This removes this project's active and archived conversations from Coincide and stops their agents and terminals. Other projects remain open.\n\nCoincide does not delete project or attachment files. Git may clean up unfinished files when an active clone is stopped. Conversation data remains in local recovery history; this is not secure erasure.")
        if !request.dirtyEditorIDs.isEmpty {
            text += "\n\n" + String(localized: "Unsaved file edits in this project will be discarded.")
        }
        return text
    }
}

/// Each placement has its own identity because a chat also appears in Recents.
private struct SidebarChatEntry: Identifiable {
    let thread: CodingThread
    let projectID: UUID?
    var id: String { (projectID?.uuidString ?? "recent") + "/" + thread.id.uuidString }
}

private struct SidebarRowStyle: ButtonStyle {
    var selected = false
    var height: CGFloat = 32
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : selected ? 0.085 : hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}

private struct SidebarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

private struct SidebarControlHover: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}

private enum SidebarRenameTarget {
    case project(UUID), thread(UUID)

    var alertTitle: String {
        switch self {
        case .project: String(localized: "Rename Project")
        case .thread: String(localized: "Rename Chat")
        }
    }
}
