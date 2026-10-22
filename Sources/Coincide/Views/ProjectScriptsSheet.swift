import CoincideCore
import SwiftUI

struct ProjectScriptsSheet: View {
    let store: WorkspaceStore
    let thread: CodingThread
    let terminals: TerminalWorkspaceStore
    let didRun: () -> Void
    let close: () -> Void
    @State private var context: ProjectScriptContext?
    @State private var selectedIndex: Int?
    @State private var loading = true
    @State private var running = false
    @State private var error: String?
    @State private var loadID = UUID()
    @State private var runTask: Task<Void, Never>?
    private var scripts: [ProjectScript] { context?.document.configuration?.scripts ?? [] }
    private var selected: ProjectScript? { selectedIndex.flatMap { scripts.indices.contains($0) ? scripts[$0] : nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run a Project Script").font(.title2)
            Text("Choose a script from t3.json to run in this conversation’s checkout.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(thread.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle).accessibilityIdentifier("project-script-cwd")
            if loading { ProgressView("Loading project scripts…") }
            else if scripts.isEmpty {
                Text(context?.document.exists == true ? "No scripts are defined in t3.json." : "Add scripts to t3.json at the checkout root to run them here.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Script", selection: $selectedIndex) {
                    Text("Choose a script").tag(Optional<Int>.none)
                    ForEach(Array(scripts.enumerated()), id: \.offset) { index, script in
                        Text(script.name).tag(Optional(index))
                    }
                }.accessibilityIdentifier("project-script-picker")
                if let selected {
                    ScrollView {
                        Text(selected.command).font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(minHeight: 70, maxHeight: 170)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("project-script-command")
                }
            }
            if let warning = context?.document.warning {
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
        loading = true; context = nil; selectedIndex = nil; error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let value = try await store.projectScripts().load(for: thread)
            try Task.checkCancellation()
            context = value
            if value.document.configuration?.scripts.isEmpty == false { selectedIndex = 0 }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @MainActor private func run() {
        guard !running, let context, let selectedIndex else { return }
        running = true; error = nil
        runTask = Task {
            defer { running = false; runTask = nil }
            do {
                try await store.projectScripts().run(context, scriptIndex: selectedIndex, in: terminals)
                didRun()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
