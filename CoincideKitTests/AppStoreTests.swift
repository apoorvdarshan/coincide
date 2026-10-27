import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct AppStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-store-\(UUID().uuidString)")

    private func threadFile(_ id: UUID) -> URL {
        directory.appendingPathComponent("threads/\(id.uuidString).json")
    }

    @Test func threadsKeepWhatThisVersionCanRead() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.flush()
        // As a newer version might write it: an unknown provider, status, item kind and session.
        let itemID = UUID()
        let json = """
            {"id":"\(thread.id.uuidString)","projectID":"\(project.id.uuidString)","title":"Later",
             "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z",
             "selection":{"provider":"future","modelID":"x"},
             "items":[
               {"id":"\(itemID.uuidString)","kind":"user","text":"hello","createdAt":"2026-10-01T10:00:00Z"},
               {"id":"\(UUID().uuidString)","kind":"hologram","text":"?","createdAt":"2026-10-01T10:00:00Z"},
               {"id":"\(UUID().uuidString)","kind":"tool","text":"","status":"paused","provider":"future","category":"teleport",
                "createdAt":"2026-10-01T10:00:00Z"}
             ],
             "sessions":["claude",{"sessionID":"c1","seenItemCount":1},"future",{"sessionID":"f1","seenItemCount":2}]}
            """
        try Data(json.utf8).write(to: threadFile(thread.id))

        let reloaded = AppStore(directory: directory)
        let loaded = try #require(reloaded.thread(thread.id))
        #expect(loaded.title == "Later")
        #expect(loaded.items.map(\.kind) == [.user, .tool])
        #expect(loaded.items.last?.status == nil && loaded.items.last?.provider == nil && loaded.items.last?.category == nil)
        #expect(loaded.sessions == [.claude: ProviderSessionRef(sessionID: "c1", seenItemCount: 1)])
        #expect(loaded.selection == ModelSelection(provider: .claude, modelID: "default"))
    }

    @Test func unreadableFilesAreSetAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projects = directory.appendingPathComponent("projects.json")
        try Data("{ not json".utf8).write(to: projects)
        let store = AppStore(directory: directory)
        #expect(store.projects.isEmpty)
        store.addProject(at: URL(fileURLWithPath: "/tmp"))
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(names.first { $0.hasPrefix("projects.json.unreadable-") })
        #expect(try String(contentsOf: directory.appendingPathComponent(aside), encoding: .utf8) == "{ not json")
        #expect(AppStore(directory: directory).projects.count == 1)
    }

    @Test func aProjectListWithAnUnreadableEntryKeepsTheRest() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = Project(name: "app", path: "/tmp/app")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = try #require(String(data: try encoder.encode(good), encoding: .utf8))
        try Data("[\(entry), {\"name\":\"no id\"}]".utf8).write(to: directory.appendingPathComponent("projects.json"))
        let store = AppStore(directory: directory)
        #expect(store.projects.map(\.id) == [good.id])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("projects.json.unreadable-") })
    }

    @Test func settingsOfUnknownProvidersDoNotResetTheOthers() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"{"providers":["codex",{"isEnabled":false},"future",{"isEnabled":true}],"fontSize":15}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("settings.json"))
        let store = AppStore(directory: directory)
        #expect(store.settings.settings(for: .codex).isEnabled == false)
        #expect(store.settings.fontSize == 15)
    }

    @Test func manyQuickChangesAllReachTheDisk() throws {
        let store = AppStore(directory: directory)
        store.saveDelay = 0
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        let item = store.append(TranscriptItem(kind: .assistant, text: "", status: .running), to: thread.id)
        for index in 0..<500 {
            store.updateItem(item, in: thread.id) { $0.text += "\(index) " }
        }
        store.flush()
        let reloaded = AppStore(directory: directory)
        #expect(reloaded.thread(thread.id)?.items.first?.text.hasSuffix("498 499 ") == true)
    }

    @Test func observersRunInTheOrderTheyRegistered() {
        let store = AppStore(directory: directory)
        var calls: [Int] = []
        let tokens = (0..<20).map { index in store.observe { _ in calls.append(index) } }
        store.notify(.settings)
        #expect(calls == Array(0..<20))
        _ = tokens
    }

    @Test func relocatingAProjectFollowsTheFolder() {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp/old-name"))
        store.relocateProject(project.id, to: URL(fileURLWithPath: "/tmp/elsewhere/new-name/"))
        #expect(store.project(project.id)?.path == "/tmp/elsewhere/new-name")
        #expect(store.project(project.id)?.name == "new-name")
        store.updateProject(project.id) { $0.name = "Custom" }
        store.relocateProject(project.id, to: URL(fileURLWithPath: "/tmp/third"))
        #expect(store.project(project.id)?.name == "Custom")
    }
}
