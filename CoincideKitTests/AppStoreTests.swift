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

    /// Pi, fx and Muse Code are no longer built in, so their raw values read as unknown providers. What a build that
    /// had them saved still loads: their provider settings are skipped and the rest kept, a selection on one falls back
    /// as an unknown provider's does, and transcript items labelled with one keep everything but the label.
    @Test func settingsAndThreadsOfRemovedProvidersStillLoad() throws {
        for raw in ["pi", "fx", "muse"] { #expect(ProviderKind(rawValue: raw) == nil) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = """
            {"defaultSelection":{"provider":"fx","modelID":"default","effort":"medium"},"defaultAccessMode":"approval",
             "providers":["pi",{"isEnabled":true,"executablePath":"/opt/pi"},"codex",{"isEnabled":false,"customModels":["gpt-x"]},
                          "fx",{"isEnabled":true},"muse",{"isEnabled":true,"environment":{"KEY":"value"}}],
             "fontSize":15}
            """
        try Data(settings.utf8).write(to: directory.appendingPathComponent("settings.json"))
        let store = AppStore(directory: directory)
        #expect(store.settings.providers == [.codex: ProviderSettings(isEnabled: false, customModels: ["gpt-x"])])
        #expect(store.settings.defaultSelection == ModelSelection(provider: .claude, modelID: "default"))
        #expect(store.settings.defaultAccessMode == .approval)
        #expect(store.settings.fontSize == 15)

        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.flush()
        let json = """
            {"id":"\(thread.id.uuidString)","projectID":"\(project.id.uuidString)","title":"Earlier",
             "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z",
             "selection":{"provider":"fx","modelID":"default","effort":"medium"},"accessMode":"fullAccess","interactionMode":"plan",
             "items":[
               {"id":"\(UUID().uuidString)","kind":"user","text":"hello","createdAt":"2026-10-01T10:00:00Z"},
               {"id":"\(UUID().uuidString)","kind":"assistant","text":"from pi","provider":"pi","modelID":"p1",
                "createdAt":"2026-10-01T10:00:00Z"},
               {"id":"\(UUID().uuidString)","kind":"tool","text":"out","provider":"fx","category":"command","status":"completed",
                "createdAt":"2026-10-01T10:00:00Z"},
               {"id":"\(UUID().uuidString)","kind":"assistant","text":"from muse","provider":"muse","createdAt":"2026-10-01T10:00:00Z"}
             ],
             "sessions":["pi",{"sessionID":"p","seenItemCount":2},"claude",{"sessionID":"c1","seenItemCount":1},
                         "fx",{"sessionID":"f","seenItemCount":3},"muse",{"sessionID":"m","seenItemCount":4}]}
            """
        try Data(json.utf8).write(to: threadFile(thread.id))
        // The index as that build wrote it: the thread's summary names fx and the removed agents' sessions.
        let indexing = AppStore(directory: directory)
        indexing.flush()
        var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexFile)) as? [String: Any])
        var entries = try #require(index["entries"] as? [[String: Any]])
        var summary = try #require(entries.first?["summary"] as? [String: Any])
        summary["selection"] = ["provider": "fx", "modelID": "default", "effort": "medium"]
        summary["sessionProviders"] = ["claude", "fx", "muse", "pi"]
        entries[0]["summary"] = summary
        index["entries"] = entries
        try JSONSerialization.data(withJSONObject: index).write(to: indexFile)

        let reloaded = AppStore(directory: directory)
        // The index entry is read past and the file read again.
        #expect(reloaded.summaryReads == 1)
        let listed = try #require(reloaded.summary(thread.id))
        #expect(listed.selection == ModelSelection(provider: .claude, modelID: "default"))
        #expect(listed.sessionProviders == [.claude])
        #expect(listed.itemCount == 4)
        let loaded = try #require(reloaded.thread(thread.id))
        #expect(loaded.title == "Earlier")
        #expect(loaded.selection == ModelSelection(provider: .claude, modelID: "default"))
        #expect(loaded.accessMode == .fullAccess && loaded.interactionMode == .plan)
        #expect(loaded.items.map(\.text) == ["hello", "from pi", "out", "from muse"])
        #expect(loaded.items.allSatisfy { $0.provider == nil })
        #expect(loaded.items[1].modelID == "p1")
        #expect(loaded.items[2].category == .command && loaded.items[2].status == .completed)
        #expect(loaded.sessions == [.claude: ProviderSessionRef(sessionID: "c1", seenItemCount: 1)])

        // The first save keeps the file as that build wrote it beside the thread (see ThreadFileTests).
        reloaded.append(TranscriptItem(kind: .user, text: "next"), to: thread.id)
        reloaded.flush()
        let copies = try FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path).filter { $0.contains(".unreadable-") }
        #expect(copies.count == 1)
        #expect(AppStore(directory: directory).thread(thread.id)?.items.count == 5)
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

    // MARK: Transcripts read on demand

    private var threadsDirectory: URL { directory.appendingPathComponent("threads") }
    private var indexFile: URL { directory.appendingPathComponent("thread-index.json") }

    /// Encodes like the store, as every version so far has written thread files.
    private static func encode(_ thread: ChatThread) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(thread)
    }

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Saves `count` threads titled "Thread <n>" with long transcripts through a store that is then dropped.
    /// Thread n was updated n seconds after `base`, so the newest is last.
    private func seedThreads(_ count: Int, items: Int = 40) -> (projectID: UUID, ids: [UUID]) {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        var ids: [UUID] = []
        for number in 0..<count {
            let id = store.createThread(in: project.id).id
            store.updateThread(id) { thread in
                thread.title = "Thread \(number)"
                thread.items = (0..<items).map { index in
                    TranscriptItem(kind: index % 2 == 0 ? .user : .assistant, text: String(repeating: "word ", count: 400))
                }
                thread.updatedAt = Self.base.addingTimeInterval(Double(number))
            }
            ids.append(id)
        }
        store.flush()
        return (project.id, ids)
    }

    private func file(_ id: UUID) -> URL { threadFile(id) }

    private func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func launchingListsEveryThreadWithoutReadingATranscript() {
        let (projectID, ids) = seedThreads(30)
        let store = AppStore(directory: directory)
        #expect(store.threadSummaries.count == 30)
        #expect(store.summaryReads == 0)
        #expect(store.transcriptReads == 0)
        #expect(store.loadedTranscriptCount == 0)
        // Listing, sorting and looking up metadata read nothing either.
        let listed = store.threads(in: projectID)
        #expect(listed.map(\.id) == ids.reversed())
        #expect(listed.allSatisfy { $0.itemCount == 40 && $0.hasUserMessages && !$0.hasDraft })
        #expect(store.recentThreads.first?.title == "Thread 29")
        #expect(store.summary(ids[0])?.title == "Thread 0")
        #expect(store.workingDirectory(for: ids[0])?.path == "/tmp")
        #expect(store.parentThread(of: ids[0]) == nil && store.forks(of: ids[0]).isEmpty)
        #expect(store.transcriptReads == 0)
        #expect(store.loadedTranscriptCount == 0)
    }

    @Test func openingAThreadReadsOnlyItsTranscript() throws {
        let (_, ids) = seedThreads(10)
        let store = AppStore(directory: directory)
        let thread = try #require(store.thread(ids[3]))
        #expect(thread.title == "Thread 3")
        #expect(thread.items.count == 40)
        #expect(store.transcriptReads == 1)
        #expect(store.loadedTranscriptCount == 1)
        #expect(store.isTranscriptLoaded(ids[3]))
        // It stays in memory for the next look.
        #expect(store.item(thread.items[5].id, in: ids[3])?.id == thread.items[5].id)
        #expect(store.thread(ids[3])?.items == thread.items)
        #expect(store.transcriptReads == 1)
        // An unknown thread reads nothing.
        #expect(store.thread(UUID()) == nil)
        #expect(store.transcriptReads == 1)
    }

    @Test func theLeastRecentlyUsedTranscriptsLeaveMemory() {
        let (_, ids) = seedThreads(6)
        let store = AppStore(directory: directory)
        store.transcriptCacheLimit = 2
        for id in ids.prefix(5) { _ = store.thread(id) }
        #expect(store.loadedTranscriptCount == 2)
        #expect(store.isTranscriptLoaded(ids[3]) && store.isTranscriptLoaded(ids[4]))
        // Using one makes it the most recent, so the other goes first.
        _ = store.thread(ids[3])
        _ = store.thread(ids[5])
        #expect(store.isTranscriptLoaded(ids[3]) && store.isTranscriptLoaded(ids[5]) && !store.isTranscriptLoaded(ids[4]))
        #expect(store.transcriptReads == 6)
        // Reading it again gives the same transcript.
        #expect(store.thread(ids[0])?.items.count == 40)
        store.transcriptCacheLimit = 0
        #expect(store.loadedTranscriptCount == 0)
    }

    @Test func unsavedChangesKeepATranscriptInMemoryUntilTheyAreOnDisk() async throws {
        let (_, ids) = seedThreads(6)
        let store = AppStore(directory: directory)
        store.transcriptCacheLimit = 0
        store.saveDelay = 3_600
        store.append(TranscriptItem(kind: .user, text: "not saved yet"), to: ids[0])
        store.updateThread(ids[1]) { $0.title = "Renamed, not saved yet" }
        for id in ids[2...] { _ = store.thread(id) }
        #expect(store.isTranscriptLoaded(ids[0]) && store.isTranscriptLoaded(ids[1]))
        #expect(!store.isTranscriptLoaded(ids[2]))
        #expect(store.thread(ids[0])?.items.last?.text == "not saved yet")

        store.flush()
        // Once written and cooled down, they may leave like any other.
        #expect(await eventually { !store.isTranscriptLoaded(ids[0]) && !store.isTranscriptLoaded(ids[1]) })
        #expect(store.thread(ids[0])?.items.last?.text == "not saved yet")
        #expect(store.thread(ids[1])?.title == "Renamed, not saved yet")
        #expect(AppStore(directory: directory).thread(ids[0])?.items.count == 41)
    }

    @Test func aSaveThatFailsKeepsTheTranscriptUntilItIsWritten() async throws {
        let (_, ids) = seedThreads(3)
        let store = AppStore(directory: directory)
        store.transcriptCacheLimit = 0
        store.saveDelay = 0
        store.failedSaveRetryDelay = 0.05
        let folder = threadsDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        store.append(TranscriptItem(kind: .user, text: "keep me"), to: ids[0])
        try await Task.sleep(for: .milliseconds(400))
        _ = store.thread(ids[1])
        _ = store.thread(ids[2])
        #expect(store.isTranscriptLoaded(ids[0]))
        let onDisk = try String(contentsOf: file(ids[0]), encoding: .utf8)
        #expect(!onDisk.contains("keep me"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        #expect(await eventually { ((try? String(contentsOf: file(ids[0]), encoding: .utf8)) ?? "").contains("keep me") })
        #expect(await eventually { !store.isTranscriptLoaded(ids[0]) })
        #expect(store.thread(ids[0])?.items.last?.text == "keep me")
    }

    @Test func heldTranscriptsStayInMemory() {
        let (_, ids) = seedThreads(5)
        let store = AppStore(directory: directory)
        store.transcriptCacheLimit = 0
        var hold: TranscriptHold? = store.holdTranscript(ids[0])
        var second: TranscriptHold? = store.holdTranscript(ids[0])
        // A hold reads nothing by itself.
        #expect(store.transcriptReads == 0)
        _ = store.thread(ids[0])
        for id in ids[1...] { _ = store.thread(id) }
        #expect(store.isTranscriptLoaded(ids[0]))
        hold = nil
        _ = store.thread(ids[1])
        #expect(store.isTranscriptLoaded(ids[0]))
        second = nil
        #expect(!store.isTranscriptLoaded(ids[0]))
        _ = (hold, second)
    }

    @Test func aRunningTurnKeepsItsTranscriptInMemory() async throws {
        let (_, ids) = seedThreads(5)
        let store = AppStore(directory: directory)
        store.updateSettings { $0.checkpointsEnabled = false }
        let claude = ScriptedProvider(kind: .claude)
        let runner = ThreadRunner(store: store, registry: ProviderRegistry(store: store, providers: [claude]))
        store.updateThread(ids[0]) { $0.selection = ModelSelection(provider: .claude, modelID: "m") }
        store.transcriptCacheLimit = 0
        await runner.send(threadID: ids[0], text: "work on it")
        #expect(runner.isRunning(ids[0]))
        store.flush()
        try await Task.sleep(for: .milliseconds(300))
        for id in ids[1...] { _ = store.thread(id) }
        #expect(store.isTranscriptLoaded(ids[0]))

        claude.last?.emit(.assistantText(itemID: "a", text: "done"))
        claude.last?.emit(.turnCompleted(.completed))
        #expect(!runner.isRunning(ids[0]))
        // The finished turn is saved at once, and then the transcript can leave memory.
        #expect(await eventually { !store.isTranscriptLoaded(ids[0]) })
        #expect(store.thread(ids[0])?.items.suffix(2).map(\.text) == ["work on it", "done"])
    }

    @Test func itemsThisRunLeftRunningStayRunningWhenReadAgain() async throws {
        let store = AppStore(directory: directory)
        store.transcriptCacheLimit = 0
        store.saveDelay = 0
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let id = store.createThread(in: project.id).id
        store.append(TranscriptItem(kind: .tool, title: "Run", status: .running), to: id)
        #expect(await eventually { !store.isTranscriptLoaded(id) })
        // Its turn may still be running: only what an earlier run left is settled.
        #expect(store.thread(id)?.items.first?.status == .running)
        store.flush()
        #expect(AppStore(directory: directory).thread(id)?.items.first?.status == .failed)
    }

    @Test func summariesFollowEveryChangeAndAreSaved() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let id = store.createThread(in: project.id).id
        #expect(store.summary(id)?.itemCount == 0 && store.summary(id)?.hasUserMessages == false)
        let reply = store.append(TranscriptItem(kind: .assistant, text: "hi"), to: id)
        #expect(store.summary(id)?.hasUserMessages == false)
        store.append(TranscriptItem(kind: .user, text: "hello"), to: id)
        #expect(store.summary(id)?.itemCount == 2 && store.summary(id)?.hasUserMessages == true)
        #expect(store.summary(id)?.updatedAt == store.thread(id)?.updatedAt)
        store.updateThread(id) {
            $0.title = "Named"
            $0.isPinned = true
            $0.draft = "typing"
            $0.branch = "feature"
            $0.worktreePath = "/tmp/feature"
            $0.accessMode = .approval
            $0.interactionMode = .plan
            $0.sessions = [.codex: ProviderSessionRef(sessionID: "x", seenItemCount: 1), .claude: ProviderSessionRef(sessionID: "c", seenItemCount: 1)]
        }
        let summary = try #require(store.summary(id))
        #expect(summary == ThreadSummary(try #require(store.thread(id))))
        #expect(summary.title == "Named" && summary.isPinned && summary.hasDraft && summary.branch == "feature")
        #expect(summary.sessionProviders == [.claude, .codex])
        #expect(store.workingDirectory(for: id)?.path == "/tmp/feature")
        store.truncate(id, from: reply)
        #expect(store.summary(id)?.itemCount == 0 && store.summary(id)?.hasUserMessages == false)
        #expect(store.summary(id)?.sessionProviders == [])
        store.updateThread(id) { $0.draft = "  " }
        #expect(store.summary(id)?.hasDraft == true)
        store.updateThread(id) { $0.draft = nil }
        #expect(store.summary(id)?.hasDraft == false)
        store.flush()

        let reloaded = AppStore(directory: directory)
        #expect(reloaded.summaryReads == 0)
        let saved = try #require(reloaded.summary(id))
        #expect(saved.title == "Named" && saved.itemCount == 0 && saved.isPinned && saved.interactionMode == .plan)
        #expect(saved == ThreadSummary(try #require(reloaded.thread(id))))
    }

    @Test func sortingPinningAndArchivingHoldWithoutTranscripts() throws {
        let (projectID, ids) = seedThreads(5)
        let store = AppStore(directory: directory)
        store.updateThread(ids[1]) { $0.isPinned = true }
        store.updateThread(ids[3]) { $0.isArchived = true }
        let expected = [ids[1], ids[4], ids[2], ids[0]]
        #expect(store.threads(in: projectID).map(\.id) == expected)
        #expect(store.threads(in: projectID, includeArchived: true).map(\.id) == [ids[1], ids[4], ids[3], ids[2], ids[0]])
        // Recent threads go by time alone and leave archived ones out.
        #expect(store.recentThreads.map(\.id) == [ids[4], ids[2], ids[1], ids[0]])
        #expect(store.threads(in: UUID()).isEmpty)
        store.flush()

        let reloaded = AppStore(directory: directory)
        #expect(reloaded.threads(in: projectID).map(\.id) == expected)
        #expect(reloaded.recentThreads.map(\.id) == [ids[4], ids[2], ids[1], ids[0]])
        // A new item moves its thread up, without reading the others.
        reloaded.append(TranscriptItem(kind: .user, text: "again"), to: ids[0])
        #expect(reloaded.threads(in: projectID).map(\.id) == [ids[1], ids[0], ids[4], ids[2]])
        #expect(reloaded.recentThreads.first?.id == ids[0])
        #expect(reloaded.transcriptReads == 1)
        // Removing the project deletes its threads and their files.
        reloaded.removeProject(projectID)
        #expect(reloaded.threadSummaries.isEmpty)
        reloaded.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path).isEmpty)
        #expect(AppStore(directory: directory).threadSummaries.isEmpty)
    }

    @Test func theIndexIsRebuiltFromTheThreadFiles() throws {
        let (projectID, ids) = seedThreads(12)
        #expect(FileManager.default.fileExists(atPath: indexFile.path))
        let indexed = AppStore(directory: directory).threadSummaries
        try FileManager.default.removeItem(at: indexFile)

        let rebuilt = AppStore(directory: directory)
        #expect(rebuilt.summaryReads == 12)
        #expect(rebuilt.transcriptReads == 0 && rebuilt.loadedTranscriptCount == 0)
        #expect(rebuilt.threadSummaries == indexed)
        #expect(rebuilt.threads(in: projectID).map(\.id) == ids.reversed())
        rebuilt.flush()
        #expect(FileManager.default.fileExists(atPath: indexFile.path))
        #expect(AppStore(directory: directory).summaryReads == 0)
    }

    @Test func onlyFilesChangedSinceTheyWereIndexedAreReadAgain() throws {
        let (projectID, ids) = seedThreads(6)
        // Another version renames one thread and deletes another; a third thread appears.
        let renamed = try String(contentsOf: file(ids[2]), encoding: .utf8)
            .replacingOccurrences(of: #""title":"Thread 2""#, with: #""title":"Renamed elsewhere, and longer""#)
        try Data(renamed.utf8).write(to: file(ids[2]))
        try FileManager.default.removeItem(at: file(ids[4]))
        let added = ChatThread(
            projectID: projectID, title: "Added elsewhere", selection: ModelSelection(provider: .codex, modelID: "x"),
            items: [TranscriptItem(kind: .user, text: "hi")], createdAt: Self.base.addingTimeInterval(100))
        try Self.encode(added).write(to: file(added.id))

        let store = AppStore(directory: directory)
        #expect(store.summaryReads == 2)
        #expect(store.transcriptReads == 0)
        #expect(store.summary(ids[2])?.title == "Renamed elsewhere, and longer")
        #expect(!store.hasThread(ids[4]))
        #expect(store.summary(added.id)?.selection.provider == .codex)
        #expect(store.threads(in: projectID).map(\.id) == [added.id, ids[5], ids[3], ids[2], ids[1], ids[0]])
        store.flush()
        let again = AppStore(directory: directory)
        #expect(again.summaryReads == 0)
        #expect(again.threadSummaries == store.threadSummaries)
    }

    @Test func anUnreadableIndexIsRebuiltRatherThanSetAside() throws {
        let (projectID, ids) = seedThreads(4)
        try Data("{ not json".utf8).write(to: indexFile)
        let store = AppStore(directory: directory)
        #expect(store.summaryReads == 4)
        #expect(store.threads(in: projectID).map(\.id) == ids.reversed())
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".unreadable-") })
        #expect(AppStore(directory: directory).summaryReads == 0)

        // An index another version wrote, with entries this one cannot read, is read past them.
        try Data(#"{"version":99,"entries":[{"what":"ever"}]}"#.utf8).write(to: indexFile)
        #expect(AppStore(directory: directory).summaryReads == 4)
        AppStore(directory: directory).flush()
        var index = try String(contentsOf: indexFile, encoding: .utf8)
        index = index.replacingOccurrences(of: #""entries":["#, with: #""entries":[{"file":"broken"},"#)
        try Data(index.utf8).write(to: indexFile)
        let partly = AppStore(directory: directory)
        #expect(partly.summaryReads == 0)
        #expect(partly.threadSummaries.count == 4)
    }

    @Test func threadsAnEarlierVersionSavedAreListedAndOpenWhole() throws {
        // A data folder as versions before the index left it: projects, thread files and a lineage sidecar.
        try FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        let project = Project(name: "app", path: "/tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([project]).write(to: directory.appendingPathComponent("projects.json"))
        let selection = ModelSelection(provider: .claude, modelID: "m")
        var threads: [ChatThread] = []
        for number in 0..<8 {
            var thread = ChatThread(
                projectID: project.id, title: "Old \(number)", selection: selection,
                items: [
                    TranscriptItem(kind: .user, text: "question \(number)"),
                    TranscriptItem(kind: .tool, title: "ls", status: .running),
                    TranscriptItem(kind: .approval, title: "Allow?", status: .waiting),
                ],
                sessions: [.claude: ProviderSessionRef(sessionID: "s\(number)", seenItemCount: 3)],
                isPinned: number == 2, isArchived: number == 5, createdAt: Self.base)
            thread.updatedAt = Self.base.addingTimeInterval(Double(number))
            threads.append(thread)
            try Self.encode(thread).write(to: file(thread.id))
        }
        let lineage = #"{"\#(threads[7].id.uuidString)":{"parentThreadID":"\#(threads[6].id.uuidString)","parentTitle":"Old 6","forkedAt":0}}"#
        try Data(lineage.utf8).write(to: directory.appendingPathComponent("thread-lineage.json"))
        let before = try threads.map { try Data(contentsOf: file($0.id)) }

        let store = AppStore(directory: directory)
        #expect(store.summaryReads == 8 && store.transcriptReads == 0)
        let order = [2, 7, 6, 4, 3, 1, 0].map { threads[$0].id }
        #expect(store.threads(in: project.id).map(\.id) == order)
        #expect(store.threads(in: project.id, includeArchived: true).count == 8)
        let summary = try #require(store.summary(threads[3].id))
        #expect(summary.itemCount == 3 && summary.hasUserMessages && summary.sessionProviders == [.claude])
        #expect(store.parentThread(of: threads[7].id)?.title == "Old 6")
        #expect(store.forks(of: threads[6].id).map(\.thread.id) == [threads[7].id])
        #expect(store.transcriptReads == 0)

        // Opening one gives the whole transcript; what the earlier run left unfinished is settled.
        let opened = try #require(store.thread(threads[3].id))
        #expect(opened.items.map(\.text) == threads[3].items.map(\.text))
        #expect(opened.items.map(\.status) == [nil, .failed, .declined])
        #expect(opened.sessions == threads[3].sessions)
        store.flush()
        // Launching and opening rewrote no thread file; only the index was added.
        #expect(try threads.map { try Data(contentsOf: file($0.id)) } == before)
        #expect(FileManager.default.fileExists(atPath: indexFile.path))
        #expect(AppStore(directory: directory).summaryReads == 0)
    }

    @Test func aThreadFileThatIsGoneOrUnreadableWhenOpenedDropsTheThread() throws {
        let (projectID, ids) = seedThreads(3)
        let store = AppStore(directory: directory)
        var changes: [StoreChange] = []
        let token = store.observe { changes.append($0) }
        try Data("garbage".utf8).write(to: file(ids[0]))
        try FileManager.default.removeItem(at: file(ids[1]))

        #expect(store.thread(ids[0]) == nil)
        #expect(!store.hasThread(ids[0]))
        #expect(changes.contains(.threadList))
        let names = try FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path)
        let aside = try #require(names.first { $0.hasPrefix("\(ids[0].uuidString).json.unreadable-") })
        #expect(try String(contentsOf: threadsDirectory.appendingPathComponent(aside), encoding: .utf8) == "garbage")
        store.append(TranscriptItem(kind: .user, text: "lost?"), to: ids[1])
        #expect(!store.hasThread(ids[1]))
        #expect(store.threads(in: projectID).map(\.id) == [ids[2]])
        #expect(store.thread(ids[2])?.items.count == 40)
        withExtendedLifetime(token) {}
        store.flush()

        let reloaded = AppStore(directory: directory)
        #expect(reloaded.summaryReads == 0)
        #expect(reloaded.threadSummaries.keys.sorted { $0.uuidString < $1.uuidString } == [ids[2]])
    }

    @Test func unreadableThreadFilesAreSetAsideAtLaunch() throws {
        let (projectID, ids) = seedThreads(3)
        // Damaged after it was indexed, and one never indexed.
        try Data("{ damaged".utf8).write(to: file(ids[0]))
        let stray = UUID()
        try Data("[]".utf8).write(to: file(stray))
        let store = AppStore(directory: directory)
        #expect(store.summaryReads == 2)
        #expect(store.threads(in: projectID).map(\.id) == [ids[2], ids[1]])
        let names = try FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path)
        #expect(names.contains { $0.hasPrefix("\(ids[0].uuidString).json.unreadable-") })
        #expect(names.contains { $0.hasPrefix("\(stray.uuidString).json.unreadable-") })
        #expect(!names.contains("\(ids[0].uuidString).json"))
    }

    @Test func aThreadInAFileNamedOtherwiseIsListedAndMovesToItsOwnFile() throws {
        try FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        let thread = ChatThread(
            projectID: UUID(), title: "By hand", selection: ModelSelection(provider: .claude, modelID: "m"),
            items: [TranscriptItem(kind: .user, text: "hello")])
        let handWritten = threadsDirectory.appendingPathComponent("by-hand.json")
        try Self.encode(thread).write(to: handWritten)

        let store = AppStore(directory: directory)
        #expect(store.summary(thread.id)?.title == "By hand")
        #expect(store.thread(thread.id)?.items.map(\.text) == ["hello"])
        store.append(TranscriptItem(kind: .assistant, text: "hi"), to: thread.id)
        store.flush()
        #expect(FileManager.default.fileExists(atPath: file(thread.id).path))

        // The file named after the thread wins over the older copy.
        let reloaded = AppStore(directory: directory)
        #expect(reloaded.threadSummaries.count == 1)
        #expect(reloaded.summary(thread.id)?.itemCount == 2)
        #expect(reloaded.thread(thread.id)?.items.map(\.text) == ["hello", "hi"])
        reloaded.deleteThread(thread.id)
        reloaded.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path).filter { $0.hasSuffix(".json") }.isEmpty)
    }
}

/// A summary read from a thread file must match the summary of the whole thread read from it.
struct ThreadSummaryTests {
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func readingOnlyTheSummaryAgreesWithReadingTheThread() throws {
        let id = #""id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)""#
        let item = { (kind: String) in #"{"id":"\#(UUID().uuidString)","kind":"\#(kind)","text":"t"}"# }
        let files = [
            "{\(id)}",
            #"{\#(id),"title":"T","createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-02T10:00:00Z","isPinned":true,"isArchived":true,"draft":"d","branch":"b","worktreePath":"/w"}"#,
            #"{\#(id),"createdAt":"2026-10-01T10:00:00Z","title":7,"accessMode":"readOnly","interactionMode":"plan","selection":{"provider":"future","modelID":"x"}}"#,
            #"{\#(id),"items":[\#(item("assistant")),"junk",{"kind":"user"},\#(item("hologram")),\#(item("user")),42]}"#,
            #"{\#(id),"items":{"not":"a list"},"draft":""}"#,
            #"{\#(id),"sessions":["future",{"sessionID":"f","seenItemCount":1},"codex",{"sessionID":"x","seenItemCount":9},"claude",{"sessionID":"c","seenItemCount":0}]}"#,
            #"{\#(id),"sessions":{"cursor":{"sessionID":"c","seenItemCount":1},"future":{"sessionID":"f","seenItemCount":1}}}"#,
            #"{\#(id),"selection":{"provider":"codex","modelID":"gpt","effort":"high"},"accessMode":"fullAccess"}"#,
        ]
        for json in files {
            let data = Data(json.utf8)
            let summary = try Self.decoder().decode(ThreadSummaryFile.self, from: data).summary
            let thread = try Self.decoder().decode(ThreadFile.self, from: data).thread
            #expect(summary == ThreadSummary(thread), "\(json)")
        }
        // What a thread file needs to be a thread at all, its summary needs too.
        for json in [#"{"id":"\#(UUID().uuidString)"}"#, #"{"projectID":"\#(UUID().uuidString)"}"#, "[]"] {
            #expect(throws: (any Error).self) { try Self.decoder().decode(ThreadSummaryFile.self, from: Data(json.utf8)) }
        }
    }
}

/// Coincide once let users add their own ACP agents (local commands and ACP Registry agents), saved as
/// `acpAgents` in the settings and run as `acp:<id>` providers. Files written then still load: those agents' entries
/// are skipped like any unknown provider's, and nothing else in them is lost.
@MainActor
struct RemovedACPAgentFilesTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-acp-agents-\(UUID().uuidString)")

    private var threadsDirectory: URL { directory.appendingPathComponent("threads") }
    private var indexFile: URL { directory.appendingPathComponent("thread-index.json") }

    private func copiesAside(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".unreadable-") }
    }

    @Test func settingsKeepEverythingButTheAddedAgents() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"""
            {"acpAgents":[
               {"id":"devin","name":"Devin","source":"registry","command":"","arguments":[],
                "registry":{"agentID":"devin","version":"3000.11.228","distribution":"npx","executable":"npm/bin/devin",
                            "arguments":["acp"],"environment":{"DEVIN_MODE":"acp"},"binDirectory":"npm/bin"}},
               {"id":"dsh","name":"DeepSeek Harness","source":"local","command":"dsh","arguments":["--profile","acp"]}],
             "providers":["codex",{"isEnabled":false},
                          "acp:devin",{"isEnabled":true,"customModels":["swe-1.5"],"environment":{"DEVIN_MODE":"acp"}},
                          "cursor",{"executablePath":"/opt/cursor-agent","customModels":["composer-2"]},
                          "acp:dsh",{"executablePath":"/opt/dsh"}],
             "defaultSelection":{"provider":"acp:dsh","modelID":"deepseek-v4","effort":"high"},
             "defaultAccessMode":"approval","fontSize":15,"sendOnReturn":false,"cursorKeychainUsageEnabled":true}
            """#
        let settingsFile = directory.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: settingsFile)

        let store = AppStore(directory: directory)
        let settings = store.settings
        #expect(
            settings.providers == [
                .codex: ProviderSettings(isEnabled: false),
                .cursor: ProviderSettings(executablePath: "/opt/cursor-agent", customModels: ["composer-2"]),
            ])
        // A default on an added agent falls back like one on any provider this version does not know.
        #expect(settings.defaultSelection == AppSettings().defaultSelection)
        #expect(settings.defaultAccessMode == .approval)
        #expect(settings.fontSize == 15)
        #expect(!settings.sendOnReturn)
        #expect(settings.cursorKeychainUsageEnabled)
        #expect(try copiesAside(in: directory).isEmpty)

        // The next save leaves the agents out and keeps the rest.
        store.updateSettings { $0.showReasoning = false }
        store.flush()
        let saved = try String(contentsOf: settingsFile, encoding: .utf8)
        #expect(!saved.contains("acpAgents") && !saved.contains("acp:"))
        var expected = settings
        expected.showReasoning = false
        #expect(AppStore(directory: directory).settings == expected)
    }

    @Test func threadsKeepTheirTranscriptsAndTheOtherAgentsSessions() throws {
        let first = AppStore(directory: directory)
        let project = first.addProject(at: URL(fileURLWithPath: "/tmp"))
        let id = first.createThread(in: project.id).id
        first.flush()
        // The thread as that version saved it: it ran on the added agent `devin`, then switched to Codex.
        let ids = (0..<4).map { _ in UUID().uuidString }
        let json = """
            {"id":"\(id.uuidString)","projectID":"\(project.id.uuidString)","title":"Try Devin",
             "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:05:00Z",
             "selection":{"provider":"acp:devin","modelID":"swe-1.5","effort":"high"},
             "accessMode":"approval","interactionMode":"plan","isPinned":true,"isArchived":false,
             "items":[
               {"id":"\(ids[0])","kind":"user","text":"Add a test","createdAt":"2026-10-01T10:00:00Z"},
               {"id":"\(ids[1])","kind":"assistant","text":"Added.","createdAt":"2026-10-01T10:01:00Z","provider":"acp:devin","modelID":"swe-1.5"},
               {"id":"\(ids[2])","kind":"user","text":"Continue with Codex","createdAt":"2026-10-01T10:02:00Z"},
               {"id":"\(ids[3])","kind":"assistant","text":"Done.","createdAt":"2026-10-01T10:03:00Z","provider":"codex","modelID":"gpt-5"}
             ],
             "sessions":["acp:devin",{"sessionID":"native-1","seenItemCount":2},"codex",{"sessionID":"c1","seenItemCount":4}]}
            """
        let file = threadsDirectory.appendingPathComponent("\(id.uuidString).json")
        try Data(json.utf8).write(to: file)

        let store = AppStore(directory: directory)
        let thread = try #require(store.thread(id))
        #expect(thread.title == "Try Devin" && thread.isPinned)
        #expect(thread.accessMode == .approval && thread.interactionMode == .plan)
        #expect(thread.selection == ModelSelection(provider: .claude, modelID: "default"))
        #expect(thread.items.map(\.text) == ["Add a test", "Added.", "Continue with Codex", "Done."])
        #expect(thread.items[1].provider == nil && thread.items[1].modelID == "swe-1.5")
        #expect(thread.items[3].provider == .codex)
        #expect(thread.sessions == [.codex: ProviderSessionRef(sessionID: "c1", seenItemCount: 4)])
        store.flush()

        // The index that version wrote names the agent too; its entry is read again from the file.
        var index = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: indexFile)) as? [String: Any])
        var entries = try #require(index["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        var summary = try #require(entries.first?["summary"] as? [String: Any])
        summary["selection"] = ["provider": "acp:devin", "modelID": "swe-1.5", "effort": "high"]
        summary["sessionProviders"] = ["acp:devin", "codex"]
        entries[0]["summary"] = summary
        index["entries"] = entries
        try JSONSerialization.data(withJSONObject: index).write(to: indexFile)
        let relaunched = AppStore(directory: directory)
        #expect(relaunched.summaryReads == 1)
        let listed = try #require(relaunched.summary(id))
        #expect(listed.title == "Try Devin" && listed.itemCount == 4)
        #expect(listed.selection == ModelSelection(provider: .claude, modelID: "default"))
        #expect(listed.sessionProviders == [.codex])

        // The first save copies the file aside, so the agent's selection and session are kept there.
        #expect(try copiesAside(in: threadsDirectory).isEmpty)
        relaunched.append(TranscriptItem(kind: .user, text: "Back to it"), to: id)
        relaunched.flush()
        let copy = try #require(try copiesAside(in: threadsDirectory).first)
        #expect(try String(contentsOf: threadsDirectory.appendingPathComponent(copy), encoding: .utf8) == json)
        #expect(AppStore(directory: directory).thread(id)?.items.map(\.text).last == "Back to it")
    }
}
