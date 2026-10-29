import Foundation
import Testing

@testable import CoincideKit

/// The agent looks at a thread's title again after its first reply and its fifth turn, never once the user named it.
@MainActor
struct ThreadTitleRefreshTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-titles-\(UUID().uuidString)")
    private let store: AppStore
    private let projectID: UUID

    init() {
        store = AppStore(directory: directory)
        store.updateSettings { $0.checkpointsEnabled = false }
        projectID = store.addProject(at: URL(fileURLWithPath: "/tmp")).id
    }

    private func makeThread(userTurns: Int, refreshes: [TitleRefresh]?) -> ChatThread {
        var thread = ChatThread(projectID: projectID, title: "hi", selection: ModelSelection(provider: .claude, modelID: "m"))
        for turn in 0..<userTurns {
            thread.items.append(TranscriptItem(kind: .user, text: "message \(turn)"))
            thread.items.append(TranscriptItem(kind: .assistant, text: "reply \(turn)"))
        }
        thread.titleRefreshes = refreshes
        return thread
    }

    private static func decoder(checkingFields: Bool = true) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if checkingFields { decoder.userInfo[.checksUnreadContent] = true }
        return decoder
    }

    // MARK: Who named the thread

    @Test func renamingMarksTheTitleTheUsersAndSurvivesARelaunch() throws {
        let id = store.createThread(in: projectID).id
        #expect(store.summary(id)?.isTitleCustom == false)
        store.renameThread(id, to: "Login screen")
        #expect(store.thread(id)?.title == "Login screen")
        #expect(store.thread(id)?.isTitleCustom == true)
        #expect(store.summary(id)?.isTitleCustom == true)
        store.flush()
        let reloaded = AppStore(directory: directory)
        #expect(reloaded.summary(id)?.isTitleCustom == true)
        #expect(reloaded.thread(id)?.isTitleCustom == true)
    }

    @Test func theAgentsTitleIsNotTheUsers() throws {
        let id = store.createThread(in: projectID).id
        store.updateThread(id) { $0.title = "hi" }
        #expect(ThreadTitles.apply(#"{"title": "Login screen email"}"#, to: id, replacing: "hi", store: store))
        let thread = try #require(store.thread(id))
        #expect(thread.title == "Login screen email")
        #expect(thread.titledByUser == nil && !thread.isTitleCustom)
        #expect(store.summary(id)?.isTitleCustom == false)
    }

    // MARK: When the agent looks again

    @Test func refreshesComeAfterTheFirstReplyAndTheFifthTurnOnlyOnce() {
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 1, refreshes: [])) == .firstReply)
        // Turns before the fifth have nothing new to look at once the first reply was.
        for turns in 1..<5 {
            #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: turns, refreshes: [.firstReply])) == nil)
        }
        // A thread whose first turns failed gets its first look at its first completed one.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 3, refreshes: [])) == .firstReply)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 5, refreshes: [.firstReply])) == .fifthTurn)
        // A fifth turn that failed leaves the look to the next completed one.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 6, refreshes: [.firstReply])) == .fifthTurn)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 5, refreshes: [.firstReply, .fifthTurn])) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 12, refreshes: [.firstReply, .fifthTurn])) == nil)
        // Never more than two: one that missed its first look gets only the later one.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 5, refreshes: [])) == .fifthTurn)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 9, refreshes: [.fifthTurn])) == nil)
        // Threads from before refreshes, imports and forks keep their titles.
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 1, refreshes: nil)) == nil)
        #expect(ThreadTitles.dueRefresh(for: makeThread(userTurns: 5, refreshes: nil)) == nil)
    }

    @Test func messagesSteeredIntoATurnDoNotCountAsTurns() {
        var steered = makeThread(userTurns: 4, refreshes: [.firstReply])
        steered.items.append(TranscriptItem(kind: .user, text: "also this", steered: true))
        #expect(ThreadTitles.dueRefresh(for: steered) == nil)
    }

    @Test func aThreadTheUserNamedOrArchivedIsLeftAlone() {
        var named = makeThread(userTurns: 1, refreshes: [])
        named.titledByUser = true
        #expect(ThreadTitles.dueRefresh(for: named) == nil)
        named.items += makeThread(userTurns: 4, refreshes: nil).items
        #expect(ThreadTitles.dueRefresh(for: named) == nil)
        var archived = makeThread(userTurns: 1, refreshes: [])
        archived.isArchived = true
        #expect(ThreadTitles.dueRefresh(for: archived) == nil)
    }

    @Test func aRefreshIsCountedWhenAskedAndOnlyWhenTitlingIsOn() throws {
        let registry = ProviderRegistry(store: store, providers: [ScriptedProvider(kind: .claude)])
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id
        store.append(TranscriptItem(kind: .user, text: "hi"), to: id)
        store.append(TranscriptItem(kind: .assistant, text: "Hello"), to: id)
        store.updateThread(id) { $0.titleRefreshes = [] }

        store.updateSettings { $0.generatesThreadTitles = false }
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry) == nil)
        #expect(store.thread(id)?.titleRefreshes == [])

        store.updateSettings { $0.generatesThreadTitles = true }
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry) == .firstReply)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply])
        #expect(ThreadTitles.refreshIfDue(threadID: id, store: store, registry: registry) == nil)
        store.flush()
        #expect(AppStore(directory: directory).thread(id)?.titleRefreshes == [.firstReply])
    }

    // MARK: Applying an answer

    @Test func anAnswerToAnOutdatedTitleOrARenamedThreadIsIgnored() throws {
        let id = store.createThread(in: projectID).id
        store.updateThread(id) { $0.title = "Login screen" }
        // The title changed while the agent thought.
        #expect(!ThreadTitles.apply(#"{"title": "Remember the email"}"#, to: id, replacing: "hi", store: store))
        #expect(store.summary(id)?.title == "Login screen")
        // Unusable answers change nothing.
        #expect(!ThreadTitles.apply(nil, to: id, replacing: "Login screen", store: store))
        #expect(!ThreadTitles.apply("no json here", to: id, replacing: "Login screen", store: store))
        // The user named it, even with the same text.
        store.renameThread(id, to: "Login screen")
        #expect(!ThreadTitles.apply(#"{"title": "Remember the email"}"#, to: id, replacing: "Login screen", store: store))
        #expect(store.summary(id)?.title == "Login screen")
    }

    // MARK: What a refresh sends

    @Test func aRefreshSendsOnlyTrimmedPartsOfTheThread() throws {
        let long = String(repeating: "word ", count: 400)
        var thread = makeThread(userTurns: 0, refreshes: [])
        thread.items = [
            TranscriptItem(kind: .user, text: "First " + long),
            TranscriptItem(kind: .assistant, text: "Old reply " + long),
            TranscriptItem(kind: .user, text: "Latest\n\n" + long),
            TranscriptItem(kind: .tool, text: "tool output " + long),
            TranscriptItem(kind: .assistant, text: "New   reply\nstarts " + long),
            TranscriptItem(kind: .assistant, text: "and goes on"),
        ]
        let parts = try #require(ThreadTitles.RefreshParts(thread))
        #expect(parts.firstMessage.count == ThreadTitles.refreshMessageLimit && parts.firstMessage.hasPrefix("First word"))
        let latest = try #require(parts.latestMessage)
        #expect(latest.count == ThreadTitles.refreshMessageLimit && latest.hasPrefix("Latest word"))
        #expect(parts.latestReply.count == ThreadTitles.refreshReplyLimit && parts.latestReply.hasPrefix("New reply starts"))
        #expect(!parts.latestReply.contains("Old") && !parts.latestReply.contains("tool"))

        let title = String(repeating: "t", count: 500)
        let prompt = ThreadTitles.refreshPrompt(title: title, parts: parts)
        #expect(prompt.contains("<title>\n\(String(repeating: "t", count: ThreadTitles.refreshTitleLimit - 1))…\n</title>"))
        #expect(prompt.contains("answer with it unchanged"))
        #expect(prompt.contains("\"title\"") && prompt.contains("fewer than 40 characters"))
        #expect(prompt.contains("<message>\n\(parts.firstMessage)\n</message>"))
        #expect(prompt.contains("<message>\n\(latest)\n</message>"))
        #expect(prompt.contains("<reply>\n\(parts.latestReply)\n</reply>"))
        // Short of the brief itself, the whole request stays small.
        #expect(prompt.count < ThreadTitles.prompt(message: "").count + 1_800)

        // After the first turn, the first message is the latest one and is sent once.
        let first = try #require(ThreadTitles.RefreshParts(makeThread(userTurns: 1, refreshes: [])))
        #expect(first == ThreadTitles.RefreshParts(firstMessage: "message 0", latestMessage: nil, latestReply: "reply 0"))
        let onePrompt = ThreadTitles.refreshPrompt(title: "hi", parts: first)
        #expect(onePrompt.components(separatedBy: "<message>").count == 2)
        #expect(!onePrompt.contains("latest message"))
        // A thread with no message to go by is not looked at.
        #expect(ThreadTitles.RefreshParts(makeThread(userTurns: 0, refreshes: [])) == nil)
    }

    // MARK: Files

    @Test func newFieldsRoundTripAndOldFilesReadAsNotCustom() throws {
        let id = store.createThread(in: projectID).id
        store.renameThread(id, to: "Mine")
        store.updateThread(id) { $0.titleRefreshes = [.firstReply, .fifthTurn] }
        store.flush()
        let file = directory.appendingPathComponent("threads/\(id.uuidString).json")
        let data = try Data(contentsOf: file)
        let read = try Self.decoder().decode(ThreadFile.self, from: data)
        #expect(!read.hasUnreadContent)
        #expect(read.thread.isTitleCustom && read.thread.titleRefreshes == [.firstReply, .fifthTurn])
        #expect(try Self.decoder().decode(ThreadSummaryFile.self, from: data).summary.isTitleCustom)

        // A thread never renamed nor refreshed is written as before.
        let plain = store.createThread(in: projectID).id
        store.flush()
        let plainJSON = try String(contentsOf: directory.appendingPathComponent("threads/\(plain.uuidString).json"), encoding: .utf8)
        #expect(!plainJSON.contains("titledByUser") && !plainJSON.contains("titleRefreshes"))

        let base = #""id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","title":"Old""#
        let old = try Self.decoder().decode(ThreadFile.self, from: Data("{\(base)}".utf8))
        #expect(!old.thread.isTitleCustom && old.thread.titledByUser == nil && old.thread.titleRefreshes == nil)
        #expect(!old.hasUnreadContent)

        let cases: [(json: String, custom: Bool, refreshes: [TitleRefresh]?, unread: Bool)] = [
            ("{\(base),\"titledByUser\":true}", true, nil, false),
            ("{\(base),\"titledByUser\":false,\"titleRefreshes\":[]}", false, [], false),
            ("{\(base),\"titledByUser\":null,\"titleRefreshes\":null}", false, nil, false),
            // What this version cannot read is left out, and the file is copied aside before it is saved.
            ("{\(base),\"titledByUser\":\"yes\"}", false, nil, true),
            ("{\(base),\"titleRefreshes\":[\"firstReply\",\"tenthTurn\"]}", false, [.firstReply], true),
        ]
        for entry in cases {
            let data = Data(entry.json.utf8)
            let file = try Self.decoder().decode(ThreadFile.self, from: data)
            #expect(file.thread.isTitleCustom == entry.custom, "\(entry.json)")
            #expect(file.thread.titleRefreshes == entry.refreshes, "\(entry.json)")
            #expect(file.hasUnreadContent == entry.unread, "\(entry.json)")
            // Reading only the summary agrees with reading the thread.
            let summary = try Self.decoder(checkingFields: false).decode(ThreadSummaryFile.self, from: data).summary
            #expect(summary == ThreadSummary(file.thread), "\(entry.json)")
        }
    }

    // MARK: Through the runner

    @Test func theRunnerRefreshesAfterTheFirstReplyAndTheFifthTurnButNotARenamedThread() async throws {
        let claude = ScriptedProvider(kind: .claude)
        let recorder = PromptRecorder()
        var titlePrompts: [String] { recorder.prompts }
        claude.configure = { session in
            session.onSend = { session, input in
                let reply: String
                if input.message.contains("Check the title of a coding thread") {
                    recorder.prompts.append(input.message)
                    reply = recorder.prompts.count == 1 ? #"{"title": "Fix the login bug"}"# : #"{"title": "Ship the login fix"}"#
                } else if input.message.contains("Generate a title") {
                    reply = #"{"title": "Greeting"}"#
                } else {
                    reply = "Let's fix the login bug."
                }
                session.emit(.assistantText(itemID: UUID().uuidString, text: reply))
                session.emit(.turnCompleted(.completed))
            }
        }
        let registry = ProviderRegistry(store: store, providers: [claude])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let id = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id

        func eventually(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<1_000 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        await runner.send(threadID: id, text: "hi")
        #expect(await eventually { store.summary(id)?.title == "Fix the login bug" })
        #expect(titlePrompts.count == 1)
        // The refresh waited for the first title and looked at it.
        #expect(titlePrompts.first?.contains("<title>\nGreeting\n</title>") == true)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply])

        for turn in 2...4 {
            await runner.send(threadID: id, text: "message \(turn)")
            #expect(await eventually { !runner.isRunning(id) })
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(titlePrompts.count == 1)

        await runner.send(threadID: id, text: "now ship it")
        #expect(await eventually { store.summary(id)?.title == "Ship the login fix" })
        #expect(titlePrompts.count == 2 && titlePrompts.last?.contains("now ship it") == true)
        #expect(store.thread(id)?.titleRefreshes == [.firstReply, .fifthTurn])

        await runner.send(threadID: id, text: "one more")
        #expect(await eventually { !runner.isRunning(id) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(titlePrompts.count == 2)

        // A thread the user named before its first message keeps the name, and the agent never titles it.
        let named = store.createThread(in: projectID, selection: ModelSelection(provider: .claude, modelID: "m")).id
        store.renameThread(named, to: "My name")
        await runner.send(threadID: named, text: "hi")
        #expect(await eventually { !runner.isRunning(named) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.summary(named)?.title == "My name")
        #expect(titlePrompts.count == 2)
        #expect(store.thread(named)?.titleRefreshes == nil)
    }
}

/// The title prompts a scripted agent was sent.
@MainActor
private final class PromptRecorder {
    var prompts: [String] = []
}
