import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor private func waitForFileUI(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Timed out waiting for native file state.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func workspaceEditorsPreserveDirtyBuffersDetectConflictsAndRetainASharedServiceUntilTheLastOwnerLeaves() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-file-ui-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("Checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    let file = checkout.appendingPathComponent("notes.txt")
    try Data("Original bytes".utf8).write(to: file)
    var a = WorkspaceProject(path: checkout.path), b = WorkspaceProject(path: checkout.path)
    a.name = "A"; b.name = "B"
    let threadA = CodingThread(project: a), threadB = CodingThread(project: b)
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    var initial = WorkspaceSnapshot(); initial.projects = [a, b]; initial.threads = [threadA, threadB]
    _ = try await database.commit(initial, event: "fixture", commandID: UUID())
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine)
    await store.load()
    let service = try store.fileService(path: checkout.path)
    #expect(service === (try store.fileService(path: checkout.appendingPathComponent(".").path)))
    let editorA = try store.fileBrowser(path: checkout.path)
    let editorB = FileBrowserStore(workspace: store, path: checkout.path, service: service)
    do {
        await editorA.start(); await editorB.start()
        #expect(await editorA.open("notes.txt")); #expect(await editorB.open("notes.txt"))
        editorA.setContents("My unsaved edit")
        #expect(editorA.isDirty && editorA.canWrite)
        store.inspectorVisible = false; store.selectedThreadID = threadB.id
        #expect(editorA === (try store.fileBrowser(path: checkout.path)))
        #expect(editorA.contents == "My unsaved edit" && store.projectRemovalRequest(a.id)?.dirtyEditorIDs.count == 1)
        try Data("Changed externally".utf8).write(to: file, options: .atomic)
        await service.refresh()
        try await waitForFileUI { editorA.hasExternalChanges && editorB.contents == "Changed externally" }
        #expect(editorA.contents == "My unsaved edit" && editorA.original == "Original bytes")
        #expect(await editorA.open("notes.txt") == false)
        await editorA.save()
        #expect(editorA.isDirty && editorA.contents == "My unsaved edit" && editorA.operationError != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Changed externally")
        let requestA = try #require(store.projectRemovalRequest(a.id))
        #expect(requestA.dirtyEditorIDs.count == 1)
        try await store.removeProject(requestA)
        #expect(store.snapshot.projects.map(\.id) == [b.id])
        #expect(service === (try store.fileService(path: checkout.path)))
        #expect(try await service.readFile(relativePath: "notes.txt").contents == "Changed externally")
        #expect(await editorA.open("notes.txt", discardChanges: true))
        editorA.setContents("Saved after the first owner left")
        await editorA.save()
        #expect(!editorA.isDirty && editorA.operationError == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Saved after the first owner left")
        try await store.removeProject(#require(store.projectRemovalRequest(b.id)))
        #expect(!store.canAccessWorkspaceFiles(checkout.path))
        await #expect(throws: WorkspaceFileError.self) { try await service.listEntries() }
        #expect(throws: CoincideError.self) { try store.fileService(path: checkout.path) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "Saved after the first owner left")
    } catch {
        await editorA.shutdown(); await editorB.shutdown(); await store.shutdown(); throw error
    }
    await editorA.shutdown(); await editorB.shutdown(); await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeFileCreationAndPreviewKeepExistingBytesAndReferencesPersistOnlyInTheCapturedConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-file-reference-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("Checkout", isDirectory: true)
    let other = root.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: checkout.path), second = WorkspaceProject(path: other.path)
    let thread = CodingThread(project: project), another = CodingThread(project: second)
    let url = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    var initial = WorkspaceSnapshot(); initial.projects = [project, second]; initial.threads = [thread, another]
    _ = try await database.commit(initial, event: "fixture", commandID: UUID())
    let store = WorkspaceStore(engine: try WorkspaceEngine(url: url, identityResolver: { _ in nil }))
    await store.load()
    let model = try store.fileBrowser(path: checkout.path)
    do {
        await model.start()
        let relative = "Sources/Hello [world] #?.swift"
        #expect(await model.createFile(path: relative))
        model.setContents("let answer = 42\n"); await model.save()
        #expect(!model.isDirty && model.operationError == nil)
        #expect(await model.createFile(path: relative) == false)
        #expect(try String(contentsOf: checkout.appendingPathComponent(relative), encoding: .utf8) == "let answer = 42\n")
        store.selectedThreadID = another.id
        store.setDraft("Inspect", id: thread.id)
        await store.insertWorkspaceReference(path: relative, workspacePath: checkout.path, threadID: thread.id)
        let expected = "Inspect [Hello \\[world\\] #?.swift](Sources/Hello%20%5Bworld%5D%20%23%3F.swift) "
        #expect(store.thread(thread.id)?.draft == expected && store.thread(another.id)?.draft == "")
        #expect(store.selectedThreadID == another.id && store.thread(thread.id)?.draftAttachments.isEmpty == true)
        let before = store.thread(thread.id)
        await store.insertWorkspaceReference(path: relative, workspacePath: other.path, threadID: thread.id)
        #expect(store.thread(thread.id) == before)
        try Data(repeating: 65, count: 1_100_000).write(to: checkout.appendingPathComponent("large.txt"))
        #expect(await model.open("large.txt"))
        #expect(model.document?.truncated == true && !model.canWrite)
        let preview = model.contents; model.setContents("Must not change a preview")
        #expect(model.contents == preview && !model.isDirty)
        #expect(try Data(contentsOf: checkout.appendingPathComponent("large.txt")).count == 1_100_000)
        #expect(!store.canAccessWorkspaceFiles(root.appendingPathComponent("Unregistered").path))
        await model.shutdown(); await store.shutdown()
        let reopened = WorkspaceStore(databaseURL: url); await reopened.load()
        #expect(reopened.thread(thread.id)?.draft == expected && reopened.thread(another.id)?.draft == "")
        #expect(reopened.thread(thread.id)?.queuedTurns == thread.queuedTurns && reopened.thread(thread.id)?.provider == thread.provider)
        await reopened.shutdown()
    } catch { await model.shutdown(); await store.shutdown(); throw error }
}
