import AppKit
import CoincideMarkdown
import Darwin
import SwiftUI

@main
enum CoincideMain {
    @MainActor static func main() {
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
    @FocusedValue(\.cloneRepositoryPresentation) private var cloneRepositoryPresentation: Binding<Bool>?
    @FocusedValue(\.newProjectPresentation) private var newProjectPresentation: Binding<Bool>?
    init() {
        do {
            let url = try AppLaunchConfiguration.databaseURL(bundleIdentifier: Bundle.main.bundleIdentifier,
                                                            environment: ProcessInfo.processInfo.environment)
            _store = State(initialValue: WorkspaceStore(databaseURL: url))
        } catch {
            FileHandle.standardError.write(Data("Coincide UI-test workspace configuration is invalid.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    var body: some Scene {
        WindowGroup("Coincide") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .task { await store.load(); delegate.attach(store) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") { store.newThread() }.keyboardShortcut("n")
                Button("New Project…") { newProjectPresentation?.wrappedValue = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(newProjectPresentation == nil)
                Button("Add Project…") { store.addProject() }.keyboardShortcut("o")
                Button("Clone Repository…") { cloneRepositoryPresentation?.wrappedValue = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(cloneRepositoryPresentation == nil)
            }
            CommandMenu("Thread") {
                Button("Stop Turn") { if let id = store.selectedThreadID { Task { await store.interrupt(id) } } }
                    .keyboardShortcut(".").disabled(store.selectedThreadID.map { !store.isBusy($0) } ?? true)
                Button("Toggle Inspector") { store.inspectorVisible.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings { SettingsView(store: store) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?
    private var pendingProjects: [URL] = []
    func attach(_ store: WorkspaceStore) {
        self.store = store
        for url in pendingProjects { store.addProject(at: url) }
        pendingProjects.removeAll()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let store { for url in urls { store.addProject(at: url) } }
        else { pendingProjects.append(contentsOf: urls) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { await store.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
