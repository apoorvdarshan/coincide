import CoincideCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    @State private var renaming: UUID?
    @State private var title = ""
    var body: some View {
        List(selection: $store.selectedThreadID) {
            ForEach(store.snapshot.projects) { project in
                Section {
                    ForEach(store.visibleThreads.filter { $0.projectID == project.id }) { thread in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(thread.title).lineLimit(1)
                                if thread.state != .idle { Text(thread.state == .awaitingApproval ? "Needs your input" : thread.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: {
                            Image(systemName: thread.isPinned ? "pin" : thread.state == .running ? "circle.dotted" : "bubble.left")
                        }
                        .tag(thread.id)
                        .contextMenu {
                            Button(thread.isPinned ? "Unpin" : "Pin") { store.togglePin(thread.id) }
                            Button("Rename…") { title = thread.title; renaming = thread.id }
                            Button(thread.isArchived ? "Unarchive" : "Archive") { store.toggleArchive(thread.id) }.disabled(store.isBusy(thread.id))
                            Button("Reveal Workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath) }
                        }
                    }
                    Button { store.newThread(projectID: project.id) } label: { Label("New Thread", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
                } header: { Text(project.name) }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.search, prompt: "Search conversations")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { store.addProject() } label: { Label("Add Project", systemImage: "folder.badge.plus") }
                Spacer()
                Toggle(isOn: $store.showArchived) { Image(systemName: "archivebox") }.toggleStyle(.button).help("Show archived threads")
            }.buttonStyle(.borderless).padding(12)
        }
        .onChange(of: store.selectedThreadID) { if let thread = store.selectedThread { store.selectedProjectID = thread.projectID } }
        .alert("Rename Thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { if let id = renaming { store.rename(id, title: title) }; renaming = nil }
        }
    }
}
