import AppKit
import CoincideCore
import CoincideTerminal
import Testing
@testable import Coincide

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeTerminalRestorationCanReuseAWindowWhilePreviousRestorationDrains() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-reopen-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archives = TerminalArchiveStore(root: root.appendingPathComponent("archive"))
    let thread = CodingThread(project: .init(path: root.path))
    var saved = try await archives.claim()
    let tabID = UUID()
    saved.tabs = [.init(id: tabID, threadID: thread.id, workspacePath: root.path, directory: root.path,
                       title: "Saved", text: "REOPEN_WITHOUT_REPLAY", isCommand: false, exitCode: nil)]
    try await archives.save(saved); await archives.release(saved.id)
    let window = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    window.restore(from: archives, currentThreads: { [thread] })
    window.suspend()
    window.restore(from: archives, currentThreads: { [thread] })
    await window.waitForRestoration()
    #expect(!window.isRestoring && window.sessions[thread.id]?.map(\.id) == [tabID])
    window.suspend(); await window.waitForPersistence()
    window.restore(from: archives, currentThreads: { [thread] }); await window.waitForRestoration()
    #expect(window.sessions[thread.id]?.map(\.id) == [tabID])
    try window.add(for: thread)
    let shells = window.suspend(); await window.waitForPersistence()
    for shell in shells { await shell.waitForClose() }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeTerminalWindowRestoresSelectedTabsAndOutputWithoutReplayingShells() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-window-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: root.path))
    let archive = TerminalArchiveStore(root: root.appendingPathComponent("archive"))
    let first = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    first.restore(from: archive, currentThreads: { [thread] }); await first.waitForRestoration()
    try first.add(for: thread)
    let shell = try #require(first.sessions[thread.id]?.first)
    try await shell.send("printf 'DURABLE_TERMINAL_✓\\n'\n")
    let end = ContinuousClock.now + .seconds(8)
    while !shell.visibleText.contains("DURABLE_TERMINAL_✓\n") && ContinuousClock.now < end {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(shell.visibleText.contains("DURABLE_TERMINAL_✓"))
    try first.add(for: thread)
    let secondID = try #require(first.sessions[thread.id]?.last?.id)
    first.panelVisible = true
    let closed = first.suspend(); await first.waitForPersistence()
    for session in closed { await session.waitForClose() }
    let second = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    second.restore(from: archive, currentThreads: { [thread] }); await second.waitForRestoration()
    #expect(second.panelVisible && second.selection[thread.id] == secondID)
    #expect(second.sessions[thread.id]?.map(\.id) == [shell.id, secondID])
    #expect(second.sessions[thread.id]?.allSatisfy { $0.isRestored && $0.processID == 0 } == true)
    #expect(second.sessions[thread.id]?.first?.visibleText.contains("DURABLE_TERMINAL_✓") == true)
    let restored = try #require(second.sessions[thread.id]?.first)
    second.close(restored, threadID: thread.id)
    second.suspend(); await second.waitForPersistence()
    let third = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    third.restore(from: archive, currentThreads: { [thread] }); await third.waitForRestoration()
    #expect(third.sessions[thread.id]?.map(\.id) == [secondID])
    third.removeAll(); await third.waitForPersistence(); third.suspend(); await third.waitForPersistence()
}

@Test @MainActor
func nativeTerminalRestorationRejectsRemovedThreadsAndChangedWorkspacesAndSeparatesWindows() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-owners-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = TerminalArchiveStore(root: root.appendingPathComponent("archive"))
    let thread = CodingThread(project: .init(path: root.path)), removed = UUID()
    var saved = try await archive.claim()
    saved.tabs = [thread.id, removed].map { .init(id: UUID(), threadID: $0, workspacePath: root.path,
        directory: root.path, title: "Old", text: "saved", isCommand: false, exitCode: nil) }
    try await archive.save(saved); await archive.release(saved.id)
    let one = TerminalWorkspaceStore(), two = TerminalWorkspaceStore()
    one.restore(from: archive, currentThreads: { [thread] }); await one.waitForRestoration()
    two.restore(from: archive, currentThreads: { [thread] }); await two.waitForRestoration()
    #expect(one.sessions[thread.id]?.count == 1 && one.sessions[removed] == nil)
    #expect(two.sessions.isEmpty)
    one.suspend(); two.suspend(); await one.waitForPersistence(); await two.waitForPersistence()
    var moved = thread; moved.workspacePath = root.appendingPathComponent("changed").path
    let three = TerminalWorkspaceStore()
    three.restore(from: archive, currentThreads: { [moved] }); await three.waitForRestoration()
    #expect(three.sessions.isEmpty)
    three.suspend(); await three.waitForPersistence()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeTerminalRestorationCannotClaimOrDeleteOutputWhenAnotherRuntimeOwnsTheDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-locked-workspace-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite")
    let owner = try WorkspaceEngine(url: database, providerFactory: { _ in
        throw CoincideError("Terminal ownership verification must not create a provider.")
    }, identityResolver: { _ in nil })
    var blocked: WorkspaceStore?
    do {
        _ = try await owner.load()
        let project = WorkspaceProject(path: root.path), thread = CodingThread(project: project)
        try await owner.dispatch(.addProjectWithThread(project: project, thread: thread))
        let history = root.appendingPathComponent("TerminalHistory"), archives = TerminalArchiveStore(root: history)
        var saved = try await archives.claim()
        let tab = TerminalTabArchive(id: UUID(), threadID: thread.id, workspacePath: root.path, directory: root.path,
                                     title: "Owned output", text: "PRESERVE_OWNER_TERMINAL_OUTPUT", isCommand: false, exitCode: 0)
        saved.tabs = [tab]; saved.selection = [thread.id: tab.id]; saved.panelVisible = true
        try await archives.save(saved); await archives.release(saved.id)
        let file = history.appendingPathComponent(saved.id.uuidString.lowercased() + ".json")
        let before = try Data(contentsOf: file)
        let store = WorkspaceStore(databaseURL: database, appMCPEnabled: false, codexHostID: UUID())
        blocked = store; await store.load()
        #expect(!store.isLoading && !store.hasLoadedWorkspace && store.snapshot.threads.isEmpty)
        #expect(store.errorMessage?.contains("Another Coincide runtime already owns") == true)
        let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
        store.registerTerminals(terminals); store.restoreTerminals(terminals)
        await terminals.waitForRestoration(); await terminals.waitForPersistence()
        #expect(terminals.sessions.isEmpty && !terminals.isRestoring && terminals.restorationError == nil)
        #expect(try Data(contentsOf: file) == before)
        // A direct test-only claim on the blocked store's actor proves the UI
        // restoration did not reserve the owner's archive behind the guard.
        let untouched = try await store.terminalArchives.claim()
        #expect(untouched == saved)
        await store.terminalArchives.release(untouched.id)
        store.unregisterTerminals(terminals); await store.shutdown()
        #expect(try Data(contentsOf: file) == before)
        #expect((await owner.current()).snapshot.threads.contains { $0.id == thread.id })
        await owner.shutdown()
    } catch {
        await blocked?.shutdown(); await owner.shutdown(); throw error
    }
}
