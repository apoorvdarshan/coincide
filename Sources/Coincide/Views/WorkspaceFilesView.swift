import CoincideCore
import SwiftUI

struct WorkspaceFilesView: View {
    @Bindable var model: FileBrowserStore
    let navigation: FileNavigation?
    @State private var pendingNavigation: FileNavigation?
    @State private var pendingPath: String?
    @State private var discard = false
    @State private var creating = false
    @State private var newPath = ""
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { model.directory = (model.directory as NSString).deletingLastPathComponent; model.query = "" } label: { Image(systemName: "chevron.up") }
                    .disabled(model.directory.isEmpty).help("Parent folder").accessibilityLabel("Parent folder")
                Text(model.directory.isEmpty ? "Workspace" : model.directory).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { newPath = model.directory.isEmpty ? "" : model.directory + "/"; creating = true } label: { Image(systemName: "doc.badge.plus") }
                    .help("New file").accessibilityLabel("New file").disabled(model.isDirty || model.isSaving)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh files").accessibilityLabel("Refresh files")
            }.padding(.horizontal)
            TextField("Search workspace files", text: $model.query).textFieldStyle(.roundedBorder).padding(.horizontal)
                .accessibilityIdentifier("workspace-file-search")
            if model.isLoading { ProgressView().controlSize(.small) }
            if let error = model.listingError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            List(model.entries, id: \.path) { entry in
                Button {
                    if entry.isDirectory { model.directory = entry.path; model.query = "" }
                    else { requestOpen(entry.path) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                        Text(model.query.isEmpty ? entry.name : entry.path).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if entry.ignored == true { Text("Ignored").font(.caption2).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("workspace-entry-" + entry.path)
            }.frame(minHeight: 110, maxHeight: 220)
            if model.truncated { Text("Some results were omitted. Narrow your search to see more.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if let error = model.operationError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            if let document = model.document {
                HStack {
                    Text(document.relativePath).font(.caption).lineLimit(1).truncationMode(.middle)
                    if model.isDirty { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Reload") { requestOpen(document.relativePath) }.disabled(model.isSaving)
                    Button("Save") { Task { await model.save() } }.disabled(!model.canWrite || !model.isDirty)
                        .accessibilityIdentifier("workspace-file-save")
                }.padding(.horizontal)
                if document.truncated {
                    Text("Preview of \(ByteCountFormatter.string(fromByteCount: Int64(document.byteLength), countStyle: .file)). This file is too large to edit here.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if model.hasExternalChanges && model.isDirty {
                    Text("Files changed on disk. Your unsaved edits are retained; reload to discard them.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                SourceEditor(text: Binding(get: { model.contents }, set: { model.setContents($0) }), path: document.relativePath, navigation: model.navigation, isEditable: model.canWrite)
                    .padding(.horizontal, 6)
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc.text", description: Text("Open a text file to read or edit it."))
            }
        }
        .task(id: model.query + "\0" + model.directory) {
            do { if !model.query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }; try Task.checkCancellation(); await model.reloadEntries() }
            catch { }
        }
        .onChange(of: navigation?.id, initial: true) {
            guard let navigation, model.consumeNavigation(navigation) else { return }
            if model.document?.relativePath == navigation.path { model.navigate(navigation) }
            else { requestOpen(navigation.path, navigation: navigation) }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $discard) {
            Button("Discard Changes", role: .destructive) {
                let path = pendingPath, navigation = pendingNavigation
                pendingPath = nil; pendingNavigation = nil
                if let path { Task { await model.open(path, navigation: navigation, discardChanges: true) } }
            }
            Button("Cancel", role: .cancel) { pendingPath = nil; pendingNavigation = nil }
        }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New File").font(.title2)
                TextField("Path relative to workspace", text: $newPath).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("workspace-new-file-path")
                Text("Existing files are preserved. Missing parent folders are created.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel") { creating = false }; Button("Create") {
                    let path = newPath; creating = false
                    Task { await model.createFile(path: path) }
                }.disabled(newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 420)
        }
    }
    private func requestOpen(_ path: String, navigation: FileNavigation? = nil) {
        if model.isDirty { pendingPath = path; pendingNavigation = navigation; discard = true }
        else { Task { await model.open(path, navigation: navigation) } }
    }
}
