import CoincideCore
import SwiftUI

struct ProjectScriptsSheet: View {
    let store: WorkspaceStore
    let thread: CodingThread
    let terminals: TerminalWorkspaceStore
    var preferredScriptID: String? = nil
    let didRun: () -> Void
    let close: () -> Void
    @State private var context: ProjectScriptContext?
    @State private var selectedID: String?
    @State private var loading = true
    @State private var running = false
    @State private var error: String?
    @State private var loadID = UUID()
    @State private var runTask: Task<Void, Never>?
    private var catalog: ProjectScriptCatalog? { context?.catalog }
    private var scripts: [ResolvedProjectScript] { catalog?.scripts ?? [] }
    private var selected: ResolvedProjectScript? { selectedID.flatMap { id in scripts.first { $0.id == id } } }
    private var project: WorkspaceProject? { store.snapshot.projects.first { $0.id == thread.projectID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run a Project Script").font(.title2)
            Text(catalog?.origin == .projectActions ? "Choose one of this project’s actions to run in this conversation’s checkout."
                 : "Choose a script from t3.json to run in this conversation’s checkout.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(thread.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle).accessibilityIdentifier("project-script-cwd")
            if loading { ProgressView("Loading project scripts…") }
            else if scripts.isEmpty {
                Text(catalog?.origin == .projectActions ? "This project has no actions. Add one in Project Settings."
                     : context?.document.exists == true ? "No scripts are defined in t3.json." : "Add scripts to t3.json at the checkout root, or add a project action, to run them here.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Script", selection: $selectedID) {
                    Text("Choose a script").tag(Optional<String>.none)
                    ForEach(scripts) { entry in
                        Text(entry.menuLabel).tag(Optional(entry.id))
                    }
                }.accessibilityIdentifier("project-script-picker")
                if let selected {
                    ScrollView {
                        Text(selected.script.command).font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(minHeight: 70, maxHeight: 170)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("project-script-command")
                    if let preview = selected.script.previewURL {
                        Text(selected.script.autoOpenPreview ? "Opens \(preview) in your browser once it responds." : "Preview: \(preview)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }
            }
            if let warning = context?.document.warning ?? context?.settingsError {
                Text(warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("project-script-error")
            }
            HStack {
                Button("Reload") { loadID = UUID() }.disabled(loading || running)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(running ? "Starting…" : "Run Script", action: run)
                    .keyboardShortcut(.defaultAction).disabled(loading || running || selected == nil)
                    .accessibilityIdentifier("run-project-script")
            }
        }.padding(24).frame(width: 500)
            .task(id: loadID) { await load() }
            .onDisappear { runTask?.cancel() }
    }
    @MainActor private func load() async {
        let previous = selectedID
        loading = true; context = nil; selectedID = nil; error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let value = try await store.projectScripts().load(for: thread)
            try Task.checkCancellation()
            context = value
            let ids = value.catalog.scripts.map(\.id)
            selectedID = [previous, preferredScriptID].compactMap { $0 }.first(where: ids.contains) ?? ids.first
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @MainActor private func run() {
        guard !running, let context, let selected else { return }
        running = true; error = nil
        runTask = Task {
            defer { running = false; runTask = nil }
            do {
                if let action = selected.action {
                    try await store.projectScripts().run(context, actionID: action.id, expectedDigest: action.digest, in: terminals)
                } else if let index = selected.fileIndex {
                    try await store.projectScripts().run(context, scriptIndex: index, in: terminals)
                }
                if let project { store.projectSettings.rememberInvokedScript(selected.id, for: project) }
                didRun()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
