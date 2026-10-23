import CoincideCore
import SwiftUI

struct RemoteFileBrowserView: View {
    @Bindable var model: RemoteFileBrowserStore
    @State private var creating = false
    @State private var newPath = ""
    @State private var reloading = false
    @State private var discarding = false
    @State private var navigation: FileNavigation?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    model.directory = model.directory.split(separator: "/").dropLast().joined(separator: "/"); model.query = ""
                } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Parent remote folder").disabled(model.directory.isEmpty)
                Text(model.directory.isEmpty ? "Workspace" : model.directory).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    newPath = model.directory.isEmpty ? "" : model.directory + "/"; creating = true
                } label: { Image(systemName: "doc.badge.plus") }
                .accessibilityLabel("New remote file").disabled(!model.session.canMutate)
                Button { Task { await model.reloadEntries() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh remote files").disabled(!model.session.canRead)
            }.padding(.horizontal)
            Picker("Search remote files", selection: $model.searchMode) {
                Text("Paths").tag(WorkspaceFileSearchMode.paths); Text("Contents").tag(WorkspaceFileSearchMode.contents)
            }.pickerStyle(.segmented).padding(.horizontal)
            TextField(model.searchMode == .paths ? "Search remote file paths" : "Search remote file contents", text: $model.query)
                .textFieldStyle(.roundedBorder).padding(.horizontal).accessibilityIdentifier("remote-file-search")
            if model.searchMode == .contents {
                HStack {
                    Toggle("Aa", isOn: $model.caseSensitive).accessibilityLabel("Remote match case")
                    Toggle("Word", isOn: $model.wholeWord).accessibilityLabel("Remote whole words")
                    Toggle(".*", isOn: $model.useRegex).accessibilityLabel("Remote regular expression")
                    Spacer()
                }.toggleStyle(.button).font(.caption).padding(.horizontal)
            }
            if model.isLoading || model.isReading { ProgressView().controlSize(.small) }
            if let error = model.listingError { message(error) }
            results.frame(minHeight: 90, maxHeight: 200)
            if let error = model.regexFallbackError { message(error) }
            if model.truncated { Text("Some results were omitted. Narrow your search to see more.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if let error = model.operationError { message(error) }
            if model.openPaths.count > 1 {
                Picker("Open remote files", selection: Binding(get: { Data((model.selectedPath ?? "").utf8) }, set: { key in
                    if let path = model.openPaths.first(where: { Data($0.utf8) == key }) { Task { await model.open(path) } }
                })) {
                    ForEach(Array(model.openPaths.enumerated()), id: \.offset) { _, path in
                        Text(path + (model.buffers[Data(path.utf8)]?.isDirty == true ? " •" : "")).tag(Data(path.utf8))
                    }
                }.padding(.horizontal)
            }
            if let document = model.document {
                HStack {
                    Text(document.relativePath).font(.caption).lineLimit(1).truncationMode(.middle)
                    if model.isDirty { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Reload") {
                        if model.isDirty { reloading = true }
                        else { Task { await model.open(document.relativePath, reload: true) } }
                    }.disabled(!model.session.canRead)
                    Button("Save") { Task { await model.save() } }.disabled(!model.canSave).accessibilityIdentifier("remote-file-save")
                }.padding(.horizontal)
                if document.truncated { Text("This remote file is too large to edit here.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if model.buffer?.hasExternalChanges == true {
                    Text("Remote files may have changed. Your editor text is retained; reload to inspect the latest file.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if !model.session.isConnected {
                    Text("Your editor buffer stays open while disconnected. Reconnect to save it.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                SourceEditor(text: Binding(get: { model.contents }, set: { model.setContents($0) }),
                    path: "remote:\(model.session.target.environmentID):\(model.session.target.threadID):\(model.session.target.rootID?.uuidString ?? "unbound"):\(Data(document.relativePath.utf8).base64EncodedString())",
                    navigation: navigation, isEditable: model.canEdit).padding(.horizontal, 6)
                if model.isDirty { Button("Discard Local Edits…") { discarding = true }.controlSize(.small).padding(.bottom, 8) }
            } else {
                ContentUnavailableView("Select a Remote File", systemImage: "doc.text", description: Text("Open a text file on the connected Mac."))
            }
        }
        .task(id: model.searchRequest) {
            do { if !model.query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }; try Task.checkCancellation(); await model.reloadEntries() }
            catch { }
        }
        .task(id: model.session.isConnected) { if model.session.canRead { await model.reloadEntries() } }
        .confirmationDialog("Reload and discard this file's local edits?", isPresented: $reloading) {
            Button("Reload Remote File", role: .destructive) {
                if let path = model.selectedPath { Task { await model.open(path, reload: true, discardChanges: true) } }
            }
        }
        .confirmationDialog("Discard this file's local edits?", isPresented: $discarding) {
            Button("Discard Local Edits", role: .destructive) { model.discardCurrentEdits() }
        }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Remote File").font(.title2)
                TextField("Path relative to remote workspace", text: $newPath).textFieldStyle(.roundedBorder)
                Text("Existing remote files are preserved. Missing parent folders are created on the remote Mac.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer(); Button("Cancel") { creating = false }
                    Button("Create") {
                        let path = newPath; creating = false
                        Task { await model.createFile(path: path) }
                    }.disabled(!model.session.canMutate || newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 460)
        }
    }

    private var results: some View {
        List {
            if model.searchMode == .contents {
                ForEach(Array(model.contentMatches.enumerated()), id: \.offset) { _, match in
                    Button {
                        Task {
                            if await model.open(match.path) {
                                navigation = .init(workspacePath: model.session.target.workspacePath, path: match.path, line: match.lineNumber)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(match.path):\(match.lineNumber)").font(.caption).lineLimit(1)
                            Text(match.lineContent).font(.system(.caption, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            } else {
                ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                    Button {
                        if entry.isDirectory { model.directory = entry.path; model.query = "" }
                        else { navigation = nil; Task { await model.open(entry.path) } }
                    } label: {
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                            Text(entry.path.split(separator: "/").last.map(String.init) ?? entry.path).lineLimit(1)
                            Spacer()
                            if entry.ignored == true { Text("Ignored").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("remote-file-entry-" + entry.path)
                }
            }
        }
    }
    private func message(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
}
