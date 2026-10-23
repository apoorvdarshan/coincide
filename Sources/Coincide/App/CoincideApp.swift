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
    @State private var mainWindows: MainWindowCoordinator
    @FocusedValue(\.cloneRepositoryPresentation) private var cloneRepositoryPresentation: Binding<Bool>?
    @FocusedValue(\.newProjectPresentation) private var newProjectPresentation: Binding<Bool>?
    @FocusedValue(\.settlementPresentation) private var settlementPresentation: Binding<CodingThread?>?
    private var defaultWindowSize: CGSize {
        MainWindowSizing.size(fitting: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 820))
    }
    init() {
        do {
            let url = try AppLaunchConfiguration.databaseURL(bundleIdentifier: Bundle.main.bundleIdentifier,
                                                            environment: ProcessInfo.processInfo.environment)
            let store = WorkspaceStore(databaseURL: url, appMCPEnabled: AppLaunchConfiguration.appMCPEnabled(bundleIdentifier: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment))
            let mainWindows = MainWindowCoordinator()
            _store = State(initialValue: store)
            _mainWindows = State(initialValue: mainWindows)
            delegate.attach(store, mainWindows: mainWindows)
        } catch {
            FileHandle.standardError.write(Data("Coincide UI-test workspace configuration is invalid.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    var body: some Scene {
        WindowGroup("Coincide", id: MainWindowCoordinator.sceneID) {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .background(MainWindowRegistration(coordinator: mainWindows))
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .commands {
            MainWindowCommands(coordinator: mainWindows)
            CommandGroup(replacing: .newItem) {
                Button("New Thread") { delegate.newThread() }.keyboardShortcut("n")
                Button("New Project…") { newProjectPresentation?.wrappedValue = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(newProjectPresentation == nil)
                Button("Add Project…") { store.addProject() }.keyboardShortcut("o")
                Button("Clone Repository…") { cloneRepositoryPresentation?.wrappedValue = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(cloneRepositoryPresentation == nil)
            }
            CommandMenu("Thread") {
                if let thread = store.selectedThread, let settlement = thread.settlement {
                    Button("Resume Conversation") { store.requestResume(thread.id, generationID: settlement.id) }
                        .disabled(settlement.phase == .resuming)
                } else {
                    Button("Settle Conversation…") {
                        if let thread = store.selectedThread { settlementPresentation?.wrappedValue = thread }
                    }.disabled(settlementPresentation == nil || (store.selectedThread.map { !store.canSettle($0) } ?? true))
                }
                Button("Stop Turn") { if let id = store.selectedThreadID { Task { await store.interrupt(id) } } }
                    .keyboardShortcut(".").disabled(store.selectedThreadID.map { !store.isBusy($0) } ?? true)
                Button("Toggle Inspector") { store.inspectorVisible.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings { SettingsView(store: store) }
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
    private var mainWindows: MainWindowCoordinator?
    private var pendingProjects: [URL] = []
    private var startup: Task<Void, Never>?
    private var ready = false
    private var isQuitting = false
    func attach(_ store: WorkspaceStore, mainWindows: MainWindowCoordinator) {
        self.store = store
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
        if store.hasUnsavedFileEdits {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit with unsaved file edits?")
            alert.informativeText = String(localized: "Unsaved file edits will be discarded. Cancel to return to your files and save them before quitting.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit and Discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        isQuitting = true
        Task { await self.waitForStartup(); await store.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
