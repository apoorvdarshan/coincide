import CoincideCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @State private var newProjectSheetPresented = false
    @State private var agentSessionImportSheetPresented = false
    @Environment(KeybindingsStore.self) private var keybindings: KeybindingsStore?
    @Environment(\.openWindow) private var openWindow

    private var canInteract: Bool { !newProjectSheetPresented && !agentSessionImportSheetPresented && !store.isLoading }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceRail(store: store)
            if store.showingSettings {
                SettingsView(store: store, embedded: true)
            } else {
                if store.sidebarVisible {
                    SidebarView(store: store, onNewProject: { newProjectSheetPresented = true },
                                onImportAgentProjects: { agentSessionImportSheetPresented = true })
                        .frame(width: 248)
                        .background(ChatChrome.sidebar)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
                        .overlay(alignment: .trailing) { Rectangle().fill(ChatChrome.separator).frame(width: 1) }
                }
                conversation
            }
        }
        .font(.system(size: 13))
        .background(ChatChrome.canvas)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert("Coincide", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: $newProjectSheetPresented) { NewProjectSheet(store: store) }
        .sheet(isPresented: $agentSessionImportSheetPresented) { AgentSessionImportView(store: store.agentSessionImports) }
        .focusedSceneValue(\.newProjectPresentation, canInteract ? $newProjectSheetPresented : nil)
        .focusedSceneValue(\.agentSessionImportPresentation, canInteract ? $agentSessionImportSheetPresented : nil)
        .overlay { if store.isLoading { ProgressView("Opening conversations…").padding(20).coincideSurface() } }
        .overlay(alignment: .topTrailing) { InAppBannerOverlay(center: .shared, hiddenThreadID: store.selectedThreadID) }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .disabled(store.isLoading)
        .mainWindowKeyboard(store: store, keybindings: keybindings) {
            MainWindowPresentations(newProject: { newProjectSheetPresented = true },
                importAgentProjects: { agentSessionImportSheetPresented = true },
                newWindow: { openWindow(id: MainWindowCoordinator.sceneID) },
                openSettings: { store.showingSettings = true }, canInteract: { canInteract })
        }
    }

    @ViewBuilder private var conversation: some View {
        if let thread = store.selectedThread {
            ChatView(store: store, threadID: thread.id).id(thread.id)
        } else {
            VStack(spacing: 24) {
                Spacer()
                Text("What should we work on?").font(.system(size: 25))
                Button { store.newThread() } label: {
                    HStack {
                        Text("Start a conversation").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "square.and.pencil")
                    }
                    .padding(22).frame(maxWidth: 640)
                    .background(ChatChrome.composer, in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain).disabled(store.isCreatingScratchConversation)
                HStack(spacing: 20) {
                    Button("Choose project…") { store.addProject() }
                    Button("Import conversations…") { agentSessionImportSheetPresented = true }
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
