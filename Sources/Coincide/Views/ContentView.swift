import CoincideCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @State private var terminals = TerminalWorkspaceStore()
    @State private var cloneSheetPresented = false
    @State private var newProjectSheetPresented = false
    @State private var agentSessionImportSheetPresented = false
    @State private var scriptThread: CodingThread?
    @State private var settlementThread: CodingThread?
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, onClone: { cloneSheetPresented = true }, onNewProject: { newProjectSheetPresented = true },
                        onSettle: { settlementThread = $0 }, onImportAgentProjects: { agentSessionImportSheetPresented = true })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            NativeInspectorSplit(isPresented: store.inspectorVisible) {
                if let thread = store.selectedThread {
                    VSplitView {
                        ChatView(store: store, threadID: thread.id, onSettle: { settlementThread = $0 }).id(thread.id).frame(minHeight: 280)
                        if terminals.panelVisible, store.workspaceReady(for: thread) {
                            TerminalPanel(terminals: terminals, thread: thread, canAdd: { store.canOpenTerminal(for: thread) },
                                          report: { store.errorMessage = $0 }, hide: { terminals.panelVisible = false })
                                .id(thread.id).frame(minHeight: 160, idealHeight: 260, maxHeight: 600)
                        }
                    }
                        .frame(minWidth: 0, maxWidth: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Coincide", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Your projects and coding agents, in a native Mac workspace.")
                    } actions: {
                        Button("New Project…") { newProjectSheetPresented = true }
                        Button("Add Project…") { store.addProject() }
                        Button("Import Agent Projects…") { agentSessionImportSheetPresented = true }
                        if !store.snapshot.projects.isEmpty { Button("New Thread") { store.newThread() } }
                    }
                }
            } inspector: {
                if let thread = store.selectedThread {
                    if store.canPresentWorkspaceInspector(for: thread) {
                        WorkspaceInspector(store: store, path: thread.workspacePath).id(thread.workspacePath)
                    } else {
                        ContentUnavailableView("Workspace Not Ready", systemImage: "arrow.down.circle", description: Text("Files and source control become available when checkout preparation finishes."))
                    }
                } else {
                    ContentUnavailableView("No Thread Selected", systemImage: "sidebar.right", description: Text("Select a thread to browse its files and source control."))
                }
            }
        }
        .toolbar {
            ToolbarItem { Button { store.newThread() } label: { Label("New Thread", systemImage: "square.and.pencil") } }
            ToolbarItem {
                Button { toggleTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                    .keyboardShortcut("t", modifiers: [.command, .option]).disabled(store.selectedThread.map { !store.workspaceReady(for: $0) } ?? true)
            }
            ToolbarItem {
                Button { scriptThread = store.selectedThread } label: { Label("Run Script…", systemImage: "play") }
                    .disabled(store.selectedThread.map { !store.canOpenTerminal(for: $0) } ?? true)
                    .accessibilityIdentifier("project-scripts")
            }
            ToolbarItem { Button { store.inspectorVisible.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") } }
        }
        .alert("Coincide", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: $cloneSheetPresented) { CloneRepositorySheet(store: store) }
        .sheet(isPresented: $newProjectSheetPresented) { NewProjectSheet(store: store) }
        .sheet(isPresented: $agentSessionImportSheetPresented) { AgentSessionImportView(store: store.agentSessionImports) }
        .sheet(item: $settlementThread) { thread in
            SettleConversationSheet(store: store, threadID: thread.id, close: { settlementThread = nil })
        }
        .sheet(item: $scriptThread) { thread in
            ProjectScriptsSheet(store: store, thread: thread, terminals: terminals,
                didRun: { terminals.panelVisible = true; scriptThread = nil }, close: { scriptThread = nil })
        }
        .focusedSceneValue(\.cloneRepositoryPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil ? nil : $cloneSheetPresented)
        .focusedSceneValue(\.newProjectPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil ? nil : $newProjectSheetPresented)
        .focusedSceneValue(\.settlementPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil ? nil : $settlementThread)
        .focusedSceneValue(\.agentSessionImportPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil || scriptThread != nil ? nil : $agentSessionImportSheetPresented)
        .overlay { if store.isLoading { ProgressView("Opening workspace…").padding().coincideSurface() } }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .disabled(store.isLoading)
        .task { await store.refreshExternalEditors() }
        .onAppear { store.registerTerminals(terminals) }
        .task(id: store.hasLoadedWorkspace) {
            store.restoreTerminals(terminals)
        }
        .onDisappear { store.unregisterTerminals(terminals) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in terminals.suspend() }
    }
    private func toggleTerminal() {
        terminals.panelVisible.toggle()
        guard terminals.panelVisible, !terminals.isRestoring, let thread = store.selectedThread,
              terminals.sessions[thread.id, default: []].isEmpty, store.canOpenTerminal(for: thread) else { return }
        do { try terminals.add(for: thread) } catch { store.errorMessage = error.localizedDescription }
    }
}
