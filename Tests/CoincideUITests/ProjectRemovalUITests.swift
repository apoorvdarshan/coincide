import AppKit
import CoincideCore
import CoincideTerminal
import Darwin
import Testing
import UniformTypeIdentifiers
@testable import Coincide

@MainActor private func waitRemovalUI(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Project removal UI resources did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removingProjectReconcilesAllWindowTerminalsPendingPastesDraftsSelectionAndSharedInspectors() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-removal-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("checkout"), otherCheckout = root.appendingPathComponent("other"), worktree = root.appendingPathComponent("worktree")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherCheckout, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    let sentinel = checkout.appendingPathComponent("keep.txt"), bytes = Data("Preserve checkout bytes and all attachments.".utf8)
    try bytes.write(to: sentinel)
    let removed = WorkspaceProject(path: checkout.path), surviving = WorkspaceProject(path: otherCheckout.path)
    let active = CodingThread(project: removed)
    var archived = CodingThread(project: removed); archived.isArchived = true; archived.workspacePath = worktree.path
    var other = CodingThread(project: surviving); other.workspacePath = checkout.path // Shared inspector ownership.
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [removed, surviving]; snapshot.threads = [active, archived, other]
    let databaseURL = root.appendingPathComponent("workspace.sqlite")
    let database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(snapshot, event: "fixture.removal-ui", commandID: UUID())
    let store = WorkspaceStore(databaseURL: databaseURL)
    await store.load()
    let firstWindow = TerminalWorkspaceStore(), secondWindow = TerminalWorkspaceStore()
    store.registerTerminals(firstWindow); store.registerTerminals(secondWindow)
    let terminalA = try LocalTerminalSession(directory: checkout, executable: "/bin/sh", arguments: ["-c", "exec sleep 120"])
    let terminalB = try LocalTerminalSession(directory: checkout, executable: "/bin/sh", arguments: ["-c", "exec sleep 120"])
    let terminalOther = try LocalTerminalSession(directory: otherCheckout, executable: "/bin/sh", arguments: ["-c", "exec sleep 120"])
    let pidA = terminalA.processID, pidB = terminalB.processID
    defer { terminalA.close(); terminalB.close(); terminalOther.close() }
    firstWindow.sessions[active.id] = [terminalA]; firstWindow.selection[active.id] = terminalA.id
    secondWindow.sessions[archived.id] = [terminalB]; secondWindow.selection[archived.id] = terminalB.id
    secondWindow.sessions[other.id] = [terminalOther]; secondWindow.selection[other.id] = terminalOther.id
    let inspector = store.gitInspector(path: checkout.path)
    let removedInspector = store.gitInspector(path: worktree.path)
    store.fileNavigation = .init(workspacePath: worktree.path, path: "keep.txt", line: 1)
    let provider = NSItemProvider(), progress = Progress(totalUnitCount: 1)
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { _ in progress }
    do {
        store.selectedThreadID = active.id; store.selectedProjectID = removed.id
        store.setDraft("Do not resurrect this removed draft", id: active.id)
        store.importAttachments(providers: [provider], threadID: active.id)
        try await waitRemovalUI { store.isImportingAttachments(active.id) }
        // Let the never-finishing item provider begin so cancellation has real work to stop.
        try await Task.sleep(for: .milliseconds(50))
        let request = try #require(store.projectRemovalRequest(removed.id))
        #expect(Set(request.threadIDs) == [active.id, archived.id])
        try await store.removeProject(request)
        try await waitRemovalUI { kill(pidA, 0) == -1 && errno == ESRCH && kill(pidB, 0) == -1 && errno == ESRCH }
        #expect(store.snapshot.projects.map(\.id) == [surviving.id] && store.snapshot.threads.map(\.id) == [other.id])
        #expect(store.selectedThreadID == other.id && store.selectedProjectID == surviving.id)
        #expect(firstWindow.sessions[active.id] == nil && firstWindow.selection[active.id] == nil)
        #expect(secondWindow.sessions[archived.id] == nil && secondWindow.selection[archived.id] == nil)
        #expect(secondWindow.sessions[other.id]?.first === terminalOther && terminalOther.lifecycle == .running)
        #expect(store.gitInspector(path: checkout.path) === inspector)
        #expect(!inspector.isBusy && removedInspector.isBusy && store.fileNavigation == nil)
        #expect(!store.isImportingAttachments(active.id) && progress.isCancelled && store.errorMessage == nil)
        store.setDraft("Late editor callback", id: active.id)
        store.importAttachments(files: [sentinel], threadID: active.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.thread(active.id) == nil && !store.isImportingAttachments(active.id) && store.errorMessage == nil)
        #expect(try Data(contentsOf: sentinel) == bytes)
        await store.shutdown()
        let reopened = WorkspaceStore(databaseURL: databaseURL); await reopened.load()
        #expect(reopened.snapshot.projects.map(\.id) == [surviving.id] && reopened.snapshot.threads.map(\.id) == [other.id])
        #expect(reopened.managedProjectsRoot.deletingLastPathComponent().path == root.path)
        #expect(reopened.worktreesRoot == root.appendingPathComponent("Worktrees", isDirectory: true))
        await reopened.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func projectRemovalRequiresRenewedConfirmationForNewUnsavedEditorsAndNewConversations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-removal-confirm-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    await store.load(); store.addProject(at: root)
    try await waitRemovalUI { store.snapshot.projects.count == 1 }
    let project = try #require(store.snapshot.projects.first)
    let beforeEdits = try #require(store.projectRemovalRequest(project.id)), editorID = UUID()
    store.setEditorDirty(editorID, workspacePath: root.path, dirty: true)
    do { try await store.removeProject(beforeEdits); Issue.record("Removal discarded a newly dirty editor without confirmation.") }
    catch { #expect(error.localizedDescription.contains("unsaved")) }
    #expect(store.snapshot.projects.count == 1)
    let beforeThread = try #require(store.projectRemovalRequest(project.id))
    #expect(beforeThread.dirtyEditorIDs == [editorID])
    store.newThread(projectID: project.id)
    try await waitRemovalUI { store.snapshot.threads.count == 1 }
    do { try await store.removeProject(beforeThread); Issue.record("Removal silently included a newly created conversation.") }
    catch { #expect(store.snapshot.threads.count == 1 && store.snapshot.projects.count == 1) }
    let confirmed = try #require(store.projectRemovalRequest(project.id))
    try await store.removeProject(confirmed)
    #expect(store.snapshot.projects.isEmpty && store.snapshot.threads.isEmpty)
    #expect(store.projectRemovalRequest(project.id) == nil && FileManager.default.fileExists(atPath: root.path))
    await store.shutdown()
}

@Test func uiTestBundleCannotFallBackToTheRealWorkspace() throws {
    let testID = AppLaunchConfiguration.uiTestingBundleIdentifier
    #expect(try AppLaunchConfiguration.databaseURL(bundleIdentifier: "com.apoorvdarshan.coincide", environment: ["COINCIDE_UI_TESTING": "1"]) == nil)
    #expect(throws: (any Error).self) { try AppLaunchConfiguration.databaseURL(bundleIdentifier: testID, environment: [:]) }
    #expect(throws: (any Error).self) { try AppLaunchConfiguration.databaseURL(bundleIdentifier: testID, environment: ["COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": "/"]) }
    #expect(throws: (any Error).self) { try AppLaunchConfiguration.databaseURL(bundleIdentifier: testID, environment: ["COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": "relative"]) }
    #if DEBUG
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-ui-testing-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": root.path]
    #expect(try AppLaunchConfiguration.databaseURL(bundleIdentifier: testID, environment: environment) == root.appendingPathComponent("workspace.sqlite"))
    let link = root.deletingLastPathComponent().appendingPathComponent("coincide-ui-testing-symlink-" + UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    defer { try? FileManager.default.removeItem(at: link) }
    #expect(throws: (any Error).self) { try AppLaunchConfiguration.databaseURL(bundleIdentifier: testID, environment: ["COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": link.path]) }
    #endif
}
