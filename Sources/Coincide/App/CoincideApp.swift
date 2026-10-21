import AppKit
import SwiftUI

@main
struct CoincideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = WorkspaceStore()
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
                Button("Add Project…") { store.addProject() }.keyboardShortcut("o")
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
