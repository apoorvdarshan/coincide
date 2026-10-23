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
    @State private var scriptPreference: String?
    @State private var projectActions = ProjectActionsPresenter()
    @State private var projectActionCommands = ProjectActionCommands()
    @State private var settlementThread: CodingThread?
    @Environment(KeybindingsStore.self) private var keybindings: KeybindingsStore?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, onClone: { cloneSheetPresented = true }, onNewProject: { newProjectSheetPresented = true },
                        onSettle: { settlementThread = $0 }, onImportAgentProjects: { agentSessionImportSheetPresented = true })
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            NativeInspectorSplit(isPresented: store.inspectorVisible) {
                if let thread = store.selectedThread {
                    TerminalDrawerSplit(terminals: terminals, threadID: thread.id, showsDrawer: terminals.isVisible(thread.id) && store.workspaceReady(for: thread)) {
                        ChatView(store: store, threadID: thread.id, onSettle: { settlementThread = $0 }).id(thread.id).frame(minHeight: 280)
                    } drawer: {
                        TerminalPanel(terminals: terminals, thread: thread, canAdd: { store.canOpenTerminal(for: thread) },
                                      report: { store.errorMessage = $0 }, hide: { terminals.setVisible(false, threadID: thread.id) })
                            .id(thread.id)
                    }
                        .frame(minWidth: 0, maxWidth: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Coincide", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Your projects and coding agents, in a native Mac workspace.")
                    } actions: {
                        Button("Start Without a Project") { store.newScratchThread() }
                            .disabled(store.isCreatingScratchConversation)
                            .accessibilityIdentifier("scratch-empty-state")
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
            ToolbarItem {
                Button { toggleTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                    .keyboardShortcut(keybindings == nil ? KeyboardShortcut("t", modifiers: [.command, .option]) : keybindings?.menuShortcut(.terminalToggle))
                    .disabled(store.selectedThread.map { !store.workspaceReady(for: $0) } ?? true)
            }
            ToolbarItem {
                ProjectActionsToolbarControl(store: store, terminals: terminals, commands: projectActionCommands, keybindings: keybindings, requests: .init(review: { scriptPreference = $1; scriptThread = $0 },
                    addAction: { projectActions.addAction($0) }, settings: { projectActions.showSettings($0) }))
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
            ProjectScriptsSheet(store: store, thread: thread, terminals: terminals, preferredScriptID: scriptPreference,
                didRun: { terminals.setVisible(true, threadID: thread.id); scriptThread = nil }, close: { scriptThread = nil })
        }
        .projectActionsPresentation(store: store, presenter: projectActions)
        .focusedSceneValue(\.cloneRepositoryPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil ? nil : $cloneSheetPresented)
        .focusedSceneValue(\.newProjectPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil ? nil : $newProjectSheetPresented)
        .focusedSceneValue(\.settlementPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil ? nil : $settlementThread)
        .focusedSceneValue(\.terminalCommands, terminalCommandTarget)
        .focusedSceneValue(\.agentSessionImportPresentation, cloneSheetPresented || newProjectSheetPresented || agentSessionImportSheetPresented || settlementThread != nil || scriptThread != nil ? nil : $agentSessionImportSheetPresented)
        .overlay { if store.isLoading { ProgressView("Opening workspace…").padding().coincideSurface() } }
        .overlay(alignment: .topTrailing) { InAppBannerOverlay(center: .shared, hiddenThreadID: store.selectedThreadID) }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .disabled(store.isLoading)
        .task { await store.refreshExternalEditors() }
        .onAppear {
            store.registerTerminals(terminals)
            let bindings = keybindings
            terminals.integration.routeKeyEvent = { [weak bindings] event in
                bindings?.dispatcher.routeTerminalEvent(event) ?? .useDefault
            }
            if bindings != nil {
                terminals.integration.keyEquivalent = { [weak bindings] session, command in
                    bindings?.dispatcher.terminalKeyEquivalent(command, in: session.view.window)
                }
            }
        }
        .task(id: store.hasLoadedWorkspace) {
            store.restoreTerminals(terminals)
        }
        .onDisappear { store.unregisterTerminals(terminals) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in terminals.suspend() }
        .mainWindowKeyboard(store: store, keybindings: keybindings) {
            MainWindowPresentations(newProject: { newProjectSheetPresented = true }, cloneRepository: { cloneSheetPresented = true },
                importAgentProjects: { agentSessionImportSheetPresented = true }, settle: { settlementThread = $0 }, runScript: { scriptThread = $0 },
                toggleTerminal: { toggleTerminal() }, terminalVisible: { store.selectedThreadID.map(terminals.isVisible) ?? false },
                terminalTarget: { terminalCommandTarget }, projectActions: { projectActionCommands },
                newWindow: { openWindow(id: MainWindowCoordinator.sceneID) }, openRemote: { openWindow(id: RemoteWorkspaceStore.sceneID) },
                openSettings: { openSettings() }, canInteract: { terminalCommandTarget != nil })
        }
    }
    private func toggleTerminal() {
        guard let thread = store.selectedThread else { return }
        do { try terminals.toggle(for: thread, canOpen: store.canOpenTerminal(for: thread)) } catch { store.errorMessage = error.localizedDescription }
    }
    private var terminalCommandTarget: TerminalCommandTarget? {
        guard !cloneSheetPresented, !newProjectSheetPresented, !agentSessionImportSheetPresented,
              settlementThread == nil, scriptThread == nil, projectActions.settings == nil, projectActions.editor == nil else { return nil }
        return .init(terminals: terminals, thread: store.selectedThread,
            workspaceReady: store.selectedThread.map { store.workspaceReady(for: $0) } ?? false,
            canOpen: store.selectedThread.map { store.canOpenTerminal(for: $0) } ?? false,
            toggle: toggleTerminal, report: { store.errorMessage = $0 })
    }
}
