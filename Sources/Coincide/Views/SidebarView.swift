import CoincideCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    let onClone: () -> Void
    let onNewProject: () -> Void
    @State private var renaming: SidebarRenameTarget?
    @State private var title = ""
    var body: some View {
        List(selection: $store.selectedThreadID) {
            ForEach(store.orderedProjects) { project in
                Section {
                    ForEach(store.sidebarThreads(projectID: project.id)) { thread in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(thread.title).lineLimit(1)
                                if let clone = project.clone, !clone.isReady {
                                    Text(ProjectClonePresentation.title(clone)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                } else if thread.state != .idle {
                                    Text(thread.state == .awaitingApproval ? "Needs your input" : thread.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: thread.isPinned ? "pin" : thread.state == .running ? "circle.dotted" : "bubble.left")
                        }
                        .tag(thread.id)
                        .contextMenu {
                            Button(thread.isPinned ? "Unpin" : "Pin") { store.togglePin(thread.id) }
                            Button("Rename…") { title = thread.title; renaming = .thread(thread.id) }
                            Button(thread.isArchived ? "Unarchive" : "Archive") { store.toggleArchive(thread.id) }.disabled(store.isBusy(thread.id))
                            Button("Reveal Workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath) }
                                .disabled(project.clone.map { !$0.isReady } ?? false)
                        }
                    }
                    if store.isProjectExpanded(project.id) {
                        Button { store.newThread(projectID: project.id) } label: { Label("New Thread", systemImage: "plus") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                } header: { projectHeader(project) }
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
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().help("Sort Projects")
                    .accessibilityLabel("Sort projects").accessibilityValue(store.projectSortMode.title)
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search conversations", text: $store.search).textFieldStyle(.plain).accessibilityLabel("Search conversations")
                }.font(.system(size: 12)).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }.padding(.horizontal, 16).padding(.vertical, 14)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New Project…", action: onNewProject)
                    Button("Open Folder…") { store.addProject() }
                    Button("Clone Repository…", action: onClone)
                } label: { Label("Add Project", systemImage: "folder.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Toggle(isOn: $store.showArchived) { Image(systemName: "archivebox") }.toggleStyle(.button).help("Show archived threads")
            }.buttonStyle(.borderless).padding(12)
        }
        .onChange(of: store.selectedThreadID) { if let thread = store.selectedThread { store.selectedProjectID = thread.projectID } }
        .alert(renaming?.alertTitle ?? String(localized: "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                switch renaming {
                case .project(let id): store.renameProject(id, title: title)
                case .thread(let id): store.rename(id, title: title)
                case nil: break
                }
                renaming = nil
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var projectMoveAction: ((IndexSet, Int) -> Void)? {
        guard store.projectSortMode == .manual else { return nil }
        return { offsets, destination in store.moveProjects(fromOffsets: offsets, toOffset: destination) }
    }

    private func projectHeader(_ project: WorkspaceProject) -> some View {
        Button { store.setProjectExpanded(project.id, expanded: !store.isProjectExpanded(project.id)) } label: {
            HStack(spacing: 5) {
                Image(systemName: store.isProjectExpanded(project.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Text(project.name).lineLimit(1)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isProjectExpanded(project.id) ? Text("Collapse \(project.name)") : Text("Expand \(project.name)"))
        .accessibilityValue(store.isProjectExpanded(project.id) ? Text("Expanded") : Text("Collapsed"))
        .contextMenu {
            Button("New Thread") { store.newThread(projectID: project.id) }
            Button("Rename Project…") { title = project.name; renaming = .project(project.id) }
            if store.projectSortMode == .manual {
                if store.orderedProjects.first?.id != project.id { Button("Move Up") { store.moveProject(project.id, by: -1) } }
                if store.orderedProjects.last?.id != project.id { Button("Move Down") { store.moveProject(project.id, by: 1) } }
            }
        }
    }

    private func sortModeItem(_ mode: ProjectSortMode) -> some View {
        Button { store.setProjectSortMode(mode) } label: {
            if store.projectSortMode == mode { Label(mode.title, systemImage: "checkmark") }
            else { Text(mode.title) }
        }
    }
}

private enum SidebarRenameTarget {
    case project(UUID), thread(UUID)
    var alertTitle: String {
        switch self {
        case .project: String(localized: "Rename Project")
        case .thread: String(localized: "Rename Thread")
        }
    }
}
