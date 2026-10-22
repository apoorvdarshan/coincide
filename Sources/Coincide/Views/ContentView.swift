import CoincideCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @State private var terminals = TerminalWorkspaceStore()
    @State private var terminalVisible = false
    @State private var cloneSheetPresented = false
    @State private var newProjectSheetPresented = false
    @State private var scriptThread: CodingThread?
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, onClone: { cloneSheetPresented = true }, onNewProject: { newProjectSheetPresented = true })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let thread = store.selectedThread {
                VSplitView {
                    ChatView(store: store, threadID: thread.id).id(thread.id).frame(minHeight: 280)
                    if terminalVisible, store.workspaceReady(for: thread) {
                        TerminalPanel(terminals: terminals, thread: thread, canAdd: { store.canOpenTerminal(for: thread) },
                                      report: { store.errorMessage = $0 }, hide: { terminalVisible = false })
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
                    if !store.snapshot.projects.isEmpty { Button("New Thread") { store.newThread() } }
                }
            }
        }
        .toolbar {
            ToolbarItem { Button { store.newThread() } label: { Label("New Thread", systemImage: "square.and.pencil") } }
            ToolbarItem {
                Button { terminalVisible.toggle() } label: { Label("Terminal", systemImage: "terminal") }
                    .keyboardShortcut("t", modifiers: [.command, .option]).disabled(store.selectedThread.map { !store.workspaceReady(for: $0) } ?? true)
            }
            ToolbarItem {
                Button { scriptThread = store.selectedThread } label: { Label("Run Script…", systemImage: "play") }
                    .disabled(store.selectedThread.map { !store.canOpenTerminal(for: $0) } ?? true)
                    .accessibilityIdentifier("project-scripts")
            }
            ToolbarItem { Button { store.inspectorVisible.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") } }
        }
        // Keep the inspector host stable while selection and the detail's native split view change.
        // Nesting it inside that conditional split view can re-enter AppKit's toolbar/constraint pass.
        .inspector(isPresented: $store.inspectorVisible) {
            Group {
                if let thread = store.selectedThread {
                    if store.workspaceReady(for: thread) {
                        WorkspaceInspector(store: store, path: thread.workspacePath).id(thread.workspacePath)
                    } else {
                        ContentUnavailableView("Workspace Not Ready", systemImage: "arrow.down.circle", description: Text("Files and source control become available when checkout preparation finishes."))
                    }
                } else {
                    ContentUnavailableView("No Thread Selected", systemImage: "sidebar.right", description: Text("Select a thread to browse its files and source control."))
                }
            }.inspectorColumnWidth(min: 280, ideal: 360, max: 600)
        }
        .alert("Coincide", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: $cloneSheetPresented) { CloneRepositorySheet(store: store) }
        .sheet(isPresented: $newProjectSheetPresented) { NewProjectSheet(store: store) }
        .sheet(item: $scriptThread) { thread in
            ProjectScriptsSheet(store: store, thread: thread, terminals: terminals,
                didRun: { terminalVisible = true; scriptThread = nil }, close: { scriptThread = nil })
        }
        .focusedSceneValue(\.cloneRepositoryPresentation, cloneSheetPresented || newProjectSheetPresented ? nil : $cloneSheetPresented)
        .focusedSceneValue(\.newProjectPresentation, cloneSheetPresented || newProjectSheetPresented ? nil : $newProjectSheetPresented)
        .overlay { if store.isLoading { ProgressView("Opening workspace…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .disabled(store.isLoading)
        .task { await store.refreshExternalEditors() }
        .onAppear { store.registerTerminals(terminals) }
        .onDisappear { terminals.closeAll(); store.unregisterTerminals(terminals) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in terminals.closeAll() }
    }
}
