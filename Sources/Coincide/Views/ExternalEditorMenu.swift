import CoincideCore
import SwiftUI

struct ExternalEditorMenu: View {
    let store: WorkspaceStore
    let workspacePath: String
    var relativePath: String? = nil
    var line: Int? = nil
    var title = "Open With…"
    var compact = false
    var body: some View {
        Menu {
            Button("Preferred Editor") { open() }
            ForEach(store.availableExternalEditors, id: \.id) { editor in
                Button(editor.name) { open(editor.id) }
            }
            Divider()
            Button("Reveal in Finder") { open(reveal: true) }
            Button("Refresh Available Editors") { Task { await store.refreshExternalEditors(forceRefresh: true) } }
        } label: {
            if compact { Image(systemName: "arrow.up.forward.app") }
            else { Text(title) }
        }
        .accessibilityLabel(title)
        .disabled(!store.canAccessWorkspaceFiles(workspacePath))
        .help("External editors open the saved version on disk. Unsaved edits in Coincide are retained.")
    }
    private func open(_ editor: ExternalEditorID? = nil, reveal: Bool = false) {
        Task {
            do {
                let location = try line.map { try ExternalEditorLocation(line: $0) }
                let target = ExternalEditorTarget(workspaceRoot: URL(fileURLWithPath: workspacePath), relativePath: relativePath, location: location)
                let service = store.externalEditors()
                if reveal { try await service.reveal(target) }
                else { try await service.open(target, editor: editor) }
            } catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

struct ExternalEditorSettings: View {
    let store: WorkspaceStore
    @AppStorage(NativeExternalEditorService.preferredEditorDefaultsKey) private var preferred = ""
    private var validatedPreference: String { ExternalEditorID(rawValue: preferred)?.rawValue ?? "" }
    var body: some View {
        Section("External Editor") {
            Picker("Preferred editor", selection: Binding(get: { validatedPreference }, set: { preferred = $0 })) {
                Text("Automatic").tag("")
                ForEach(store.availableExternalEditors, id: \.id) { Text($0.name).tag($0.id.rawValue) }
                if let id = ExternalEditorID(rawValue: preferred), !store.availableExternalEditors.contains(where: { $0.id == id }) {
                    Text("\(ExternalEditorDescriptor(id: id).name) (unavailable)").tag(id.rawValue)
                }
            }
            Button("Refresh Available Editors") { Task { await store.refreshExternalEditors(forceRefresh: true) } }
            Text("Automatic uses an installed editor, or the default macOS application.").font(.caption).foregroundStyle(.secondary)
            Text("External apps receive the version saved on disk. Coincide keeps unsaved edits here.")
                .font(.caption).foregroundStyle(.secondary)
        }.task { await store.refreshExternalEditors() }
    }
}
