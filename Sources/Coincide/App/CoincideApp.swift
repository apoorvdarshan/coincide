import AppKit
import CoincideMarkdown
import CoincideCore
import Darwin
import SwiftUI

@main
enum CoincideMain {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst() == ["--verify-owned-codex-keychain"] {
            do {
                try CodexKeychainVerification.run()
                print("Owned Codex Data Protection Keychain create/read/update/delete passed; synthetic item removed.")
            } catch {
                FileHandle.standardError.write(Data("Owned Codex Data Protection Keychain acceptance failed; no saved account was accessed.\n".utf8))
                exit(EXIT_FAILURE)
            }
            return
        }
        if CommandLine.arguments.dropFirst() == ["--verify-resources"] {
            guard let image = NativeMath.image(#"x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#, dark: false),
                  image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
                FileHandle.standardError.write(Data("Native math resources could not be rendered.\n".utf8)); exit(EXIT_FAILURE)
            }
            print("Native math resources rendered successfully."); return
        }
        CoincideApp.main()
    }
}

struct CoincideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: WorkspaceStore
    @State private var remoteStore: RemoteWorkspaceStore
    @State private var mainWindows: MainWindowCoordinator
    @State private var keybindings: KeybindingsStore
    @FocusedValue(\.cloneRepositoryPresentation) private var cloneRepositoryPresentation: Binding<Bool>?
    @FocusedValue(\.newProjectPresentation) private var newProjectPresentation: Binding<Bool>?
    @FocusedValue(\.settlementPresentation) private var settlementPresentation: Binding<CodingThread?>?
    @FocusedValue(\.agentSessionImportPresentation) private var agentSessionImportPresentation: Binding<Bool>?
    @FocusedValue(\.remoteWorkspacePresentation) private var remotePresentation: RemoteWorkspacePresentation?
    @FocusedValue(\.mainWindowController) private var keyboardController: MainWindowController?
    private var defaultWindowSize: CGSize {
        MainWindowSizing.size(fitting: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 820))
    }
    init() {
        do {
            let url = try AppLaunchConfiguration.databaseURL(bundleIdentifier: Bundle.main.bundleIdentifier,
                                                            environment: ProcessInfo.processInfo.environment)
            let store = WorkspaceStore(databaseURL: url, appMCPEnabled: AppLaunchConfiguration.appMCPEnabled(bundleIdentifier: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment))
            let mainWindows = MainWindowCoordinator()
            let dataRoot = url?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Coincide", isDirectory: true)
            let remoteRoot = dataRoot.appendingPathComponent("RemoteEnvironments", isDirectory: true)
            let remoteStore: RemoteWorkspaceStore
            if let fixtureFactory = try NativeRemoteUITestingConnection.clientFactory(bundleIdentifier: Bundle.main.bundleIdentifier,
                bundleURL: Bundle.main.bundleURL, environment: ProcessInfo.processInfo.environment) {
                remoteStore = RemoteWorkspaceStore(root: remoteRoot, clientFactory: fixtureFactory)
            } else {
                remoteStore = RemoteWorkspaceStore(root: remoteRoot)
            }
            let keybindings = KeybindingsStore(fileURL: dataRoot.appendingPathComponent("keybindings.json"))
            _keybindings = State(initialValue: keybindings)
            Task { await keybindings.start() }
            _store = State(initialValue: store)
            _remoteStore = State(initialValue: remoteStore)
            _mainWindows = State(initialValue: mainWindows)
            delegate.attach(store, mainWindows: mainWindows, remoteStore: remoteStore, keybindings: keybindings)
        } catch {
            FileHandle.standardError.write(Data("Coincide UI-test workspace configuration is invalid.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    var body: some Scene {
        WindowGroup("Coincide", id: MainWindowCoordinator.sceneID) {
            ContentView(store: store).environment(keybindings)
                .frame(minWidth: 900, minHeight: 600)
                .background(MainWindowRegistration(coordinator: mainWindows))
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .commands {
            RemoteWorkspaceCommands(shortcut: keybindings.menuShortcut(.remoteOpen), allowsInvocation: { !keybindings.dispatcher.declinedCurrentEvent() })
            TerminalCommands(keybindings: keybindings)
            NavigationCommands(keybindings: keybindings)
            MainWindowCommands(coordinator: mainWindows, newWindowShortcut: keybindings.menuShortcut(.windowNew), allowsInvocation: { !keybindings.dispatcher.declinedCurrentEvent() }) {
                Button("New Thread") {
                    guard !keybindings.dispatcher.declinedCurrentEvent() else { return }
                    if let remotePresentation { remotePresentation.newThread.wrappedValue = true }
                    else if let keyboardController { keyboardController.perform(.chatNew) }
                    else { delegate.newThread() }
                }.keyboardShortcut(keybindings.menuShortcut(.chatNew))
                    .disabled(remotePresentation != nil
                        ? !remoteStore.canWrite || remoteStore.selectedProjectID == nil
                        : keyboardController.map { !$0.canPerform(.chatNew) } ?? false)
                Button("New Project…") { if !keybindings.dispatcher.declinedCurrentEvent() { newProjectPresentation?.wrappedValue = true } }
                    .keyboardShortcut(keybindings.menuShortcut(.projectNew)).disabled(newProjectPresentation == nil)
                Button("Add Project…") {
                    guard !keybindings.dispatcher.declinedCurrentEvent() else { return }
                    if let remotePresentation { remotePresentation.addProject.wrappedValue = true }
                    else { store.addProject() }
                }.keyboardShortcut(keybindings.menuShortcut(.projectAdd)).disabled(remotePresentation != nil && !remoteStore.canWrite)
                Button("Clone Repository…") { if !keybindings.dispatcher.declinedCurrentEvent() { cloneRepositoryPresentation?.wrappedValue = true } }
                    .keyboardShortcut(keybindings.menuShortcut(.projectClone)).disabled(cloneRepositoryPresentation == nil)
                Button("Import Agent Projects…") { if !keybindings.dispatcher.declinedCurrentEvent() { agentSessionImportPresentation?.wrappedValue = true } }
                    .keyboardShortcut(keybindings.menuShortcut(.projectImport))
                    .disabled(remotePresentation != nil || agentSessionImportPresentation == nil)
            }
            CommandMenu("Thread") {
                ThreadMenuItems(keybindings: keybindings)
                if remotePresentation != nil {
                    Button("Resume Queue") {
                        if let thread = remoteStore.selectedThread {
                            Task { await remoteStore.perform(.resumeQueue(threadID: thread.id, expectedConfiguration: .init(thread: thread))) }
                        }
                    }.disabled(!remoteStore.canWrite || remoteStore.selectedThread?.queuePaused != true)
                } else if let thread = store.selectedThread, let settlement = thread.settlement {
                    Button("Resume Conversation") {
                        guard !keybindings.dispatcher.declinedCurrentEvent() else { return }
                        store.requestResume(thread.id, generationID: settlement.id)
                    }
                        .keyboardShortcut(keybindings.menuShortcut(.threadSettle)).disabled(settlement.phase == .resuming)
                } else {
                    Button("Settle Conversation…") {
                        guard !keybindings.dispatcher.declinedCurrentEvent() else { return }
                        if let thread = store.selectedThread { settlementPresentation?.wrappedValue = thread }
                    }.keyboardShortcut(keybindings.menuShortcut(.threadSettle))
                        .disabled(settlementPresentation == nil || (store.selectedThread.map { !store.canSettle($0) } ?? true))
                }
                Button("Stop Turn") {
                    guard !keybindings.dispatcher.declinedCurrentEvent() else { return }
                    if remotePresentation != nil {
                        if let thread = remoteStore.selectedThread { Task { await remoteStore.stop(thread) } }
                    } else if let thread = store.selectedThread {
                        Task { await store.interrupt(thread.id, expectedRunID: thread.activeRun?.id, expectedRuntimeID: thread.runtimeID) }
                    }
                }
                    .keyboardShortcut(keybindings.menuShortcut(.threadStop))
                    .disabled(remotePresentation != nil
                        ? !remoteStore.canWrite || remoteStore.selectedThread?.activeRun == nil || remoteStore.selectedThread?.runtimeID == nil
                        : store.selectedThreadID.map { !store.isBusy($0) } ?? true)
                Button("Toggle Inspector") {
                    guard !keybindings.dispatcher.declinedCurrentEvent() else { return }
                    if let remotePresentation { remotePresentation.inspectorVisible.wrappedValue.toggle() }
                    else { store.inspectorVisible.toggle() }
                }.keyboardShortcut(keybindings.menuShortcut(.rightPanelToggle))
            }
        }
        Window("Remote Workspaces", id: RemoteWorkspaceStore.sceneID) {
            RemoteWorkspaceView(store: remoteStore).frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        Settings { SettingsView(store: store).environment(keybindings) }
    }
}

enum MainWindowSizing {
    static func size(fitting display: CGSize) -> CGSize {
        CGSize(width: min(1280, max(1, display.width)), height: min(820, max(1, display.height)))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?
    private weak var remoteStore: RemoteWorkspaceStore?
    private weak var keybindings: KeybindingsStore?
    private var mainWindows: MainWindowCoordinator?
    private var pendingProjects: [URL] = []
    private var startup: Task<Void, Never>?
    private var ready = false
    private var isQuitting = false
    func attach(_ store: WorkspaceStore, mainWindows: MainWindowCoordinator, remoteStore: RemoteWorkspaceStore? = nil, keybindings: KeybindingsStore? = nil) {
        self.store = store
        self.remoteStore = remoteStore
        self.keybindings = keybindings
        self.mainWindows = mainWindows
        startLoading()
    }
    private func startLoading() {
        guard startup == nil, let store else { return }
        startup = Task { [weak self, weak store] in
            guard let store else { return }
            await store.load()
            guard let self, self.store === store, !self.isQuitting else { return }
            self.ready = true
            let projects = self.pendingProjects; self.pendingProjects.removeAll()
            for url in projects { store.addProject(at: url) }
            self.mainWindows?.presentIfNeeded()
        }
    }
    func waitForStartup() async { await startup?.value }
    func newThread() {
        guard !isQuitting else { return }
        mainWindows?.presentIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            await self.waitForStartup()
            guard !self.isQuitting else { return }
            self.store?.newThread()
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isQuitting else { return }
        mainWindows?.presentIfNeeded()
        if ready, let store { for url in urls { store.addProject(at: url) } }
        else { pendingProjects.append(contentsOf: urls) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isQuitting else { return false }
        // Settings or a panel can be visible without a conversation window.
        mainWindows?.presentIfNeeded()
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        startLoading()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !isQuitting else { return .terminateLater }
        if !store.composerDraftTools.imports.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit with unfinished attachments?")
            alert.informativeText = String(localized: "Some chosen or pasted attachments are not yet attached to a draft. Their captured retry copies are kept only for this session. Cancel to retry or remove them, or quit and choose or paste them again later. Successfully attached files and saved prompts remain available.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit and Discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        if store.hasUnsavedFileEdits || remoteStore?.hasUnsavedWorkspaceEdits == true {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit with unsaved file edits?")
            alert.informativeText = String(localized: "Unsaved file edits and commit messages will be discarded. Cancel to return to your work and save it before quitting. Unconfirmed remote operation records remain available after restart.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit and Discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        isQuitting = true
        Task {
            await self.waitForStartup()
            await self.remoteStore?.shutdown()
            if self.remoteStore?.hasUnsavedDrafts == true {
                let alert = NSAlert()
                alert.messageText = String(localized: "Quit with unsaved remote drafts?")
                alert.informativeText = String(localized: "Some remote drafts could not be saved on this Mac. Cancel to copy your text before closing. The remote connection has been stopped.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.addButton(withTitle: String(localized: "Quit and Discard"))
                guard alert.runModal() == .alertSecondButtonReturn else {
                    self.remoteStore?.cancelShutdown()
                    self.isQuitting = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await store.shutdown()
            await self.keybindings?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
