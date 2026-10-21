import CoincideCore
import SwiftUI

struct WorkspaceInspector: View {
    var store: WorkspaceStore
    let path: String
    @State private var tab = "Changes"
    @State private var files: FileBrowserStore?
    var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $tab) { Text("Changes").tag("Changes"); Text("Files").tag("Files") }.pickerStyle(.segmented).padding()
            if tab == "Changes" { GitInspectorView(workspace: store, path: path) }
            else if let files { WorkspaceFilesView(model: files, navigation: store.fileNavigation?.workspacePath == path ? store.fileNavigation : nil) }
            else { ProgressView("Opening workspace…") }
        }
        .onChange(of: store.fileNavigation?.id, initial: true) { if store.fileNavigation?.workspacePath == path { tab = "Files" } }
        .task(id: path) {
            do {
                let model = try store.fileBrowser(path: path)
                files = model; await model.start()
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}
