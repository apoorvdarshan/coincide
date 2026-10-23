import CoincideCore
import SwiftUI

struct WorkspaceInspector: View {
    var store: WorkspaceStore
    let path: String
    @State private var tab = "Changes"
    @State private var files: FileBrowserStore?
    @State private var searchFocusRequest: UUID?
    @Environment(MainWindowController.self) private var controller: MainWindowController?
    var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $tab) { Text("Changes").tag("Changes"); Text("Files").tag("Files") }.pickerStyle(.segmented).padding()
            if tab == "Changes" { GitInspectorView(workspace: store, path: path) }
            else if !store.canAccessWorkspaceFiles(path) {
                ContentUnavailableView("Workspace Held", systemImage: "pause.circle", description: Text("File access resumes after the current workspace action finishes or is inspected. Pull request recovery remains available in Changes."))
            }
            else if let files { WorkspaceFilesView(model: files, navigation: store.fileNavigation?.workspacePath == path ? store.fileNavigation : nil, searchFocusRequest: searchFocusRequest) }
            else { ProgressView("Opening workspace…") }
        }
        .onChange(of: store.fileNavigation?.id, initial: true) { if store.fileNavigation?.workspacePath == path { tab = "Files" } }
        // Go to File, Search Project Contents, Show Changes and Reopen Closed View.
        .onChange(of: controller?.inspectorRequest, initial: true) { _, request in
            guard let request else { return }
            tab = request.tab.rawValue
            if let mode = request.searchMode, store.canAccessWorkspaceFiles(path), let model = try? store.fileBrowser(path: path),
               model.searchMode != mode { model.searchMode = mode }
            if request.focusSearch { searchFocusRequest = request.id }
            controller?.consumeInspectorRequest(request.id)
        }
        .onChange(of: tab, initial: true) { _, value in controller?.inspectorTab = InspectorTab(rawValue: value) ?? .changes }
        .task(id: store.canAccessWorkspaceFiles(path)) {
            guard store.canAccessWorkspaceFiles(path) else { return }
            do {
                let model = try store.fileBrowser(path: path)
                files = model; await model.start()
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}
