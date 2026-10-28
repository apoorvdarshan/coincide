import AppKit
import CoincideKit
import Testing
@testable import Coincide

@MainActor
struct CLISessionImportViewTests {
    @Test func previewIsReadOnlyAndImportIsAnExplicitActionWithDuplicateLabel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-import-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let controller = CLISessionImportController(store: store, roots: [:])
        controller.loadViewIfNeeded()
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
        let importButton = try #require(buttons.first { $0.title == String(localized: "Import") })
        #expect(!importButton.isEnabled && store.threadSummaries.isEmpty)
        let data = Data("""
            {"type":"session_meta","payload":{"id":"a0000000-0000-0000-0000-000000000001","cwd":"/tmp/fixture"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Question"}]}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}}
            """.utf8)
        let preview = try CLISessionImport.parse(data, sourceURL: directory.appendingPathComponent("source.jsonl"))
        controller.show(preview)
        #expect(importButton.isEnabled && store.threadSummaries.isEmpty && store.projects.isEmpty)
        let transcript = try #require(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
        #expect(!transcript.isEditable && transcript.string.contains("Question") && transcript.string.contains("Answer"))
        let id = try store.importSession(preview)
        controller.show(preview)
        #expect(importButton.title == String(localized: "Open Existing Thread"))
        var opened: UUID?
        controller.onImport = { opened = $0 }
        importButton.performClick(nil)
        #expect(opened == id && store.threadSummaries.count == 1)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
struct ImportedSessionUndoFailureTests {
    @Test func retryingAPartialSelectionKeepsRedoForEveryRestoredThread() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-import-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let inbox = ThreadInbox(store: store, ui: UIState(directory: directory), reportError: { _ in })
        let project = store.addProject(at: directory)
        let ids = (0..<2).map { _ in store.createThread(in: project.id).id }
        try inbox.delete(ids)
        store.flush()
        let blocker = directory.appendingPathComponent("threads/\(ids[0].uuidString).json")
        try Data("external file".utf8).write(to: blocker)
        inbox.undo()
        #expect(!store.hasThread(ids[0]) && store.hasThread(ids[1]))
        #expect(inbox.undoManager.canUndo && store.canUndoDeletion(of: ids[0]))
        try FileManager.default.removeItem(at: blocker)
        inbox.undo()
        #expect(ids.allSatisfy(store.hasThread))
        inbox.redo()
        #expect(ids.allSatisfy { !store.hasThread($0) })
    }

    @Test(arguments: [false, true])
    func failedUndoKeepsTheSourceAndTranscriptForRetry(blockArchive: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-import-undo-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let ui = UIState(directory: directory)
        var errors = 0
        let inbox = ThreadInbox(store: store, ui: ui, reportError: { _ in errors += 1 })
        let data = Data("""
            {"type":"session_meta","payload":{"id":"a0000000-0000-0000-0000-000000000002","cwd":"/tmp/fixture"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Keep my history"}]}}
            {"type":"future","payload":{"original":"preserve this too"}}
            """.utf8)
        let preview = try CLISessionImport.parse(data, sourceURL: directory.appendingPathComponent("source.jsonl"))
        let id = try store.importSession(preview)
        let archive = try #require(store.importedSourceURL(for: id))
        let transcript = try #require(store.thread(id))
        try inbox.delete([id])
        store.flush()
        let blocker: URL
        if blockArchive {
            blocker = archive.deletingLastPathComponent()
            try FileManager.default.removeItem(at: blocker)
            try Data("temporary obstruction".utf8).write(to: blocker)
        } else {
            blocker = directory.appendingPathComponent("threads/\(id.uuidString).json")
            try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
            try Data("temporary obstruction".utf8).write(to: blocker.appendingPathComponent("child"))
        }
        inbox.undo()
        #expect(errors == 1 && !store.hasThread(id))
        #expect(store.canUndoDeletion(of: id) && inbox.undoManager.canUndo)
        try FileManager.default.removeItem(at: blocker)
        inbox.undo()
        #expect(store.thread(id)?.items == transcript.items)
        #expect(try Data(contentsOf: #require(store.importedSourceURL(for: id))) == data)
        inbox.redo()
        store.flush()
        #expect(!store.hasThread(id) && !FileManager.default.fileExists(atPath: archive.path))
        inbox.undo()
        #expect(store.hasThread(id))
        #expect(try Data(contentsOf: #require(store.importedSourceURL(for: id))) == data)
    }
}
