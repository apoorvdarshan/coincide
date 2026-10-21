import CoincideCore
import SwiftUI

struct WorkspaceInspector: View {
    var store: WorkspaceStore
    let path: String
    @State private var tab = "Changes"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $tab) { Text("Changes").tag("Changes"); Text("Files").tag("Files") }.pickerStyle(.segmented).padding()
            if tab == "Changes" { ChangesView(path: path, report: { store.errorMessage = $0 }) }
            else { FilesView(path: path, report: { store.errorMessage = $0 }) }
        }
    }
}

private struct ChangesView: View {
    let path: String
    let report: (String) -> Void
    @State private var branch = ""
    @State private var files: [ChangedFile] = []
    @State private var selected: String?
    @State private var diff = ""
    @State private var staged = false
    @State private var commitMessage = ""
    @State private var statusError: String?
    @State private var loading = false
    var body: some View {
        VStack(spacing: 8) {
            HStack { Label(branch.isEmpty ? "Source control" : branch, systemImage: "arrow.triangle.branch"); Spacer(); Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading) }.padding(.horizontal)
            if let statusError { ContentUnavailableView("Git Unavailable", systemImage: "folder.badge.questionmark", description: Text(statusError)) }
            else {
                List(files, selection: $selected) { file in
                    HStack { Text(file.status).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary); Text(file.path).lineLimit(1).truncationMode(.middle) }.tag(file.path)
                        .contextMenu {
                            Button("Stage File") { Task { await perform { try await git.stage([file.path]) } } }
                            if file.isStaged { Button("Unstage File") { Task { await perform { try await git.unstage([file.path]) } } } }
                        }
                }.frame(minHeight: 100, maxHeight: 220)
                Toggle("Staged diff", isOn: $staged).padding(.horizontal)
                ScrollView([.horizontal, .vertical]) {
                    Text(diff.isEmpty ? "No changes in this view." : diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
                Divider()
                TextField("Commit message", text: $commitMessage).textFieldStyle(.roundedBorder).padding(.horizontal)
                HStack {
                    Button("Stage All") { Task { await perform { try await git.stage(files.map(\.path)) } } }.disabled(files.isEmpty || loading)
                    Spacer()
                    Button("Commit Staged") { Task { await perform { try await git.commit(message: commitMessage); commitMessage = "" } } }
                        .disabled(!files.contains(where: \.isStaged) || commitMessage.isEmpty || loading)
                }.padding([.horizontal, .bottom])
            }
        }
        .task { await refresh() }
        .onChange(of: selected) { Task { await loadDiff() } }
        .onChange(of: staged) { Task { await loadDiff() } }
    }
    private var git: GitService { GitService(root: URL(fileURLWithPath: path)) }
    private func refresh() async {
        loading = true; defer { loading = false }
        do { let snapshot = try await git.status(); branch = snapshot.branch; files = snapshot.changes; statusError = nil; await loadDiff() }
        catch { statusError = error.localizedDescription }
    }
    private func loadDiff() async {
        let selection = selected, wantsStaged = staged
        do {
            let value = try await git.diff(file: files.first { $0.path == selection }, staged: wantsStaged)
            guard selection == selected, wantsStaged == staged else { return }; diff = value
        } catch { report(error.localizedDescription) }
    }
    private func perform(_ operation: () async throws -> Void) async {
        loading = true
        do { try await operation(); await refresh() } catch { report(error.localizedDescription) }
        loading = false
    }
}

private struct FilesView: View {
    let path: String
    let report: (String) -> Void
    @State private var directory = ""
    @State private var files: [WorkspaceFile] = []
    @State private var editing: String?
    @State private var original = ""
    @State private var contents = ""
    @State private var pendingFile: WorkspaceFile?
    @State private var confirmDiscard = false
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
                TextEditor(text: $contents).font(.system(.caption, design: .monospaced)).accessibilityLabel("File editor").padding(.horizontal, 6)
            } else { ContentUnavailableView("Select a File", systemImage: "doc.text", description: Text("Open a text file to read or edit it.")) }
        }.task { loadDirectory() }
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
        do { let text = try workspace.read(file.path); editing = file.path; original = text; contents = text }
        catch { report(error.localizedDescription) }
    }
    private func save() {
        guard let editing else { return }
        do { try workspace.write(editing, text: contents, expectedContents: original); original = contents }
        catch { report(error.localizedDescription) }
    }
}
