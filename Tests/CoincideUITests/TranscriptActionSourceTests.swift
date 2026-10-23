@testable import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor @Test(arguments: ["birth", "project", "project-birth", "project-path", "workspace-bytes", "preparation", "configuration", "message", "runtime"])
func transcriptActionSourceRejectsReboundOwnershipAndSameLengthMessageRevisions(mode: String) throws {
    var project = WorkspaceProject(path: "/private/café")
    var thread = CodingThread(project: project, model: "offline-model")
    let message = ChatMessage(id: "same-message", role: .assistant, text: "same size one")
    thread.messages = [message]
    let source = try #require(TranscriptActionSource(thread: thread, project: project, message: message))
    #expect(source.matches(thread: thread, project: project))
    switch mode {
    case "birth": thread.createdAt = thread.createdAt.addingTimeInterval(1)
    case "project": project.id = UUID(); thread.projectID = project.id
    case "project-birth": project.createdAt = (project.createdAt ?? .now).addingTimeInterval(1)
    case "project-path": project.path += "/replacement"
    case "workspace-bytes":
        let composed = thread.workspacePath.precomposedStringWithCanonicalMapping
        let changed = thread.workspacePath.utf8.elementsEqual(composed.utf8)
            ? thread.workspacePath.decomposedStringWithCanonicalMapping : composed
        #expect(changed == thread.workspacePath && !changed.utf8.elementsEqual(thread.workspacePath.utf8))
        thread.workspacePath = changed
    case "preparation":
        thread.workspacePreparation = .init(request: .init(sourcePath: project.path, destinationRoot: project.path + "/worktrees", selection: .reuse(path: thread.workspacePath)))
    case "configuration": thread.model = "changed-model"
    case "message":
        thread.messages[0].text = "same size two"
        #expect(thread.messages[0].text.utf8.count == message.text.utf8.count)
    default: thread.runtimeID = UUID()
    }
    #expect(!source.matches(thread: thread, project: project))
}

@MainActor private struct TranscriptActionFixture {
    let root: URL
    let workspace: URL
    let store: WorkspaceStore
    let thread: CodingThread
    let runID: UUID

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-transcript-action-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("Workspace")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let project = WorkspaceProject(path: workspace.path)
            var thread = CodingThread(project: project, model: "private-offline-model")
            let runID = UUID(), start = Date(timeIntervalSince1970: 1_800_000_000)
            var record = ThreadRunRecord(run: .init(id: runID, configuration: .init(thread: thread), startedAt: start), origin: .user, userMessageID: "input")
            record.status = .completed; record.endedAt = start.addingTimeInterval(2); record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            var input = ChatMessage(id: "input", role: .user, text: "Source input"), response = ChatMessage(id: "response", role: .assistant, text: "Source reply")
            input.runReference = .init(threadID: thread.id, runID: runID); response.runReference = input.runReference
            input.createdAt = start; response.createdAt = start.addingTimeInterval(1)
            thread.messages = [input, response]; thread.runHistory = [record]
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = root.appendingPathComponent("workspace.sqlite")
            _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "private-transcript-action", commandID: UUID())
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in
                throw CoincideError("No provider may launch in transcript source and file tests.")
            }, identityResolver: { _ in nil })
            let store = WorkspaceStore(engine: engine); await store.load()
            store.selectedProjectID = project.id; store.selectedThreadID = thread.id
            return .init(root: root, workspace: workspace, store: store, thread: try #require(store.thread(thread.id)), runID: runID)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func finish() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["birth", "project", "workspace", "configuration", "message", "selection"])
func retainedTranscriptEditAndForkActionsCannotRetargetAfterTheirSourceChanges(mode: String) async throws {
    let f = try await TranscriptActionFixture.make()
    do {
        var presented: [TranscriptSheetRequest] = []
        let view = TranscriptRowsView(store: f.store, thread: f.thread, state: TranscriptViewState(), present: { presented.append($0) })
        let rows = TranscriptLayout.rows(thread: f.thread)
        guard case .message(let input, let inputMeta)? = rows.first(where: { $0.id == "input" }),
              case .message(let response, let responseMeta)? = rows.first(where: { $0.id == "response" }) else {
            Issue.record("The private completed run has no attributed transcript messages."); await f.finish(); return
        }
        let edit = view.actions(input, inputMeta), fork = view.actions(response, responseMeta)
        #expect(edit.editFromHere != nil && fork.forkFromHere != nil)
        edit.editFromHere?(); fork.forkFromHere?()
        #expect(presented.map(\.action) == [.history(f.runID, .rewindBeforeRun), .history(f.runID, .forkAfterRun)])
        presented.removeAll()
        switch mode {
        case "birth": f.store.snapshot.threads[0].createdAt = f.thread.createdAt.addingTimeInterval(1)
        case "project": f.store.snapshot.threads[0].projectID = UUID()
        case "workspace": f.store.snapshot.threads[0].workspacePath += "/replacement"
        case "configuration": f.store.snapshot.threads[0].model = "changed-model"
        case "message":
            f.store.snapshot.threads[0].messages[0].text = "Source other"
            f.store.snapshot.threads[0].messages[1].text = "Source other"
            #expect(f.store.snapshot.threads[0].messages[0].text.utf8.count == input.text.utf8.count)
        default: f.store.selectedThreadID = nil
        }
        edit.editFromHere?(); fork.forkFromHere?()
        #expect(presented.isEmpty)
        #expect(f.store.snapshot.threads[0].queuedTurns.isEmpty && f.store.snapshot.threads[0].activeRun == nil)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func transcriptPlanSaveUsesTheRegisteredEditorAndNeverOverwritesExistingOrDirtySources() async throws {
    let f = try await TranscriptActionFixture.make()
    do {
        let message = try #require(f.thread.messages.last)
        let source = try #require(f.store.captureTranscriptSource(thread: f.thread, message: message))
        let contents = "# Exact plan\n\nKeep decomposed e\u{301}, 🌍 and the final newline.\n"
        let saved = f.workspace.appendingPathComponent("plan.md")
        let browser = try f.store.fileBrowser(path: f.workspace.path)
        try await f.store.saveTranscriptPlan(source, path: "plan.md", contents: contents)
        #expect(try Data(contentsOf: saved) == Data(contents.utf8))
        #expect(try f.store.fileBrowser(path: f.workspace.path) === browser)
        var overwriteRefused = false
        do { try await f.store.saveTranscriptPlan(source, path: "plan.md", contents: "forbidden replacement") }
        catch { overwriteRefused = true }
        #expect(overwriteRefused)
        #expect(try Data(contentsOf: saved) == Data(contents.utf8))
        let editorFile = f.workspace.appendingPathComponent("editor.txt")
        try Data("original editor\n".utf8).write(to: editorFile)
        #expect(await browser.open("editor.txt"))
        browser.setContents("newer unsaved text e\u{301} 🌍\n")
        let dirty = browser.contents
        #expect(browser.isDirty)
        var dirtyRefused = false
        do { try await f.store.saveTranscriptPlan(source, path: "another-plan.md", contents: contents) }
        catch { dirtyRefused = true }
        #expect(dirtyRefused && browser.isDirty && browser.contents.utf8.elementsEqual(dirty.utf8))
        #expect(browser.document?.relativePath == "editor.txt")
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("another-plan.md").path))
        #expect(try Data(contentsOf: editorFile) == Data("original editor\n".utf8))
        f.store.snapshot.threads[0].createdAt = f.thread.createdAt.addingTimeInterval(1)
        var staleRefused = false
        do { try await f.store.saveTranscriptPlan(source, path: "stale-plan.md", contents: contents) }
        catch { staleRefused = true }
        #expect(staleRefused && browser.contents.utf8.elementsEqual(dirty.utf8))
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("stale-plan.md").path))
        #expect(f.store.snapshot.threads[0].messages == f.thread.messages && f.store.snapshot.threads[0].queuedTurns.isEmpty)
    } catch { await f.finish(); throw error }
    await f.finish()
}
