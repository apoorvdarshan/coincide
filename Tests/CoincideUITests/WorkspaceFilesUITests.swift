import CoincideCore
import AppKit
import Foundation
import SwiftUI
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

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeContentSearchKeepsConversationAndDirtyEditorStateWhileOpeningTheExactUTF16Match() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-content-search-ui-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("Checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    let source = "Header\n😀 needle NEEDLE needlework\nneedle\n"
    try Data(source.utf8).write(to: checkout.appendingPathComponent("source.swift"))
    try Data("Nothing to find".utf8).write(to: checkout.appendingPathComponent("other.txt"))
    let project = WorkspaceProject(path: checkout.path)
    var thread = CodingThread(project: project); thread.draft = "Keep my unsent prompt"
    var initial = WorkspaceSnapshot(); initial.projects = [project]; initial.threads = [thread]
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(initial, event: "fixture", commandID: UUID())
    let store = WorkspaceStore(engine: try WorkspaceEngine(url: databaseURL, identityResolver: { _ in nil }))
    await store.load()
    let model = try store.fileBrowser(path: checkout.path)
    do {
        await model.start()
        let conversations = store.snapshot.threads
        model.searchMode = .contents; model.query = "needle"; model.wholeWord = true
        await model.reloadEntries()
        #expect(model.listingError == nil && model.regexFallbackError == nil)
        let match = try #require(model.contentMatches.first { $0.lineNumber == 2 })
        #expect(match.path == "source.swift" && match.matchRanges.map(\.start) == [3, 10])
        let range = try #require(match.matchRanges.first)
        let navigation = FileNavigation(workspacePath: checkout.path, path: match.path, line: match.lineNumber,
                                        utf16Column: range.start, utf16Length: range.end - range.start)
        #expect(await model.open(match.path, navigation: navigation))
        let host = NSHostingView(rootView: SourceEditor(text: Binding(get: { model.contents }, set: { model.setContents($0) }),
                                                       path: match.path, navigation: model.navigation, isEditable: model.canWrite)
            .frame(width: 400, height: 240))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 240); host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            for child in view.subviews { if let text = editor(in: child) { return text } }
            return nil
        }
        let textView = try #require(editor(in: host))
        #expect(textView.string == source)
        #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "needle")
        #expect(textView.selectedRange() == NSRange(location: 10, length: 6))
        model.setContents(source + "My unsaved addition\n")
        let dirty = model.contents
        model.caseSensitive = true; model.query = "NEEDLE"; await model.reloadEntries()
        #expect(model.contentMatches.count == 1 && model.contentMatches[0].matchRanges.map(\.start) == [10])
        #expect(model.contents == dirty && model.isDirty)
        model.useRegex = true; model.query = "["; await model.reloadEntries()
        #expect(model.contentMatches.isEmpty && model.regexFallbackError != nil && model.listingError == nil)
        model.searchMode = .paths; model.query = "other"; await model.reloadEntries()
        #expect(model.entries.map(\.path) == ["other.txt"] && model.contentMatches.isEmpty && model.regexFallbackError == nil)
        #expect(model.contents == dirty && store.snapshot.threads == conversations)
        #expect(store.selectedThreadID == thread.id && store.thread(thread.id)?.draft == "Keep my unsent prompt")
        #expect(try String(contentsOf: checkout.appendingPathComponent("source.swift"), encoding: .utf8) == source)
    } catch { await store.shutdown(); throw error }
    await store.shutdown()
}

private actor HeldNativeFileRead {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hold() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sameFileNavigationCancelsAnOlderPendingOpenWithoutReplacingTheLatestEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-file-navigation-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("Checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: checkout.appendingPathComponent(name)) }
    let project = WorkspaceProject(path: checkout.path), thread = CodingThread(project: project)
    var initial = WorkspaceSnapshot(); initial.projects = [project]; initial.threads = [thread]
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(initial, event: "fixture", commandID: UUID())
    let store = WorkspaceStore(engine: try WorkspaceEngine(url: databaseURL, identityResolver: { _ in nil }))
    await store.load()
    let service = try store.fileService(path: checkout.path), gate = HeldNativeFileRead()
    let model = FileBrowserStore(workspace: store, path: checkout.path, service: service, documentLoader: { path in
        let value = try await service.readFile(relativePath: path)
        if path == "b.txt" { await gate.hold() }
        return value
    })
    var pending: Task<Bool, Never>?
    do {
        #expect(await model.open("a.txt"))
        pending = Task { await model.open("b.txt") }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !gate.entered {
            guard ContinuousClock.now < deadline else { throw CoincideError("The held native file read did not start.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isReading && !model.canWrite)
        let latest = FileNavigation(workspacePath: checkout.path, path: "a.txt", line: 1, utf16Column: 1, utf16Length: 2)
        model.navigate(latest)
        #expect(model.document?.relativePath == "a.txt" && model.navigation == latest && !model.isReading && model.canWrite)
        model.setContents("Keep my latest edit")
        await gate.release()
        #expect(await pending?.value == false)
        #expect(model.document?.relativePath == "a.txt" && model.navigation == latest && model.contents == "Keep my latest edit" && model.isDirty)
        #expect(model.operationError == nil && store.snapshot.threads == [thread])
        #expect(try String(contentsOf: checkout.appendingPathComponent("a.txt"), encoding: .utf8) == "a.txt")
        #expect(try String(contentsOf: checkout.appendingPathComponent("b.txt"), encoding: .utf8) == "b.txt")
    } catch { await gate.release(); _ = await pending?.value; await model.shutdown(); await store.shutdown(); throw error }
    await model.shutdown(); await store.shutdown()
}
