import CoincideCore
import SwiftUI

struct WorkspaceInspector: View {
    var store: WorkspaceStore
    let path: String
    @State private var tab = "Changes"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $tab) { Text("Changes").tag("Changes"); Text("Files").tag("Files") }.pickerStyle(.segmented).padding()
            if tab == "Changes" { GitInspectorView(workspace: store, path: path) }
            else { FilesView(path: path, navigation: store.fileNavigation?.workspacePath == path ? store.fileNavigation : nil, report: { store.errorMessage = $0 }) }
        }
        .onChange(of: store.fileNavigation?.id, initial: true) { if store.fileNavigation?.workspacePath == path { tab = "Files" } }
    }
}

private struct FilesView: View {
    let path: String
    let navigation: FileNavigation?
    let report: (String) -> Void
    @State private var directory = ""
    @State private var files: [WorkspaceFile] = []
    @State private var editing: String?
    @State private var original = ""
    @State private var contents = ""
    @State private var pendingFile: WorkspaceFile?
    @State private var confirmDiscard = false
    @State private var editorNavigation: FileNavigation?
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { directory = (directory as NSString).deletingLastPathComponent; loadDirectory() } label: { Image(systemName: "chevron.up") }.disabled(directory.isEmpty)
                Text(directory.isEmpty ? "Workspace" : directory).lineLimit(1).truncationMode(.middle)
                Spacer(); Button { loadDirectory() } label: { Image(systemName: "arrow.clockwise") }
            }.padding(.horizontal)
            List(files) { file in
                Button {
                    if file.isDirectory { directory = file.path; loadDirectory() }
                    else if contents != original { pendingFile = file; confirmDiscard = true }
                    else { open(file) }
                } label: { Label(file.name, systemImage: file.isDirectory ? "folder" : "doc.text").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
            }.frame(minHeight: 140, maxHeight: 240)
            if let editing {
                HStack {
                    Text(editing).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(); Button("Save") { save() }.disabled(contents == original)
                }.padding(.horizontal)
                SourceEditor(text: $contents, path: editing, navigation: editorNavigation).padding(.horizontal, 6)
            } else { ContentUnavailableView("Select a File", systemImage: "doc.text", description: Text("Open a text file to read or edit it.")) }
        }.task { loadDirectory() }
        .onChange(of: navigation?.id, initial: true) {
            guard let navigation else { return }
            let file = WorkspaceFile(path: navigation.path, isDirectory: false)
            if editing == navigation.path { editorNavigation = navigation }
            else if contents != original { pendingFile = file; confirmDiscard = true }
            else { open(file) }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { if let pendingFile { open(pendingFile) }; pendingFile = nil }
            Button("Cancel", role: .cancel) { pendingFile = nil }
        }
    }
    private var workspace: WorkspaceFiles { WorkspaceFiles(root: URL(fileURLWithPath: path)) }
    private func loadDirectory() {
        do { files = try workspace.list(directory) } catch { report(error.localizedDescription) }
    }
    private func open(_ file: WorkspaceFile) {
        do { let text = try workspace.read(file.path); editing = file.path; original = text; contents = text; editorNavigation = navigation?.path == file.path ? navigation : nil }
        catch { report(error.localizedDescription) }
    }
    private func save() {
        guard let editing else { return }
        do { try workspace.write(editing, text: contents, expectedContents: original); original = contents }
        catch { report(error.localizedDescription) }
    }
}
