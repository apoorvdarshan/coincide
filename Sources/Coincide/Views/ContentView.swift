import CoincideCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @State private var terminals = TerminalWorkspaceStore()
    @State private var terminalVisible = false
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store).navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let thread = store.selectedThread {
                VSplitView {
                    ChatView(store: store, threadID: thread.id).id(thread.id).frame(minHeight: 280)
                    if terminalVisible {
                        TerminalPanel(terminals: terminals, thread: thread, report: { store.errorMessage = $0 }, hide: { terminalVisible = false })
                            .id(thread.id).frame(minHeight: 160, idealHeight: 260, maxHeight: 600)
                    }
                }
                    .inspector(isPresented: $store.inspectorVisible) {
                        WorkspaceInspector(store: store, path: thread.workspacePath).id(thread.workspacePath)
                            .inspectorColumnWidth(min: 280, ideal: 360, max: 600)
                    }
            } else {
                ContentUnavailableView {
                    Label("Coincide", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Your projects and coding agents, in a native Mac workspace.")
                } actions: {
                    Button("Add Project…") { store.addProject() }
                    if !store.snapshot.projects.isEmpty { Button("New Thread") { store.newThread() } }
                }
            }
        }
        .toolbar {
            ToolbarItem { Button { store.newThread() } label: { Label("New Thread", systemImage: "square.and.pencil") } }
            ToolbarItem {
                Button { terminalVisible.toggle() } label: { Label("Terminal", systemImage: "terminal") }
                    .keyboardShortcut("t", modifiers: [.command, .option]).disabled(store.selectedThread == nil)
            }
            ToolbarItem { Button { store.inspectorVisible.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") } }
        }
        .alert("Coincide", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .overlay { if store.isLoading { ProgressView("Opening workspace…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .disabled(store.isLoading)
        .onDisappear { terminals.closeAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in terminals.closeAll() }
    }
}
