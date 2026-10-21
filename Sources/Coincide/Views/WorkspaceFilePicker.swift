import CoincideCore
import SwiftUI

struct WorkspaceFilePicker: View {
    let workspace: WorkspaceStore
    let path: String
    let select: (String) -> Void
    let cancel: () -> Void
    @State private var query = ""
    @State private var entries: [WorkspaceEntry] = []
    @State private var truncated = false
    @State private var loading = false
    @State private var searchError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reference a Workspace File").font(.title2)
            TextField("Search files and folders", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("composer-file-search")
            List(entries, id: \.path) { entry in
                Button { select(entry.path) } label: {
                    Label(entry.path, systemImage: entry.isDirectory ? "folder" : "doc.text")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("composer-file-" + entry.path)
            }.frame(minHeight: 160, idealHeight: 240, maxHeight: 320)
            if loading { ProgressView().controlSize(.small) }
            if let searchError { Text(searchError).font(.caption).foregroundStyle(.red) }
            if truncated { Text("Narrow your search to see more results.").font(.caption).foregroundStyle(.secondary) }
            Text("Adds a relative file or folder link to your message. Ignored files are excluded from search.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 480)
        .task(id: query) {
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                try Task.checkCancellation(); loading = true
                let service = try workspace.fileService(path: path)
                let page = try await service.searchEntries(query: query)
                try Task.checkCancellation()
                guard workspace.canAccessWorkspaceFiles(path) else { return }
                entries = page.entries; truncated = page.truncated; searchError = nil; loading = false
            } catch is CancellationError { }
            catch { if !Task.isCancelled { entries = []; searchError = error.localizedDescription; loading = false } }
        }
    }
}
