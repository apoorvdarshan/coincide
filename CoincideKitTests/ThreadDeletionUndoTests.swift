import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct ThreadDeletionUndoTests {
    @Test func undoRestoresUnsavedHistoryAndKeepsItAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let project = store.addProject(at: directory)
        let id = store.createThread(in: project.id).id
        store.append(TranscriptItem(kind: .user, text: "Keep this unsaved message"), to: id)
        store.updateThread(id) { $0.draft = "Keep this draft" }
        var snapshot = try store.deleteThreadForUndo(id)
        #expect(!store.hasThread(id))
        #expect(store.canUndoDeletion(of: id))
        do {
            let saved = try #require(snapshot)
            #expect(try store.restoreDeletedThread(saved))
            #expect(try !store.restoreDeletedThread(saved))
        }
        snapshot = nil
        #expect(!store.canUndoDeletion(of: id))
        store.flush()
        let reopened = AppStore(directory: directory)
        #expect(reopened.thread(id)?.items.map(\.text) == ["Keep this unsaved message"])
        #expect(reopened.thread(id)?.draft == "Keep this draft")
    }

    @Test func undoPreservesUnknownSavedFieldsAndDoesNotRecreateRemovedProjects() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = AppStore(directory: directory)
        let project = initial.addProject(at: directory)
        let id = initial.createThread(in: project.id).id
        initial.flush()
        let file = directory.appendingPathComponent("threads/\(id.uuidString).json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["futureField"] = ["keep": "exactly"]
        let original = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        try original.write(to: file, options: .atomic)
        let store = AppStore(directory: directory)
        let snapshot = try #require(try store.deleteThreadForUndo(id))
        #expect(try store.restoreDeletedThread(snapshot))
        #expect(try Data(contentsOf: file) == original)
        store.append(TranscriptItem(kind: .user, text: "New unsaved message"), to: id)
        let second = try #require(try store.deleteThreadForUndo(id))
        #expect(try store.restoreDeletedThread(second))
        #expect(store.thread(id)?.items.last?.text == "New unsaved message")
        let savedOriginal = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("unreadable-undo") }
        #expect(try Data(contentsOf: #require(savedOriginal)) == original)
        let third = try #require(try store.deleteThreadForUndo(id))
        store.removeProject(project.id)
        #expect(try !store.restoreDeletedThread(third))
        #expect(!store.hasThread(id))
    }
}
